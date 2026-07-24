# Diktat-Overlay — Design

**Datum:** 2026-07-24
**Status:** Entwurf zur Freigabe
**Meilenstein:** M6/M7-nah (UI-Rückmeldung) — eigenständiges Feature auf `main`.

## Ziel

Während eines Diktats ein **kleines, dezentes Overlay** einblenden, das zeigt, was TypeLess gerade
tut (hört zu / verarbeitet / fertig) und — wenn der Text in der Zwischenablage landet — kurz den
erkannten Text. Es erscheint **nur während eines Diktats** und verschwindet danach wieder. Keine
Töne. Das Menüleisten-Symbol bleibt zusätzlich unverändert.

Das kehrt die bewusste M4-Entscheidung „kein Overlay, keine Töne — das Menüleisten-Symbol ist die
einzige Rückmeldung" **gezielt** um: Ein Overlay kommt hinzu, Töne nicht. Grund: Die ~6 s
Verarbeitung ohne jede Rückmeldung fühlen sich länger und unsicherer an, als sie sind; ein kurzer,
ruhiger Hinweis „ich höre / ich denke / fertig" verbessert das Erlebnis spürbar. `CLAUDE.md` wird
entsprechend angepasst.

## Nicht-Ziele

- **Keine Töne** (bleibt bewusst aus).
- **Kein Dauer-Overlay** — nur während eines Diktats sichtbar.
- **Kein Live-Transkript** — der Text erscheint erst am Ende (das STT ist nicht streaming; s.
  Erinnerung „STT-Latenz-Boden"). Der Live-Pegel zeigt „ich höre", nicht „das habe ich verstanden".
- **Keine Interaktion** — das Overlay ist reine Anzeige, man klickt es nicht an (s. „passives
  Fenster" unten).

## Verhalten & Zustände

Das Overlay erscheint beim Aufnahmestart (Fn gedrückt) unten mittig und durchläuft je nach Verlauf:

| Phase | Anzeige | Dauer |
|---|---|---|
| **Hört zu** | Live-Pegel (kleine Balken, reagieren auf die Stimme) + „Hört zu …" | solange aufgenommen wird |
| **Verarbeitet** | Spinner + „Verarbeitet …" | solange die Engine arbeitet (~4–6 s) |
| **Eingefügt** | „Eingefügt ✓" (kein Text — steht ja schon im Feld) | ~1 s, dann ausblenden |
| **Zwischenablage** | „Fertig · ⌘V" + Textvorschau (s. u.) | ~4 s zum Lesen, dann ausblenden |
| **Fehler** | Warnsymbol + kurzer Grund (z. B. „Nichts erkannt", „Audiogerät gewechselt") | ~2,5 s, dann ausblenden |

Die Übergänge folgen exakt dem bestehenden `SessionState` des `DictationCoordinator`
(`recording → processing →` `eingefügt`/`inZwischenablage`/`failed`). Startet ein neues Diktat,
während eine Endmeldung noch steht, ersetzt die neue Aufnahme sie sofort.

### Textvorschau — nur bei Zwischenablage

Der erkannte/verfeinerte Text wird **ausschließlich** im Zwischenablage-Fall gezeigt: Dort sieht der
Anwender den Text noch nicht (beim direkten Einfügen erscheint er ja sichtbar im Zielfeld — eine
Vorschau wäre überflüssig). Die Vorschau macht dort zugleich sichtbar, was ⌘V einfügen wird.

- **Länge:** erste **~90 Zeichen**, am Wortende abgeschnitten (nicht mitten im Wort), dann „ …".
  Kürzere Diktate erscheinen ganz. So bleibt das Fenster **eine Zeile** breit, egal wie lang das
  Diktat ist. (Der Wert 90 ist ein fester Startwert und leicht im Code justierbar.)
- **Kürzungsregel:** ist der Text länger als die Grenze, wird bei der letzten Wortgrenze vor der
  Grenze geschnitten (fällt diese ins erste knappe Drittel, hart an der Grenze), abschließende
  Satzzeichen/Leerzeichen entfernt, dann „ …" angehängt.

### Live-Pegel — echt, nicht generisch

Während der Aufnahme zeigen kleine Balken den **echten** Spitzenpegel des Mikrofons — sie reagieren
auf die Stimme und belegen so „TypeLess hört *dich*", nicht bloß „Aufnahme läuft". Der
`SilenceDetector.peak([Float]) -> Float` berechnet diesen Spitzenwert bereits; neu ist nur, dass der
Recorder ihn **während** der Aufnahme periodisch (z. B. je eingehendem Audio-Puffer, geglättet) nach
außen gibt, statt ihn nur am Ende für die Stille-Erkennung zu nutzen. Fällt dieser Pegel-Kanal aus
(unerwartet), zeigen die Balken eine ruhige Ruhelage — das Overlay bricht nie ab.

## Architektur

Wie beim Einrichtungs-Fenster (Verteilung Teil 2b): **Logik im testbaren Kern, Darstellung in der
dünnen App-Schicht.**

### Anzeige-Zustand (in `TypeLessCore`)

Ein eigener, vom `SessionState` **abgeleiteter** Anzeige-Typ trägt genau das, was das Overlay
braucht — analog zu `SetupState` (Teil 2b):

```
enum OverlayZustand {
    case aus
    case hoertZu(pegel: Float)      // 0…1, geglättet
    case verarbeitet
    case eingefuegt                 // kurze Erfolgsmeldung
    case zwischenablage(vorschau: String)
    case fehler(String)
}
```

Der `DictationCoordinator` hält diesen Zustand als beobachtbare Eigenschaft und leitet ihn aus
seinem `SessionState` plus den Zusatzdaten (aktueller Pegel während der Aufnahme; erkannter Text beim
Zustellen in die Zwischenablage) ab. Der `SessionState` selbst bleibt die Wahrheit über den Ablauf;
`OverlayZustand` ist die **Anzeige-Projektion** davon. Die reine Ableitung und die Textkürzung sind
ohne Fenster unit-testbar.

### Overlay-Fenster (in `Sources/TypeLess`)

Ein eigenes, **passives** Fenster (`NSPanel`), das die App-Schicht analog zum Einrichtungs-Fenster
über den beobachteten `OverlayZustand` öffnet/aktualisiert/schließt (AppDelegate-getrieben mit
`withObservationTracking`). Kritische Eigenschaften — **das Overlay darf den bestehenden
Einfüge-Weg (M5) nicht stören:**

- **Übernimmt nie den Tastaturfokus** (`.nonactivatingPanel`, `canBecomeKey`/`canBecomeMain`
  bleiben `false`). Würde es den Fokus stehlen, bräche das direkte Einfügen an der Cursorposition —
  denn das braucht den Fokus im Zielfeld. Das ist die wichtigste Anforderung an das Fenster.
- **Klick-durchlässig** (`ignoresMouseEvents = true`) — man kann nicht hineinklicken, es liegt nur
  darüber.
- **Schwebt über allem** (Floating-Level, sichtbar auf allen Spaces und über Vollbild-Fenstern),
  **unten mittig** auf dem Bildschirm mit dem Tastaturfokus.
- Ruhiges Ein-/Ausblenden (kurze Deckkraft-Animation), `prefers-reduced-motion` gemäß dezent.

Das Aussehen folgt dem macOS-HUD-Stil: kleines, abgerundetes, halbtransparentes dunkles Panel
(Vibrancy), heller Text — wie im freigegebenen Mockup.

## Datenschutz

Der angezeigte Text ist der lokal erkannte Diktattext; er wird **nur im lokalen Fenster** für wenige
Sekunden gezeigt und verlässt den Rechner nicht — konsistent mit dem Grundprinzip des Projekts. Der
Pegel ist eine reine Lautstärke-Zahl, kein Audio. Beides bleibt im Prozess.

## Fehlerbehandlung

- Jeder `failed`-Grund des `SessionState` wird kurz als Fehler-Overlay gezeigt (Warnsymbol + Text),
  dann ausgeblendet — der Anwender erfährt den Grund, ohne ins Menü schauen zu müssen.
- Fällt der Pegel-Kanal aus, bleibt die Aufnahme-Anzeige in ruhiger Ruhelage (kein Abbruch).
- Das Overlay ist **nie** Voraussetzung für das Diktat: Schlägt seine Darstellung fehl, läuft das
  Diktat (Aufnahme, Verarbeitung, Einfügen/Zwischenablage) unverändert weiter. Es ist reine Zutat.

## Testing-Strategie

- **`OverlayZustand`-Ableitung** (Unit): `SessionState` + Zusatzdaten → erwarteter `OverlayZustand`
  (u. a.: `inZwischenablage` trägt die Vorschau, `eingefügt` trägt **keinen** Text, `recording`
  trägt den Pegel, jeder `failed`-Grund wird durchgereicht).
- **Textkürzung** (Unit): kurz → ganz; lang → am Wortende + „ …"; genau an der Grenze; ohne
  Wortgrenze im knappen Bereich → harter Schnitt.
- **Pegel-Weiterleitung** (Unit, mit Fake-Recorder): der während der Aufnahme gelieferte Pegel
  landet im `OverlayZustand`.
- **Fenster-Darstellung** (`NSPanel`): **Handprobe** — kein sinnvoller Unit-Test; der Beweis ist,
  dass das Overlay sichtbar erscheint, den Fokus **nicht** stiehlt (direktes Einfügen funktioniert
  weiter) und in allen fünf Phasen korrekt aussieht. Analog zur Handprobe des Einrichtungs-Fensters.

## Offene Umsetzungsdetails (für den Plan, nicht designrelevant)

- Genaue Glättung/Frequenz der Pegel-Ausgabe (flüssig, aber nicht flackernd).
- Wo die Auto-Ausblende-Timer laufen (Kern mit injizierbarer Uhr für Testbarkeit vs. App-Schicht).
- Exakte Panel-Maße/Abstände (am Mockup ausgerichtet).

## Umsetzungs-Reihenfolge (Grobschnitt)

1. `OverlayZustand` + Ableitung aus `SessionState` + Textkürzung (Kern, unit-getestet).
2. Live-Pegel: Recorder gibt den Spitzenpegel während der Aufnahme aus; Koordinator reicht ihn in
   den `OverlayZustand` (unit-getestet mit Fake-Recorder).
3. Overlay-`NSPanel` in der App-Schicht (passiv, fokus-frei, unten mittig), AppDelegate-getrieben.
4. Auto-Ausblenden + Fehler-/Endphasen-Timing.
5. `CLAUDE.md` anpassen (M4-Overlay-Entscheidung umgekehrt).
6. Handprobe: alle fünf Phasen sichtbar korrekt; direktes Einfügen weiterhin unbeeinträchtigt.
