# Direktes Einfügen in Electron-/Chromium-Apps — Design

**Datum:** 2026-07-25
**Status:** Entwurf zur Freigabe
**Meilenstein:** M5-Nachbesserung (Text-Einfügen) — eigenständiges Feature auf `main`.

## Ziel

TypeLess soll seinen Text auch in **Electron-/Chromium-Apps** (Claude, Slack, VS Code, Discord …)
**direkt an der Cursorposition** einfügen — nicht nur über die Zwischenablage. Ohne die
Sicherheitsregeln aus M5 aufzuweichen.

## Hintergrund (belegte Diagnose)

Eine Instrumentierung von `AXInsertionTarget` (Wegwerf-Branch `debug/ax-claude`) ergab eindeutig:
Bei Claude findet TypeLess **kein fokussiertes AX-Element** (`kAXFocusedUIElementAttribute` liefert
nichts) — weder beim Fn-Druck noch beim Zustellen. Zum Vergleich lieferte Notizen im selben Lauf
`rolle=AXTextArea settable=true`, stabile Identität, und der Text wurde direkt eingefügt.

Grund: **Chromium (die Basis von Electron) baut seinen Accessibility-Baum nicht von selbst auf.**
Er aktiviert ihn erst, wenn eine assistive Technologie das anfordert — über das dokumentierte
Attribut **`AXManualAccessibility`** (oder wenn VoiceOver läuft). Ohne diese Anforderung ist der
AX-Baum leer, TypeLess sieht kein Zielfeld und weicht (korrekt, konservativ) auf die Zwischenablage
aus.

Zur Einordnung: Apples eingebautes Diktat schreibt in dieselben Apps problemlos, weil es über den
**System-Texteingabe-Kanal in Echtzeit** liefert und die App gar nicht erst über die
Bedienungshilfen befragt. TypeLess prüft dagegen bewusst **vorher** über die Bedienungshilfen (weil
zwischen Sprechen und fertigem Text ~6 s liegen, in denen der Fokus wandern kann) — und genau diese
Prüfung geht bei Electron leer aus. Das eigentliche Tippen (`CGEventKeyboardSetUnicodeString`) käme
in Electron an; es ist die Vorab-Prüfung, die bremst.

## Ansatz

**Electron-Apps „aufwecken":** Bevor TypeLess das fokussierte Element abfragt, setzt es auf dem
App-Element (per Prozesskennung) das Attribut `AXManualAccessibility = true`. Chromium baut daraufhin
seinen AX-Baum auf; danach liefern die bestehenden Abfragen (`fokusziel()`, `fokusKennung()`) für
Electron-Apps dieselben Daten wie für native Apps, und die **fünf M5-Bedingungen greifen unverändert**.

```
AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid),
                             "AXManualAccessibility" as CFString, kCFBooleanTrue)
```

- **Nur `AXManualAccessibility`**, bewusst **nicht** `AXEnhancedUserInterface`: Letzteres löst bei
  manchen Apps ungewollte Fenster-/Layout-Änderungen aus. `AXManualAccessibility` ist der
  Chromium-spezifische, nebenwirkungsarme Schalter.
- Bei **nativen** Apps ist das Setzen wirkungslos (sie kennen das Attribut nicht / haben ihren Baum
  ohnehin) — ein harmloser No-Op. Fehler beim Setzen werden ignoriert.
- Setzen braucht die **Bedienungshilfen** (wie jede AX-Schreiboperation). Fehlen sie, wird ohnehin
  nie direkt eingefügt — konsistent, kein Sonderfall.

### Wann geweckt wird — das Timing

Der AX-Baum braucht nach dem Setzen einen kurzen Moment. Damit er **vor** dem Fn-Druck steht (und
damit auch die M5-Prüfung „ist der Cursor noch im selben Feld?", die sich das Feld **beim Fn-Druck**
merkt, sauber greift), wird an **zwei** Stellen geweckt:

1. **Primär: beim App-Wechsel.** Ein Beobachter auf
   `NSWorkspace.didActivateApplicationNotification` weckt jede App, zu der der Anwender wechselt.
   Beim Fn-Druck ist der Baum dann längst wach → direktes Einfügen klappt beim **ersten** Versuch.
2. **Absicherung: beim Fn-Druck.** Zusätzlich weckt TypeLess beim Fn-Druck die vorderste App
   (idempotent). Das deckt den Randfall ab, dass eine App schon im Vordergrund war, als TypeLess
   startete (dann gab es kein `didActivate`-Ereignis). Für diesen einen Erststart-Fall kann der
   erste Versuch noch in der Zwischenablage landen (Baum baut sich gerade auf); ab dem zweiten
   greift er.

### Nebenwirkung (transparent benannt)

TypeLess aktiviert damit den Accessibility-Baum in Apps, zu denen der Anwender wechselt — genau das,
was ein Screenreader tut, mit minimalem Mehraufwand in der Ziel-App. Der Baum bleibt aktiv, solange
die App läuft. Das ist der etablierte, von Chromium selbst vorgesehene Mechanismus, kein Eingriff in
fremden Speicher o. Ä.

## Architektur

- **`InsertionTarget`-Protokoll** bekommt eine Methode `weckeBedienungshilfen(fuer pid: pid_t)`
  (fragt nur/schreibt nur dieses eine Attribut, liest **keinen** Inhalt). `AXInsertionTarget`
  implementiert sie über `AXUIElementSetAttributeValue`; die Test-Attrappe kann sie beobachten.
- **Ein kleiner Aufwecker-Typ** (`BedienungshilfenAufwecker` o. ä.) kapselt den
  `NSWorkspace`-Aktivierungs-Beobachter und ruft `weckeBedienungshilfen(fuer:)` für jede aktivierte
  App. Er lebt in `TypeLessCore` (das die AX-/AppKit-Schicht ohnehin nutzt), wird in der App-Schicht
  (`TypeLessApp`/AppDelegate) beim Start erzeugt und am Leben gehalten — wie die anderen Beobachter.
- **Fn-Druck-Weckung:** Im `DictationCoordinator` wird beim `.pressed` — dort, wo ohnehin
  `vordersteApp()` und `fokusKennung()` gelesen werden — vorab `weckeBedienungshilfen(fuer:)` für die
  vorderste App aufgerufen.

Die **fünf M5-Bedingungen und `stelleZu` bleiben unverändert.** Dieser Fix stellt nur sicher, dass
die AX-Abfragen bei Electron-Apps überhaupt Daten liefern.

## Datenschutz

Unverändert. `weckeBedienungshilfen(fuer:)` **setzt** ein einziges Bool-Attribut auf dem App-Element
und **liest nichts**. Die Feld-Abfragen bleiben wie bisher auf Rolle/Setzbarkeit/Identität beschränkt,
nie Inhalt. Nichts verlässt den Rechner.

## Bekannte Grenze (erweitert, bewusst akzeptiert)

Manche Electron-Apps weisen ihre **Passwortfelder** nicht über die AX-Subrolle
`AXSecureTextField` aus (schon in M5 benannt). Bisher war das folgenlos, weil TypeLess in
Electron-Apps nie direkt tippte. Mit diesem Fix werden Electron-Felder zugänglich — dadurch könnte
TypeLess in ein **nicht als solches erkanntes** Passwortfeld einer Electron-App tippen. Das Risiko
ist gering (man diktiert keine Passwörter, und man tippt bewusst per Fn-Taste), aber es ist real und
hier benannt. Schließen ließe es sich nur durch Lesen des Feldinhalts — das schließt das
Datenschutz-Versprechen aus. Vom Anwender als vertretbar akzeptiert.

## Fehlerbehandlung

- Schlägt das Setzen von `AXManualAccessibility` fehl (native App, fehlende Rechte, App verschwindet),
  wird der Fehler **ignoriert** — TypeLess verhält sich dann exakt wie heute (Zwischenablage-Fallback).
- Der Aufwecker ist **nie** Voraussetzung fürs Diktat: Fällt er ganz aus, läuft alles wie bisher,
  nur ohne direktes Einfügen in Electron.

## Testing-Strategie

- **Verdrahtung (Unit):** Der `DictationCoordinator` ruft beim Fn-Druck
  `weckeBedienungshilfen(fuer:)` für die vorderste App — mit der Test-Attrappe des `InsertionTarget`
  prüfbar (die Attrappe merkt sich die geweckte PID). Die M5-Zustell-Tests bleiben unverändert grün.
- **Aufwecker-Typ:** die reine „bei Aktivierung wecken"-Verdrahtung, soweit ohne echtes `NSWorkspace`
  sinnvoll testbar (Auslöser → Aufruf).
- **Echter AX-Set + NSWorkspace-Beobachter:** Handprobe (kein sinnvoller Unit-Test), Teil der Abnahme.
- **Abnahme (Handprobe, der eigentliche Beweis):**
  1. In **Claude** diktieren → Text wird **direkt** eingefügt (nicht Zwischenablage).
  2. In einer weiteren Electron-App (z. B. **VS Code** oder **Slack**) → ebenfalls direkt.
  3. In **Notizen** (nativ) → weiter direkt (keine Regression).
  4. In ein Ziel, das die Zwischenablage erzwingt (z. B. Terminal) → weiter Zwischenablage.
  5. Kurz gegenprüfen, dass der App-Wechsel-Weg greift (erster Diktat-Versuch nach Wechsel zu Claude
     klappt schon direkt).

## Umsetzungs-Reihenfolge (Grobschnitt)

1. `InsertionTarget`-Protokoll um `weckeBedienungshilfen(fuer:)` erweitern; `AXInsertionTarget`
   implementiert das Setzen von `AXManualAccessibility`. Test-Attrappe(n) nachziehen.
2. Fn-Druck-Weckung im `DictationCoordinator` (Unit-Test: vorderste App wird geweckt).
3. `BedienungshilfenAufwecker` (NSWorkspace-Aktivierungs-Beobachter) + Verdrahtung in der App-Schicht.
4. Handprobe: Claude/VS Code/Slack direkt, Notizen ohne Regression, Terminal weiter Zwischenablage.
5. `CLAUDE.md`-Notiz zu den bekannten Grenzen aktualisieren (Electron jetzt unterstützt; Passwortfeld-
   Grenze in Electron erweitert benannt).
