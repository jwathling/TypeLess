"""Verifiziert das Einzige, was sich nicht mocken lässt: den echten Unix-Domain-Socket.

Dazu die zweite nicht mockbare Zusicherung dieser Task: Das ~14 s lange STT-Warm-up blockiert
den Serverstart **nicht** — ``/health`` antwortet währenddessen und meldet ``starting``. Das
lässt sich nur an der echten App mit **aktivem** Lifespan zeigen, deshalb laufen diese Tests
gegen ``build_app()`` unter uvicorn statt gegen eine handverdrahtete App.
"""

from __future__ import annotations

import asyncio
import shutil
import socket
import tempfile
import threading
from collections.abc import Callable, Iterator
from pathlib import Path

import pytest
import uvicorn
from httpx import AsyncClient, AsyncHTTPTransport

from tests.test_runtime import SpyRefiner, SpyTranscriber
from typeless_engine.config import EngineConfig
from typeless_engine.dictionary import DictionaryEngine
from typeless_engine.server.__main__ import build_app, prepare_socket_path
from typeless_engine.server.runtime import EngineRuntime

# Reißleine für alle Wartevorgänge. Wir warten nie eine feste Zeit ab, sondern pollen bis zu
# einer Bedingung — der Timeout schlägt nur zu, wenn der Testling wirklich hängt.
_TIMEOUT_SECONDS = 10.0
_POLL_INTERVAL_SECONDS = 0.01


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


@pytest.fixture
def socket_dir() -> Iterator[Path]:
    """Kurzes, eindeutiges Temp-Verzeichnis für Unix-Domain-Sockets.

    ``tmp_path`` taugt dafür auf macOS nicht: Es liegt unter einem tief verschachtelten,
    pro Boot zufälligen Pfad (``/private/var/folders/.../T/pytest-of-.../pytest-N/<testname>/``),
    und ein darunter angelegter Socket sprengt regelmäßig das Limit von ``sockaddr_un.sun_path``
    (104 Byte). Ein eindeutiger Name direkt unter ``/tmp`` ist kurz genug, kollidiert nicht mit
    parallelen Läufen und wird hier garantiert wieder abgeräumt.
    """
    path = Path(tempfile.mkdtemp(prefix="tl-", dir="/tmp"))
    try:
        yield path
    finally:
        shutil.rmtree(path, ignore_errors=True)


async def _wait_until(condition: Callable[[], bool], message: str) -> None:
    """Pollt bis zur Bedingung — statt einer festen Wartezeit (die entweder bremst oder flakt)."""
    for _ in range(int(_TIMEOUT_SECONDS / _POLL_INTERVAL_SECONDS)):
        if condition():
            return
        await asyncio.sleep(_POLL_INTERVAL_SECONDS)
    raise AssertionError(message)


# ---- prepare_socket_path ----------------------------------------------------


def test_prepare_socket_path_removes_stale_socket(socket_dir: Path) -> None:
    """Nach einem Absturz bleibt die Socket-Datei liegen — sonst startet der Server nie wieder."""
    socket_path = socket_dir / "nested" / "typeless.sock"
    socket_path.parent.mkdir(parents=True)

    # Verwaister Socket: gebunden, aber niemand lauscht mehr. Die Datei bleibt liegen.
    stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stale.bind(str(socket_path))
    stale.close()
    assert socket_path.is_socket()

    prepare_socket_path(socket_path)

    assert not socket_path.exists()
    assert socket_path.parent.is_dir()


def test_prepare_socket_path_refuses_to_delete_a_regular_file(socket_dir: Path) -> None:
    """``socket_path`` ist frei konfigurierbar — ein Tippfehler darf keine Datei kosten."""
    socket_path = socket_dir / "wichtig.txt"
    socket_path.write_bytes(b"nicht loeschen")

    with pytest.raises(RuntimeError, match="kein Unix-Domain-Socket"):
        prepare_socket_path(socket_path)

    assert socket_path.read_bytes() == b"nicht loeschen"


def test_prepare_socket_path_refuses_to_evict_a_live_instance(socket_dir: Path) -> None:
    """Sonst liefe die erste Instanz weiter (mit ~1,5 GB STT-RAM), nur eben unerreichbar."""
    socket_path = socket_dir / "typeless.sock"
    live = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    live.bind(str(socket_path))
    live.listen(1)
    try:
        with pytest.raises(RuntimeError, match="läuft bereits ein Sidecar"):
            prepare_socket_path(socket_path)

        assert socket_path.is_socket(), "Der Socket der laufenden Instanz wurde entfernt"
    finally:
        live.close()


def test_prepare_socket_path_refuses_to_delete_when_liveness_is_undeterminable(
    socket_dir: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Ein anderer ``OSError`` als ``ConnectionRefusedError`` ist kein Beweis für "verwaist".

    Simuliert z. B. ``PermissionError`` beim Verbindungsversuch — die Datei liegt zwar da,
    aber ob dahinter eine lebende Instanz steckt, lässt sich dann nicht feststellen. Im
    Zweifel muss abgebrochen werden, nicht gelöscht.
    """
    socket_path = socket_dir / "typeless.sock"
    stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stale.bind(str(socket_path))
    stale.close()
    assert socket_path.is_socket()

    def _raise_permission_error(self: socket.socket, address: str) -> None:
        raise PermissionError("simulierter Rechte-Fehler beim Verbindungsversuch")

    monkeypatch.setattr(socket.socket, "connect", _raise_permission_error)

    with pytest.raises(RuntimeError, match="nicht feststellbar"):
        prepare_socket_path(socket_path)

    assert socket_path.is_socket(), "Ein Socket mit unbekanntem Zustand wurde gelöscht"


def test_prepare_socket_path_creates_missing_directory(socket_dir: Path) -> None:
    socket_path = socket_dir / "neu" / "typeless.sock"

    prepare_socket_path(socket_path)

    assert socket_path.parent.is_dir()
    # Die Dateirechte des Sockets sind die einzige Zugangskontrolle des Sidecars; uvicorn
    # chmoddet den Socket selbst auf 0o666, also muss das Elternverzeichnis schützen.
    assert socket_path.parent.stat().st_mode & 0o777 == 0o700


# ---- Server über den echten Socket ------------------------------------------


def _make_runtime(transcriber: SpyTranscriber | None = None) -> EngineRuntime:
    return EngineRuntime(
        EngineConfig(stt_backend="mock", llm_backend="mock"),
        transcriber=transcriber or SpyTranscriber(),
        refiner=SpyRefiner(),
        dictionary=DictionaryEngine({}),
    )


@pytest.mark.anyio
async def test_server_speaks_over_a_real_unix_socket(socket_dir: Path) -> None:
    socket_path = socket_dir / "typeless.sock"
    runtime = _make_runtime()
    await runtime.startup()

    config = uvicorn.Config(
        build_app(EngineConfig(stt_backend="mock", llm_backend="mock"), runtime=runtime),
        uds=str(socket_path),
        log_level="warning",
    )
    server = uvicorn.Server(config)
    task = asyncio.create_task(server.serve())
    try:
        await _wait_until(socket_path.exists, "Server hat den Socket nicht angelegt")

        transport = AsyncHTTPTransport(uds=str(socket_path))
        async with AsyncClient(transport=transport, base_url="http://sidecar") as client:
            response = await client.get("/health")

        assert response.status_code == 200
        assert response.json()["status"] == "ready"
    finally:
        server.should_exit = True
        await task


class GatedTranscriber(SpyTranscriber):
    """Ein Transcriber, dessen Warm-up hängt, bis der Test ihn freigibt.

    Steht stellvertretend für die ~14 s, die ``whisper-large-v3-turbo`` zum Laden braucht —
    ohne den Test 14 s lang schlafen zu lassen.
    """

    def __init__(self) -> None:
        super().__init__()
        self.gate = threading.Event()
        self.warming_up = threading.Event()

    def warm_up(self) -> None:
        self.warming_up.set()
        assert self.gate.wait(timeout=_TIMEOUT_SECONDS), "Warm-up-Gate wurde nie freigegeben"
        super().warm_up()


@pytest.mark.anyio
async def test_health_answers_during_warm_up_and_flips_to_ready(socket_dir: Path) -> None:
    """Die Kernzusicherung von M2: Das Warm-up blockiert den Serverstart nicht.

    Läuft gegen ``build_app()`` mit **aktivem** Lifespan — genau der Pfad, den ``main()``
    nimmt. Ein Warm-up im Vordergrund (statt als Hintergrund-Task) würde hier schon daran
    scheitern, dass uvicorn den Socket nie anlegt.
    """
    socket_path = socket_dir / "typeless.sock"
    stt = GatedTranscriber()
    cfg = EngineConfig(stt_backend="mock", llm_backend="mock")

    server = uvicorn.Server(
        uvicorn.Config(
            build_app(cfg, runtime=_make_runtime(transcriber=stt)),
            uds=str(socket_path),
            log_level="warning",
        )
    )
    task = asyncio.create_task(server.serve())
    transport = AsyncHTTPTransport(uds=str(socket_path))
    try:
        await _wait_until(socket_path.exists, "Server hat den Socket nicht angelegt")
        await _wait_until(stt.warming_up.is_set, "Das Warm-up wurde nie gestartet")

        async with AsyncClient(transport=transport, base_url="http://sidecar") as client:
            # Das Warm-up hängt noch am Gate — der Server antwortet trotzdem.
            during = await client.get("/health")
            assert during.status_code == 200
            assert during.json()["status"] == "starting"
            assert during.json()["stt_loaded"] is False

            stt.gate.set()

            ready: dict[str, object] = {}

            async def is_ready() -> bool:
                response = await client.get("/health")
                ready.update(response.json())
                return bool(ready["status"] == "ready")

            for _ in range(int(_TIMEOUT_SECONDS / _POLL_INTERVAL_SECONDS)):
                if await is_ready():
                    break
                await asyncio.sleep(_POLL_INTERVAL_SECONDS)

            assert ready["status"] == "ready", "Der Sidecar wurde nach dem Warm-up nie bereit"
            assert ready["stt_loaded"] is True
        assert stt.warm_ups == 1
    finally:
        stt.gate.set()  # nie einen Worker-Thread hängen lassen, auch wenn der Test scheitert
        server.should_exit = True
        await task
