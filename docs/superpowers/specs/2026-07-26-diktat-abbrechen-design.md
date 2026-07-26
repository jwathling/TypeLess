# Diktat abbrechen — Design

**Datum:** 2026-07-26
**Status:** Entwurf zur Freigabe
**Meilenstein:** eigenständiges Feature auf `main`. Baut auf der Spec
`2026-07-26-einfach-tippen-design.md` auf (dort Teil 3: Abbruch **beim Sprechen**).

## Ziel

Ein laufendes Diktat soll **während der Verarbeitung** abbrechbar sein — also in den ~6 s zwischen
dem Loslassen der Fn-Taste und dem Erscheinen des Textes. Wer merkt „das war Quatsch", soll
verhindern können, dass der Text im Feld landet.

**Abgrenzung.** Der Abbruch **während des Sprechens** (Fn noch gehalten) existiert bereits als
Nebeneffekt der Fn-als-Modifier-Wache und bekommt in der Einfach-tippen-Spec nur eine Rückmeldung.
Diese Spec deckt ausschließlich die **Verarbeitungsphase** ab, für die es bisher **keinen** Weg gibt.

## Hintergrund

Nach dem Loslassen läuft die Verarbeitung in einer Task, die in `verarbeitungen[id]` liegt
(`DictationCoordinator`). Sie ist heute nicht abbrechbar: Es gibt keinen Auslöser, und der einzige
Ausgang ist die Zustellung.

Der technische Abbruch selbst ist unproblematisch — `Task.cancel()` genügt, und der Transport ist
darauf vorbereitet: `HTTPUnixTransport.roundTrip` hängt in `withTaskCancellationHandler` und schließt
die Verbindung beim Abbruch (der Kommentar dort nennt genau diesen Fall). Das Problem ist der
**Auslöser**.

### Warum kein Event-Tap

Ein globaler Escape-Hotkey über einen `CGEventTap` wäre ein Datenschutzbruch. Die Event-Maske des
bestehenden Taps bleibt laut M4-Regel **ausschließlich `.flagsChanged`**; sie um `.keyDown` zu
erweitern hieße, jeden Tastendruck des Anwenders mitzulesen. Das ist ausgeschlossen.

### Der Weg: temporär registrierter Hotkey

`RegisterEventHotKey` (Carbon — im Projekt schon für `IsSecureEventInputEnabled` in Gebrauch) **liest
keine Tasten mit**. Es meldet genau eine Kombination beim System an; das System ruft zurück, wenn sie
gedrückt wird. Alle anderen Tastendrücke bleiben unsichtbar. Datenschutzlich ist das genau das
Gegenteil eines Taps.

Zweiter Baustein: **Der Hotkey wird nur registriert, solange er gebraucht wird** — beim Eintritt in
`.processing`, und beim Verlassen wieder freigegeben. Außerhalb der Verarbeitung ist Escape für alle
anderen Apps völlig normal. Ein dauerhaft registriertes Escape würde es systemweit blockieren, was
inakzeptabel wäre.

Während `.recording` wird **nicht** registriert: Dort erledigt die Fn-als-Modifier-Wache den Abbruch
schon (s. Einfach-tippen-Spec, Teil 3). Für den Anwender ist das Verhalten identisch — Escape bricht
ab —, nur der Mechanismus dahinter unterscheidet sich je Phase.

## Ansatz

```
Eintritt in .processing   -> Hotkey Escape registrieren
Escape gedrückt           -> verarbeitungen[juengste]?.cancel()
Verlassen von .processing -> Hotkey freigeben  (in JEDEM Fall: Erfolg, Fehler, Abbruch)
```

Abgebrochen wird die **jüngste** Verarbeitung (`juengsteVerarbeitung`) — das ist die, deren Overlay
der Anwender gerade sieht. Ältere, noch laufende Verarbeitungen bleiben unberührt; sie gehören zu
einem früheren Diktat, das der Anwender nicht gemeint hat.

### Der Abbruch ist kein Fehler

`verarbeite` fängt heute jeden Fehler des `await client.process(...)` ab und meldet
`.fehler(beschreibe(error))`. Ein Abbruch käme dort als `CancellationError` an und würde als
Fehlschlag angezeigt — falsch. Er braucht einen eigenen Ausgang: Zustellung `.abgebrochen`,
Overlay `.abgebrochen`, `session` zurück auf `.idle`. Kein Warnzeichen im Menü, weil nichts
schiefgegangen ist.

### Die Zwischenablage bleibt bei Abbruch leer

Die Einfach-tippen-Spec füllt die Zwischenablage bei **jedem** Diktat als Netz. Bei einem Abbruch
gilt das **nicht**: Der Anwender will diesen Text ausdrücklich nicht. Das ist konsistent mit der
bestehenden Regel für Fehlerfälle — alter Inhalt schlägt einen unerwünschten neuen.

Praktisch ergibt sich das von selbst, wenn der Abbruch greift, **bevor** `stelleZu` läuft (dort wird
die Zwischenablage gefüllt).

### Der Schnitt ist atomar — kein halbes Ergebnis

Der kritische Moment: Was, wenn Escape eintrifft, während die Zustellung schon läuft?

Der Ablauf in `verarbeite` ist `await client.process(...)` → `stelleZu(...)` → `beendeVerarbeitung(...)`.
Beide letzten Schritte sind **synchron** und laufen auf dem `MainActor`. Es genügt daher **ein
`Task.isCancelled`-Check unmittelbar vor `stelleZu`**:

- Meldet er `true` → nichts zustellen, `.abgebrochen`.
- Meldet er `false` → zustellen. Ein danach eintreffender Abbruch kann nichts mehr bewirken, weil
  zwischen Check und Zustellung **kein Suspension-Punkt** liegt.

Damit gibt es kein Fenster für ein halbes Ergebnis: Entweder abgebrochen oder zugestellt. Das ist
dieselbe Zusicherung, die M5 mit „nie ein drittes Ergebnis" gibt.

**Ehrlich benannt:** Ein Abbruch, der später als dieser Check eintrifft, wird ignoriert — der Text
ist dann eingefügt. Bei ~6 s Verarbeitung und einem Check am Ende ist das Fenster winzig, aber es
existiert, und es ist die sichere Seite (lieber ein nicht abgebrochenes Diktat als ein halb
eingefügtes).

### Die Engine läuft weiter

Der Abbruch schließt die HTTP-Verbindung, aber die Engine verarbeitet ihr Diktat zu Ende: Die
MLX-Generierung läuft in einem Worker-Thread und ist nicht unterbrechbar, und `to_thread.run_sync`
lässt sich nicht wirklich abbrechen (dieselbe Einsicht steht schon im Streaming-Zweig).

Folge: Das Ergebnis wird verworfen, und ein unmittelbar folgendes Diktat wartet ggf. wenige Sekunden
auf den Lock. Das ist tolerierbar. Ein echter serverseitiger Abbruch bräuchte einen neuen Endpunkt
und eine unterbrechbare Generierung — **nicht** Teil dieser Spec (YAGNI).

## Bekannte Grenze: Escape-Kollision

Solange die Verarbeitung läuft (~6 s), ist Escape systemweit belegt. Poppt in dieser Zeit ein Dialog
auf, den der Anwender mit Escape schließen will, bricht er stattdessen sein Diktat ab und der Dialog
bleibt offen.

Das ist der Preis der intuitivsten Taste. Abgemildert dadurch, dass das Overlay während der
Verarbeitung sichtbar ist — der Anwender sieht, dass ein Diktat läuft. Eine konfigurierbare
Abbruch-Taste gehört in die Settings-UI (M7) und ist hier nicht vorgesehen.

## Auswirkung auf den Code

| Datei | Änderung |
|---|---|
| `Hotkey/AbbruchHotkey.swift` (neu) | Protokoll + Carbon-Umsetzung (`RegisterEventHotKey`/`UnregisterEventHotKey`), Callback als `@Sendable`-Closure. Protokoll, damit ohne echte Registrierung testbar — gleiche Bauart wie `Pasteboard`, `TextInserter`, `InsertionTarget` |
| `Dictation/DictationCoordinator.swift` | Hotkey beim Eintritt in `.processing` registrieren, beim Verlassen freigeben; `brichAb()`; `Task.isCancelled`-Check vor `stelleZu`; `CancellationError` als eigener Ausgang statt `.fehler` |
| `Dictation/Zustellung` | Fall `.abgebrochen` ergänzen |
| `Overlay/OverlayZustand.swift` | `.abgebrochen` wird bereits in der Einfach-tippen-Spec ergänzt — hier nur mitbenutzt |
| `Tests/…/DictationCoordinatorTests.swift` | Proben s. unten |
| `CLAUDE.md` | Abbruch-Verhalten dokumentieren (beide Phasen, mit Escape-Grenze) |

## Testbarkeit

Mit einer Hotkey-Attrappe, die den Callback auf Kommando auslöst, ist alles ohne echte Registrierung
prüfbar:

- **Registrierung folgt dem Zustand:** registriert beim Eintritt in `.processing`, freigegeben beim
  Verlassen — und zwar auf **allen** Ausgängen: Erfolg, Fehler, Abbruch. Je eine Probe; ohne die
  bliebe der Hotkey hängen und Escape wäre dauerhaft blockiert.
- **Abbruch während der Verarbeitung** ⇒ `.abgebrochen`, Zwischenablage **unangetastet**, Einfüger
  nie aufgerufen. Mutationsprobe: Check vor `stelleZu` entfernen ⇒ Test rot.
- **Abbruch ist kein Fehler:** `session` endet auf `.idle`, nicht `.failed`; Overlay zeigt
  `.abgebrochen`, nicht `.fehler`.
- **Abbruch trifft die jüngste Verarbeitung**, nicht eine ältere noch laufende.
- **Escape ohne laufendes Diktat** (kein `.processing`) ⇒ folgenlos, kein Zustandswechsel.

**Handprobe:** Diktat abbrechen und prüfen, dass kein Text erscheint und die Zwischenablage ihren
alten Inhalt behält; danach ein normales Diktat, um zu belegen, dass der Hotkey freigegeben wurde und
Escape wieder normal funktioniert.

## Bewusst nicht enthalten

- **Menüpunkt „Diktat abbrechen"** — bei ~6 s Verarbeitung ist das Öffnen des Menüs langsamer als
  das Diktat. Escape deckt den Fall vollständig ab.
- **Serverseitiger Abbruch** (neuer Endpunkt, unterbrechbare Generierung) — s. „Die Engine läuft
  weiter".
- **Konfigurierbare Abbruch-Taste** — gehört in die Settings-UI (M7).
- **Rückgängig nach dem Einfügen** — das ist ⌘Z in der Zielanwendung, nicht TypeLess' Aufgabe.
