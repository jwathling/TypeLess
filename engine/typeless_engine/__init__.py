"""TypeLess-Engine: headless STT- + LLM-Pipeline mit austauschbaren Backends.

Die öffentliche API besteht aus den abstrakten Interfaces (`Transcriber`, `Refiner`),
den Datentypen (`AudioBuffer`, `Transcription`, `Mode`, `ProcessResult`) und der
`process`-Pipeline. Konkrete Engines (MLX, Mock, später whisper.cpp) werden über die
Factory ausgewählt und sind nie direkt vom Kern referenziert.
"""

from __future__ import annotations

__version__ = "0.1.0"
