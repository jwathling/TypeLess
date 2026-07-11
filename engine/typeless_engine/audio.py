"""Audio-Hilfsfunktionen.

Bewusst nur stdlib ``wave`` + ``numpy``, um keine System-Bibliothek (libsndfile) zu
benötigen. Reicht für WAV-Eingaben in CLI/Tests. Im Produktivpfad liefert die Swift-App
bereits sauberes 16-kHz-Mono-Float32 über den Sidecar.
"""

from __future__ import annotations

import wave
from pathlib import Path

import numpy as np

from .models import TARGET_SAMPLE_RATE, AudioBuffer


def load_wav(path: str | Path) -> AudioBuffer:
    """Lädt eine WAV-Datei als Mono-Float32 und resampled auf 16 kHz."""
    p = Path(path)
    with wave.open(str(p), "rb") as wav:
        n_channels = wav.getnchannels()
        sample_width = wav.getsampwidth()
        sample_rate = wav.getframerate()
        frames = wav.readframes(wav.getnframes())

    samples = _pcm_to_float32(frames, sample_width)
    if n_channels > 1:
        samples = samples.reshape(-1, n_channels).mean(axis=1)

    buffer = AudioBuffer(samples=samples.astype(np.float32), sample_rate=sample_rate)
    if buffer.sample_rate != TARGET_SAMPLE_RATE:
        buffer = resample(buffer, TARGET_SAMPLE_RATE)
    return buffer


def _pcm_to_float32(frames: bytes, sample_width: int) -> np.ndarray:
    """Konvertiert PCM-Rohbytes in Float32 im Bereich [-1, 1]."""
    if sample_width == 2:
        data = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    elif sample_width == 4:
        data = np.frombuffer(frames, dtype=np.int32).astype(np.float32) / 2147483648.0
    elif sample_width == 1:
        # 8-bit PCM ist unsigned (0..255), Mittelpunkt 128.
        data = (np.frombuffer(frames, dtype=np.uint8).astype(np.float32) - 128.0) / 128.0
    else:
        raise ValueError(f"Nicht unterstützte Sample-Breite: {sample_width} Byte")
    return data


def resample(audio: AudioBuffer, target_rate: int) -> AudioBuffer:
    """Einfaches lineares Resampling (ausreichend für Dev/CLI)."""
    if audio.sample_rate == target_rate or len(audio.samples) == 0:
        return AudioBuffer(samples=audio.samples, sample_rate=target_rate)
    duration = len(audio.samples) / audio.sample_rate
    target_len = int(round(duration * target_rate))
    src_idx = np.linspace(0, len(audio.samples) - 1, num=target_len)
    resampled = np.interp(src_idx, np.arange(len(audio.samples)), audio.samples)
    return AudioBuffer(samples=resampled.astype(np.float32), sample_rate=target_rate)
