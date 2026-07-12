"""Start des Sidecars auf einem Unix-Domain-Socket.

Bewusst kein TCP-Port: Der Socket ist eine Datei, die Zugangskontrolle sind Dateirechte.
Es gibt keine Netzwerkschnittstelle, unter der der Sidecar erreichbar wäre.

    uv run python -m typeless_engine.server
"""

from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path

import uvicorn
from fastapi import FastAPI

from ..config import EngineConfig
from ..logging_ import configure_logging, get_logger
from .app import create_app
from .runtime import EngineRuntime

_log = get_logger(__name__)


def prepare_socket_path(path: Path) -> None:
    """Legt das Verzeichnis an und entfernt eine verwaiste Socket-Datei.

    Nach einem Absturz bleibt die Datei liegen; uvicorn würde sich sonst weigern, den
    Socket anzulegen, und der Sidecar käme nie wieder hoch.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        _log.warning("Entferne verwaiste Socket-Datei: %s", path)
        path.unlink()


def build_app(config: EngineConfig | None = None) -> FastAPI:
    """Baut Runtime + App und verdrahtet den Lebenszyklus."""
    cfg = config or EngineConfig()
    runtime = EngineRuntime.from_config(cfg)

    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        # Das Warm-up läuft als Hintergrund-Task: Der Server muss sofort antworten können,
        # damit /health die ~14 s Ladezeit als "starting" melden kann.
        warm_up = asyncio.create_task(runtime.startup())
        runtime.start_idle_watcher()
        try:
            yield
        finally:
            warm_up.cancel()
            await runtime.shutdown()

    app = create_app(runtime)
    app.router.lifespan_context = lifespan
    return app


def main() -> None:
    """Startet den Sidecar auf dem konfigurierten Socket."""
    configure_logging()
    cfg = EngineConfig()
    prepare_socket_path(cfg.socket_path)
    _log.info("Sidecar startet auf %s", cfg.socket_path)

    uvicorn.run(build_app(cfg), uds=str(cfg.socket_path), log_level=cfg.log_level.lower())


if __name__ == "__main__":
    main()
