"""On-device-Handprobe (Apple Silicon): lädt die Modelle in einen FRISCHEN Cache und zeigt den
Byte-Fortschritt. Simuliert den ersten Start auf einem neuen Mac.

    cd engine && uv run --extra mlx python scripts/measure_model_bootstrap.py
"""

from __future__ import annotations

import tempfile
import time
from pathlib import Path

from typeless_engine.config import EngineConfig
from typeless_engine.server import models_bootstrap as mb


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        import os

        os.environ["HF_HOME"] = str(Path(tmp) / "models")  # frischer Cache
        cfg = EngineConfig()
        print(f"cached (frisch, erwartet False): {mb.models_cached(cfg)}")
        total = mb.total_download_bytes(cfg)
        print(f"Gesamtgröße: {total / 1e9:.2f} GB")

        t0 = time.perf_counter()
        letzte = 0.0

        def on_progress(downloaded: int, total_bytes: int) -> None:
            nonlocal letzte
            now = time.perf_counter()
            if now - letzte >= 2.0 or downloaded == total_bytes:  # nicht zu geschwätzig
                pct = 100 * downloaded / total_bytes if total_bytes else 0
                print(f"  {pct:5.1f} %  ({downloaded / 1e9:.2f} / {total_bytes / 1e9:.2f} GB)")
                letzte = now

        mb.download_models(cfg, on_progress)
        print(f"fertig in {time.perf_counter() - t0:.0f} s; cached jetzt: {mb.models_cached(cfg)}")


if __name__ == "__main__":
    main()
