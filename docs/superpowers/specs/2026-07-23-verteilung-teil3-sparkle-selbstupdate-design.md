# Verteilung Teil 3: Sparkle-Selbst-Update + Release-Automatik — Design

**Datum:** 2026-07-23
**Status:** Entwurf zur Freigabe
**Meilenstein:** M8 (Verteilung & Selbst-Update — abschließender Teil)
**Baut auf:** `docs/superpowers/specs/2026-07-16-verteilung-eigene-macs-design.md` (Bausteine 3+4).
Teil 1 (Engine-Bündelung) und Teil 2 (Modell-Bootstrap + Erststart-Fenster) sind bereits auf `main`.

## Ziel

TypeLess soll über GitHub **installiert** und danach **automatisch aktualisiert** werden können —
auf den eigenen Macs des Anwenders. Nach diesem Teil ist die Verteilungskette komplett: neue Version
bauen → ein `release`-Lauf → die installierte App meldet sie und tauscht sich per Klick selbst aus,
ohne dass Berechtigungen erneut erteilt werden müssen.

## Realitäts-Abgleich mit dem Ist-Stand (wichtig — korrigiert die alte Annahme)

Die Gesamt-Spec ging von einem **~1,3–1,5 GB** großen Bundle aus (eingebettetes Python + Modelle,
„Plan A"). Umgesetzt wurde in Teil 1 aber **„Plan B"**: Weder Python noch Modelle stecken im Bundle.

Gemessen am realen Stand:

| Bestandteil | Größe | Ort | Beim Update angefasst? |
|---|---|---|---|
| `TypeLess.app` (Swift-Binary + `uv` + Engine-Quellen) | **~44 MB** | das Bundle selbst | **ja** (wird ersetzt) |
| Python-/MLX-Umgebung | ~1 GB | `~/Library/Application Support/TypeLess/runtime` | nein (bleibt) |
| Modelle | ~3,9 GB | `~/Library/Application Support/TypeLess/models` | nein (bleibt) |

**Folgen für Teil 3:**
- Das Update-Zip ist **~44 MB** — weit unter der GitHub-2-GB-Grenze. Der frühere AirDrop-Gedanke
  („5 GB zu groß für GitHub") **entfällt vollständig**: Erstinstallation *und* Updates laufen über
  GitHub.
- Updates sind schnell. Modelle werden bei einem Update **nie** neu geladen (sie liegen extern).
- Ändert ein Update `uv.lock`, baut `uv run --frozen` die Umgebung beim nächsten Start automatisch
  inkrementell nach — kein Sonderpfad im Update nötig.

## Nicht-Ziele (unverändert aus der Gesamt-Spec)

- Keine Weitergabe an Fremde, kein Apple-Entwicklerkonto, keine Notarisierung, kein App Store.
  Selbst-signierte Identität „TypeLess Dev"; auf fremden Macs käme die Gatekeeper-Warnung.
- Keine Intel-Macs. Keine Änderung an STT-Latenz, Modellauswahl oder Diktat-Verhalten.
- **Kein Delta-/Patch-Update.** Sparkle unterstützt das; bei 44 MB Vollpaket lohnt es nicht (YAGNI).

---

## Baustein A: Sparkle-Integration (Swift)

### Einbindung

Sparkle wird als **Swift-Package-Abhängigkeit** in `apps/macos/Package.swift` aufgenommen und nur
mit dem `TypeLess`-Executable-Target verlinkt. **`TypeLessCore` bleibt frei von Sparkle** (und damit
UI-/framework-frei und weiter ohne Fenster testbar) — Sparkle ist reine App-Schicht.

### Update-Controller

Ein kleiner Typ in `Sources/TypeLess/` (z. B. `UpdaterController.swift`) kapselt Sparkles
`SPUStandardUpdaterController`. Betriebsart entsprechend der Anwender-Entscheidung
**„automatisch prüfen, aber vor Download/Installation fragen"**:

- `SUEnableAutomaticChecks = true` (Sparkle prüft periodisch von selbst),
- **kein** automatisches Herunterladen/Installieren (Sparkle fragt vor jedem Schritt),
- `SUScheduledCheckInterval` = **86400** (täglich; konservativ, kein Netz-Dauerlast).

### Menüpunkt

Das MenuBarExtra-Menü (`MenuContent.swift`) bekommt einen Eintrag **„Nach Updates suchen…"**, der
`updater.checkForUpdates()` auslöst. Er ist die manuelle Ergänzung zur automatischen Prüfung.

### Sichtbarkeit in einer LSUIElement-App

TypeLess läuft ohne Dock-Icon (`LSUIElement`). Sparkles Dialoge (》neue Version《, Fortschritt,
Neustart-Aufforderung) sind normale Fenster und würden hinter anderen Apps erscheinen. Wie beim
Einrichtungs-Fenster (Teil 2b) wird beim Anzeigen `NSApp.activate(ignoringOtherApps: true)` gerufen,
damit der Dialog nach vorn kommt. Sparkles `SPUStandardUserDriver` liefert die Dialoge selbst; die
App sorgt nur für die Aktivierung (Sparkle-Delegate-Haken `updater(_:willShowModalAlert:)` o. ä.).

### Info.plist-Schlüssel

`build-app.sh` erzeugt die `Info.plist`. Ergänzt werden:

- `SUFeedURL` — Roh-URL der `appcast.xml` im GitHub-Repo
  (`https://raw.githubusercontent.com/<user>/TypeLess/main/appcast.xml`),
- `SUPublicEDKey` — der öffentliche EdDSA-Schlüssel (Base64),
- `SUEnableAutomaticChecks = true`, `SUScheduledCheckInterval = 86400`.

Der konkrete GitHub-Benutzername steht erst nach dem Repo-Setup fest; bis dahin ein klar benannter
Platzhalter, den das Repo-Setup ersetzt (eine Stelle im Skript).

---

## Baustein B: EdDSA-Update-Signatur

Sparkle verifiziert jedes Update über eine **EdDSA-Signatur (ed25519)**, unabhängig von der
macOS-Code-Signatur. Zwei getrennte Vertrauensanker, beide nötig:

- **Code-Signatur „TypeLess Dev"** → Berechtigungserhalt (macOS bindet Rechte an die Signatur-
  Identität + Bundle-ID). Bleibt über alle Versionen gleich.
- **EdDSA-Signatur** → Sparkle akzeptiert nur Updates, deren Zip mit dem privaten Schlüssel signiert
  ist, dessen öffentlicher Teil in der laufenden App steht.

Das Schlüsselpaar wird **einmalig** mit Sparkles `generate_keys` erzeugt. Der öffentliche Schlüssel
landet in der `Info.plist` (`SUPublicEDKey`). Der private Schlüssel legt Sparkle standardmäßig im
**Schlüsselbund** ab; das `release`-Skript nutzt `sign_update`, das ihn dort findet.

---

## Baustein C: `release`-Skript & Appcast

### `scripts/release.sh`

Ein neues Skript, das `build-app.sh` als Bau-/Signier-Baustein wiederverwendet und darum herum die
Release-Schritte legt. Ein Lauf, streng in dieser Reihenfolge:

1. **Version bestimmen** aus **einer** Quelle (s. u.).
2. **Bauen + signieren** (bestehendes `build-app.sh` in Release-Konfiguration, Engine eingebettet,
   Code-Signatur „TypeLess Dev").
3. **Verifizieren**, dass die Signatur gültig ist (`codesign --verify --deep --strict`) — bricht
   sonst ab, bevor irgendetwas hochgeladen wird.
4. **Packen** zu `TypeLess-<version>.zip` (`ditto -c -k --keepParent`, erhält die Signatur).
5. **EdDSA-Signatur** des Zips erzeugen (`sign_update`) → liefert Signatur + Dateigröße.
6. **`appcast.xml`** um einen `<item>` ergänzen (Version, Asset-URL des GitHub-Releases,
   `length` = Dateigröße, `sparkle:edSignature`, `pubDate`).
7. **Hochladen**: `gh release create <tag> TypeLess-<version>.zip` (Tag = Version), dann
   `appcast.xml` committen und pushen.

### Version aus einer Quelle

Heute steht `0.3.0` hartcodiert im `Info.plist`-Heredoc von `build-app.sh`. Das wird durch **eine**
Quelle ersetzt: eine `VERSION`-Datei im Repo-Root (nur die Versionsnummer, z. B. `0.4.0`).
`build-app.sh` liest sie beim Erzeugen der `Info.plist` (`CFBundleShortVersionString` **und**
`CFBundleVersion`); `release.sh` liest dieselbe Datei für Zip-Name, Git-Tag und Appcast-Eintrag.
Damit können App-Version, Zip, Tag und Appcast **nicht** auseinanderlaufen. Das Anheben der Version
ist ein bewusster Edit der `VERSION`-Datei vor dem Release.

### Trockenlauf & Idempotenz (das Testbare an diesem Skript)

`release.sh --dry-run` durchläuft Schritte 1–6 **ohne** `gh release create`/Push: es baut, packt,
signiert und **zeigt** den neuen Appcast-Eintrag, ohne etwas zu veröffentlichen. So ist der
kritische Teil (korrekter Appcast-Eintrag, Version aus einer Quelle) prüfbar, ohne bei jedem Test
ein echtes Release zu erzeugen. Ein zweiter Lauf mit derselben Version fügt **keinen** doppelten
Appcast-Eintrag hinzu (idempotent).

### Appcast-Erzeugung als testbare Einheit

Die reine Logik „Appcast-XML + neuer Eintrag → aktualisiertes XML" wird als kleines, **für sich
testbares** Stück gehalten (ein Shell-Funktions- oder Python-Helfer, den `release.sh` aufruft) —
gegen feste Eingaben prüfbar (Eintrag vorhanden/Version schon da/leerer Appcast), ohne Bauen oder
Netz. Die genaue Sprache ist Implementierungsdetail des Plans; Bedingung ist die Testbarkeit.

---

## Baustein D: GitHub-Repo & Schlüssel-Sicherung

### Repo (einmalig)

Öffentliches GitHub-Repo `TypeLess` anlegen (`gh repo create`) und als `origin`-Remote setzen. Der
Anwender hat einen GitHub-Account und `gh` ist verfügbar; falls `gh auth login` noch aussteht, ist
das ein einmaliger interaktiver Schritt des Anwenders (im Plan als solcher markiert). Das Repo
enthält Quellcode, `appcast.xml` und die Releases (Zip-Assets).

### Schlüssel-Sicherung (Definition-of-Done, nicht optional)

Ohne gesicherte Schlüssel bricht die Verteilkette bei einem Mac-Neuaufsetzen. Gesichert und
dokumentiert werden **beide**:

- **Code-Signing-Identität „TypeLess Dev"** — Export aus dem Schlüsselbund als passwortgeschützte
  `.p12` (Zertifikat **inkl.** privatem Schlüssel).
- **Privater Sparkle-EdDSA-Schlüssel** — Export via Sparkles `generate_keys -x <datei>` aus dem
  Schlüsselbund.

Eine kurze **`docs/RELEASE.md`** hält fest: wie man die Version anhebt und released, wo die beiden
Schlüssel gesichert liegen, wie man sie auf einem neuen Build-Mac wieder importiert, und was bei
Verlust passiert (Rechte auf allen Macs neu erteilen; neuer EdDSA-Schlüssel bedeutet, dass bereits
installierte Apps das nächste Update nicht mehr als vertraut annehmen — dann einmalige
Neuinstallation). Der **Ablageort** der Schlüssel-Backups ist eine Anwender-Entscheidung
(z. B. Passwortmanager oder verschlüsseltes externes Backup); die Spec verlangt nur, **dass** beide
gesichert und in `RELEASE.md` vermerkt sind — die geheimen Dateien selbst kommen **nicht** ins
(öffentliche) Repo.

---

## Datenfluss end-to-end

**Frische Installation (unverändert gültig, jetzt mit realen Größen):**
```
GitHub-Release öffnen → TypeLess-x.y.z.zip (~44 MB) laden → TypeLess.app nach /Applications
→ erster Start: Rechtsklick→Öffnen (einmalige Gatekeeper-Warnung)
→ Berechtigungen erteilen (einmal pro Mac)
→ uv baut die Python-Umgebung auf (~1 GB, einige Minuten) + Einrichtungs-Fenster lädt Modelle (~3,9 GB)
→ „ready" → Menüleisten-Betrieb, ab jetzt offline
```

**Update:**
```
App prüft Appcast (täglich/manuell) → „neue Version da" → Klick
→ Sparkle lädt Zip (~44 MB), verifiziert EdDSA + Code-Identität, tauscht App aus
→ Neustart der App; Modelle & Python-Umgebung bleiben; Berechtigungen bleiben erhalten
```

---

## Testing-Strategie

- **Appcast-Erzeugung:** Unit-/Funktionstest der reinen Logik (neuer Eintrag korrekt; Version schon
  vorhanden → kein Duplikat; leerer Appcast → wohlgeformt).
- **`release.sh --dry-run`:** baut/packt/signiert ohne Veröffentlichung; belegt Version aus einer
  Quelle und den korrekten Appcast-Eintrag; zweiter Lauf idempotent.
- **Version-Einzelquelle:** Prüfen, dass `Info.plist`, Zip-Name, Tag und Appcast alle aus `VERSION`
  stammen (eine Änderung an `VERSION` schlägt konsistent durch).
- **Sparkle-Integration:** überwiegend **Handprobe** (kein sinnvoller Unit-Test für den echten
  Update-Mechanismus). Der Menüpunkt und die Controller-Verdrahtung werden, soweit ohne echten
  Sparkle-Server möglich, geprüft; der eigentliche Beweis ist der Handproben-Durchlauf unten.
- **Abnahme (Handprobe, der eigentliche Beweis):**
  1. `release.sh` erzeugt v_a, GitHub-Release + Appcast stehen.
  2. Frische Installation von v_a (idealerweise zweiter Mac oder frisches macOS-Benutzerkonto):
     läuft bis „ready".
  3. `VERSION` anheben, `release.sh` erzeugt v_b.
  4. In der laufenden v_a „Nach Updates suchen…" → Sparkle bietet v_b an → installieren.
  5. **Nachweisen:** Rechte bleiben erhalten (kein erneuter Berechtigungs-Dialog), Modelle werden
     **nicht** neu geladen, die App läuft als v_b weiter.

---

## Risiken & offene Punkte

- **Sparkle mit selbst-signierter, nicht notarisierter App:** Sparkle verifiziert primär über EdDSA;
  die stabile Code-Signatur trägt den Berechtigungserhalt. Im Handproben-Update mit zu belegen (der
  Fall, den Unit-Tests nicht abdecken).
- **`gh`-Authentifizierung:** einmaliger interaktiver Anwender-Schritt (`gh auth login`), falls noch
  nicht geschehen — kein Automatisierungs-Blocker, nur im Plan zu benennen.
- **uv-Sync-Phase beim ersten Start ist ohne Fenster** (der Server antwortet erst nach dem
  Umgebungsaufbau; das Einrichtungs-Fenster aus Teil 2b erscheint erst zur Modell-Phase). Bekannt,
  **außerhalb des Scopes von Teil 3** — Kandidat für den M8-Feinschliff (Fortschritt der uv-Phase
  sichtbar machen), hier nur vermerkt, damit die lange „stille" Erststart-Phase nicht als Regression
  missverstanden wird.

---

## Umsetzungs-Reihenfolge (Grobschnitt)

1. `VERSION`-Datei + `build-app.sh` liest daraus (Version aus einer Quelle) — hält alles lauffähig.
2. EdDSA-Schlüssel erzeugen; `SUPublicEDKey`/`SUFeedURL`/Auto-Check-Schlüssel in die `Info.plist`.
3. Sparkle als SwiftPM-Dependency + `UpdaterController` + Menüpunkt „Nach Updates suchen…" (LSUIElement-
   Aktivierung).
4. Appcast-Helfer (testbar) + `release.sh` (bauen/verifizieren/packen/`sign_update`/Appcast/dry-run).
5. GitHub-Repo anlegen, Remote setzen, Feed-URL/Benutzername einsetzen; `release.sh` real bis
   `gh release create`.
6. `docs/RELEASE.md` + Schlüssel-Sicherung (beide Schlüssel exportiert und dokumentiert).
7. Abnahme: frische Installation v_a → Update auf v_b, Berechtigungs- und Modell-Erhalt nachgewiesen.

Jeder Schritt hält die App lauffähig; die Swift- und Skript-Anteile bleiben klein und je für sich
prüfbar, soweit die Natur der Aufgabe (Handprobe für den echten Update-Mechanismus) es zulässt.
