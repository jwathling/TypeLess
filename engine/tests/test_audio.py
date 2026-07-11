"""Tests für das WAV-Laden und Resampling."""

from __future__ import annotations

import struct
import wave
from pathlib import Path

import numpy as np
import pytest

from typeless_engine.audio import load_wav, resample
from typeless_engine.models import TARGET_SAMPLE_RATE, AudioBuffer


def _sine(n: int, rate: int, freq: float = 440.0) -> np.ndarray:
    t = np.arange(n) / rate
    return (0.5 * np.sin(2 * np.pi * freq * t)).astype(np.float32)


def _write_pcm_wav(path: Path, samples: np.ndarray, rate: int, channels: int = 1) -> None:
    """Schreibt ein klassisches PCM-WAV (Format-Tag 1) über die stdlib."""
    pcm = (samples * 32767).astype(np.int16)
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(channels)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(pcm.tobytes())


def _write_extensible_wav(path: Path, samples: np.ndarray, rate: int) -> None:
    """Schreibt ein WAVE_FORMAT_EXTENSIBLE-WAV (Format-Tag 0xFFFE), 16 bit mono.

    Genau das erzeugt ``afconvert -f WAVE -d LEI16@16000 -c 1`` auf macOS — die stdlib
    ``wave`` lehnt es ab ("unknown format: 65534").
    """
    pcm = (samples * 32767).astype(np.int16).tobytes()
    channels, bits = 1, 16
    block_align = channels * bits // 8
    # KSDATAFORMAT_SUBTYPE_PCM
    subformat = struct.pack("<H", 1) + b"\x00\x00\x00\x00\x10\x00\x80\x00\x00\xaa\x00\x38\x9b\x71"
    fmt_body = struct.pack(
        "<HHIIHH", 0xFFFE, channels, rate, rate * block_align, block_align, bits
    ) + struct.pack(
        "<HHI", 22, bits, 0x4
    )  # cbSize, validBits, channelMask
    fmt_body += subformat
    fmt_chunk = b"fmt " + struct.pack("<I", len(fmt_body)) + fmt_body
    data_chunk = b"data" + struct.pack("<I", len(pcm)) + pcm
    riff = b"WAVE" + fmt_chunk + data_chunk
    path.write_bytes(b"RIFF" + struct.pack("<I", len(riff)) + riff)


def test_load_plain_pcm_wav(tmp_path: Path) -> None:
    path = tmp_path / "pcm.wav"
    _write_pcm_wav(path, _sine(TARGET_SAMPLE_RATE, TARGET_SAMPLE_RATE), TARGET_SAMPLE_RATE)

    audio = load_wav(path)

    assert audio.sample_rate == TARGET_SAMPLE_RATE
    assert audio.samples.dtype == np.float32
    assert audio.duration_seconds == pytest.approx(1.0)
    assert np.abs(audio.samples).max() == pytest.approx(0.5, abs=0.01)


def test_load_extensible_wav_from_afconvert(tmp_path: Path) -> None:
    """WAVE_FORMAT_EXTENSIBLE muss geladen werden — das liefert afconvert auf macOS."""
    path = tmp_path / "extensible.wav"
    _write_extensible_wav(path, _sine(TARGET_SAMPLE_RATE, TARGET_SAMPLE_RATE), TARGET_SAMPLE_RATE)

    audio = load_wav(path)

    assert audio.sample_rate == TARGET_SAMPLE_RATE
    assert audio.duration_seconds == pytest.approx(1.0)
    assert np.abs(audio.samples).max() == pytest.approx(0.5, abs=0.01)


def test_stereo_is_downmixed_to_mono(tmp_path: Path) -> None:
    path = tmp_path / "stereo.wav"
    mono = _sine(TARGET_SAMPLE_RATE, TARGET_SAMPLE_RATE)
    stereo = np.repeat(mono, 2)  # identische Kanäle -> Mittelwert == mono
    _write_pcm_wav(path, stereo, TARGET_SAMPLE_RATE, channels=2)

    audio = load_wav(path)

    assert audio.samples.ndim == 1
    assert audio.duration_seconds == pytest.approx(1.0)


def test_non_16khz_is_resampled(tmp_path: Path) -> None:
    path = tmp_path / "44k.wav"
    _write_pcm_wav(path, _sine(44_100, 44_100), 44_100)

    audio = load_wav(path)

    assert audio.sample_rate == TARGET_SAMPLE_RATE
    assert len(audio.samples) == TARGET_SAMPLE_RATE


def test_resample_is_noop_at_target_rate() -> None:
    audio = AudioBuffer(samples=_sine(1000, TARGET_SAMPLE_RATE))

    out = resample(audio, TARGET_SAMPLE_RATE)

    assert np.array_equal(out.samples, audio.samples)
