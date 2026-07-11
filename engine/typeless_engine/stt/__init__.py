"""Speech-to-Text-Backends (austauschbar hinter dem ``Transcriber``-Interface)."""

from __future__ import annotations

from .mock import MockTranscriber

__all__ = ["MockTranscriber"]

# MLXWhisperTranscriber wird bewusst NICHT eager importiert, da ``mlx_whisper`` nur auf
# Apple Silicon installiert ist. Import bei Bedarf via ``factory.build_transcriber``.
