# TypeLess — Projektkontext für Claude Code

Vollständig lokale KI-Diktier-App für macOS (Apple Silicon, 16 GB RAM). Ziel: qualitativ
mit Superwhisper/Voicely konkurrieren. Ablauf: Hotkey (Hold-to-talk) → sprechen → lokale
Transkription → deterministisches Wörterbuch → LLM-Sprachverbesserung → Einfügen an der
Cursorposition. **Keine Cloud, keine APIs, keine Daten verlassen den Rechner.**

## Architektur

Native **SwiftUI-Shell** (Hotkey, Audio, Overlay, Text-Einfügen) + **Python-MLX-Sidecar**
(STT + LLM), verbunden über einen lokalen **Unix-Domain-Socket** (kein TCP).

```
apps/macos/   # SwiftUI-App: Hotkey, Audio, Overlay, Einfügen, Settings   (M5-Umkehrung fertig, nur macOS)
engine/       # Python-Sidecar: STT + LLM + Wörterbuch + Pipeline          (M1 fertig)
```

`apps/macos/` (Swift-Package mit drei Targets, s. `apps/macos/README.md`):

```
Sources/TypeLessCore/     # Bibliothek ohne jede UI (kein SwiftUI-/AppKit-UI-Import), daher
                          # vollständig testbar ohne ein Fenster zu öffnen.
  Sidecar/                # HTTPUnixTransport, SidecarClient, SidecarLifecycle (UDS zur Engine)
  Permissions/             # PermissionsService (Mikrofon/Bedienungshilfen/Eingabeüberwachung)
  Settings/                 # SettingsStore (engineDirectory/socketPath/uvPath, UserDefaults)
  Audio/                    # AudioResampler (→16 kHz mono), SilenceDetector, AudioRecorder /
                          # AVAudioEngineRecorder (echte Aufnahme)
  Hotkey/                   # HotkeyMonitor / FnKeyMonitor — CGEventTap auf die Fn-Taste,
                          # .listenOnly (verschluckt nichts), erkennt Emoji-Picker-Konflikt
  Dictation/                # Pasteboard-Protokoll, DictationCoordinator — führt Hotkey,
                          # Aufnahme, Engine und Zwischenablage zusammen (SessionState)
  AppState.swift            # @MainActor @Observable Zustandsautomat — das Bindeglied zur UI
                          # (Engine-Achse, EngineState; getrennt von SessionState)
Sources/TypeLess/          # Dünne SwiftUI-Hülle (MenuBarExtra) — zeigt nur an, was AppState und
                          # DictationCoordinator sagen, enthält selbst keine Logik.
                          # TypeLessApp.swift (Komposition + App-Delegate für Start/Beenden),
                          # MenuContent.swift (Menüinhalt, beide Zustandsachsen),
                          # SystemPasteboard.swift (NSPasteboard — AppKit bleibt hier, nicht in
                          # TypeLessCore).
Tests/TypeLessCoreTests/  # 151 Tests (Swift Testing), fast alle mit Mocks/Fakes — kein echter
                          # Sidecar nötig. Zwei Proben fassen echte Audio-Hardware an und
                          # überspringen sich ohne Mikrofonrecht selbst.
```

Engine-Datenfluss:
```
Audio ──Transcriber──▶ Rohtext ──Wörterbuch──▶ bereinigt ──Refiner(LLM)──▶ Sanity-Check
                                                            ok ? LLM-Text : bereinigter Rohtext
```

## Kernentscheidungen (verbindlich)

- **STT:** `mlx-whisper` mit `whisper-large-v3-turbo` (Auto-Detect für DE+EN gemischt).
- **LLM:** `mlx-lm` mit `Qwen3-4B-Instruct-2507-4bit` als **Default**. Der ursprünglich
  geplante 3B-Default ist **verworfen**: Er löscht im Diktat-Modus reproduzierbar ganze
  Sätze und formuliert um — auch mit verschärftem Prompt (in M1 gemessen). 3B/7B bleiben
  über `EngineConfig` wählbar.
- **RAM-Strategie (16 GB):** STT warm halten, LLM **on-demand** (spekulativer Preload beim
  Hotkey-Druck + Idle-Unload + Memory-Pressure-Handling). Nie beide dauerhaft resident.
- **Text-Einfügen:** Die Zwischenablage schreibt **immer zuerst** (Netz — `CGEventPost` meldet
  keinen Misserfolg zurück, „erst tippen, bei Misserfolg schreiben" ist also unmöglich); danach
  der Versuch mit `CGEventKeyboardSetUnicodeString` (universell), außer bei einer der vier
  AX-freien Ausschlussbedingungen (s. „Aktueller Stand" → M5-Umkehrung) — dann bleibt es bei der
  Zwischenablage allein.
- **Hotkey:** `KeyboardShortcuts` (Sindre Sorhus) + CGEventTap für Hold-to-talk.

## Austauschbarkeit (wichtiges Prinzip)

Der Kern hängt **ausschließlich** an den Interfaces `interfaces/transcriber.py`
(`transcribe(audio) -> Transcription`) und `interfaces/refiner.py`. Die **einzige** Stelle,
die konkrete Engines kennt, ist `factory.py`. Ein neues Backend (z. B. whisper.cpp) =
neue Klasse + ein Zweig in der Factory, sonst nichts. Diesen Vertrag nicht aufweichen.

## Engine entwickeln & testen

```bash
cd engine
uv sync --extra dev                  # Kern + Tests (überall lauffähig)
uv sync --extra dev --extra mlx      # zusätzlich MLX — NUR Apple Silicon

uv run pytest -q                     # Tests (Mock-Backends, kein Modell nötig)
bash ../scripts/check.sh             # black + ruff + mypy(strict) + pytest

uv run python -m typeless_engine.server   # Sidecar starten (UDS, siehe engine/README.md)

# Mock-Pfad (ohne Modelle):
uv run typeless dict "wir nutzen hot spot"
uv run typeless refine "text" --mode diktat --llm mock --show-stages

# Echter Pfad (Apple Silicon, lädt Modelle beim 1. Lauf):
uv run typeless refine "hot spot ist mega" --mode diktat --show-stages
uv run typeless transcribe test.wav --mode diktat --show-stages
# WAV erzeugen aus Sprachmemo (.m4a):
#   afconvert -f WAVE -d LEI16@16000 -c 1 memo.m4a test.wav
```

Persönliches Wörterbuch (deterministisch, vor dem LLM): JSON unter
`~/Library/Application Support/TypeLess/dictionary.json` (Default-Pfad), Beispiel in
`engine/examples/dictionary.example.json`.

## macOS-Shell entwickeln & testen

```bash
cd apps/macos
swift build && swift test        # 151 Tests (Swift Testing), Mocks — kein Sidecar nötig

bash scripts/build-app.sh        # baut TypeLess.app aus dem Repo-Root (relativer Pfad ab dort)
open apps/macos/TypeLess.app
```

`scripts/build-app.sh` erzeugt ein echtes `.app`-Bundle (macOS vergibt Mikrofon-/
Accessibility-Rechte an eine Bundle-**Identität**, nicht an ein nacktes Binary). Signiert wird mit
einer **stabilen, selbst-signierten** Entwickler-Identität „TypeLess Dev", sobald sie im
Schlüsselbund liegt — einmal anzulegen mit `bash scripts/setup-signing-identity.sh` (kein
Apple-Konto, keine Kosten). Dadurch bleibt die Identität über **alle** Neubauten gleich und die
Rechte werden nur **einmalig** erteilt. Fehlt die Identität, fällt das Skript auf eine Ad-hoc-
Signatur zurück — die wechselt bei jedem Neubau, dann muss man die Rechte nach jedem Bau neu
erteilen (der Schalter in den Einstellungen sieht dabei noch „an" aus, zeigt aber auf die alte
Identität). Ein echtes Apple-Zertifikat für die Weitergabe an andere gibt es erst in M8.

Die App startet den Sidecar selbst (spekulativ übernimmt sie eine bereits laufende Instanz statt
eine zweite zu spawnen) und beendet einen selbst gestarteten Sidecar beim Beenden wieder mit —
egal ob über den Menü-Button, Cmd+Q oder „Beenden“ im Dock (`applicationShouldTerminate` in
`TypeLessApp.swift` fängt **jeden** dieser Wege ab, s. Kommentar dort). Beim Beenden läuft dort
erst `dictation.stop()` (ein fertig gesprochenes, noch laufendes Diktat wird zu Ende verarbeitet),
danach erst `state.shutdown()` — sonst wird der Engine unter einer noch laufenden Verarbeitung der
Boden weggezogen.

**Diktieren (ab M4):** **Fn halten**, sprechen, **loslassen** — der bereinigte/verfeinerte Text
wird an der Cursorposition eingefügt (Regelfall seit der M5-Umkehrung, s. „Aktueller Stand"
unten) und landet dabei **zusätzlich immer** in der Zwischenablage (Netz, ⌘V liefert denselben
Text); nur wenn eine der vier Bedingungen fürs direkte Einfügen fehlt, bleibt es bei der
Zwischenablage allein. Ein Tastendruck bei gehaltenem Fn bricht das Diktat ab — das Overlay
meldet „Abgebrochen", aber **nur** oberhalb der Audio-Mindestmenge (sonst bliebe ein normales
Fn+Pfeil kommentarlos). Während der **Verarbeitung** bricht **Escape** ab (Overlay: „Abgebrochen";
die Zwischenablage bleibt dabei unangetastet — anders als bei einem geglückten Diktat, das dort
immer ein Netz ablegt). Der Hotkey ist **nur** für die Dauer der Verarbeitung registriert, damit
Escape sonst nicht systemweit blockiert ist; **bekannte Grenze:** Poppt in diesen ~6 s ein Dialog
auf, den man mit Escape schließen will, bricht man stattdessen das Diktat ab. Bewusste Entscheidung
des Anwenders: ein kleines Overlay unten mittig auf dem Bildschirm zeigt den Verlauf **nur während
des Diktats** — Live-Pegel beim Zuhören, Verarbeitung,
Ergebnis; eine Textvorschau erscheint dabei ausschließlich, wenn der Text in der Zwischenablage
landet (nie beim direkten Einfügen — der Text steht ja schon im Feld). **Weiterhin keine Töne.**
Das Menüleisten-Symbol bleibt als zusätzliche Rückmeldung. Voraussetzung: Systemeinstellungen →
Tastatur → „Beim Drücken der 🌐-Taste“ → „Keine Aktion“ (steht das auf Emoji-Picker/Eingabequelle/
Systemdiktat, poppt bei jedem Diktat der Emoji-Picker auf — die App weist im Menü darauf hin,
ändert die Einstellung aber nicht selbst).

## Aktueller Stand

- [x] **M1** — Engine-Kern: Interfaces, Wörterbuch, Modi (Diktat/Prompt/Email/Slack/
  BrainDump), Pipeline + Sanity-Check (Länge **und** Divergenz), MLX-Backends (lazy) +
  Mocks, CLI. 41 Tests grün, ruff/mypy(strict)/black sauber.
- [x] **M1 auf echten Modellen verifiziert** (Apple Silicon, s. „Messwerte" unten).
- [x] **M2** — Sidecar-Server: FastAPI/uvicorn über **Unix-Domain-Socket** (kein TCP-Port).
  `engine/typeless_engine/server/`: `runtime.py` (Modelle, Lock, Idle-Unload — kennt kein
  HTTP), `app.py` (dünne HTTP-Schicht, zustandslos), `__main__.py` (Start, Socket-Hygiene).
  86 Tests grün, gegen echte Modelle über den Socket verifiziert.
  - `GET /health` → `starting|ready`, antwortet **immer sofort** (auch während der
    Verarbeitung; Modellaufrufe laufen im Worker-Thread).
  - `POST /preload` → `202` nach ~1 ms, lädt das LLM im Hintergrund (Hotkey-**Druck**).
  - `POST /process?mode=…[&language=…][&sample_rate=16000]` → rohes Float32-PCM als Body
    (16 kHz mono), liefert `ProcessResult` als JSON (Hotkey-**Loslassen**).
  - `POST /unload` → LLM sofort freigeben (macOS-Speicherdruck).
  - **Fehlerverhalten:** LLM-Ausfall → `200` mit `refined: false` + Rohtext (Diktat geht nie
    verloren). STT-Ausfall → `500`. Ungültige Eingabe → `400`, bevor ein Modell lädt.
  - Verarbeitung ist **serialisiert** (Lock); ein Unload fällt nie in eine laufende
    Generierung. Socket-Datei wird beim Start/Ende aufgeräumt; ein **lebender** Sidecar wird
    per `connect()`-Probe erkannt und nicht überschrieben.
- [x] **M3** — Swift-Shell: `TypeLessCore` (HTTP-Transport über UDS, `SidecarClient`,
  `SidecarLifecycle` — übernimmt einen laufenden Sidecar oder startet ihn selbst,
  `PermissionsService`, `SettingsStore`, `AppState` als `@MainActor @Observable`-
  Zustandsautomat) + dünne `MenuBarExtra`-Oberfläche (`LSUIElement`, kein Dock-Icon). 43 Tests
  grün, **gegen die echte Engine verifiziert** (Selbststart, Übernahme einer laufenden Instanz,
  Fehlerfall bei fehlendem Engine-Verzeichnis — je über Prozesstabelle und Menü-Text belegt).
  Beenden über Menü-Button, Cmd+Q **und** Dock laufen alle durch denselben
  `applicationShouldTerminate`-Pfad — kein verwaister Sidecar.
- [x] **M4** — Audio, Hotkey, Diktat-Koordinator: `Sources/TypeLessCore/Audio/`
  (`AudioResampler` auf 16 kHz mono, `SilenceDetector`, `AudioRecorder`/`AVAudioEngineRecorder`
  — fragt Mikrofonzugriff **vor** dem Start ab), `Hotkey/` (`HotkeyMonitor`/`FnKeyMonitor` — ein
  **mitlesender** `CGEventTap` auf die Fn-Taste, verschluckt nichts, Fn-Kombinationen bleiben
  unverändert; erkennt per `fnKeyOpensEmojiPicker()`, ob macOS die Taste selbst belegt),
  `Dictation/` (`Pasteboard`-Protokoll, `DictationCoordinator` als eigener `SessionState`
  — **getrennt** von `EngineState`, Diktat hat im Menü Vorrang). Text landet nach Fn-Loslassen in
  der Zwischenablage; kein Overlay, keine Töne (Entscheidung des Anwenders — die Latenz von
  ~6 s laut M1-Messwerten bleibt bis zur Optimierung in M8 unverdeckt). `Sources/TypeLess/
  SystemPasteboard.swift` bringt die echte `NSPasteboard`-Umsetzung in die App-Schicht, ohne
  AppKit in `TypeLessCore` zu ziehen. 93 Tests grün, **gegen echte Hardware verifiziert**
  (Selbststart der Engine + Hotkey-Installation über das echte, ad-hoc signierte Bundle,
  Fehlerfall bei fehlender Engine ohne Absturz, sauberes Beenden ohne verwaisten Sidecar —
  jeweils über Prozesstabelle und Menütext belegt; das eigentliche Diktat mit echter Sprache ist
  Handprobe).
  Vier Fallen, die das Abschluss-Review fand, sind zugemauert — jede mit Mutationsprobe:
  1. **Verlorenes Fn-Loslassen** (macOS schaltet den Tap unter Last ab): Mikrofon blieb offen,
     der nächste `stop()` lieferte *alles seit dem ersten Druck* — fremdes Audio an die Engine.
     Jetzt: verwaiste Aufnahme wird beim nächsten Druck verworfen, ein Doppelstart im Recorder
     **wirft** (statt still zu schlucken), Watchdog bricht nach `aufnahmeObergrenze` (120 s) ab.
  2. **Fn als Modifier** (Fn+Pfeil, gehalten): nahm auf, Whisper halluzinierte, Zwischenablage
     zerstört. Jetzt `KeyDownCounter` — `CGEventSource.counterForEventType` liefert eine reine
     Ordnungszahl der Tastendrücke, **ohne je einen Keycode zu sehen**. Steigt sie zwischen Druck
     und Loslassen, wird das Diktat kommentarlos verworfen. **Die Event-Maske des Taps bleibt
     ausschließlich `.flagsChanged` — sie um `.keyDown` zu erweitern wäre ein Datenschutzbruch.**
  3. **`AVAudioEngineConfigurationChange`** (AirPods verbinden mitten im Diktat) kürzte die
     Aufnahme stillschweigend; wird jetzt gemeldet und die Aufnahme verworfen.
  4. **„Hotkey inaktiv" war toter Code** (`start()` warf nie) — das Menü sagte „Bereit", während
     der Hotkey tot war. Jetzt am **Ende des Streams** erkannt, unterschieden über
     `Task.isCancelled` (nicht über ein Flag — das meldete beim Neustart einen Ausfall, den es
     nicht gab).
  In **allen** Fehlerfällen bleibt die **Zwischenablage unangetastet** (alter Inhalt schlägt
  Leere) — s. Spec.
- [x] **M5** — Text an der Cursorposition einfügen (statt Zwischenablage). `Sources/TypeLessCore/
  Insertion/`: `InsertionTarget` (fragt über die AX-Schnittstelle, wohin eingefügt werden darf —
  vorderste App; **liest nie Feldinhalte** — `kAXValueAttribute` wird inzwischen gar nicht mehr
  angefasst, die frühere Setzbarkeitsprüfung gehörte zur seither entfernten Vorab-Klassifizierung)
  und `TextInserter` (`CGEventKeyboardSetUnicodeString`, surrogatpaar-sichere Zerlegung, baut erst
  alle Ereignisse und postet dann — kein halb eingefügter Text). Der `DictationCoordinator`
  prüfte beim Zustellen **fünf** Bedingungen (heute vier, s. M5-Umkehrung unten), sonst
  Zwischenablage: Bedienungshilfen erteilt **und** Secure Event Input aus, dieselbe App, dasselbe
  Textfeld (Element-Identität, nicht Inhalt), ein beschreibbares Feld, kein Passwortfeld.
  **Oberste Regel: entweder eingefügt
  oder in der Zwischenablage — nie ein drittes Ergebnis.** (Der Text liegt inzwischen **immer**
  zusätzlich in der Zwischenablage — Netz, s. M5-Umkehrung unten.) Die M4-Regel „die
  Zwischenablage bekommt jedes Ergebnis" ist **gefallen**: Jedes Diktat prüft seinen **eigenen**
  gemerkten Fokus, nicht den des jüngsten (sonst tippte ein überholtes Diktat in das inzwischen
  fokussierte Fenster). Bedienungshilfen werden beim Start **angefordert** (nicht nur geprüft),
  das Menü warnt bei fehlendem Recht.
  122 Tests grün, **mit echter Sprache in mehreren Apps handverifiziert** (direktes Einfügen in
  mehreren Apps). Bekannte, in der Spec benannte Grenze: Passwortfeld ohne AX-Subrolle.
- [x] **M5-Nachbesserung — direktes Einfügen in Electron-/Chromium-Apps** (Claude, Slack, VS Code, …).
  Solche Apps bauen ihren Bedienungshilfen-Baum erst **auf Anforderung** auf — ohne den fand TypeLess
  dort kein Textfeld und wich auf die Zwischenablage aus (per Diagnose belegt: `kAXFocusedUIElementAttribute`
  liefert nichts). `AXInsertionTarget.weckeBedienungshilfen(fuer:)` setzt `AXManualAccessibility` auf dem
  App-Element (**nur setzen, liest nichts**; bewusst **nicht** `AXEnhancedUserInterface` — löst bei manchen
  Apps Layout-Wechsel aus). `Insertion/BedienungshilfenAufwecker` weckt jede App **beim Wechsel**
  (`NSWorkspace.didActivateApplication`, damit der Baum vor dem Fn-Druck steht); zusätzlich weckt der
  `DictationCoordinator` beim Fn-Druck die vorderste App (Absicherung). Die **fünf M5-Bedingungen und
  `stelleZu` blieben zum Zeitpunkt dieser Nachbesserung unverändert** — der Fix machte die
  AX-Abfragen bei Electron nur überhaupt wirksam. (Heute sind es vier AX-freie Bedingungen, s.
  M5-Umkehrung unten.)
  **Erweiterte, bewusst akzeptierte Grenze:** In Electron-Apps kann ein Passwortfeld ohne
  `AXSecureTextField`-Subrolle nicht als solches erkannt werden → dann würde direkt hineingetippt (Schließen
  ginge nur durch Lesen des Feldinhalts, was das Datenschutz-Versprechen ausschließt).
- [x] **M5-Nachbesserung — direktes Einfügen in WebKit-Editoren** (Apple Mail-Nachrichtenrumpf, Webmail,
  Rich-Text-Editoren). Solche Felder melden sich über die Bedienungshilfen als **`AXWebArea`** (WebKit-Editor
  für Formatierung/Bilder), nicht als klassisches `AXTextField`/`AXTextArea` — sie standen darum nicht auf
  der Whitelist erlaubter Feldtypen und wichen auf die Zwischenablage aus (per Diagnose belegt: `rolle=AXWebArea
  settable=true`, trotzdem abgelehnt). Fix: Die reine Rollen-Logik wurde aus `AXInsertionTarget.fokusziel()`
  in die AX-freie, testbare `AXInsertionTarget.klassifiziere(rolle:subrolle:setzbar:)` gezogen (beide
  Bezeichner inzwischen mit der M5-Umkehrung entfernt, s. unten); sie ließ `AXWebArea` **nur zusammen mit
  `settable=true`** zu — eine reine Anzeige-Webseite (Safari) meldete `kAXValue` nicht als setzbar und fiel
  heraus, es wurde also nie in eine nicht editierbare Seite getippt. Die **fünf M5-Bedingungen blieben zum
  Zeitpunkt dieses Fixes unverändert** (gleiche App, gleiches Feld, kein Passwortfeld, kein blind tippen);
  der Fix erweiterte nur die Liste beschreibbarer Feldtypen. (Heute sind es vier AX-freie Bedingungen, s.
  M5-Umkehrung unten.) Damit kam auch die bis dahin ungetestete Whitelist unter Test (7 neue Proben,
  Passwort-Subrolle schlug weiterhin alles — auch bei `AXWebArea`); diese Proben sind mit der Whitelist
  selbst inzwischen wieder entfernt (s. M5-Umkehrung unten). 158 Tests grün, Mail-Nachrichtenrumpf
  handverifiziert.
- [x] **M5-Umkehrung — einfach tippen, überall.** Die M5-Vorabprüfung fragte über die
  Bedienungshilfen, *ob* getippt werden darf. Zwei ihrer fünf Bedingungen brauchten ein
  **fokussiertes AX-Element** („beschreibbares Textfeld?", „noch dasselbe Feld?") — und genau daran
  scheiterten Apps mit unvollständigem AX-Baum: Spotify liefert **kein** fokussiertes Element, das
  VS-Code-Suchfeld meldet `AXStaticText settable=false`. Dort wurde nie getippt, obwohl das Tippen
  angekommen **wäre**. Jetzt wird getippt, außer in **vier** Fällen, die alle **ohne** AX-Element
  prüfbar sind: Bedienungshilfen fehlen, Secure Event Input aktiv (beides Physik — macOS verwirft
  die Ereignisse garantiert), andere App als beim Fn-Druck, erkanntes Passwortfeld. `Fokusziel`,
  `Fokuskennung` und die Feldtypen-Whitelist sind **entfernt**.
  **Zwischenablage als Netz:** Jedes geglückte Diktat landet **zusätzlich** in der Zwischenablage,
  geschrieben **vor** dem Tippversuch (`CGEventPost` meldet keinen Misserfolg — „erst tippen, dann
  bei Misserfolg schreiben" ist unmöglich). Damit ist die M5-Zusicherung „bei Erfolg bleibt die
  Zwischenablage unangetastet" **bewusst aufgegeben**; bei **Fehlern** bleibt sie weiter unberührt.
  Preis: vorher Kopiertes ist nach jedem Diktat weg.
  **Abbruch beim Sprechen:** Eine Taste bei gehaltenem Fn verwirft das Diktat (das tat die
  Fn-als-Modifier-Wache schon immer) — jetzt meldet das Overlay „Abgebrochen", aber **nur** oberhalb
  der Audio-Mindestmenge, damit ein normales Fn+Pfeil kommentarlos bleibt.
  **Bewusst eingekaufte Restrisiken:** Ein Fokuswechsel **innerhalb** derselben App (⌘L in die
  Adressleiste, Tab ins Betreff-Feld) wird nicht mehr erkannt — der Text landet dann im neuen Feld,
  genau wie beim echten Tippen, und liegt dank Netz trotzdem in der Zwischenablage. Die
  Passwortfeld-Erkennung greift nur, wo AX Auskunft gibt; wo nicht, wird hineingetippt (Schaden
  asymmetrisch harmlos: TypeLess tippt **hinein** und liest nie **heraus**). Fehlt ein
  beschreibbares Element im Fokus ganz, wirken die Ereignisse beim fokussierten Responder als
  **Kommandos** statt als Text — `CGEventTextInserter` postet dabei aber ausschließlich
  `virtualKey: 0`, nie den Leertasten-Keycode (49), Play/Pause & Co. bleiben also außen vor
  (s. Spec, Restrisiko 4).
- [x] **Diktat abbrechen (Verarbeitungsphase).** Bis dahin ließ sich ein Diktat nur **beim
  Sprechen** verwerfen (Taste bei gehaltenem Fn); in den ~6 s Verarbeitung gab es **keinen** Weg.
  Jetzt bricht **Escape** dort ab: `Task.cancel()` auf die jüngste Verarbeitung, Zustellung
  `.abgebrochen`, `session` zurück auf `.idle` — **kein Fehler**, kein Warnzeichen, und
  ausdrücklich **kein Netz** in der Zwischenablage (diesen Text will der Anwender nicht).
  **Datenschutz:** Der Auslöser ist `RegisterEventHotKey` (Carbon), **kein** Event-Tap — es sieht
  ausschließlich die angemeldete Kombination, nie andere Tastendrücke. Die Fn-Tap-Maske bleibt
  unverändert `.flagsChanged`.
  **Nur zeitweise registriert:** `synchronisiereAbbruchHotkey()` leitet die Registrierung
  idempotent aus `session` ab, statt sie an einzelne Übergänge zu hängen — es gibt drei Wege aus
  `.processing` heraus (Zustellung, Fehler, **neues Diktat**), und auf einem vergessenen bliebe
  Escape systemweit belegt, bis die App beendet wird.
  **Atomarer Schnitt:** Ein `Task.isCancelled`-Check unmittelbar vor `stelleZu` genügt, weil
  Zustellung und Zustandswechsel synchron auf dem MainActor laufen — dazwischen liegt kein
  Suspension-Punkt. Entweder abgebrochen oder zugestellt, nie beides. Ein Escape **nach** diesem
  Check wird bewusst ignoriert (lieber ein nicht abgebrochenes als ein halb eingefügtes Diktat).
  **Bewusst akzeptiert:** Die Engine rechnet ihr abgebrochenes Diktat zu Ende (MLX-Generierung ist
  nicht unterbrechbar), ein direkt folgendes Diktat wartet daher ggf. wenige Sekunden auf den Lock.
  Escape ist während der Verarbeitung systemweit belegt — s. Grenze unter „Diktieren".
- [x] **M8-Teil vorgezogen — Prompt-Prefix-Cache** (LLM-Latenz). Der `MLXRefiner` cacht den
  festen 424-Token-Systemprompt **einmal** beim `preload()` und generiert pro Diktat nur den
  kurzen Suffix (Diktattext) gegen diesen KV-Cache; danach wird der Cache auf die Präfixlänge
  zurückgestutzt. Alles in `engine/typeless_engine/llm/mlx_refiner.py` — die Schnittstelle
  `Refiner` und `factory.py` bleiben unberührt (Austauschbarkeit). Die reinen Helfer
  (`statischer_praefix` über den längsten gemeinsamen Präfix zweier Diktate, `beginnt_mit` als
  Wächter) und die Cache-Politik sind **ohne MLX** testbar (Test-Unterklasse `SpyRefiner`); die
  MLX-Aufrufe liegen hinter drei Nähten (`_prime_cache`/`_generate`/`_reset_cache`).
  **Qualitätsneutral belegt:** on-device (echtes 4B-Modell) war die Ausgabe mit Cache in 3/3
  greedy-Läufen **bit-identisch** zur Ausgabe ohne Cache (über je zwei Diktate). **Kein Diktat
  geht je verloren:** jeder Fehlerpfad (Cache-Aufbau scheitert, Wächter negativ, Ausnahme mitten
  in der Generierung) fällt auf den Voll-Prefill zurück — zwei Mutationsproben belegen das. Ein
  nicht sauber zurückstutzbarer Cache (künftiges Backend) wird **verworfen** statt still
  korrumpiert. 109 Engine-Tests grün (+ 2 On-device, überspringen sich ohne `TYPELESS_ONDEVICE=1`).
- [ ] **M6** Modi-Umschalter · **M7** Settings-UI · **M8** Polish/Packaging (Rest).

## Messwerte (M1, Apple Silicon, 16 GB)

Speicher laut MLX-API (`mx.get_active_memory()`; **RSS ist irreführend**, da MLX die
Gewichte per mmap lädt):

| Zustand | Speicher | Plan-Annahme |
|---|---|---|
| Idle (nur STT warm) | **1,51 GB** | 2,0–2,5 GB |
| Peak (STT + LLM 4B) | **3,62 GB** | 4,0–4,5 GB |
| Nach LLM-Unload | 1,51 GB | — |

Latenz: STT ≈ **0,17× Echtzeit** (48 s Audio → 8,4 s). LLM-Preload 3,9 s (gecacht),
Refine 3,2–3,6 s. Für ein 15-s-Diktat also grob 2,6 s STT + ~3,5 s LLM. Das Planziel von
2–4 s nach dem Loslassen wird damit **nicht** erreicht (eher 6 s); der spekulative Preload
verdeckt nur die Ladezeit, nicht die Generierung.

**Nach dem Prompt-Prefix-Cache (s. M8-Teil oben):** Der feste Systemprompt wird nicht mehr bei
jedem Diktat neu geprefillt. On-device gemessene Ersparnis **~1,3–3,1 s pro Diktat** (lastabhängig).
Damit landet ein Diktat grob bei **~6–7 s statt ~8–9 s** nach dem Loslassen. Die ~4 s STT bleiben
die Untergrenze — tiefer geht es nur über die zurückgestellten Qualitäts-Kompromisse (kleineres
Whisper, kürzerer Prompt). Das ist der verbleibende Posten für M8.

## Konventionen

- Python 3.11+, Typannotationen überall, `from __future__ import annotations`.
- Tooling: ruff + black (line-length 100), mypy **strict**, pytest. Vor Commits
  `scripts/check.sh` grün halten.
- Kommentare/Docstrings auf Deutsch (bestehendem Stil folgen).
- MLX-Imports immer **lazy** (nur bei Nutzung), damit der Kern plattformunabhängig bleibt.
- Iterativ arbeiten: jeder Meilenstein bleibt lauffängig. Commit/Push nur auf Ansage.
