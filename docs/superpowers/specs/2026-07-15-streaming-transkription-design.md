# Streaming-Transkription (der „Streaming-Motor") — Entwurf

**Stand:** Entwurf freigegeben (15.07.2026)
**Ausgangslage:** M1–M5 + der M8-Prompt-Cache sind auf `main`. Diktieren funktioniert, der Text
erscheint an der Cursorposition. Zwischen Fn-Loslassen und fertigem Text vergehen aber ~6–7 s;
davon sind ~4 s reine Transkription (Whisper verarbeitet das ganze Audio erst **nach** dem
Loslassen).
**Ziel:** Die Latenz nach dem Loslassen auf **~2–3 s** senken, indem Whisper schon **während** des
Sprechens mitläuft. Das Einfügen am Ende (Wörterbuch → LLM → Löschschutz → einmal einfügen) bleibt
unverändert — der Löschschutz ist nicht berührt.

Dies ist der **erste** von zwei Teilen. Der zweite Teil (ein Overlay, das den mitlaufenden Text
anzeigt) bekommt eine eigene Spec und wird **danach** gebaut. Der Motor stellt den mitlaufenden
Text bereit; sichtbar macht ihn erst der Overlay-Teil.

---

## Anwender-Entscheidungen (im Brainstorming getroffen, verbindlich)

- **Echtes Streaming, nicht nur Anzeige:** Der eingefügte Text entsteht aus dem während des
  Sprechens festgeschriebenen Transkript (plus dem letzten Rest beim Loslassen), **nicht** aus
  einem sauberen Voll-Durchlauf nach dem Loslassen. Der Geschwindigkeitsgewinn ist der Zweck.
- **Bewusst akzeptiertes Qualitätsrisiko:** Der so zusammengesetzte Text kann *minimal* von einem
  einzigen sauberen Durchlauf abweichen. Das ist der Preis für die Latenz und ist abgesegnet.
  (Anders als beim Prompt-Cache ist Streaming **nicht** mathematisch identisch zum Batch-Weg.)
- **Kein Live-Einfügen:** Text wird weiterhin **genau einmal** am Ende eingefügt, nach dem
  vollständigen Löschschutz. Live-Einfügen bleibt ausgeschlossen (kollidiert mit dem Löschschutz).

---

## Was gebaut wird — und was ausdrücklich nicht

**Gebaut wird** die Streaming-Kette: ein Streaming-fähiger Erkenner in der Engine, ein laufender
Kanal über den bestehenden Unix-Domain-Socket, und die Swift-Seite, die das Audio häppchenweise
hochstreamt und am Ende das fertige Ergebnis einfügt.

**Nicht in dieser Spec** (jeweils mit Begründung):
- **Das Overlay** — eigene, nachgelagerte Spec. Der Motor *stellt* den mitlaufenden Text über den
  Kanal *bereit*; im Motor-Teil bleibt die einzige sichtbare Rückmeldung das Menüleisten-Symbol
  wie heute.
- **Live-Einfügen / Text erscheint im Feld während des Sprechens** — dauerhaft ausgeschlossen
  (Löschschutz).
- **Ein sauberer Voll-Durchlauf am Ende zur Qualitätssicherung** — würde den Latenzgewinn
  auffressen; per Anwender-Entscheidung verworfen.

---

## Architektur

### Der Austauschbarkeits-Vertrag bleibt erhalten

Der Kern hängt weiterhin **ausschließlich** an den Interfaces. Der bestehende Batch-Vertrag
`interfaces/transcriber.py` (`transcribe(audio) -> Transcription`) wird **nicht verändert**.
Daneben kommt ein **optionales** Streaming-Protokoll (`interfaces/transcriber.py`, z. B.
`StreamingTranscriber`) mit den Bausteinen:

- `stream_begin(sample_rate)` — eine Sitzung eröffnen,
- `stream_feed(pcm_chunk)` — ein Audio-Häppchen einspeisen; liefert die **neu festgeschriebenen**
  Wörter (ggf. leer),
- `stream_finalize()` — Sitzung abschließen; liefert das **vollständige** Roh-Transkript.

Die Pipeline nutzt den Streaming-Weg **nur, wenn** der konfigurierte Transcriber dieses Protokoll
implementiert; sonst fällt sie transparent auf `transcribe(audio)` zurück. Mock-Backends und
künftige Engines (z. B. whisper.cpp), die nur Batch können, funktionieren **unverändert**.
`factory.py` bleibt die **einzige** Stelle, die konkrete Engines kennt. Der MLX-Transcriber
implementiert **beide** Verträge; die Refiner-Seite ist unberührt.

### Der Mechanismus: LocalAgreement

Whisper ist auf 30-s-Fenster ausgelegt, streamt also nicht von Haus aus. Die bewährte Brücke ist
**LocalAgreement-2**:

1. Ankommende Audio-Häppchen werden an einen wachsenden Puffer gehängt.
2. In festem Takt (Richtwert ~0,5–1 s Audio, in der Umsetzung eine Konstante) wird der Puffer
   erneut durch Whisper (`whisper-large-v3-turbo`, warm) transkribiert.
3. Ein Wort gilt als **festgeschrieben („committed")**, sobald **zwei aufeinanderfolgende**
   Durchläufe an derselben Stelle dasselbe Wort liefern. Festgeschriebene Wörter ändern sich nicht
   mehr und werden über den Kanal ausgeliefert.
4. Bereits festgeschriebenes Audio wird vorne aus dem Puffer getrimmt (ein Kontext-Rest bleibt
   stehen, damit das nächste Fenster genug Zusammenhang hat) — so bleibt das Whisper-Fenster
   beschränkt, auch bei langem Diktat.
5. Bei `stream_finalize()` (Fn losgelassen) wird der verbleibende, noch nicht festgeschriebene
   Rest ein letztes Mal transkribiert und angehängt. Ergebnis: festgeschriebene Wörter + Rest =
   vollständiges Roh-Transkript.

Diese Logik ist **reine Textverarbeitung** (Wörter/Zeitstempel vergleichen) und daher **ohne MLX**
testbar; nur der Whisper-Aufruf selbst ist MLX.

### Der laufende Kanal (über den bestehenden Unix-Socket)

Heute ist der Socket Frage-Antwort. Neu kommt ein **bidirektionaler Streaming-Endpunkt** über
**denselben Unix-Domain-Socket** hinzu (kein TCP, kein Port — die Datenschutz-Linie bleibt):

- Swift eröffnet beim Fn-**Druck** die Streaming-Verbindung und schickt fortlaufend
  Float32-PCM-Häppchen (16 kHz mono) hoch, während aufgenommen wird.
- Die Engine schickt die **festgeschriebenen** Wörter zurück, sobald sie stabil sind (dieser
  Rückkanal ist die Datenquelle für das spätere Overlay; im Motor-Teil wird er bereitgestellt und
  geloggt, aber noch nicht sichtbar gemacht).
- Beim Fn-**Loslassen** signalisiert Swift „Ende". Die Engine ruft `stream_finalize()`, schickt
  das Roh-Transkript durch **Wörterbuch → Refiner (mit M8-Prompt-Cache) → Löschschutz** — **exakt
  die bestehende Pipeline** — und liefert das `ProcessResult` wie heute zurück. Swift fügt es
  **einmal** ein (bestehende M5-Einfüge-Logik, unverändert).
- Der bestehende `POST /process` bleibt vollständig erhalten — als Rückfallweg (s. u.).

Die Verarbeitung bleibt **serialisiert**: Es gibt zu jeder Zeit höchstens eine Streaming-Sitzung
(ein Anwender, ein Diktat). Der bestehende Lock in `runtime.py` deckt das ab.

---

## Speicher / GPU auf 16 GB

Whisper rechnet jetzt **während** des Sprechens. Zwei Punkte:

- **GPU-Rechenzeit überlappt kaum:** Während des Sprechens läuft nur die Transkription auf der GPU.
  Die LLM-**Generierung** (der zweite GPU-Fresser) läuft weiterhin erst **nach** `finalize()` — es
  gibt also kein Gegeneinander von STT und LLM-Generierung.
- **Speicher-Spitze:** Der spekulative LLM-**Preload** (Gewichte laden, weitgehend mmap/I/O, kaum
  GPU) kann wie heute beim Fn-Druck anlaufen. Beide Modelle sind dann kurz resident — die
  M1-Messung wies genau diesen Fall mit **3,62 GB** Spitze aus (STT ~1,5 GB + LLM 4B), gut im
  16-GB-Budget. Der Idle-Unload und das Memory-Pressure-Handling bleiben unverändert.

Falls sich in der Messung doch Konkurrenz zeigt, wird der Preload leicht nach hinten getaktet
(erst kurz vor dem Loslassen bzw. nach genug festgeschriebenem Text) — Umsetzungsdetail, kein
Vertragsbruch.

---

## Fehler- und Randverhalten

**Oberstes Gesetz bleibt „nie ein Diktat verlieren":**

- **Streaming-Fehler jeder Art** (Kanal reißt ab, ein Whisper-Durchlauf scheitert, das Backend kann
  kein Streaming): Die Engine hält das **vollständige** Audio ohnehin gepuffert und fällt auf den
  heutigen **Batch-Weg** (`transcribe(audio)` bzw. `POST /process`) zurück. Das Diktat kommt
  vollständig, nur ohne den Zeitgewinn.
- **LLM-Ausfall** am Ende: unverändert — `refined: false` + Rohtext (Diktat geht nie verloren).
- **Leeres/zu kurzes Diktat:** unverändert; keine Einfügung, Zwischenablage unangetastet.
- **Obergrenze 120 s** (`aufnahmeObergrenze`) bleibt; Streaming verkraftet lange Diktate sogar
  besser (das Whisper-Fenster bleibt durch das Trimmen beschränkt).
- **Verworfenes Diktat** (die M4-Schutzfälle: verlorenes Fn-Loslassen, Fn als Modifier,
  Audio-Konfigurationswechsel): führen wie bisher zum Verwerfen — die Streaming-Sitzung wird dann
  sauber geschlossen, ohne etwas einzufügen. Die Zwischenablage/das Zielfeld bleiben unangetastet.

**Akzeptierte Grenze:** Der festgeschriebene Streaming-Text kann minimal von einem einzigen
sauberen Durchlauf abweichen (Anwender-Entscheidung).

---

## Tests

- **Ohne MLX (überall lauffähig):** Die LocalAgreement-Logik — wann gilt ein Wort als
  festgeschrieben, was bleibt beim Trimmen als Kontext, was liefert `finalize()` — wird mit
  **erfundenen Transkript-Folgen** geprüft (ein gefälschter Whisper, der vorgegebene Teil-Ergebnisse
  liefert, so wie `test_stt.py` heute `mlx_whisper` fälscht). Kein echtes Modell nötig. Auch der
  **Batch-Rückfall** (Streaming-Fehler → voller Batch-Durchlauf, nichts verloren) wird so geprüft.
- **Kanal/Transport:** Der Streaming-Endpunkt wird gegen einen gefälschten Erkenner getestet
  (Häppchen rein → festgeschriebene Wörter raus → `finalize` → `ProcessResult`), ohne Modell.
- **Auf Apple Silicon (`--extra mlx`):** Die echte, gemessene **Latenz nach dem Loslassen** (Ziel
  ~2–3 s) und ein **Qualitäts-Stichprobenvergleich** Streaming vs. Batch auf einigen echten
  Diktaten — belegt, dass die Abweichung klein bleibt.
- Alle bestehenden Engine-Tests (109) bleiben grün; `scripts/check.sh` (black + ruff + mypy strict +
  pytest) bleibt sauber. Swift: bestehende Tests bleiben grün, neue Tests für die Streaming-Upload-
  Seite mit Fakes.

---

## Konventionen

Python 3.11+, `from __future__ import annotations`, Typannotationen überall, MLX-Imports **lazy**
(nur bei Nutzung — der Kern bleibt plattformunabhängig), Kommentare/Docstrings auf Deutsch. Swift:
`TypeLessCore` bleibt UI-frei und ohne AppKit; Streaming-Transport gehört in die Sidecar-Schicht
neben den bestehenden `SidecarClient`. Vor dem Commit `scripts/check.sh` (Engine) bzw.
`swift build && swift test` (App) grün.

## Ausdrücklich zurückgestellt (spätere Specs / Meilensteine)

- **Das Overlay** — nächste Spec, baut direkt auf dem hier bereitgestellten Rückkanal auf.
- **STT-Qualität weiter anheben** (größeres/anderes Whisper) — unberührt; eigene Abwägung, falls je
  nötig.
- **M6 Modi-Umschalter · M7 Settings-UI · M8 Rest (Packaging)** — unberührt.
