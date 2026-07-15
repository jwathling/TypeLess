# Streaming-Motor — Engine + Server (Python-Hälfte) — Implementierungsplan

> **Für agentische Bearbeiter:** ERFORDERLICHE SUB-SKILL: `superpowers:subagent-driven-development`
> (empfohlen) oder `superpowers:executing-plans`. Schritte nutzen Checkbox-Syntax (`- [ ]`).

**Ziel:** Die Engine so erweitern, dass sie Audio schon **während** des Sprechens transkribiert
(LocalAgreement) und den fertigen Text über einen Streaming-Endpunkt am Unix-Socket liefert — ohne
den Austauschbarkeits-Vertrag zu brechen und ohne je ein Diktat zu verlieren.

**Architektur:** Ein **optionales** Streaming-Protokoll neben dem unveränderten Batch-Vertrag; eine
reine LocalAgreement-Logik (ohne MLX); der MLX-Transcriber implementiert das Streaming über einen
wachsenden Puffer; die Runtime fährt eine serialisierte Streaming-Sitzung mit Batch-Rückfall; ein
`POST /process/stream`-Endpunkt liest den gestreamten Request-Body häppchenweise.

**Tech-Stack:** Python 3.11+, mlx-whisper (lazy, Apple-Silicon), FastAPI/Starlette über
Unix-Domain-Socket, numpy, pytest.

**Abgrenzung:** Dies ist die **Python-Hälfte** des Streaming-Motors. Die **Swift-Hälfte**
(Chunked-Upload über `HTTPUnixTransport`, Umbau des `DictationCoordinator`) ist ein **eigener,
nachgelagerter Plan** und baut auf dem hier gebauten Endpunkt auf. Das **Overlay** ist eine eigene
spätere Spec.

**Spec:** `docs/superpowers/specs/2026-07-15-streaming-transkription-design.md` — bei Zweifeln gilt
die Spec.

## Global Constraints

- Python 3.11+, `from __future__ import annotations`, Typannotationen überall.
- **MLX-Imports IMMER lazy** (nur innerhalb von Methoden). Der Kern bleibt ohne Apple Silicon
  importierbar; die reinen Module (Protokoll, LocalAgreement) berühren kein MLX.
- Kommentare/Docstrings auf **Deutsch**, bestehendem Stil folgend.
- **Austauschbarkeit (heilig):** Der Batch-Vertrag `Transcriber.transcribe(audio) -> Transcription`
  ändert sich **nicht**. Streaming kommt als **optionales** Zusatz-Protokoll `StreamingTranscriber`
  daneben. `factory.py` bleibt die **einzige** Stelle, die konkrete Engines kennt. Der Refiner ist
  unberührt.
- **Nie ein Diktat verlieren:** Kann das Backend kein Streaming oder scheitert das Streaming, fällt
  die Runtime auf den heutigen **Batch-Weg** (`transcribe(audio)`) über das vollständig gepufferte
  Audio zurück.
- **Serialisiert:** Höchstens eine Streaming-Sitzung zur Zeit; der bestehende `asyncio.Lock` der
  Runtime deckt das. Kein Idle-Unload fällt in eine laufende Sitzung.
- **Nur Unix-Domain-Socket**, kein TCP/Port.
- Vor jedem Commit `bash scripts/check.sh` grün (black + ruff + mypy strict + pytest). Alle **109**
  bestehenden Engine-Tests bleiben grün.

**Akzeptierte Grenze (Anwender-Entscheidung):** Der festgeschriebene Streaming-Text kann *minimal*
von einem einzigen sauberen Batch-Durchlauf abweichen. Streaming ist **nicht** mathematisch
identisch zum Batch (anders als der M8-Prompt-Cache).

---

## Dateistruktur

| Datei | Verantwortung |
|---|---|
| `engine/typeless_engine/interfaces/transcriber.py` (ändern) | Optionales `StreamingTranscriber`-Protokoll neben dem unveränderten `Transcriber`. |
| `engine/typeless_engine/stt/local_agreement.py` (neu) | Reine LocalAgreement-2-Logik: aus aufeinanderfolgenden Voll-Hypothesen festgeschriebene Wörter ableiten. Kein MLX. |
| `engine/typeless_engine/stt/mlx_whisper.py` (ändern) | `MLXWhisperTranscriber` implementiert zusätzlich `StreamingTranscriber` (wachsender Puffer + LocalAgreement). |
| `engine/typeless_engine/pipeline/__init__.py` (ändern) | `process_text` exportieren (von der Runtime für den Refine-Schritt gebraucht). |
| `engine/typeless_engine/server/runtime.py` (ändern) | `process_stream(...)`: serialisierte Streaming-Sitzung, Preload-Überlappung, Batch-Rückfall, Refine am Ende. |
| `engine/typeless_engine/server/app.py` (ändern) | `POST /process/stream`: gestreamten Body häppchenweise dekodieren, an die Runtime, `ProcessResponse` zurück. |
| `engine/tests/test_local_agreement.py` (neu) | Reine LocalAgreement-Logik. |
| `engine/tests/test_stt_streaming.py` (neu) | MLX-Streaming-Orchestrierung mit gefälschtem Whisper. |
| `engine/tests/test_runtime_streaming.py` (neu) | Runtime-Sitzung: Streaming-Pfad, Batch-Rückfall, Preload. |
| `engine/tests/test_server_stream.py` (neu) | Endpunkt: Byte-Dekodierung über Chunk-Grenzen, Weiterreichen. |
| `engine/scripts/measure_streaming.py` (neu) | On-device-Handprobe: Latenz Streaming vs. Batch + Text-Vergleich auf einer echten WAV. |

---

## Task 1: Optionales `StreamingTranscriber`-Protokoll

Ein Zusatz-Vertrag neben `Transcriber`. Wer ihn implementiert, kann Audio häppchenweise annehmen
und stabile Wörter vor dem Ende liefern. Der Batch-Vertrag bleibt Pflicht (Rückfallweg).

**Files:**
- Modify: `engine/typeless_engine/interfaces/transcriber.py`
- Test: `engine/tests/test_local_agreement.py` (nur der Protokoll-Teil hier; die Logik folgt in Task 2 — dieser Task testet die Vertrags-Form über eine Mini-Implementierung)

**Interfaces:**
- Produces:
  - `class StreamingTranscriber(Transcriber)` mit abstrakten Methoden
    `stream_begin(self, *, language: str | None = None) -> None`,
    `stream_feed(self, samples: np.ndarray) -> str`,
    `stream_finalize(self) -> Transcription`.

- [ ] **Schritt 1: Fehlschlagenden Test schreiben**

Neue Datei `engine/tests/test_local_agreement.py` (vorerst nur der Protokoll-Test; Task 2 füllt
die Datei mit der eigentlichen Logik weiter):

```python
"""Tests rund um Streaming-Transkription — reine Logik, ohne MLX."""

from __future__ import annotations

import numpy as np

from typeless_engine.interfaces import StreamingTranscriber, Transcriber
from typeless_engine.models import AudioBuffer, Transcription


class _MiniStreaming(StreamingTranscriber):
    """Kleinste zulässige Implementierung — belegt die Vertrags-Form (kein echtes STT)."""

    def transcribe(self, audio: AudioBuffer, *, language: str | None = None) -> Transcription:
        return Transcription(text="batch")

    def stream_begin(self, *, language: str | None = None) -> None:
        self._words: list[str] = []

    def stream_feed(self, samples: np.ndarray) -> str:
        self._words.append("x")
        return "x"

    def stream_finalize(self) -> Transcription:
        return Transcription(text=" ".join(self._words))


def test_streaming_transcriber_is_a_transcriber() -> None:
    # Ein StreamingTranscriber MUSS auch den Batch-Vertrag erfüllen (Rückfallweg).
    s = _MiniStreaming()
    assert isinstance(s, Transcriber)
    assert isinstance(s, StreamingTranscriber)


def test_batch_only_is_not_streaming() -> None:
    # Ein reiner Batch-Transcriber darf NICHT als Streaming durchgehen — daran unterscheidet die
    # Runtime, ob sie streamen oder auf Batch zurückfallen muss.
    class BatchOnly(Transcriber):
        def transcribe(self, audio: AudioBuffer, *, language: str | None = None) -> Transcription:
            return Transcription(text="batch")

    assert not isinstance(BatchOnly(), StreamingTranscriber)


def test_stream_roundtrip_shape() -> None:
    s = _MiniStreaming()
    s.stream_begin()
    assert s.stream_feed(np.zeros(4, dtype=np.float32)) == "x"
    assert s.stream_finalize().text == "x"
```

- [ ] **Schritt 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `cd engine && uv run pytest tests/test_local_agreement.py -q`
Erwartung: FAIL — `ImportError: cannot import name 'StreamingTranscriber'`.

- [ ] **Schritt 3: Umsetzung**

In `engine/typeless_engine/interfaces/transcriber.py` ergänzen (Import oben:
`import numpy as np`):

```python
class StreamingTranscriber(Transcriber):
    """Optionaler Zusatzvertrag: Transkribieren *während* des Sprechens.

    Wer das implementiert, nimmt Audio häppchenweise entgegen und liefert stabile Wörter schon vor
    dem Ende. Der Batch-Vertrag ``transcribe()`` bleibt Pflicht — die Runtime nutzt ihn als
    Rückfallweg, wenn Streaming nicht geht oder scheitert.

    Eine Sitzung: ``stream_begin`` → beliebig oft ``stream_feed`` → genau ein ``stream_finalize``.
    """

    @abstractmethod
    def stream_begin(self, *, language: str | None = None) -> None:
        """Eröffnet eine Streaming-Sitzung. ``language=None`` = Auto-Detect."""
        raise NotImplementedError

    @abstractmethod
    def stream_feed(self, samples: np.ndarray) -> str:
        """Nimmt weitere Mono-Float32-16-kHz-Samples entgegen.

        Liefert den seit dem letzten Aufruf **neu festgeschriebenen** Text (leerer String, wenn
        nichts Neues sicher ist).
        """
        raise NotImplementedError

    @abstractmethod
    def stream_finalize(self) -> Transcription:
        """Schließt die Sitzung ab und liefert das **vollständige** Transkript."""
        raise NotImplementedError
```

Und in `engine/typeless_engine/interfaces/__init__.py` `StreamingTranscriber` mit exportieren
(neben `Transcriber`, `Refiner`).

- [ ] **Schritt 4: Test laufen lassen, grün bestätigen**

Run: `cd engine && uv run pytest tests/test_local_agreement.py -q`
Erwartung: PASS, 3 Tests.

- [ ] **Schritt 5: Commit**

```bash
cd engine && bash ../scripts/check.sh
git add typeless_engine/interfaces tests/test_local_agreement.py
git commit -m "Streaming: optionales StreamingTranscriber-Protokoll neben dem Batch-Vertrag"
```

---

## Task 2: LocalAgreement-2 (reine Logik)

Das Herz. Ein Wort gilt als **festgeschrieben**, sobald **zwei aufeinanderfolgende** Voll-Hypothesen
an derselben Stelle übereinstimmen. Festgeschriebene Wörter ändern sich nie mehr. Reine
Textverarbeitung, ohne MLX.

**Files:**
- Create: `engine/typeless_engine/stt/local_agreement.py`
- Test: `engine/tests/test_local_agreement.py` (erweitern)

**Interfaces:**
- Produces:
  - `class LocalAgreement` mit `insert(self, hypothesis: list[str]) -> list[str]`
    (liefert neu festgeschriebene Wörter), `finalize(self) -> list[str]`
    (schreibt den Rest der letzten Hypothese fest) und Property `committed -> list[str]`.

- [ ] **Schritt 1: Fehlschlagenden Test schreiben**

An `engine/tests/test_local_agreement.py` anhängen:

```python
from typeless_engine.stt.local_agreement import LocalAgreement


def test_nichts_wird_bei_erster_hypothese_festgeschrieben() -> None:
    la = LocalAgreement()
    # Eine einzelne Hypothese hat noch keinen Vorgänger zum Übereinstimmen -> nichts sicher.
    assert la.insert(["also", "ich"]) == []
    assert la.committed == []


def test_uebereinstimmender_praefix_wird_festgeschrieben() -> None:
    la = LocalAgreement()
    la.insert(["also", "ich", "wollte"])
    # Zweite Hypothese stimmt im Präfix "also ich" überein -> das wird sicher; "sage" noch nicht.
    newly = la.insert(["also", "ich", "sage"])
    assert newly == ["also", "ich"]
    assert la.committed == ["also", "ich"]


def test_kein_rueckgaengig_bei_widerspruch_im_festgeschriebenen() -> None:
    la = LocalAgreement()
    la.insert(["a", "b", "c"])
    la.insert(["a", "b", "c"])  # "a b c" wird sicher
    assert la.committed == ["a", "b", "c"]
    # Eine spätere Hypothese widerspricht dem bereits Festgeschriebenen -> NICHT zurückrollen
    # (Streaming kann Ausgegebenes nicht zurücknehmen; bewusst akzeptiert).
    assert la.insert(["a", "x", "y"]) == []
    assert la.committed == ["a", "b", "c"]


def test_finalize_schreibt_den_rest_fest() -> None:
    la = LocalAgreement()
    la.insert(["a", "b", "c"])
    la.insert(["a", "b", "c"])  # "a b c" sicher, letzte Hypothese = ["a","b","c"]
    la.insert(["a", "b", "c", "d"])  # "d" noch nicht bestätigt
    assert la.committed == ["a", "b", "c"]
    # finalize akzeptiert den Rest der letzten Hypothese ohne zweite Bestätigung.
    assert la.finalize() == ["d"]
    assert la.committed == ["a", "b", "c", "d"]


def test_typischer_diktat_verlauf() -> None:
    la = LocalAgreement()
    out: list[str] = []
    out += la.insert(["das"])
    out += la.insert(["das", "ist"])          # "das" sicher
    out += la.insert(["das", "ist", "ein"])   # "ist" sicher
    out += la.insert(["das", "ist", "ein", "test"])  # "ein" sicher
    out += la.finalize()                       # "test" per finalize
    assert out == ["das", "ist", "ein", "test"]
    assert la.committed == ["das", "ist", "ein", "test"]
```

- [ ] **Schritt 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `cd engine && uv run pytest tests/test_local_agreement.py -q`
Erwartung: FAIL — `ModuleNotFoundError: ... local_agreement`.

- [ ] **Schritt 3: Umsetzung**

Neue Datei `engine/typeless_engine/stt/local_agreement.py`:

```python
"""LocalAgreement-2 — die Streaming-Brücke für Whisper.

Whisper ist auf 30-s-Fenster ausgelegt und streamt nicht von Haus aus. LocalAgreement überbrückt
das: Die Engine transkribiert das bisher Gesprochene wiederholt; ein Wort gilt erst als
**festgeschrieben**, sobald ZWEI aufeinanderfolgende Durchläufe an derselben Stelle dasselbe Wort
liefern. Festgeschriebene Wörter ändern sich nie mehr.

Reine Textverarbeitung (Wortlisten) — bewusst ohne jeden MLX-Bezug, damit sie überall testbar ist.
"""

from __future__ import annotations


def _gemeinsamer_praefix(a: list[str], b: list[str]) -> list[str]:
    """Längster gemeinsamer Präfix zweier Wortlisten."""
    n = 0
    while n < len(a) and n < len(b) and a[n] == b[n]:
        n += 1
    return a[:n]


class LocalAgreement:
    """Leitet aus aufeinanderfolgenden Voll-Hypothesen die festgeschriebenen Wörter ab."""

    def __init__(self) -> None:
        self._committed: list[str] = []
        self._prev: list[str] = []

    def insert(self, hypothesis: list[str]) -> list[str]:
        """Nimmt die aktuelle Voll-Hypothese (Wortliste). Liefert die NEU festgeschriebenen Wörter.

        Festgeschrieben wird der gemeinsame Präfix der letzten und der aktuellen Hypothese, soweit
        er über das schon Festgeschriebene hinausgeht. Widerspricht die neue Hypothese dem bereits
        Festgeschriebenen, wird NICHT zurückgerollt (Ausgegebenes lässt sich nicht zurücknehmen).
        """
        agreed = _gemeinsamer_praefix(self._prev, hypothesis)
        self._prev = list(hypothesis)
        if len(agreed) <= len(self._committed):
            return []
        newly = agreed[len(self._committed) :]
        self._committed = list(agreed)
        return newly

    def finalize(self) -> list[str]:
        """Schreibt den Rest der letzten Hypothese ohne zweite Bestätigung fest (Ende des Diktats)."""
        if len(self._prev) <= len(self._committed):
            return []
        newly = self._prev[len(self._committed) :]
        self._committed = list(self._prev)
        return newly

    @property
    def committed(self) -> list[str]:
        return list(self._committed)
```

- [ ] **Schritt 4: Test laufen lassen, grün bestätigen**

Run: `cd engine && uv run pytest tests/test_local_agreement.py -q`
Erwartung: PASS (8 Tests inkl. Task 1).

- [ ] **Schritt 5: Commit**

```bash
cd engine && bash ../scripts/check.sh
git add typeless_engine/stt/local_agreement.py tests/test_local_agreement.py
git commit -m "Streaming: LocalAgreement-2 (reine Logik) — festschreiben bei Übereinstimmung"
```

---

## Task 3: MLX-Streaming-Transcriber

`MLXWhisperTranscriber` implementiert zusätzlich `StreamingTranscriber`: Die Feeds werden an einen
wachsenden Puffer gehängt, in festem Takt wird der Puffer erneut durch Whisper geschickt, und
LocalAgreement leitet die festgeschriebenen Wörter ab. `finalize` transkribiert ein letztes Mal und
akzeptiert den Rest.

**Files:**
- Modify: `engine/typeless_engine/stt/mlx_whisper.py`
- Test: `engine/tests/test_stt_streaming.py`

**Interfaces:**
- Consumes: `LocalAgreement` (Task 2), `StreamingTranscriber` (Task 1).
- Produces: `MLXWhisperTranscriber` erfüllt jetzt `StreamingTranscriber`; Modulkonstante
  `STREAM_STEP_SAMPLES = TARGET_SAMPLE_RATE` (≈1 s Takt).

- [ ] **Schritt 1: Fehlschlagenden Test schreiben**

Neue Datei `engine/tests/test_stt_streaming.py`:

```python
"""MLX-Streaming-Orchestrierung mit gefälschtem Whisper (ohne echtes Modell)."""

from __future__ import annotations

from typing import Any

import numpy as np
import pytest

from typeless_engine.models import TARGET_SAMPLE_RATE
from typeless_engine.stt.mlx_whisper import STREAM_STEP_SAMPLES, MLXWhisperTranscriber


class FakeGrowingWhisper:
    """Liefert mit wachsendem Audio mehr Wörter — je 1 s Audio ein weiteres Wort aus WORDS."""

    WORDS = ["das", "ist", "ein", "kurzer", "test"]

    def transcribe(self, samples: np.ndarray, **kwargs: Any) -> dict[str, Any]:
        sekunden = max(1, len(samples) // TARGET_SAMPLE_RATE)
        text = " ".join(self.WORDS[:sekunden])
        return {"text": " " + text + " ", "language": "de"}


@pytest.fixture
def fake_stream(monkeypatch: pytest.MonkeyPatch) -> FakeGrowingWhisper:
    fake = FakeGrowingWhisper()
    monkeypatch.setattr(MLXWhisperTranscriber, "_import_backend", lambda self: fake)
    return fake


def _sekunde() -> np.ndarray:
    return np.zeros(TARGET_SAMPLE_RATE, dtype=np.float32)


def test_stream_schreibt_stabile_woerter_fest(fake_stream: FakeGrowingWhisper) -> None:
    t = MLXWhisperTranscriber()
    t.stream_begin()
    committed = ""
    for _ in range(5):
        committed += t.stream_feed(_sekunde())
    final = t.stream_finalize()
    # Alle fünf Wörter erscheinen am Ende, in Reihenfolge.
    assert final.text.split() == FakeGrowingWhisper.WORDS
    assert final.language == "de"


def test_stream_feed_unter_dem_takt_transkribiert_nicht(fake_stream: FakeGrowingWhisper) -> None:
    t = MLXWhisperTranscriber()
    t.stream_begin()
    # Ein Häppchen kürzer als der Takt darf noch nichts festschreiben.
    assert t.stream_feed(np.zeros(STREAM_STEP_SAMPLES // 2, dtype=np.float32)) == ""


def test_finalize_liefert_alles_auch_ohne_zweite_bestaetigung(fake_stream: FakeGrowingWhisper) -> None:
    t = MLXWhisperTranscriber()
    t.stream_begin()
    t.stream_feed(_sekunde())  # nur "das" gesehen, noch nichts sicher
    final = t.stream_finalize()
    assert final.text.split() == ["das"]
```

- [ ] **Schritt 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `cd engine && uv run pytest tests/test_stt_streaming.py -q`
Erwartung: FAIL — `ImportError: cannot import name 'STREAM_STEP_SAMPLES'` bzw. fehlende
Streaming-Methoden.

- [ ] **Schritt 3: Umsetzung**

In `engine/typeless_engine/stt/mlx_whisper.py`:

Import ergänzen und die Klassen-Basis erweitern:

```python
from ..interfaces import StreamingTranscriber
from .local_agreement import LocalAgreement
```

Konstante neben `WARM_UP_SAMPLES`:

```python
# Takt der Streaming-Neu-Transkription: alle ~1 s Audio wird der Puffer erneut durch Whisper
# geschickt. Kürzer => mehr GPU-Last, kaum stabilere Wörter; länger => sichtbar trägeres Overlay.
STREAM_STEP_SAMPLES = TARGET_SAMPLE_RATE
```

Klassensignatur ändern zu `class MLXWhisperTranscriber(StreamingTranscriber):` und die
Streaming-Methoden ergänzen (der bestehende `transcribe` bleibt unverändert und dient als
Batch-Rückfall):

```python
    def stream_begin(self, *, language: str | None = None) -> None:
        self._stream_language = language
        self._stream_buffer = np.zeros(0, dtype=np.float32)
        self._stream_new_samples = 0
        self._agreement = LocalAgreement()

    def stream_feed(self, samples: np.ndarray) -> str:
        self._stream_buffer = np.concatenate([self._stream_buffer, samples.astype(np.float32)])
        self._stream_new_samples += len(samples)
        # Nur im festen Takt erneut transkribieren — nicht bei jedem winzigen Häppchen.
        if self._stream_new_samples < STREAM_STEP_SAMPLES:
            return ""
        self._stream_new_samples = 0
        newly = self._agreement.insert(self._transcribe_buffer_words())
        return " ".join(newly)

    def stream_finalize(self) -> Transcription:
        # Ein letzter Durchlauf über das vollständige Audio, dann den Rest ohne zweite
        # Bestätigung akzeptieren (Ende des Diktats).
        self._agreement.insert(self._transcribe_buffer_words())
        self._agreement.finalize()
        text = " ".join(self._agreement.committed).strip()
        seconds = len(self._stream_buffer) / TARGET_SAMPLE_RATE
        return Transcription(
            text=text, language=self._stream_language, duration_seconds=seconds
        )

    def _transcribe_buffer_words(self) -> list[str]:
        """Transkribiert den aktuellen Puffer und liefert die Wortliste (leer bei leerem Puffer)."""
        if len(self._stream_buffer) == 0:
            return []
        mlx_whisper = self._import_backend()
        result = mlx_whisper.transcribe(
            self._stream_buffer,
            path_or_hf_repo=self._model,
            language=self._stream_language,
            condition_on_previous_text=False,  # gleiche Begründung wie im Batch-Pfad
        )
        return str(result.get("text", "")).strip().split()
```

- [ ] **Schritt 4: Test laufen lassen, grün bestätigen**

Run: `cd engine && uv run pytest tests/test_stt_streaming.py tests/test_stt.py -q`
Erwartung: PASS (neue + alle bestehenden STT-Tests; der Batch-`transcribe` ist unverändert).

- [ ] **Schritt 5: Commit**

```bash
cd engine && bash ../scripts/check.sh
git add typeless_engine/stt/mlx_whisper.py tests/test_stt_streaming.py
git commit -m "Streaming: MLXWhisperTranscriber als StreamingTranscriber (wachsender Puffer + LocalAgreement)"
```

---

## Task 4: Runtime-Streaming-Sitzung mit Batch-Rückfall

Die Runtime bekommt `process_stream`: eine serialisierte Sitzung, die Audio-Häppchen konsumiert,
sie (falls das Backend streamen kann) live transkribiert und parallel das LLM lädt, am Ende den
Text durch Wörterbuch → Refiner → Löschschutz schickt. Kann das Backend kein Streaming oder
scheitert es, fällt sie auf den heutigen Batch-Weg über das vollständig gepufferte Audio zurück.

**Files:**
- Modify: `engine/typeless_engine/server/runtime.py`
- Modify: `engine/typeless_engine/pipeline/__init__.py` (`process_text` exportieren)
- Test: `engine/tests/test_runtime_streaming.py`

**Interfaces:**
- Consumes: `StreamingTranscriber` (Task 1); `process_text` (Pipeline, bestehend in `process.py`).
- Produces: `EngineRuntime.process_stream(self, audio_chunks: AsyncIterator[np.ndarray],
  mode: Mode, *, language: str | None = None) -> ProcessResult`.

- [ ] **Schritt 1: Fehlschlagenden Test schreiben**

Neue Datei `engine/tests/test_runtime_streaming.py`:

```python
"""Runtime-Streaming-Sitzung: Streaming-Pfad, Batch-Rückfall, Preload — mit Mock-Backends."""

from __future__ import annotations

from collections.abc import AsyncIterator
from typing import Any

import numpy as np
import pytest

from typeless_engine.config import EngineConfig
from typeless_engine.dictionary import DictionaryEngine
from typeless_engine.interfaces import Refiner, StreamingTranscriber, Transcriber
from typeless_engine.models import AudioBuffer, Mode, Transcription
from typeless_engine.server.runtime import EngineRuntime


class StreamingMock(StreamingTranscriber):
    """Streaming-Transcriber-Attrappe; protokolliert die Aufrufe."""

    def __init__(self) -> None:
        self.began = False
        self.feeds = 0
        self.finalized = False
        self.total_samples = 0

    def warm_up(self) -> None: ...
    def transcribe(self, audio: AudioBuffer, *, language: str | None = None) -> Transcription:
        return Transcription(text="BATCH sollte hier nicht laufen")

    def stream_begin(self, *, language: str | None = None) -> None:
        self.began = True

    def stream_feed(self, samples: np.ndarray) -> str:
        self.feeds += 1
        self.total_samples += len(samples)
        return ""

    def stream_finalize(self) -> Transcription:
        self.finalized = True
        return Transcription(text="hallo welt", language="de")


class BatchOnlyMock(Transcriber):
    def __init__(self) -> None:
        self.seen_samples = 0

    def warm_up(self) -> None: ...
    def transcribe(self, audio: AudioBuffer, *, language: str | None = None) -> Transcription:
        self.seen_samples = len(audio.samples)
        return Transcription(text="batch text", language="de")


class RaisingStreamingMock(StreamingMock):
    def stream_feed(self, samples: np.ndarray) -> str:
        raise RuntimeError("Streaming kaputt")

    def transcribe(self, audio: AudioBuffer, *, language: str | None = None) -> Transcription:
        return Transcription(text="rettung per batch", language="de")


class EchoRefiner(Refiner):
    def preload(self) -> None: ...
    def unload(self) -> None: ...
    def refine(self, text: str, mode: Mode, *, language: str | None = None) -> str:
        return text.upper()


@pytest.fixture
def anyio_backend() -> str:
    # Gleiches Muster wie test_runtime.py: async-Tests laufen auf asyncio.
    return "asyncio"


def _runtime(transcriber: Transcriber) -> EngineRuntime:
    rt = EngineRuntime(
        EngineConfig(stt_backend="mock", llm_backend="mock"),
        transcriber=transcriber,
        refiner=EchoRefiner(),
        dictionary=DictionaryEngine({}),
    )
    return rt


async def _chunks(n: int, size: int) -> AsyncIterator[np.ndarray]:
    for _ in range(n):
        yield np.zeros(size, dtype=np.float32)


@pytest.mark.anyio
async def test_streaming_pfad_wird_genutzt() -> None:
    stt = StreamingMock()
    rt = _runtime(stt)
    await rt.startup()
    result = await rt.process_stream(_chunks(3, 16000), Mode.DIKTAT)
    assert stt.began and stt.finalized and stt.feeds == 3
    assert result.raw_text == "hallo welt"
    assert result.final_text == "HALLO WELT"  # EchoRefiner -> Großschrift


@pytest.mark.anyio
async def test_batch_rueckfall_wenn_backend_nicht_streamt() -> None:
    stt = BatchOnlyMock()
    rt = _runtime(stt)
    await rt.startup()
    result = await rt.process_stream(_chunks(3, 16000), Mode.DIKTAT)
    # Kein Streaming möglich -> alles Audio gesammelt und einmal batch-transkribiert.
    assert stt.seen_samples == 3 * 16000
    assert result.raw_text == "batch text"


@pytest.mark.anyio
async def test_streaming_fehler_faellt_auf_batch_zurueck() -> None:
    stt = RaisingStreamingMock()
    rt = _runtime(stt)
    await rt.startup()
    result = await rt.process_stream(_chunks(3, 16000), Mode.DIKTAT)
    # Streaming stolpert -> Rettung über den Batch-Weg, Diktat NICHT verloren.
    assert result.raw_text == "rettung per batch"
```

Hinweis: `@pytest.mark.anyio` + die lokale `anyio_backend`-Fixture sind exakt das Muster aus
`tests/test_runtime.py` (dort ebenfalls lokal definiert) — kein `conftest.py` nötig.

- [ ] **Schritt 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `cd engine && uv run pytest tests/test_runtime_streaming.py -q`
Erwartung: FAIL — `AttributeError: 'EngineRuntime' object has no attribute 'process_stream'`.

- [ ] **Schritt 3: Umsetzung**

In `engine/typeless_engine/pipeline/__init__.py` `process_text` mit exportieren (neben `process`,
`PipelineConfig`).

In `engine/typeless_engine/server/runtime.py`:

Imports ergänzen:

```python
from collections.abc import AsyncIterator

import numpy as np

from ..interfaces import Refiner, StreamingTranscriber, Transcriber
from ..pipeline import PipelineConfig, process, process_text
```

Methode in `EngineRuntime` ergänzen (nach `process`):

```python
    async def process_stream(
        self,
        audio_chunks: AsyncIterator[np.ndarray],
        mode: Mode,
        *,
        language: str | None = None,
    ) -> ProcessResult:
        """Wie ``process``, aber die Transkription läuft schon **während** des Sprechens.

        Serialisiert (ein Diktat zur Zeit). Das LLM wird parallel zur Transkription geladen, damit
        seine Ladezeit im Sprechen verschwindet. Kann das Backend kein Streaming oder scheitert das
        Streaming, fällt der Aufruf auf den Batch-Weg über das vollständig gepufferte Audio zurück —
        nie ein Diktat verlieren.
        """
        await self._ready.wait()
        if self._startup_error is not None:
            raise StartupFailedError(self._startup_error)
        effective_language = language if language is not None else self._config.language

        async with self._lock:
            self._busy = True
            self._refiner.reset()
            # LLM parallel laden (Gewichte, weitgehend I/O) — überlappt mit der Transkription.
            preload_task = asyncio.create_task(to_thread.run_sync(self._refiner.preload))
            try:
                transcription = await self._consume_stream(audio_chunks, effective_language)
                await preload_task
                self._llm_loaded = self._refiner.last_error is None
                self._last_used = self._clock()
                result = await to_thread.run_sync(
                    self._refine_transcription, transcription, mode, effective_language
                )
                if self._refiner.last_error is not None:
                    result = replace(result, fallback_reason=self._refiner.last_error)
                return result
            finally:
                if not preload_task.done():
                    preload_task.cancel()
                    with contextlib.suppress(asyncio.CancelledError, Exception):
                        await preload_task
                self._busy = False

    async def _consume_stream(
        self, audio_chunks: AsyncIterator[np.ndarray], language: str | None
    ) -> Transcription:
        """Konsumiert die Audio-Häppchen und liefert das Roh-Transkript.

        Streamt, wenn das Backend es kann; sammelt dabei ALLES Audio, um bei einem Streaming-Fehler
        (oder einem reinen Batch-Backend) auf ``transcribe(audio)`` zurückfallen zu können.
        """
        streaming = self._transcriber if isinstance(self._transcriber, StreamingTranscriber) else None
        collected: list[np.ndarray] = []
        if streaming is not None:
            try:
                await to_thread.run_sync(lambda: streaming.stream_begin(language=language))
                async for chunk in audio_chunks:
                    collected.append(chunk)
                    newly = await to_thread.run_sync(streaming.stream_feed, chunk)
                    # Festgeschriebenen Text bereitstellen + loggen (Datenquelle fürs spätere
                    # Overlay; im Motor-Teil noch nicht zum Client durchgereicht — s. Spec §3).
                    if newly:
                        _log.debug("festgeschrieben: %s", newly)
                return await to_thread.run_sync(streaming.stream_finalize)
            except Exception:  # noqa: BLE001 - jeder Streaming-Fehler => Batch-Rückfall
                _log.warning("Streaming fehlgeschlagen — falle auf Batch zurück.")
                async for chunk in audio_chunks:
                    collected.append(chunk)  # evtl. noch nicht konsumierte Häppchen mitnehmen
                return await self._batch_transcribe(collected, language)
        # Reines Batch-Backend: alles sammeln, einmal transkribieren.
        async for chunk in audio_chunks:
            collected.append(chunk)
        return await self._batch_transcribe(collected, language)

    async def _batch_transcribe(
        self, chunks: list[np.ndarray], language: str | None
    ) -> Transcription:
        samples = (
            np.concatenate(chunks) if chunks else np.zeros(0, dtype=np.float32)
        ).astype(np.float32)
        audio = AudioBuffer(samples=samples)
        return await to_thread.run_sync(lambda: self._transcriber.transcribe(audio, language=language))

    def _refine_transcription(
        self, transcription: Transcription, mode: Mode, language: str | None
    ) -> ProcessResult:
        """Blockierender Teil: Wörterbuch → Refiner → Löschschutz (bestehende Pipeline)."""
        return process_text(
            transcription.text,
            mode,
            refiner=self._refiner,
            dictionary=self._dictionary,
            language=transcription.language or language,
        )
```

Hinweis: `contextlib` und `replace` sind in `runtime.py` bereits importiert; `Transcription` aus
`..models` ergänzen, falls noch nicht importiert.

- [ ] **Schritt 4: Test laufen lassen, grün bestätigen**

Run: `cd engine && uv run pytest tests/test_runtime_streaming.py tests/test_runtime.py -q`
Erwartung: PASS (neue + alle bestehenden Runtime-Tests).

- [ ] **Schritt 5: Mutationsprobe (Batch-Rückfall)**

Beweise, dass ein Test den Rückfall bewacht: In `_consume_stream` den `except`-Block
vorübergehend durch `raise` ersetzen (Streaming-Fehler durchschlagen lassen) und
`test_streaming_fehler_faellt_auf_batch_zurueck` laufen lassen — muss **rot** werden. Mutation
zurücknehmen, grün bestätigen. Ergebnis im Bericht festhalten.

- [ ] **Schritt 6: Commit**

```bash
cd engine && bash ../scripts/check.sh
git add typeless_engine/server/runtime.py typeless_engine/pipeline/__init__.py tests/test_runtime_streaming.py
git commit -m "Streaming: EngineRuntime.process_stream mit Preload-Überlappung und Batch-Rückfall"
```

---

## Task 5: `POST /process/stream`-Endpunkt

Ein Endpunkt, der den gestreamten Request-Body häppchenweise dekodiert (über 4-Byte-Grenzen hinweg
sauber puffern!) und an `runtime.process_stream` reicht. Antwort ist wie bei `/process` ein
`ProcessResponse`.

**Files:**
- Modify: `engine/typeless_engine/server/app.py`
- Test: `engine/tests/test_server_stream.py`

**Interfaces:**
- Consumes: `EngineRuntime.process_stream` (Task 4).
- Produces: HTTP-Route `POST /process/stream` (Query: `mode`, optional `language`, `sample_rate`).

- [ ] **Schritt 1: Fehlschlagenden Test schreiben**

Neue Datei `engine/tests/test_server_stream.py`:

```python
"""Endpunkt /process/stream: Byte-Dekodierung über Chunk-Grenzen, Weiterreichen an die Runtime."""

from __future__ import annotations

from collections.abc import AsyncIterator

import numpy as np
from fastapi.testclient import TestClient

from typeless_engine.models import Mode, ProcessResult
from typeless_engine.server.app import create_app


class StubRuntime:
    """Minimale Runtime-Attrappe: sammelt die empfangenen Samples, liefert ein festes Ergebnis."""

    def __init__(self) -> None:
        self.received = np.zeros(0, dtype=np.float32)

    async def process_stream(self, audio_chunks: AsyncIterator[np.ndarray], mode, *, language=None):
        async for chunk in audio_chunks:
            self.received = np.concatenate([self.received, chunk])
        return ProcessResult(
            raw_text="roh",
            dictionary_text="roh",
            final_text="FERTIG",
            mode=mode,
            language="de",
            refined=True,
        )


def test_stream_endpunkt_dekodiert_ueber_chunk_grenzen() -> None:
    stub = StubRuntime()
    client = TestClient(create_app(stub))  # type: ignore[arg-type]

    # Drei Float32-Samples = 12 Byte, absichtlich in Häppchen zerschnitten, die MITTEN in einem
    # Sample brechen (5 + 4 + 3 Byte) — der Endpunkt muss die Reste über Grenzen hinweg puffern.
    payload = np.array([1.0, 2.0, 3.0], dtype="<f4").tobytes()
    parts = [payload[0:5], payload[5:9], payload[9:12]]

    def gen() -> bytes:
        yield from parts

    resp = client.post("/process/stream?mode=diktat", content=gen())
    assert resp.status_code == 200
    assert resp.json()["final_text"] == "FERTIG"
    assert np.allclose(stub.received, [1.0, 2.0, 3.0])


def test_stream_endpunkt_lehnt_falsche_sample_rate_ab() -> None:
    client = TestClient(create_app(StubRuntime()))  # type: ignore[arg-type]
    resp = client.post("/process/stream?mode=diktat&sample_rate=8000", content=b"")
    assert resp.status_code == 400


def test_stream_endpunkt_lehnt_unbekannten_modus_ab() -> None:
    client = TestClient(create_app(StubRuntime()))  # type: ignore[arg-type]
    resp = client.post("/process/stream?mode=quatsch", content=b"\x00\x00\x00\x00")
    assert resp.status_code == 400
```

- [ ] **Schritt 2: Test laufen lassen, Fehlschlag bestätigen**

Run: `cd engine && uv run pytest tests/test_server_stream.py -q`
Erwartung: FAIL — 404 (Route existiert noch nicht).

- [ ] **Schritt 3: Umsetzung**

In `engine/typeless_engine/server/app.py`:

Import ergänzen: `from fastapi import Request` (neben den bestehenden fastapi-Importen).

Route innerhalb `create_app` ergänzen (nach `/process`):

```python
    @app.post("/process/stream", response_model=ProcessResponse)
    async def process_audio_stream(
        request: Request,
        mode: Annotated[str, Query()],
        language: Annotated[str | None, Query()] = None,
        sample_rate: Annotated[int, Query()] = TARGET_SAMPLE_RATE,
    ) -> ProcessResponse:
        """Gestreamtes Float32-PCM (16 kHz mono) -> fertiger Text.

        Der Body kommt häppchenweise (chunked) an, während der Anwender noch spricht. Die
        Chunk-Grenzen liegen NICHT auf Sample-Grenzen — deshalb wird der 4-Byte-Rest über Grenzen
        hinweg gepuffert.
        """
        if sample_rate != TARGET_SAMPLE_RATE:
            raise HTTPException(
                status_code=400, detail=f"Erwarte {TARGET_SAMPLE_RATE} Hz, erhalten {sample_rate} Hz."
            )
        try:
            parsed_mode = Mode.from_string(mode)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

        async def sample_chunks() -> "AsyncIterator[np.ndarray]":
            leftover = b""
            async for raw in request.stream():
                if not raw:
                    continue
                buf = leftover + raw
                n = len(buf) - (len(buf) % _BYTES_PER_SAMPLE)
                if n:
                    yield np.frombuffer(buf[:n], dtype="<f4").astype(np.float32)
                leftover = buf[n:]
            # Ein unvollständiges Rest-Sample (<4 Byte) am Ende wird bewusst verworfen.

        try:
            result = await runtime.process_stream(
                sample_chunks(), parsed_mode, language=language
            )
        except StartupFailedError as exc:
            raise HTTPException(
                status_code=503, detail=f"Sidecar nicht einsatzbereit: {exc}"
            ) from exc
        except Exception as exc:  # noqa: BLE001 - ohne Transkription gibt es nichts zu retten
            _log.exception("Streaming-Verarbeitung fehlgeschlagen")
            raise HTTPException(
                status_code=500, detail=f"Verarbeitung fehlgeschlagen: {exc}"
            ) from exc

        return ProcessResponse(
            final_text=result.final_text,
            raw_text=result.raw_text,
            dictionary_text=result.dictionary_text,
            mode=result.mode.value,
            language=result.language,
            refined=result.refined,
            fallback_reason=result.fallback_reason,
            timings_ms=result.timings_ms,
        )
```

Für die Typannotation im generator-Docstring: oben `from collections.abc import AsyncIterator` und
`import numpy as np` sind in `app.py` bereits vorhanden (numpy ja; AsyncIterator ergänzen).

- [ ] **Schritt 4: Test laufen lassen, grün bestätigen**

Run: `cd engine && uv run pytest tests/test_server_stream.py tests/test_server_api.py -q`
Erwartung: PASS (neue + alle bestehenden Server-Tests).

- [ ] **Schritt 5: Commit**

```bash
cd engine && bash ../scripts/check.sh
git add typeless_engine/server/app.py tests/test_server_stream.py
git commit -m "Streaming: POST /process/stream — gestreamten Body dekodieren, an die Runtime"
```

---

## Task 6: On-device-Handprobe (Latenz + Qualität)

Ein kleines Messskript, das auf Apple Silicon eine echte WAV einmal per Batch und einmal per
Streaming durch die Engine schickt und beides vergleicht: **Latenz nach dem Loslassen** (Ziel
~2–3 s statt ~6–7 s) und den **Text** (zum Augenschein-Vergleich der Qualität). Von Hand
auszuführen — synthetische Sprache taugt für Whisper nicht.

**Files:**
- Create: `engine/scripts/measure_streaming.py`

**Interfaces:**
- Consumes: `MLXWhisperTranscriber` (Batch + Streaming), `STREAM_STEP_SAMPLES`.

- [ ] **Schritt 1: Messskript schreiben**

Neue Datei `engine/scripts/measure_streaming.py`:

```python
"""On-device-Handprobe für den Streaming-Motor (Apple Silicon).

Vergleicht Batch- und Streaming-Transkription EINER echten WAV: die Latenz nach dem "Loslassen"
(beim Streaming: nur der letzte Feed + finalize; beim Batch: der ganze Durchlauf) sowie den Text.

WAV erzeugen (aus einer Sprachmemo):
    afconvert -f WAVE -d LEI16@16000 -c 1 memo.m4a test.wav

Ausführen:
    cd engine && uv run --extra mlx python scripts/measure_streaming.py test.wav
"""

from __future__ import annotations

import sys
import time
import wave

import numpy as np

from typeless_engine.models import TARGET_SAMPLE_RATE, AudioBuffer
from typeless_engine.stt.mlx_whisper import STREAM_STEP_SAMPLES, MLXWhisperTranscriber


def _load_wav(path: str) -> np.ndarray:
    with wave.open(path, "rb") as w:
        if w.getframerate() != TARGET_SAMPLE_RATE or w.getnchannels() != 1:
            raise SystemExit(
                f"Erwarte 16 kHz mono. Erzeugen: afconvert -f WAVE -d LEI16@16000 -c 1 memo.m4a {path}"
            )
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2")
    return (pcm.astype(np.float32) / 32768.0).astype(np.float32)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Aufruf: python scripts/measure_streaming.py <pfad.wav>")
    samples = _load_wav(sys.argv[1])
    dauer = len(samples) / TARGET_SAMPLE_RATE
    t = MLXWhisperTranscriber()
    t.warm_up()

    # --- Batch: alles nach dem Loslassen ---
    t0 = time.perf_counter()
    batch = t.transcribe(AudioBuffer(samples=samples))
    batch_latenz = time.perf_counter() - t0

    # --- Streaming: während des "Sprechens" füttern, Latenz = nur der Schluss ---
    t.stream_begin()
    step = STREAM_STEP_SAMPLES
    letzter_feed = 0.0
    for i in range(0, len(samples), step):
        chunk = samples[i : i + step]
        t0 = time.perf_counter()
        t.stream_feed(chunk)
        letzter_feed = time.perf_counter() - t0  # Dauer des jeweils letzten Feeds
    t0 = time.perf_counter()
    streaming = t.stream_finalize()
    finalize_latenz = time.perf_counter() - t0
    stream_latenz = letzter_feed + finalize_latenz

    print(f"\nAudio-Dauer: {dauer:.1f} s")
    print(f"Batch-Latenz (nach Loslassen): {batch_latenz:.2f} s")
    print(f"Streaming-Latenz (nach Loslassen): {stream_latenz:.2f} s  "
          f"(letzter Feed {letzter_feed:.2f} + finalize {finalize_latenz:.2f})")
    print(f"\nBatch-Text:\n  {batch.text}")
    print(f"\nStreaming-Text:\n  {streaming.text}")
    print(f"\nIdentisch: {batch.text == streaming.text}")


if __name__ == "__main__":
    main()
```

- [ ] **Schritt 2: Ohne MLX prüfen, dass das Skript sauber importiert/abbricht**

Run: `cd engine && uv run python scripts/measure_streaming.py`
Erwartung: sauberer Abbruch mit „Aufruf: …" (kein Traceback, kein MLX nötig für diesen Pfad).

- [ ] **Schritt 3: On-device ausführen (Apple Silicon, echte WAV)**

Eine kurze Sprachmemo als `engine/test.wav` bereitlegen (s. Kommentar im Skript), dann:
Run: `cd engine && uv run --extra mlx python scripts/measure_streaming.py test.wav`
Erwartung: Die **Streaming-Latenz** liegt deutlich unter der **Batch-Latenz** (Ziel-Größenordnung
~2–3 s vs. ~4–6 s), und der Streaming-Text ist nah am Batch-Text. **Die Ausgabe (beide Latenzen,
beide Texte) im Bericht festhalten** — das ist der Beleg für den Latenzgewinn und das kleine
Qualitäts-Delta.

- [ ] **Schritt 4: Commit**

```bash
cd engine && bash ../scripts/check.sh
git add scripts/measure_streaming.py
git commit -m "Streaming: On-device-Messskript (Latenz Streaming vs. Batch + Text-Vergleich)"
```

---

## Handprobe / Abschluss

Nach Task 6 ist die **Python-Hälfte** fertig und belegt: Die Engine kann streamen, der Endpunkt ist
erreichbar, der Batch-Rückfall greift, und die Latenz sinkt messbar. Die Engine ist damit für sich
lauffähig und getestet — **benutzbar wird das Feature aber erst mit der Swift-Hälfte** (eigener,
direkt nachgelagerter Plan: Chunked-Upload über `HTTPUnixTransport` + Umbau des
`DictationCoordinator`, der das Audio während der Aufnahme hochstreamt und am Ende einmal einfügt).

Nichts an der bestehenden Batch-Kette (`/process`) wurde verändert — die heutige Diktat-Funktion
bleibt unberührt, bis die Swift-Seite auf den Streaming-Endpunkt umgestellt wird.
