"""Audio-Hilfsfunktionen.

Bewusst nur stdlib + ``numpy``, um keine System-Bibliothek (libsndfile) zu benötigen.
Reicht für WAV-Eingaben in CLI/Tests. Im Produktivpfad liefert die Swift-App bereits
sauberes 16-kHz-Mono-Float32 über den Sidecar.

Der RIFF-Parser ist handgeschrieben, weil die stdlib ``wave`` nur den klassischen
Format-Tag 1 (PCM) kennt. ``afconvert`` — der auf macOS naheliegende Weg, eine Sprachmemo
nach WAV zu wandeln — schreibt aber WAVE_FORMAT_EXTENSIBLE (Tag 0xFFFE), woran ``wave``
mit "unknown format: 65534" scheitert.
"""

from __future__ import annotations

import struct
from pathlib import Path

import numpy as np

from .models import TARGET_SAMPLE_RATE, AudioBuffer

# WAV-Format-Tags.
_FMT_PCM = 0x0001
_FMT_IEEE_FLOAT = 0x0003
_FMT_EXTENSIBLE = 0xFFFE


def load_wav(path: str | Path) -> AudioBuffer:
    """Lädt eine WAV-Datei als Mono-Float32 und resampled auf 16 kHz."""
    fmt_tag, n_channels, sample_rate, bits_per_sample, frames = _read_riff(Path(path))

    samples = _pcm_to_float32(frames, fmt_tag, bits_per_sample)
    if n_channels > 1:
        samples = samples.reshape(-1, n_channels).mean(axis=1)

    buffer = AudioBuffer(samples=samples.astype(np.float32), sample_rate=sample_rate)
    if buffer.sample_rate != TARGET_SAMPLE_RATE:
        buffer = resample(buffer, TARGET_SAMPLE_RATE)
    return buffer


def _read_riff(path: Path) -> tuple[int, int, int, int, bytes]:
    """Liest fmt- und data-Chunk. Liefert (Format-Tag, Kanäle, Rate, Bits, Rohdaten)."""
    raw = path.read_bytes()
    if raw[:4] != b"RIFF" or raw[8:12] != b"WAVE":
        raise ValueError(f"Keine RIFF/WAVE-Datei: {path}")

    fmt: tuple[int, int, int, int] | None = None
    data: bytes | None = None

    pos = 12
    while pos + 8 <= len(raw):
        chunk_id = raw[pos : pos + 4]
        (size,) = struct.unpack("<I", raw[pos + 4 : pos + 8])
        body = raw[pos + 8 : pos + 8 + size]

        if chunk_id == b"fmt ":
            tag, channels, rate, _byte_rate, _align, bits = struct.unpack("<HHIIHH", body[:16])
            if tag == _FMT_EXTENSIBLE:
                # Der echte Typ steckt im SubFormat-GUID; dessen erste zwei Bytes sind der Tag.
                (tag,) = struct.unpack("<H", body[24:26])
            fmt = (tag, channels, rate, bits)
        elif chunk_id == b"data":
            data = body

        pos += 8 + size + (size % 2)  # Chunks sind auf gerade Länge gepaddet.

    if fmt is None or data is None:
        raise ValueError(f"WAV ohne fmt- oder data-Chunk: {path}")
    return (*fmt, data)


def _pcm_to_float32(frames: bytes, fmt_tag: int, bits_per_sample: int) -> np.ndarray:
    """Konvertiert Rohbytes in Float32 im Bereich [-1, 1]."""
    if fmt_tag == _FMT_IEEE_FLOAT and bits_per_sample == 32:
        return np.frombuffer(frames, dtype=np.float32).copy()
    if fmt_tag != _FMT_PCM:
        raise ValueError(f"Nicht unterstützter WAV-Format-Tag: 0x{fmt_tag:04X}")

    if bits_per_sample == 16:
        return np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    if bits_per_sample == 32:
        return np.frombuffer(frames, dtype=np.int32).astype(np.float32) / 2147483648.0
    if bits_per_sample == 8:
        # 8-bit PCM ist unsigned (0..255), Mittelpunkt 128.
        return (np.frombuffer(frames, dtype=np.uint8).astype(np.float32) - 128.0) / 128.0
    raise ValueError(f"Nicht unterstützte Bit-Tiefe: {bits_per_sample}")


def resample(audio: AudioBuffer, target_rate: int) -> AudioBuffer:
    """Einfaches lineares Resampling (ausreichend für Dev/CLI)."""
    if audio.sample_rate == target_rate or len(audio.samples) == 0:
        return AudioBuffer(samples=audio.samples, sample_rate=target_rate)
    duration = len(audio.samples) / audio.sample_rate
    target_len = int(round(duration * target_rate))
    src_idx = np.linspace(0, len(audio.samples) - 1, num=target_len)
    resampled = np.interp(src_idx, np.arange(len(audio.samples)), audio.samples)
    return AudioBuffer(samples=resampled.astype(np.float32), sample_rate=target_rate)
