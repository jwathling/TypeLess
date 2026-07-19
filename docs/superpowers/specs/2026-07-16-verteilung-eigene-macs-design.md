# TypeLess auf eigene Macs verteilen und updaten — Design

**Datum:** 2026-07-16
**Status:** Entwurf zur Freigabe
**Meilenstein:** M8 (Teil: Verteilung & Selbst-Update)

## Ziel

TypeLess soll auf einem **frischen** Apple-Silicon-Mac (ohne Entwickler-Aufbau) über GitHub
installiert und danach **automatisch aktualisiert** werden können. Zielgruppe: ausschließlich die
**eigenen Geräte** des Anwenders. Der Datenschutz-Grundsatz bleibt unberührt — die Modelle und die
gesamte Verarbeitung bleiben lokal; über das Netz laufen nur der einmalige Modell-Download (von
Hugging Face) und die Update-Prüfung (bei GitHub).

## Nicht-Ziele (bewusst ausgeklammert)

- **Keine Weitergabe an Fremde.** Kein Apple-Entwicklerkonto, keine Notarisierung, kein
  „Developer ID"-Zertifikat. Die App wird mit einer **selbst-signierten** Identität signiert; auf
  einem fremden Mac käme die Gatekeeper-Warnung „unbekannter Entwickler". Falls Weitergabe je
  gewünscht wird, ist das ein eigener, späterer Schritt (Developer ID + Notarisierung).
- **Kein App Store.**
- **Keine Intel-Macs** (MLX läuft nur auf Apple Silicon / Metal).
- **Keine Modell-Auswahl-UI** (Wechsel turbo/small o. Ä.) — das ist M7-Thema, nicht hier.
- Die STT-Latenz wird **nicht** angefasst (siehe Erinnerung „STT-Latenz-Boden": bei `turbo`
  bleiben, Latenz-Thema ruht).

## Architektur-Überblick

Vier Bausteine, die zusammenspielen:

1. **Engine-Bündelung** — ein eigenständiges, „mitwanderndes" Python samt MLX-Umgebung fest im
   `.app`-Bündel. Die ausgelieferte App startet dieses eingebettete Python statt `uv run`.
2. **Modell-Bootstrap & Erststart-Fenster** — beim allerersten Start lädt die App die ~4 GB
   Modelle in einen Cache, der Updates überlebt, und zeigt den Fortschritt in einem einmaligen
   Einrichtungs-Fenster.
3. **Selbst-Update (Sparkle)** — die App prüft das öffentliche GitHub-Repo, meldet neue Versionen
   und tauscht sich per Klick selbst aus; die Berechtigungen bleiben dank stabiler Signatur.
4. **Build- & Release-Automatik** — ein `release`-Skript baut, signiert, verpackt und lädt die
   Version als GitHub-Release hoch. Plus das öffentliche Repo als Zuhause.

Leitprinzip: **Der bestehende Entwickler-Ablauf bleibt intakt.** Beim Bauen aus dem Projekt
(`swift build`, `uv run`) läuft alles wie bisher. Nur die *ausgelieferte* App nutzt das
eingebettete Python. Die App erkennt zur Laufzeit, in welchem Modus sie läuft.

---

## Baustein 1: Engine-Bündelung

### Ansatz (bevorzugt)

Ein **relocatable** Python (python-build-standalone, wie es auch `uv` verwendet) plus die
installierten MLX-Pakete werden ins App-Bündel unter `Contents/Resources/engine/` gelegt:

```
TypeLess.app/Contents/
  MacOS/TypeLess                     # Swift-Binary (wie bisher)
  Resources/engine/
    python/                          # eingebettetes, verschiebbares Python 3.11
    site-packages/ (o. venv/)        # numpy, mlx-whisper, mlx-lm, fastapi, uvicorn, …
    typeless_engine/                 # der Engine-Quellcode
```

Die App startet dann statt `uv run python -m typeless_engine.server`:

```
<Bundle>/Contents/Resources/engine/python/bin/python3 -m typeless_engine.server
```

### Bundled-vs-Dev-Erkennung

Der `SidecarLifecycle` bekommt das auszuführende Programm und Arbeitsverzeichnis heute schon von
außen (`ProcessRunner.run(executable:arguments:workingDirectory:…)`) — die **Lebenszyklus-Logik
(Übernahme, sauberes Beenden) ändert sich nicht**. Neu ist nur, *wie* diese Werte bestimmt werden:

- Existiert die eingebettete Engine unter `Bundle.main.resourceURL/engine/`, läuft die App im
  **Bundled-Modus**: `executable` = eingebettetes Python, `workingDirectory` = eingebettete
  Engine, plus die Cache-Umgebungsvariablen (Baustein 2).
- Sonst **Dev-Modus** (wie heute): `uvPath` + `engineDirectory` aus `SettingsStore`.

Diese Auswahl ist eine kleine, **reine Funktion** (Eingaben: „Ressource vorhanden?" + Settings →
Ausgabe: executable/args/workingDirectory/env) und damit ohne echtes Bundle unit-testbar. Der
`SettingsStore`-Default `~/Projekte/TypeLess/engine` bleibt als Dev-Fallback erhalten.

### Machbarkeits-Test zuerst (Risiko-Absicherung)

Python + MLX portabel zu machen, ist der eine Teil, der scheitern *kann* (native Metal-Bausteine,
`@rpath`/dylib-Pfade, ggf. `numba`). Deshalb ist der **erste Schritt** des Umsetzungsplans ein
Spike: das gebündelte Python in einer Umgebung **ohne** `uv` und **ohne** das Projektverzeichnis
starten und ein echtes Diktat verarbeiten. Erst wenn das grün ist, wird darauf aufgebaut.

### Plan B (Rückfall, falls die Bündelung sich als zu sperrig erweist)

Statt Python vollständig einzubetten, liefert die App eine **standalone `uv`-Binary** mit und
richtet die Umgebung beim ersten Start selbst ein (`uv sync` in ein Verzeichnis unter Application
Support). Preis: Der erste Start braucht zusätzlich Zeit/Netz für die Python-Pakete. Vorteil:
robuster gegen die dylib-Fallen. Wird nur gezogen, wenn der Spike zeigt, dass das volle Einbetten
unverhältnismäßig ist — die Entscheidung fällt **nach** dem Spike, nicht blind.

### Größe

Die MLX-Umgebung ist aktuell ~1,2 GB, mit eingebettetem Python landet das Bündel bei grob
**~1,3–1,5 GB** — unter der GitHub-Grenze von 2 GB pro Datei. `numba` (transitiv über mlx-whisper,
zur Laufzeit nur für Wort-Zeitstempel nötig, die wir nicht nutzen) ist ein Kandidat zum späteren
Ausdünnen, aber **nicht kritisch** für dieses Vorhaben.

---

## Baustein 2: Modell-Bootstrap & Erststart-Fenster

### Cache-Ort

Die Modelle (`whisper-large-v3-turbo` ~1,6 GB, `Qwen3-4B-Instruct-2507-4bit` ~2,3 GB) liegen in

```
~/Library/Application Support/TypeLess/models/
```

Erreicht wird das, indem der Engine-Prozess mit gesetztem `HF_HOME` (Hugging-Face-Cache-Wurzel) auf
diesen Pfad gestartet wird. Der Ort liegt **außerhalb** des App-Bündels und **überlebt damit
Updates** — spätere Updates laden die Modelle nie erneut.

### Ablauf beim ersten Start

1. Die App prüft, ob die benötigten Modelle im Cache liegen.
2. Fehlen sie, öffnet sich ein **einmaliges Einrichtungs-Fenster** („TypeLess wird eingerichtet …"
   mit Fortschrittsbalken) und die App stößt den Modell-Download in der Engine an.
3. Die Engine lädt die Modelle und meldet Fortschritt; die App zeigt ihn an.
4. Ist alles im Cache, schließt sich das Fenster und die App geht in den normalen Menüleisten-
   Betrieb. **Dieses Fenster erscheint nur dieses eine Mal** — die „kein Fenster beim Diktieren"-
   Regel der App bleibt vollständig erhalten.

### Engine-Schnittstelle für den Bootstrap

Der Server bekommt einen Weg, den Download **explizit** anzustoßen und den Fortschritt abzufragen,
statt ihn nur beiläufig beim ersten `transcribe`/`preload` passieren zu lassen:

- `POST /models/ensure` → `202`, startet den Download der von den **konfigurierten Backends**
  benötigten Modelle im Hintergrund (idempotent: bereits vorhandene Modelle werden übersprungen).
- Der Fortschritt wird über den bestehenden Status-Weg gemeldet: `GET /health` liefert zusätzlich
  einen optionalen `models`-Block:
  `{ state: "missing" | "downloading" | "ready", downloaded_bytes, total_bytes, current_file }`.

Welche Modelle nötig sind, weiß der jeweilige Backend (STT/LLM). Der Bootstrap fragt das über die
Backends/`factory` ab — der **Austauschbarkeits-Vertrag** (`transcribe`/`refine`) bleibt unberührt;
die Modell-Liste ist Infrastruktur, kein Teil des Kern-Vertrags. Ein neues Backend bringt seine
eigene Modell-Liste mit, sonst ändert sich nichts.

Fortschritts-Quelle: bevorzugt über einen Hugging-Face-Download-Callback (exakte Byte-Zahlen);
falls sich das als unzuverlässig erweist, als einfacher Rückfall die **Größe des Cache-Verzeichnis**
gegen die erwartete Gesamtgröße. Die genaue Mechanik ist Implementierungsdetail des Plans.

### Fehlerbehandlung

- **Kein/abgebrochenes Netz beim ersten Start:** Das Einrichtungs-Fenster zeigt einen klaren
  Fehler samt „Erneut versuchen"; die App bleibt bedienbar, hängt nicht. Ein halb geladener Cache
  wird beim nächsten Versuch fortgesetzt bzw. sauber neu geladen (Hugging Face macht das inkrementell).
- **Kein Diktat vor „ready":** Solange die Modelle fehlen, ist der Hotkey wirkungslos bzw. weist im
  Menü auf die laufende Einrichtung hin (kein stiller Fehlschlag).

---

## Baustein 3: Selbst-Update (Sparkle)

### Integration

Sparkle (Standard-Update-Framework für Mac-Apps außerhalb des App Store) wird als
Swift-Package-Abhängigkeit eingebunden. Die App prüft periodisch (und auf Wunsch manuell über das
Menü) einen **Appcast** (XML) im öffentlichen Repo, meldet neue Versionen und installiert sie nach
Bestätigung.

### Signatur & Vertrauen

- **Update-Signatur:** Sparkle verlangt für Updates eine **EdDSA-Signatur** (ed25519). Das
  Schlüsselpaar wird einmalig erzeugt; der private Schlüssel bleibt auf dem Build-Mac (gesichert,
  s. u.), der öffentliche steht in der App.
- **Berechtigungserhalt:** macOS bindet Mikrofon-/Bedienungshilfen-/Eingabeüberwachungs-Rechte an
  die **Code-Signatur-Identität** (Designated Requirement aus Zertifikat + Bundle-ID). Weil alle
  Versionen mit **derselben** stabilen selbst-signierten Identität („TypeLess Dev") und derselben
  Bundle-ID (`de.typeless.TypeLess`) signiert werden, bleiben die Rechte über alle Updates hinweg
  erhalten. Der Anwender erteilt sie **einmal pro Mac** beim ersten Start, danach nie wieder.
- Sparkle prüft zusätzlich, dass die neue Version dieselbe Signatur-Identität trägt wie die
  laufende (Schutz gegen untergeschobene Updates) — bei stabiler Identität unproblematisch.

### Appcast & Auslieferung

- Das Update-Paket ist ein **`.zip` des `.app`-Bündels** (~1,3–1,5 GB, unter der 2-GB-Grenze).
- `appcast.xml` liegt im Repo; die Sparkle-Feed-URL zeigt auf dessen Roh-URL
  (`raw.githubusercontent.com`). Jeder Eintrag nennt Version, Asset-URL (GitHub-Release),
  Dateigröße und EdDSA-Signatur.

---

## Baustein 4: Build- & Release-Automatik

### `release`-Skript

Ein Skript (Erweiterung des bestehenden `scripts/build-app.sh`) führt in einem Lauf aus:

1. Swift-App bauen (Release-Konfiguration).
2. Eingebettetes Python + MLX-Umgebung + Engine-Quellen ins Bündel legen.
3. Bündel mit der stabilen Identität „TypeLess Dev" signieren (`codesign`).
4. Bündel zu `TypeLess-<version>.zip` packen.
5. Update-Signatur erzeugen (Sparkles `sign_update` mit dem EdDSA-Schlüssel).
6. `appcast.xml` um den neuen Eintrag ergänzen.
7. Per `gh release create` das Zip als Release-Asset hochladen, `appcast.xml` committen/pushen.

Die Version kommt aus **einer** Quelle (Info.plist `CFBundleShortVersionString`), damit App,
Zip-Name und Appcast nie auseinanderlaufen.

### Signatur-Sicherung (wichtig für die Langlebigkeit)

Damit die Berechtigungs-Kette über Jahre hält, werden **beide** Schlüssel gesichert und dokumentiert:

- die selbst-signierte Code-Signing-Identität „TypeLess Dev" (Export aus dem Schlüsselbund, `.p12`),
- der private Sparkle-EdDSA-Schlüssel.

Gingen sie verloren (z. B. Mac-Neuaufsetzen ohne Backup), müsste der Anwender die Rechte auf allen
Geräten einmal neu erteilen und Sparkle könnte keine vertrauten Updates mehr signieren. Die
Sicherung ist Teil der Definition-of-Done, nicht optional.

### Repo

Öffentliches GitHub-Repo mit Quellcode, `appcast.xml` und den Releases. Aktuell hat das lokale
Projekt kein Remote; das Skript setzt ein bestehendes Remote voraus (einmalig `gh repo create`).

---

## Datenfluss end-to-end

**Frische Installation:**
```
GitHub-Release öffnen → TypeLess-x.y.z.zip laden → TypeLess.app nach /Applications
→ erster Start: Rechtsklick→Öffnen (einmalige Gatekeeper-Warnung)
→ Berechtigungen erteilen (einmal pro Mac)
→ Einrichtungs-Fenster: Modelle laden (~4 GB, ein paar Minuten)
→ „ready" → Menüleisten-Betrieb, ab jetzt offline
```

**Update:**
```
App prüft Appcast → „neue Version da" → Klick
→ Sparkle lädt Zip (~1,3–1,5 GB), verifiziert EdDSA + Identität, tauscht App aus
→ Neustart der App; Modelle bleiben im Cache; Berechtigungen bleiben erhalten
```

---

## Testing-Strategie

- **Bundled-vs-Dev-Auswahl:** reine Funktion → Unit-Tests (Ressource vorhanden/fehlt × Settings →
  erwartetes executable/args/workingDirectory/env).
- **Modell-Bootstrap-Zustandsautomat:** Unit-Tests mit Fakes (`missing → downloading(%) → ready`
  und der Fehlerpfad kein-Netz → „Erneut versuchen").
- **Einrichtungs-Fenster:** Das zugrunde liegende ViewModel wird testbar gehalten (Zustände, keine
  Logik in der View).
- **`release`-Skript:** idempotent, mit Trockenlauf prüfbar (Appcast-Eintrag korrekt, Version aus
  einer Quelle).
- **Engine-Server:** die neuen `/models/ensure` + `models`-Statusfelder mit den bestehenden
  Server-Tests (ohne echte Modelle, Mock-Backends).
- **Abnahme (Handprobe):** Der eigentliche Beweis ist eine **frische Installation** — idealerweise
  auf einem zweiten Mac, ersatzweise in einem **frischen macOS-Benutzerkonto** (kein `uv`, kein
  Projektverzeichnis, keine erteilten Rechte). Danach ein **Update** v→v+1 mit Nachweis, dass die
  Berechtigungen erhalten bleiben und die Modelle nicht erneut geladen werden.

---

## Risiken & offene Punkte

- **Python/MLX-Bündelung (Hauptrisiko):** durch den Machbarkeits-Spike zuerst abgesichert; Plan B
  (mitgeliefertes `uv`) steht bereit.
- **Sparkle mit selbst-signierter, nicht notarisierter App:** Updates werden über die EdDSA-Signatur
  verifiziert; die stabile Code-Signatur genügt für den Berechtigungserhalt. Im Spike/Handtest
  mit zu belegen.
- **Bündelgröße nahe der 2-GB-Grenze:** aktuell ~1,3–1,5 GB, komfortabel darunter; `numba`-
  Ausdünnen als Reserve vorgemerkt, falls die Umgebung wächst.

---

## Umsetzungs-Reihenfolge (Grobschnitt)

1. **Spike:** gebündeltes Python + MLX auf sauberer Umgebung starten und diktieren (Go/No-Go für
   Plan A vs. Plan B).
2. Bundled-vs-Dev-Auswahl im `SidecarLifecycle`/Composition-Root + `release`-Skript, das die
   Engine einbettet.
3. Modell-Cache-Umleitung + Engine-Bootstrap-Endpunkt + Statusfelder.
4. Erststart-Erkennung + Einrichtungs-Fenster (SwiftUI).
5. Sparkle-Integration + Appcast + EdDSA-Signatur.
6. `release`-Skript vervollständigen (signieren, packen, `gh release`), Schlüssel-Sicherung
   dokumentieren.
7. Abnahme: frische Installation + Update-Durchlauf.

Die Swift- und Engine-Anteile sind bewusst klein gehalten und je für sich testbar; die
Reihenfolge hält jeden Schritt lauffähig.
