# Einfach tippen — Text in jedes Feld einfügen — Design

**Datum:** 2026-07-26
**Status:** Entwurf zur Freigabe
**Meilenstein:** M5-Umkehrung (Text-Einfügen) — eigenständiges Feature auf `main`.

## Ziel

TypeLess soll seinen Text **überall** an der Cursorposition einfügen — auch dort, wo die
Bedienungshilfen keine oder eine unbrauchbare Auskunft geben: **Spotify-Suchfeld**,
**VS-Code-Suchfeld**, und jedes weitere Feld, das seine AX-Rolle nicht sauber meldet.

Der Weg dorthin ist eine **Umkehrung der M5-Logik**: nicht mehr „fragen, ob getippt werden darf",
sondern „tippen — außer in den wenigen Fällen, in denen es nachweislich schadet oder wirkungslos
wäre".

## Hintergrund (belegte Diagnose)

M5 fragt vor jedem Einfügen über die Bedienungshilfen fünf Bedingungen ab. Zwei davon —
*„ist das ein beschreibbares Textfeld?"* und *„ist es noch dasselbe Feld?"* — brauchen ein
**fokussiertes AX-Element**. Genau daran scheitern die Zielfälle:

| App | AX-Antwort | Folge heute |
|---|---|---|
| Spotify-Suchfeld | **kein fokussiertes Element** | Zwischenablage |
| VS-Code-Suchfeld | `AXStaticText`, `settable=false` | Zwischenablage |

Das eigentliche Tippen (`CGEventKeyboardSetUnicodeString`) **käme in beiden Fällen an**. Die
Electron-Spec vom 2026-07-25 hat das bereits festgehalten: *„Das eigentliche Tippen käme in Electron
an; es ist die Vorab-Prüfung, die bremst."* Dieselbe Diagnose, eine Ebene weiter gedacht.

### Die Prüfung ersetzt ein Auge, das beim Tippen mitläuft

Warum gab es die Prüfung überhaupt? Beim echten Tippen prüft **niemand** vorab, ob ein Feld
beschreibbar ist. Das Ereignis geht an die vorderste App, die App gibt es an das fokussierte
Element, und was daraus wird, entscheidet die App. Das ist unproblematisch, weil der Mensch in der
Schleife steht: Er sieht nach ~50 ms ein Zeichen erscheinen und korrigiert sofort, wenn es das
falsche Ziel war.

TypeLess hat diese Schleife nicht: Der Text kommt in einem Rutsch, ~6 s nachdem der Anwender
zuletzt hingesehen hat, und `CGEventPost` liefert keine Rückmeldung. Die AX-Prüfung war der Ersatz
für dieses fehlende Auge.

**Die Einsicht dieser Spec:** Dieser Ersatz ist teurer als das Risiko, das er abwehrt. Er wehrt
genau ein Szenario ab — *der Anwender hat während der ~6 s den Fokus gewechselt* — und bezahlt dafür
mit dem Totalausfall in jeder App, deren AX-Baum unvollständig ist. Das Restrisiko nach der
Umkehrung ist identisch mit dem, was beim echten Tippen ohnehin passiert wäre.

## Ansatz

`stelleZu` prüft nur noch **drei Bedingungen, die alle ohne fokussiertes AX-Element auskommen** —
plus die Passwortfeld-Prüfung, soweit sie greift. Sonst wird getippt.

```
1. Bedienungshilfen erteilt?      AXIsProcessTrusted()          — sonst verpufft jedes CGEvent
2. Sichere Eingabe aus?           IsSecureEventInputEnabled()   — sonst verwirft macOS das Ereignis
3. Dieselbe App wie beim Druck?   NSWorkspace.frontmost…        — braucht kein Sonderrecht
4. Kein Passwortfeld?             AX-Subrolle, falls verfügbar

alle vier erfüllt  -> tippen
sonst              -> Zwischenablage (wie bisher)
```

Bedingung 1 und 2 sind **keine Vorsicht, sondern Physik**: Ohne Bedienungshilfen und bei aktiver
sicherer Eingabe (Terminal, 1Password) verwirft macOS synthetische Tastatur-Ereignisse garantiert.
Ohne diese beiden Prüfungen wäre das Diktat spurlos weg, bei zufriedener Anzeige. Beide kosten
nichts und brauchen kein AX-Element.

Bedingung 3 ist der billige Rest der alten Fokusprüfung: Ist beim Loslassen eine andere App vorne
als beim Fn-Druck, hat der Anwender nachweislich gewechselt. Das ist der einzige Fall, in dem der
Fokuswechsel **sicher feststeht** — und er ist ohne Sonderrechte prüfbar.

### Was wegfällt

Die beiden Bedingungen, die ein fokussiertes AX-Element brauchen:

- **„Ist es ein beschreibbares Textfeld?"** (`klassifiziere`-Whitelist) — entfällt. Diese Whitelist
  war ohnehin nie eine Aussage über *Suchfelder*: Ein natives Suchfeld meldet sich als
  `AXTextField` mit Subrolle `AXSearchField` und wurde von M5 **immer schon direkt betippt**
  (Safari-, Finder-, Mail-Suche). Dass Spotify und VS Code herausfielen, war ein Nebeneffekt
  unvollständiger AX-Umsetzung, keine Sicherheitsentscheidung.
- **„Ist es noch dasselbe Feld?"** (`Fokuskennung`, Element-Identität) — entfällt. Damit fällt auch
  der Schutz gegen Fokuswechsel *innerhalb* derselben App (⌘L in die Adressleiste, Tab ins
  Betreff-Feld). Das ist der bewusst eingekaufte Preis, s. „Restrisiko".

`Fokuskennung` und die Whitelist werden **entfernt**, nicht ungenutzt liegen gelassen — toter Code
in einem sicherheitsrelevanten Pfad ist schlechter als ein Git-Verlauf, der beides zurückholt.

### Was ausdrücklich bleibt

- **Die Zwischenablage bleibt bei Erfolg unangetastet.** Unverändert die Entscheidung des Anwenders.
- **Der Zwischenablage-Fallback** für die vier Ausnahmen oben — inklusive der Regel, dass bei
  einem *Fehler* (Engine weg) die Zwischenablage unberührt bleibt: alter Inhalt schlägt Leere.
- **`AXManualAccessibility`-Aufwecker** (Electron-Nachbesserung). Er wird für das Tippen nicht mehr
  gebraucht, aber weiterhin für die Passwortfeld-Erkennung: Ohne AX-Baum keine Subrolle, keine
  Erkennung.
- **`.cgAnnotatedSessionEventTap`** als Post-Ziel. Ein Wechsel auf `.cghidEventTap` bleibt
  verboten — daran hängt die Fn-als-Modifier-Wache (s. `KeyDownCounter`).
- **Keine Mini-Pausen zwischen den Häppchen.** Verlorene Zeichen bei schnell gepostetem
  `CGEventPost` sind eine bekannte Fehlerklasse (Electron, Java), in TypeLess aber **nie
  aufgetreten** — M5 wurde ohne Pausen in mehreren Apps handverifiziert. Prophylaxe ohne Beleg wäre
  genau der Fehler, den diese Spec bei den AX-Abfragen korrigiert. Nachrüsten, falls die Handprobe
  Zeichenverlust zeigt (Kosten wären ohnehin vernachlässigbar: ~26 ms bei 250 Zeichen).

## Restrisiko — ehrlich benannt

**1. Fokuswechsel innerhalb derselben App.** Wechselt der Anwender während der ~6 s das Feld,
ohne die App zu wechseln, landet der Text im neuen Feld. Beispiele: ⌘L in die Browser-Adressleiste,
Tab vom Mail-Rumpf ins Betreff-Feld. Das ist **exakt das Ergebnis, das echtes Tippen gehabt hätte**.
Bewusst eingekauft, weil der Gegenwert — Diktieren funktioniert überall — höher wiegt.

**2. Die Passwortfeld-Erkennung wird schwächer.** Sie hing schon in M5 an der Subrolle
`AXSecureTextField`; jetzt greift sie zusätzlich nur dort, wo überhaupt ein AX-Element auffindbar
ist. In einer App ohne AX-Baum wird in ein Passwortfeld hineingetippt. Der Schaden ist asymmetrisch
harmlos: TypeLess tippt **hinein** und liest nie **heraus** — Folge ist ein fehlgeschlagener Login,
kein Datenleck. Das Datenschutz-Versprechen (nie Feldinhalte lesen) bleibt unberührt.

**3. Verpufftes Tippen ohne Netz.** Schluckt eine App annotierte Session-Ereignisse, ist das Diktat
verloren — die Zwischenablage bleibt bei erfolgreichem Tippen ja bewusst unangetastet, enthält den
Text also nicht. Das ist **kein neues** Risiko: In
allen Apps, in denen M5 heute direkt tippt, besteht es schon und ist nie aufgetreten. Die bekannten
Gründe fürs Verpuffen (fehlende Rechte, sichere Eingabe) sind durch Bedingung 1 und 2 abgedeckt.
Falls sich das in der Praxis als störend erweist, wäre ein Menüpunkt „letztes Diktat in die
Zwischenablage" der nächste Schritt — **nicht** Teil dieser Spec (YAGNI).

## Auswirkung auf den Code

| Datei | Änderung |
|---|---|
| `Insertion/InsertionTarget.swift` | `Fokusziel`-Whitelist und `Fokuskennung` entfernen; Schnittstelle auf `vordersteApp()`, `bedienungshilfenErteilt()`, `sichereEingabeAktiv()`, `istPasswortfeld()`, `weckeBedienungshilfen(fuer:)` reduzieren |
| `Dictation/DictationCoordinator.swift` | `stelleZu` auf die drei Bedingungen + Passwortfeld umbauen; `zielFokus` aus `verarbeite`/`handlePressed` entfernen |
| `Insertion/TextInserter.swift` | unverändert |
| `Tests/…/InsertionTargetTests.swift` | Whitelist-/Identitätsproben ersetzen durch Proben der vier neuen Bedingungen |
| `Tests/…/DictationCoordinatorTests.swift` | Zustellproben auf die neue Regel umschreiben |
| `CLAUDE.md` | M5-Abschnitt umschreiben: „fünf Bedingungen" → neue Regel; die überholte Behauptung, Suchfelder seien nicht erreichbar, streichen |

Die injizierbaren Nähte (`istVertrauenswuerdig`, `sichereEingabeAktiv`) **bleiben** — sie sind der
Grund, warum die Sicherheitsregeln überhaupt scharf testbar sind, unabhängig vom Zustand der
Maschine. Für `istPasswortfeld()` kommt eine gleichartige Naht dazu.

## Testbarkeit

Die Entscheidungslogik bleibt eine reine Funktion über mitgereichte Werte (`static stelleZu`, ohne
`self`) — jede der vier Bedingungen ist einzeln mit Attrappen prüfbar, ohne Fenster und ohne
erteilte Rechte. Für jede Bedingung eine Probe „greift" und „greift nicht", plus je eine
Mutationsprobe: Regel entfernen ⇒ Test rot. Die bestehende Regel „entweder eingefügt oder in der
Zwischenablage — nie ein drittes Ergebnis" bleibt und bleibt getestet.

**Handprobe (nicht automatisierbar):** Spotify-Suchfeld, VS-Code-Suchfeld, Mail-Rumpf, Claude,
Slack, Safari-Adressleiste, Terminal mit sicherer Eingabe, natives Passwortfeld. Dabei gezielt auf
Zeichenverlust bei langem Text achten (s. „Keine Mini-Pausen").

## Nicht Teil dieser Spec

- Simuliertes ⌘V als Einfügeweg — geprüft und verworfen: Es braucht die Zwischenablage und löst ein
  Problem, das mit direktem Tippen gar nicht entsteht.
- Wiederherstellen der Zwischenablage nach dem Einfügen — entfällt, weil die Zwischenablage im
  Erfolgsfall nicht mehr angefasst wird.
- Menüpunkt „letztes Diktat in die Zwischenablage" — erst, wenn Restrisiko 3 real auftritt.
