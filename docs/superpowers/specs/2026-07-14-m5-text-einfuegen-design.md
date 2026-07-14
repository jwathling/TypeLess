# M5 — Text an der Cursorposition einfügen

**Stand:** Entwurf freigegeben (14.07.2026)
**Ausgangslage:** M4 ist auf `main`. Diktieren funktioniert (Fn halten → sprechen → loslassen),
der fertige Text landet in der **Zwischenablage**, der Anwender drückt ⌘V.
**Ziel von M5:** Der Text landet direkt dort, wo der Cursor steht — ohne ⌘V, ohne die
Zwischenablage anzufassen.

---

## Entscheidungen des Anwenders (verbindlich)

Diese vier Punkte sind **nicht** technische Abwägungen, sondern Produktentscheidungen. Sie sind
in einem Gespräch getroffen worden und dürfen nicht ohne Rücksprache geändert werden.

| Frage | Entscheidung |
|---|---|
| Wohin soll der Text? | **In das Textfeld, in dem der Cursor beim Diktieren stand.** Wörtlich: „Wenn ich diktiere, muss ich mit dem Cursor schon in irgendein Textfeld geklickt haben. Dort soll der Text dann eingefügt werden." |
| Fokus hat sich während der Verarbeitung geändert? | **Nicht tippen.** Text in die Zwischenablage, Menü sagt es. Niemals in ein fremdes Fenster schreiben. |
| Zwischenablage überschreiben, wenn direkt eingefügt wurde? | **Nein — unangetastet lassen.** Diktieren und Kopieren dürfen sich nicht gegenseitig stören. |
| Direktes Einfügen nicht möglich? | **Auf die Zwischenablage ausweichen und es sagen.** Kein simuliertes ⌘V. |

Daraus folgt die **oberste Regel von M5**, die jede Implementierung einhalten muss:

> **Der Text wird entweder an der richtigen Stelle eingefügt — oder er liegt in der
> Zwischenablage. Ein drittes Ergebnis gibt es nicht.** Ein Diktat geht nie verloren, und es
> landet nie an einer Stelle, an der der Anwender es nicht haben wollte.

## Das Problem in einem Satz

Zwischen dem Loslassen der Taste und dem fertigen Text vergehen rund **6 Sekunden** (M1-Messwerte;
Optimierung erst in M8). TypeLess kann nicht in die Vergangenheit tippen — es tippt in das
Textfeld, das **beim Fertigwerden** den Fokus hat. Im Normalfall ist das dasselbe. Klickt der
Anwender zwischendurch woanders hin, ist es das nicht, und ein ungeprüftes Tippen schriebe das
Diktat in einen Slack-Chat oder ein Suchfeld.

Deshalb wird nicht *angenommen*, dass das Ziel stimmt — es wird **geprüft**.

---

## Architektur

Zwei neue Bausteine in `TypeLessCore`, beide als Protokoll (testbar ohne echte UI), beide mit
ihrer AppKit-/AX-Umsetzung in der App-Schicht bzw. hinter einem Protokoll:

```
Sources/TypeLessCore/Insertion/
  TextInserter.swift        # Protokoll: insert(_ text: String) throws
  InsertionTarget.swift     # Protokoll: Wer hat gerade den Fokus, und ist das ein Textfeld?
```

Der `DictationCoordinator` bleibt der Ort, an dem beides zusammenkommt — er bekommt zwei neue
Abhängigkeiten und eine neue Zustellregel. Er wächst dadurch; wenn die Zustell-Logik den
Koordinator unübersichtlich macht, wandert sie in einen eigenen Baustein `Zustellung`
(Entscheidung während der Umsetzung, nicht vorab).

### Datenfluss

```
Fn-Druck   ──▶ Fokus merken (welche App ist vorne? → PID)
               │
Fn-Loslassen ─▶ Aufnahme → Engine (~6 s) → fertiger Text
                                            │
                                            ▼
                              ┌─── Zustellung (prüft 4 Bedingungen) ───┐
                              │                                        │
                     alle erfüllt                            eine verletzt
                              │                                        │
                              ▼                                        ▼
                    TextInserter.insert()                    Pasteboard.write()
                    Zwischenablage bleibt                    Menü: „Text liegt in der
                    unberührt                                Zwischenablage — ⌘V"
```

### Die fünf Bedingungen fürs direkte Einfügen

Alle fünf müssen erfüllt sein, sonst greift die Zwischenablage:

1. **Bedienungshilfen erteilt** — und **Secure Event Input nicht aktiv**. Ohne das Recht kann
   TypeLess keine Tastatur-Ereignisse erzeugen. Und ist Secure Event Input an (Terminal →
   „Sichere Tastatureingabe", 1Password u. Ä.), verwirft macOS synthetische Tastendrücke
   **unabhängig** vom Recht — das Tippen verpufft dann wirkungslos. (Nachgetragen nach dem
   Abschluss-Review: Ohne diese Prüfung wäre das Diktat **spurlos weg** — weder eingefügt noch
   in der Zwischenablage —, bei zufriedener Anzeige.)
2. **Dieselbe App wie beim Fn-Druck.** Verglichen wird die Prozesskennung (PID) der vordersten
   App, gemerkt beim Fn-Druck des **jeweiligen** Diktats.
3. **Dasselbe Textfeld wie beim Fn-Druck.** Verglichen wird die **Identität** des fokussierten
   AX-Elements — **nie sein Inhalt** (s. „Datenschutz"). Entscheidung des Anwenders,
   nachgetragen nach dem Abschluss-Review: Ohne diese Bedingung genügte die gleiche App, und ein
   ⌘L während der Wartezeit ließe das Diktat in der **Adressleiste** des Browsers landen (oder in
   Mail im Betreff statt im Rumpf). Das entspricht nicht dem, was der Anwender wollte: *„Wenn ich
   diktiere, muss ich mit dem Cursor schon in irgendein Textfeld geklickt haben. Dort soll der
   Text dann eingefügt werden."*
   **Bewusst akzeptierter Preis:** Manche Apps bauen ihre AX-Elemente im Hintergrund neu, ohne
   dass der Anwender etwas tut. Dann weicht TypeLess gelegentlich **unnötig** auf die
   Zwischenablage aus. Das ist der harmlosere Fehler; der umgekehrte (Diktat in der Adressleiste)
   ist der ärgerlichere. **Offen bis zur Handprobe:** wie oft das in echten Apps (Safari, Chrome,
   Slack, Mail) über die ~6 s Wartezeit hinweg passiert. Tritt es häufig auf, ist direktes
   Einfügen dort faktisch tot und die Bedingung muss nachjustiert werden.
4. **Ein beschreibbares Textfeld hat den Fokus.** Über die AX-Schnittstelle erfragt. Deckt den
   Fall ab, dass der Anwender zwar in derselben App ist, aber gar nicht in einem Textfeld steht.
5. **Es ist kein Passwortfeld** (AX-Subrolle `AXSecureTextField`). In ein Passwortfeld tippt
   TypeLess **grundsätzlich nicht**.
   **Bekannte Grenze:** Apps mit lückenhafter AX-Umsetzung melden für ihr Passwortfeld unter
   Umständen **gar keine** Subrolle — dann sieht TypeLess ein normales Textfeld. Schließen ließe
   sich das nur, indem man den **Inhalt** des Feldes läse, und genau das schließt das
   Datenschutz-Versprechen aus. Die Lücke ist der Preis dieser Zusicherung, keine Nachlässigkeit.

Bedingung 4 ist zugleich die Antwort auf ein Problem, das sonst unlösbar wäre: Ob eine App eine
synthetische Eingabe **hinterher** geschluckt hat, lässt sich nicht zuverlässig feststellen —
`CGEventPost` ist in Apples Header als `void` deklariert und gibt **keinerlei** Rückmeldung. Ein
ausbleibender Fehler ist also **keine** Bestätigung, dass der Text angekommen ist. Deshalb wird
**vorher** gefragt statt hinterher gehofft.

---

## Die M4-Regel, die fällt

M4 kannte die Regel: *„Die Zwischenablage bekommt das Ergebnis in JEDEM Fall — auch von einer
Verarbeitung, die längst von einer jüngeren überholt wurde."* (s. `DictationCoordinator
.verarbeite` und `.beendeVerarbeitung`). Das war harmlos, solange der Anwender selbst ⌘V drückte.

**Mit automatischem Einfügen ist sie gefährlich** und wird ersetzt:

> Jedes fertige Diktat wird zugestellt — aber jedes prüft seinen **eigenen**, beim Fn-Druck
> gemerkten Fokus. Nicht den des jüngsten.

Ein überholtes Diktat tippt also nicht in das Fenster, in dem der Anwender inzwischen steht. Zwei
schnell hintereinander gesprochene Diktate landen dadurch in der richtigen Reihenfolge am
richtigen Ort — die Engine verarbeitet ohnehin serialisiert (Lock in `runtime.py`, M2), die
Ergebnisse treffen also in der Reihenfolge ein, in der gesprochen wurde.

Die bestehende `juengsteVerarbeitung`-Prüfung bleibt, aber **nur** für die Zustandsanzeige — sie
entscheidet nicht mehr über die Zustellung.

---

## Zustände

`SessionState` bekommt einen neuen Fall:

```swift
public enum SessionState: Sendable, Equatable {
    case idle
    case recording
    case processing
    case inZwischenablage      // NEU
    case failed(String)
}
```

`inZwischenablage` ist **kein Fehler**. Es ist der Normalfall des Ausweichwegs: Alles hat
funktioniert, der Text ist da, er konnte nur nicht sicher direkt eingefügt werden. Menütext:
**„Text liegt in der Zwischenablage — ⌘V zum Einfügen"**. Der Zustand fällt beim nächsten
Fn-Druck zurück auf `.recording`.

Ein eigener Zustand (statt `.failed`) ist wichtig, weil das Menüsymbol sonst ein Warnzeichen
zeigte, wo nichts schiefging — und weil der Anwender genau wissen soll, dass jetzt ⌘V dran ist.

## Fehlerverhalten

Unverändert gilt die Regel aus M4: **Bei jedem Fehlschlag bleibt die Zwischenablage
unangetastet** (alter Inhalt schlägt Leere) — mit der einen, ausdrücklichen Ausnahme, dass die
Zwischenablage der bewusst gewählte Ausweichweg ist. Dann und nur dann wird sie beschrieben.

| Fall | Verhalten |
|---|---|
| Engine liefert keinen Text (STT-Ausfall, Engine weg) | `.failed(Grund)`, Zwischenablage unangetastet |
| Engine liefert Text, LLM ausgefallen (`refined: false`) | **Kein Fehler** (M2-Vertrag) — Rohtext wird ganz normal zugestellt |
| Eine der vier Bedingungen verletzt | `.inZwischenablage`, Text in der Zwischenablage |
| `TextInserter` wirft (Ereignis nicht erzeugbar) | `.inZwischenablage`, Text in der Zwischenablage |

---

## Berechtigungen — die Lektion aus M4

In der Handprobe zu M4 kostete ein Berechtigungsproblem einen Abend: Ein `CGEventTap` lässt sich
auch **ohne** Eingabeüberwachung anlegen, `tapCreate` meldet keinen Fehler — der Tap sieht im
Hintergrund nur nie ein Ereignis. TypeLess **prüfte** das Recht bloß und **forderte es nie an**,
also fragte macOS nie, und das Menü behauptete „Bereit", während der Hotkey tot war.

M5 macht diesen Fehler nicht noch einmal. Für die **Bedienungshilfen** gilt daher verbindlich:

- **Anfordern, nicht nur prüfen:** `AXIsProcessTrustedWithOptions` mit
  `kAXTrustedCheckOptionPrompt: true` beim Programmstart — analog zu
  `PermissionsService.requestInputMonitoring()`, das in M4 aus genau diesem Grund entstanden ist.
- **Das Menü darf nicht lügen:** Fehlt das Recht, sagt die Statuszeile das — und zwar oben, nicht
  als eines von drei Häkchen weiter unten. Fehlender Zugriff heißt: Es wird nie direkt eingefügt,
  sondern immer die Zwischenablage benutzt. Das muss der Anwender wissen, bevor er sich wundert.
- **Kein stiller Ausfall:** TypeLess bleibt in diesem Zustand voll benutzbar (Zwischenablage-Weg),
  aber es tut nicht so, als sei alles in Ordnung.

Wichtig für die Handprobe: Die Ad-hoc-Signatur (`codesign --sign -`) erzeugt bei **jedem Neubau**
eine neue Identität; macOS hält TypeLess dann für eine andere App und verwirft alle erteilten
Rechte. Ein echtes Zertifikat gibt es erst in M8.

## Datenschutz

Die Haltung des Projekts bleibt unangetastet und wird durch M5 **nicht** aufgeweicht:

- Der `CGEventTap` in `FnKeyMonitor` behält seine Event-Maske aus **ausschließlich**
  `.flagsChanged`. **Er wird in M5 nicht angefasst.** Ihn um `.keyDown` zu erweitern wäre ein
  Datenschutzbruch.
- Die AX-Abfrage liest **nur**, ob das fokussierte Element ein beschreibbares Textfeld ist (Rolle
  und Bearbeitbarkeit) — **nicht dessen Inhalt**. TypeLess erfährt nie, was in dem Feld steht.
- Kein Logging von Diktaten, kein Text auf die Platte, kein Netzwerkzugriff. Unverändert.

---

## Testbarkeit

Beide neuen Bausteine sind Protokolle, damit der `DictationCoordinator` weiterhin vollständig mit
Attrappen prüfbar ist — kein Fenster, kein echtes Tippen, keine Hardware:

- **`InsertionTarget`** liefert im Test eine steuerbare Antwort („App X, Textfeld ja/nein,
  Passwortfeld ja/nein"). Damit lassen sich alle vier Bedingungen einzeln verletzen.
- **`TextInserter`** ist im Test eine Attrappe, die nur mitschreibt, was getippt worden wäre.

Die Tests müssen mindestens belegen:

1. Normalfall: Fokus unverändert, Textfeld da → getippt, **Zwischenablage unangetastet**.
2. App gewechselt → **nicht** getippt, Text in der Zwischenablage, `.inZwischenablage`.
3. Kein Textfeld im Fokus → **nicht** getippt, Zwischenablage.
4. Passwortfeld → **nicht** getippt, Zwischenablage.
5. Bedienungshilfen fehlen → **nicht** getippt, Zwischenablage.
6. `TextInserter` wirft → Zwischenablage (Diktat nicht verloren).
7. Zwei Diktate hintereinander: jedes prüft seinen **eigenen** gemerkten Fokus (die gefallene
   M4-Regel).
8. Engine-Fehler → `.failed`, Zwischenablage **unangetastet**.

Wie in M4 gilt: **Jeder Fix und jede Schutzregel braucht eine Mutationsprobe** — Regel entfernen,
Test muss **rot werden** (nicht hängen), Regel wiederherstellen, grün. Ein Test, der unter einer
Mutation hängt statt rot zu werden, ist wertlos; das ist in diesem Projekt dreimal passiert.

Der echte `CGEventTextInserter` und die echte AX-Abfrage brauchen zusätzlich je eine Probe an
echter Hardware, die sich **ohne erteiltes Recht selbst überspringt** (Muster aus M4:
`AudioRecorderTests`, `.enabled(if:)`).

## Was NICHT in M5 gehört (YAGNI)

- **Kein simuliertes ⌘V** — vom Anwender ausdrücklich abgelehnt.
- **Kein Sichern/Wiederherstellen der Zwischenablage** — wird nicht gebraucht, weil im Normalfall
  gar nicht auf die Zwischenablage geschrieben wird.
- **Kein Einfügen über die AX-API** (`kAXValueAttribute` setzen). Der ursprüngliche Plan nannte
  das als Option; es wird **verworfen**: Es überschreibt in vielen Apps das ganze Feld statt an
  der Cursorposition einzufügen. Die AX-Schnittstelle wird in M5 **nur zum Fragen** benutzt, nie
  zum Schreiben.
- **Keine App-spezifischen Sonderwege.** Wenn eine App auffällt, wird das in M8 behandelt.
- **Keine Latenz-Optimierung** — bleibt M8.
