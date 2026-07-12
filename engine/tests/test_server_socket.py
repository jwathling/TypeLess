"""Verifiziert das Einzige, was sich nicht mocken lässt: den echten Unix-Domain-Socket."""

from __future__ import annotations

import asyncio
from pathlib import Path

import pytest
import uvicorn
from httpx import AsyncClient, AsyncHTTPTransport

from tests.test_runtime import SpyRefiner, SpyTranscriber
from typeless_engine.config import EngineConfig
from typeless_engine.dictionary import DictionaryEngine
from typeless_engine.server.__main__ import prepare_socket_path
from typeless_engine.server.app import create_app
from typeless_engine.server.runtime import EngineRuntime


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


def test_prepare_socket_path_removes_stale_file(tmp_path: Path) -> None:
    """Nach einem Absturz bleibt die Socket-Datei liegen — sonst startet der Server nie wieder."""
    socket_path = tmp_path / "nested" / "typeless.sock"
    socket_path.parent.mkdir(parents=True)
    socket_path.write_bytes(b"")  # verwaiste Datei
    assert socket_path.exists()

    prepare_socket_path(socket_path)

    assert not socket_path.exists()
    assert socket_path.parent.is_dir()


def test_prepare_socket_path_creates_missing_directory(tmp_path: Path) -> None:
    socket_path = tmp_path / "neu" / "typeless.sock"

    prepare_socket_path(socket_path)

    assert socket_path.parent.is_dir()


@pytest.mark.anyio
async def test_server_speaks_over_a_real_unix_socket(tmp_path: Path) -> None:
    socket_path = tmp_path / "typeless.sock"
    runtime = EngineRuntime(
        EngineConfig(stt_backend="mock", llm_backend="mock"),
        transcriber=SpyTranscriber(),
        refiner=SpyRefiner(),
        dictionary=DictionaryEngine({}),
    )
    await runtime.startup()

    config = uvicorn.Config(
        create_app(runtime), uds=str(socket_path), log_level="warning", lifespan="off"
    )
    server = uvicorn.Server(config)
    task = asyncio.create_task(server.serve())
    try:
        for _ in range(200):  # auf den Socket warten
            if socket_path.exists():
                break
            await asyncio.sleep(0.01)
        assert socket_path.exists(), "Server hat den Socket nicht angelegt"

        transport = AsyncHTTPTransport(uds=str(socket_path))
        async with AsyncClient(transport=transport, base_url="http://sidecar") as client:
            response = await client.get("/health")

        assert response.status_code == 200
        assert response.json()["status"] == "ready"
    finally:
        server.should_exit = True
        await task
