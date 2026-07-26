# Einfach tippen — Text in jedes Feld einfügen — Design

**Datum:** 2026-07-26
**Status:** Entwurf zur Freigabe
**Meilenstein:** M5-Umkehrung (Text-Einfügen) — eigenständiges Feature auf `main`.

## Ziel

Drei zusammenhängende Änderungen am Zustellweg:

1. **Überall einfügen.** TypeLess soll seinen Text auch dort an der Cursorposition einfügen, wo die
   Bedienungshilfen keine oder eine unbrauchbare Auskunft geben: **Spotify-Suchfeld**,
   **VS-Code-Suchfeld**, und jedes weitere Feld, das seine AX-Rolle nicht sauber meldet.
2. **Zwischenablage als Netz.** Jedes Diktat landet **zusätzlich** in der Zwischenablage, damit kein
   Text verloren gehen kann — auch dann nicht, wenn das Tippen unerwartet verpufft.
3. **Abbruch beim Sprechen sichtbar machen.** Der Abbruch existiert technisch schon, gibt aber keine
   Rückmeldung.

Der Weg zu (1) ist eine **Umkehrung der M5-Logik**: nicht mehr „fragen, ob getippt werden darf",
sondern „tippen — außer in den wenigen Fällen, in denen es nachweislich schadet oder wirkungslos
wäre".

Der Abbruch **während der Verarbeitung** ist bewusst **nicht** Teil dieser Spec — er braucht eine
eigene Hotkey-Infrastruktur und ist als eigenes Feature geführt (s. Spec `2026-07-26-diktat-abbrechen-design.md`).

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

## Teil 1: Die neue Zustellregel

`stelleZu` prüft nur noch **vier Bedingungen, die alle ohne fokussiertes AX-Element auskommen**
(die Passwortfeld-Prüfung, soweit sie greift, eingeschlossen). Sonst wird getippt.

```
1. Bedienungshilfen erteilt?      AXIsProcessTrusted()          — sonst verpufft jedes CGEvent
2. Sichere Eingabe aus?           IsSecureEventInputEnabled()   — sonst verwirft macOS das Ereignis
3. Dieselbe App wie beim Druck?   NSWorkspace.frontmost…        — braucht kein Sonderrecht
4. Kein Passwortfeld?             AX-Subrolle, falls verfügbar

alle vier erfüllt  -> tippen
sonst              -> nur Zwischenablage
```

Bedingung 1 und 2 sind **keine Vorsicht, sondern Physik**: Ohne Bedienungshilfen und bei aktiver
sicherer Eingabe (Terminal, 1Password) verwirft macOS synthetische Tastatur-Ereignisse garantiert.
Ohne diese beiden Prüfungen wäre das Tippen wirkungslos, bei zufriedener Anzeige. Beide kosten
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

## Teil 2: Zwischenablage als Netz

**Jedes Diktat mit nicht-leerem Text wird in die Zwischenablage geschrieben — vor dem Tippen.**

Die Reihenfolge ist tragend, nicht beliebig: Nur wenn der Text **vor** dem Tippversuch in der
Zwischenablage liegt, trägt das Netz auch dann, wenn das Tippen unerwartet verpufft (App schluckt
annotierte Session-Ereignisse). Umgekehrt — erst tippen, dann bei Misserfolg schreiben — funktioniert
nicht, weil `CGEventPost` keinen Misserfolg meldet.

Damit ist die bisherige Zusicherung **„bei Erfolg bleibt die Zwischenablage unangetastet"
aufgehoben**. Das war eine ausdrückliche Anwender-Entscheidung aus M5 und wird hier bewusst
zurückgenommen, weil das Netz höher wiegt.

**Der Preis, bewusst gezahlt:** Nach jedem Diktat ist vorher Kopiertes weg. Wer eine URL kopiert und
dann diktiert, findet die URL nicht mehr in der Zwischenablage. Als Nebennutzen ist das letzte
Diktat dafür immer greifbar und lässt sich mehrfach einfügen.

Unverändert bleiben zwei Regeln:

- **Leerer Text wird nicht geschrieben.** Es gibt nichts zu retten, und ein leerer Text würde die
  Zwischenablage ohne Gegenwert zerstören (`.nichtsErkannt`).
- **Bei einem Fehler bleibt die Zwischenablage unangetastet** (Engine weg, STT-Ausfall): Es gibt
  keinen Text, also nichts zu schreiben — alter Inhalt schlägt Leere.

**Die Anzeige muss weiter unterscheiden.** Obwohl der Text jetzt immer in der Zwischenablage liegt,
bleibt die Unterscheidung `.eingefuegt` gegen `.inZwischenablage` erhalten: Sie sagt dem Anwender, ob
er noch ⌘V drücken muss. Die Textvorschau im Overlay erscheint weiterhin nur bei
`.inZwischenablage` — beim Einfügen steht der Text ja schon im Feld.

## Teil 3: Abbruch beim Sprechen sichtbar machen

Der Abbruch **existiert schon**, als Nebeneffekt der Fn-als-Modifier-Wache: Wer bei gehaltenem Fn
eine Taste drückt, dessen Diktat wird verworfen (`KeyDownCounter`, s. `handleReleased()`). Redest du,
merkst „Quatsch" und tippst Escape, während Fn unten bleibt, ist das Diktat weg — Zwischenablage
unberührt, Engine nie bemüht.

Das passiert heute **kommentarlos**. Genau das ändert dieser Teil: Das Overlay meldet kurz
„Abgebrochen".

**Die Wache selbst bleibt inhaltlich unverändert.** Insbesondere bleibt die Event-Maske des Taps
ausschließlich `.flagsChanged` — sie um `.keyDown` zu erweitern wäre ein Datenschutzbruch (M4).
Es kommt nur eine Rückmeldung hinzu.

### Wann die Meldung erscheint — und wann nicht

Die Wache kann nicht unterscheiden, ob der Anwender **abbrechen** wollte oder Fn nur als **Modifier**
benutzt hat (Fn+Pfeil, Fn+Entf). Beides führt zum Verwerfen, und das ist richtig. Eine Meldung bei
*jedem* Fn+Pfeil wäre aber ein Ärgernis — das ist normale Tastaturnutzung, kein Diktat.

Deshalb wird an die bereits vorhandene Schwelle angeknüpft: Die Meldung erscheint **nur, wenn
mindestens `minimumSampleCount` Audio aufgenommen wurde** — also wenn der Anwender Fn lange genug
gehalten hat, dass ein Diktat plausibel ist. Kurzes Fn+Pfeil bleibt kommentarlos wie heute.

## Restrisiko — ehrlich benannt

**1. Fokuswechsel innerhalb derselben App.** Wechselt der Anwender während der ~6 s das Feld,
ohne die App zu wechseln, landet der Text im neuen Feld. Beispiele: ⌘L in die Browser-Adressleiste,
Tab vom Mail-Rumpf ins Betreff-Feld. Das ist **exakt das Ergebnis, das echtes Tippen gehabt hätte**.
Bewusst eingekauft, weil der Gegenwert — Diktieren funktioniert überall — höher wiegt. Der Text liegt
zudem in der Zwischenablage (Teil 2), ist also nicht verloren, sondern nur an der falschen Stelle.

**2. Die Passwortfeld-Erkennung wird schwächer.** Sie hing schon in M5 an der Subrolle
`AXSecureTextField`; jetzt greift sie zusätzlich nur dort, wo überhaupt ein AX-Element auffindbar
ist. In einer App ohne AX-Baum wird in ein Passwortfeld hineingetippt. Der Schaden ist asymmetrisch
harmlos: TypeLess tippt **hinein** und liest nie **heraus** — Folge ist ein fehlgeschlagener Login,
kein Datenleck. Das Datenschutz-Versprechen (nie Feldinhalte lesen) bleibt unberührt.

**3. Verpufftes Tippen** — durch Teil 2 **abgeräumt**: Der Text liegt in jedem Fall in der
Zwischenablage, ein ⌘V rettet ihn. Damit gilt „ein Diktat darf nie verloren gehen" wieder
uneingeschränkt, und zwar erstmals auch für die Apps, in denen M5 heute schon ohne Netz tippt.

## Auswirkung auf den Code

| Datei | Änderung |
|---|---|
| `Insertion/InsertionTarget.swift` | `Fokusziel`-Whitelist und `Fokuskennung` entfernen; Schnittstelle auf `vordersteApp()`, `bedienungshilfenErteilt()`, `sichereEingabeAktiv()`, `istPasswortfeld()`, `weckeBedienungshilfen(fuer:)` reduzieren |
| `Dictation/DictationCoordinator.swift` | `stelleZu` auf die vier Bedingungen umbauen und die Zwischenablage **vor** dem Tippen füllen; `zielFokus` aus `verarbeite`/`handlePressed` entfernen; im Verwerfen-Pfad von `handleReleased()` die Abbruch-Meldung setzen (nur über der Audio-Schwelle) |
| `Overlay/OverlayZustand.swift` | Fall `.abgebrochen` ergänzen (kurze Anzeigedauer, wie `.fehler` ohne Fehlercharakter) |
| `Dictation/SessionState` | Dokumentation von `.inZwischenablage` nachziehen — sie zählt heute die „fünf Bedingungen" auf |
| `Insertion/TextInserter.swift` | unverändert |
| `Tests/…/InsertionTargetTests.swift` | Whitelist-/Identitätsproben ersetzen durch Proben der vier neuen Bedingungen |
| `Tests/…/DictationCoordinatorTests.swift` | Zustellproben auf die neue Regel umschreiben; Proben für Netz-Reihenfolge und Abbruch-Meldung ergänzen |
| `CLAUDE.md` | M5-Abschnitt umschreiben: „fünf Bedingungen" → neue Regel; die überholte Behauptung, Suchfelder seien nicht erreichbar, streichen; Zwischenablage-Verhalten korrigieren |

Die injizierbaren Nähte (`istVertrauenswuerdig`, `sichereEingabeAktiv`) **bleiben** — sie sind der
Grund, warum die Sicherheitsregeln überhaupt scharf testbar sind, unabhängig vom Zustand der
Maschine. Für `istPasswortfeld()` kommt eine gleichartige Naht dazu.

## Testbarkeit

Die Entscheidungslogik bleibt eine reine Funktion über mitgereichte Werte (`static stelleZu`, ohne
`self`) — jede der vier Bedingungen ist einzeln mit Attrappen prüfbar, ohne Fenster und ohne
erteilte Rechte. Für jede Bedingung eine Probe „greift" und „greift nicht", plus je eine
Mutationsprobe: Regel entfernen ⇒ Test rot.

Eigene Proben für die neuen Teile:

- **Netz-Reihenfolge:** Die Zwischenablage-Attrappe muss den Text auch dann enthalten, wenn die
  Einfüge-Attrappe wirft — und ebenso, wenn sie *nicht* wirft (Netz gilt immer).
- **Kein Netz ohne Text:** leerer Text ⇒ Zwischenablage unangetastet.
- **Kein Netz bei Fehler:** Engine wirft ⇒ Zwischenablage unangetastet.
- **Abbruch-Meldung:** über der Audio-Schwelle ⇒ `.abgebrochen`; darunter (Fn+Pfeil) ⇒ kommentarlos
  `.aus`. Beide Richtungen, weil genau hier der Ärgernis-Fall liegt.

Die Regel „entweder eingefügt oder in der Zwischenablage — nie ein drittes Ergebnis" bleibt und
bleibt getestet; sie wird durch das Netz sogar leichter einzuhalten.

**Handprobe (nicht automatisierbar):** Spotify-Suchfeld, VS-Code-Suchfeld, Mail-Rumpf, Claude,
Slack, Safari-Adressleiste, Terminal mit sicherer Eingabe, natives Passwortfeld. Dabei gezielt auf
Zeichenverlust bei langem Text achten (s. unten).

## Bewusst nicht enthalten

- **Keine Mini-Pausen zwischen den Häppchen.** Verlorene Zeichen bei schnell gepostetem
  `CGEventPost` sind eine bekannte Fehlerklasse (Electron, Java), in TypeLess aber **nie
  aufgetreten** — M5 wurde ohne Pausen in mehreren Apps handverifiziert. Prophylaxe ohne Beleg wäre
  genau der Fehler, den diese Spec bei den AX-Abfragen korrigiert. Nachrüsten, falls die Handprobe
  Zeichenverlust zeigt (Kosten wären ohnehin vernachlässigbar: ~26 ms bei 250 Zeichen).
- **Simuliertes ⌘V als Einfügeweg** — geprüft und verworfen: Es braucht die Zwischenablage als
  Übertragungsweg und löst ein Problem, das mit direktem Tippen gar nicht entsteht.
- **Diktat-Verlauf im Menü** statt des Zwischenablage-Netzes — die aufwandsärmere Variante gewinnt
  zuerst. Wird erst relevant, wenn das Überschreiben der Zwischenablage im Alltag stört.
- **Abbruch während der Verarbeitung** — eigenes Feature, s. Spec `2026-07-26-diktat-abbrechen-design.md`.
