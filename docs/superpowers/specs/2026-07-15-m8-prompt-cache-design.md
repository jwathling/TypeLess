# M8 (vorgezogen) — Latenz senken durch Prompt-Prefix-Cache

**Stand:** Entwurf freigegeben (15.07.2026)
**Ausgangslage:** M5 ist auf `main`. Diktieren funktioniert, der Text erscheint an der
Cursorposition. Zwischen Fn-Loslassen und fertigem Text vergehen aber ~8–9 s (unter Last; die
ältere M1-Doku nannte ~6 s).
**Ziel:** Die LLM-Latenz senken, **ohne einen Deut Qualität aufzugeben**. Anwender-Entscheidung:
zuerst nur die Gratis-Gewinne; Kompromisse (kleineres Whisper, kürzerer Prompt, LLM überspringen)
sind ausdrücklich **zurückgestellt**, ebenso Live-Einfügen (kollidiert mit dem Löschschutz).

---

## Gemessener Ist-Zustand (Apple M4, 10 GPU-Kerne, 16 GB, unter Alltagslast)

Alle Zahlen frisch gemessen (nicht aus der M1-Doku übernommen), Modelle gecacht:

| Stufe | Zeit | Eigenschaft |
|---|---|---|
| Transkription (STT, `whisper-large-v3-turbo`) | ~4 s | **fast konstant** — Whisper verarbeitet immer ein 30-s-Fenster |
| LLM-Prefill des festen Systemprompts | **~3 s** | **bei jedem Diktat aufs Neue** — das ist der Angriffspunkt |
| LLM-Generierung (~40 Tokens Diktat) | ~1,5–2 s | ~20 tok/s Dauertempo |
| LLM-Modell laden (gecacht) | ~2,5 s | durch spekulativen Preload beim Fn-Druck **größtenteils verdeckt** |

Der Diktat-Systemprompt ist **424 Tokens** lang (Korrektur-Anweisung + Few-Shot-Beispiele) und
**vollständig statisch**; nur der Diktattext (~30 Tokens) wechselt. Gemessene Ersparnis durch
Cachen des festen Präfixes: **2,99 s → 0,42 s = 2,57 s pro Diktat.**

**Ehrliche Erwartung:** ~8–9 s → **~5–6 s**. Die ~4 s STT bleiben die Untergrenze und werden hier
**nicht** angefasst — das ginge nur über die zurückgestellten Qualitäts-Kompromisse.

---

## Was gebaut wird

Ein **Prompt-Prefix-KV-Cache** ausschließlich im **`MLXRefiner`**
(`engine/typeless_engine/llm/mlx_refiner.py`). Sonst nichts.

### Architektur — der Austauschbarkeits-Vertrag bleibt unberührt

Die Optimierung lebt **komplett innerhalb** von `MLXRefiner`. Die Schnittstelle
`interfaces/refiner.py` (`preload()`, `unload()`, `refine(text, mode, *, language)`) ändert sich
**nicht**. `factory.py` ändert sich nicht. Mock-Backends und alle bestehenden Tests bleiben
unangetastet. Ein anderes LLM-Backend (z. B. später llama.cpp) erbt diese Optimierung nicht und
muss sie auch nicht — sie ist ein reines Interna von MLX.

### Der Mechanismus

Ein KV-Cache ist die **vorausberechnete** Attention-Repräsentation (Keys/Values) eines
Token-Präfixes. Ob das Modell sie jetzt oder eben berechnet hat, ist mathematisch identisch — das
Modell sieht denselben Zustand und erzeugt dieselbe Ausgabe. Der Cache verschiebt also **wo**
gerechnet wird, nie **was** herauskommt.

1. **Fester Präfix je Modus.** Für einen Modus ist `chat_template(system_prompt + Vorlage)` bis zum
   Beginn des Diktattextes eine feste Tokenfolge. Sie wird einmal ermittelt und als Token-IDs
   festgehalten (nicht als String — Tokenisierung ist nicht teilstring-komponierbar).
2. **Präfix einmal vorwärmen — im Preload.** `preload()` lädt wie bisher das Modell **und** schickt
   den Diktat-Präfix **einmal** durchs Modell, dessen KV-Cache behalten wird. Diese ~3 s fallen
   **einmal pro Modell-Ladung** an (nicht pro Diktat) und landen im spekulativen Preload-Fenster,
   das beim Fn-Druck startet, während der Anwender noch spricht.
3. **Pro Diktat nur den Rest nachladen.** `refine()` tokenisiert den vollen Prompt, **prüft**, dass
   er mit dem gecachten Präfix beginnt (s. Absicherung 1), speist gegen den vorgewärmten Cache nur
   die **restlichen** Tokens (den Diktattext) ein, generiert, und **stutzt den Cache danach wieder
   auf die Präfixlänge zurück** — bereit fürs nächste Diktat.
4. **Ein einziger, wiederverwendeter Cache genügt.** Die Verarbeitung ist bereits serialisiert
   (`asyncio.Lock` in `runtime.py`) — es läuft nie mehr als ein `refine()` gleichzeitig, also ist
   der eine geteilte, nach jedem Lauf zurückgestutzte Cache gefahrlos.

Andere Modi (Prompt/E-Mail/Slack/BrainDump) bauen ihren Präfix-Cache **faul beim ersten Gebrauch**
— relevant erst ab M6 (Modus-Umschalter). Für heute zählt der Diktat-Modus, den `preload()`
vorwärmt.

### Zwei Absicherungen (unverhandelbar)

1. **Präfix-Wächter.** Vor jeder Wiederverwendung wird geprüft, dass die volle Prompt-Tokenfolge
   **wirklich** mit den gecachten Präfix-Tokens beginnt. Trifft das mal nicht zu (Tokenizer-
   Überraschung, geänderter Systemprompt ohne Neu-Vorwärmen), fällt `refine()` auf den heutigen
   **Voll-Prefill** zurück (ganzer Prompt, kein Cache). Die Optimierung darf das Ergebnis **nie**
   verändern und ein Diktat **nie** verlieren.
2. **Cache am Modell-Lebenszyklus.** Der Cache gehört zum geladenen Modell: `unload()` (auch der
   Idle-Unload und der Memory-Pressure-Unload) verwirft ihn mit, `preload()` baut ihn neu. Nichts
   bleibt veraltet stehen. Das bestehende Idle-Unload-Verhalten ändert sich nicht.

---

## Fehler- und Randverhalten

- **Cache-Aufbau scheitert** (Speicher, Backend-Fehler): still auf den Voll-Prefill-Pfad
  zurückfallen. Ein Diktat darf daran nie scheitern — dieselbe Haltung wie beim bestehenden
  LLM-Ausfall (`refined: false` + Rohtext).
- **Präfix-Wächter schlägt an**: Voll-Prefill für diesen einen Aufruf; kein Absturz, kein
  Qualitätsunterschied.
- **Leerer Diktattext**: unverändert — `refine()` gibt den Text sofort zurück, ohne das Modell zu
  bemühen (bestehendes Verhalten).
- **Sanity-Check** (Länge + Divergenz, fällt bei Bedarf auf den Rohtext zurück): **unberührt**. Er
  arbeitet auf dem fertigen LLM-Text, der Cache ändert diesen Text nicht.

---

## Tests

- **Ohne MLX (überall lauffähig):** Die reine Logik — Präfix-Ermittlung und der Präfix-Wächter
  (`beginnt die volle Tokenfolge mit dem Präfix?`, inklusive des Negativfalls, der den Rückfall
  auslöst) — wird mit einem gefälschten Tokenizer/Backend geprüft, so wie `test_stt.py` das
  `mlx_whisper`-Modul fälscht. Kein echtes Modell nötig.
- **Auf Apple Silicon (`--extra mlx`), die entscheidende Zusicherung:** Die Ausgabe **mit** Cache
  ist identisch zur Ausgabe **ohne** Cache — bei gleichem Sampler-Seed für denselben Diktattext.
  Das ist der Beweis, dass die Optimierung qualitätsneutral ist. Dazu eine Messung, die die
  Ersparnis belegt (Voll-Prefill vs. gecacht), analog zu den Messwerten oben.
- Alle bestehenden Engine-Tests (98) bleiben grün; `scripts/check.sh` (black + ruff + mypy strict +
  pytest) bleibt sauber.

## Konventionen

Python 3.11+, `from __future__ import annotations`, Typannotationen überall, MLX-Imports **lazy**
(nur bei Nutzung — der Kern bleibt plattformunabhängig), Kommentare/Docstrings auf Deutsch. Vor dem
Commit `scripts/check.sh` grün.

## Ausdrücklich nicht in diesem Spec (zurückgestellt)

- **STT beschleunigen** (kleineres/anderes Whisper) — Qualitäts-Kompromiss, vertagt.
- **Live-Einfügen / Streaming** — kollidiert mit dem Löschschutz (Sanity-Check), vom Anwender
  zurückgestellt.
- **Kürzerer Systemprompt / LLM überspringen** — Qualitäts-Risiko, vertagt.
- **Untersuchung des ~20-tok/s-Generierungstempos** — unklarer Ertrag; nach dem Cache ist die
  Generierung (~1,5–2 s) nicht mehr der dominante Posten.

Wenn ~5–6 s sich im Alltag nicht gut genug anfühlen, wird als Nächstes über die STT-Untergrenze
gesprochen — dann mit offenem Qualitäts-Budget.
