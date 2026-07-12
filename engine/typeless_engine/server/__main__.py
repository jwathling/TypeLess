"""Start des Sidecars auf einem Unix-Domain-Socket.

Bewusst kein TCP-Port: Der Socket ist eine Datei, die Zugangskontrolle sind Dateirechte.
Es gibt keine Netzwerkschnittstelle, unter der der Sidecar erreichbar wäre.

    uv run python -m typeless_engine.server
"""

from __future__ import annotations

import asyncio
import contextlib
import socket
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

# Lebendigkeitstest am bestehenden Socket: Ein lauschender Sidecar akzeptiert lokal sofort,
# ein verwaister Socket weist die Verbindung ebenso sofort ab. Der Timeout ist nur eine
# Reißleine, keine Wartezeit im Normalfall.
_LIVENESS_TIMEOUT_SECONDS = 0.5


def _socket_is_alive(path: Path) -> bool:
    """Lauscht an ``path`` eine lebende Instanz?

    Ein kurzer Verbindungsversuch ist die einzige verlässliche Unterscheidung zwischen einem
    nach einem Absturz liegengebliebenen (verwaisten) Socket und dem Socket eines laufenden
    Sidecars — die Datei selbst sieht in beiden Fällen identisch aus.

    Raises:
        RuntimeError: Wenn der Verbindungsversuch mit einem anderen ``OSError`` als
            ``ConnectionRefusedError``/``FileNotFoundError`` scheitert (z. B. ``PermissionError``
            oder ``TimeoutError``). Das ist kein Beweis für "verwaist" — im Zweifel wird
            abgebrochen statt gelöscht.
    """
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(_LIVENESS_TIMEOUT_SECONDS)
    try:
        probe.connect(str(path))
    except (ConnectionRefusedError, FileNotFoundError):
        # Die Datei liegt da (oder ist gerade verschwunden), aber niemand lauscht -> verwaist.
        return False
    except OSError as exc:
        # Alles andere (z. B. PermissionError, TimeoutError bei vollem Listen-Backlog) ist kein
        # Beweis für "verwaist" — eine lebende Instanz könnte dahinterstecken. Im Zweifel wird
        # nichts gelöscht, sondern abgebrochen.
        raise RuntimeError(
            f"Zustand des Sockets {path} nicht feststellbar, deshalb wird nichts gelöscht."
        ) from exc
    else:
        return True
    finally:
        probe.close()


def prepare_socket_path(path: Path) -> None:
    """Legt das Verzeichnis an und entfernt eine **verwaiste** Socket-Datei.

    Nach einem Absturz bleibt die Datei liegen; uvicorn würde sich sonst weigern, den
    Socket anzulegen, und der Sidecar käme nie wieder hoch.

    Gelöscht wird aber nur, was nachweislich ein toter Socket ist. ``socket_path`` ist frei
    konfigurierbar — ein Tippfehler darf nicht dazu führen, dass der Sidecar wortlos eine
    beliebige Datei entfernt. Und lauscht dort bereits eine Instanz, wäre ein Entfernen fatal:
    Die erste liefe weiter (und hielte ~1,5 GB STT-RAM), wäre für Clients aber unerreichbar.

    Das Elternverzeichnis wird mit ``0o700`` angelegt: Die Zugangskontrolle des Sockets ist
    das einzige Sicherheitsmerkmal des Sidecars (kein Auth, keine Tokens), und uvicorn setzt
    den frisch angelegten Socket selbst auf ``0o666``.

    Raises:
        RuntimeError: Wenn der Pfad kein Socket ist, dort bereits ein Sidecar lauscht oder sich
            der Zustand des Sockets nicht feststellen lässt (siehe ``_socket_is_alive``).
    """
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)

    if not path.exists() and not path.is_symlink():
        return

    if not path.is_socket():
        raise RuntimeError(
            f"{path} existiert bereits und ist kein Unix-Domain-Socket. Der Sidecar löscht "
            "keine fremden Dateien — bitte 'socket_path' prüfen."
        )

    if _socket_is_alive(path):
        raise RuntimeError(
            f"Es läuft bereits ein Sidecar auf diesem Socket: {path}. "
            "Beende die laufende Instanz, bevor du eine neue startest."
        )

    _log.warning("Entferne verwaiste Socket-Datei: %s", path)
    path.unlink(missing_ok=True)


def build_app(
    config: EngineConfig | None = None, *, runtime: EngineRuntime | None = None
) -> FastAPI:
    """Baut Runtime + App und verdrahtet den Lebenszyklus.

    ``runtime`` ist ein Testhaken: Ohne Angabe wird die Runtime wie im Produktivpfad über
    ``EngineRuntime.from_config`` (und damit über die Factory) gebaut. Der Aufruf
    ``build_app(cfg)`` bleibt unverändert gültig.
    """
    cfg = config or EngineConfig()
    engine = runtime or EngineRuntime.from_config(cfg)

    async def warm_up_visibly() -> None:
        """Warm-up mit sichtbarem Fehler.

        Ohne dieses ``except`` bliebe eine Exception im Hintergrund-Task unabgeholt: ``/health``
        meldete für immer ``starting``, und der einzige Hinweis wäre ein "Task exception was
        never retrieved" beim Garbage-Collect. Ein Sidecar, dessen STT nicht lädt, muss das im
        Log sagen.
        """
        try:
            await engine.startup()
        except asyncio.CancelledError:
            raise  # Regulärer Shutdown während des Warm-ups — kein Fehler.
        except Exception:  # noqa: BLE001 - jeder Backend-Fehler ist hier gleichwertig
            _log.exception("STT-Warm-up fehlgeschlagen — /health bleibt auf 'starting'.")

    @asynccontextmanager
    async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
        # Das Warm-up läuft als Hintergrund-Task: Der Server muss sofort antworten können,
        # damit /health die ~14 s Ladezeit als "starting" melden kann.
        warm_up = asyncio.create_task(warm_up_visibly())
        engine.start_idle_watcher()
        try:
            yield
        finally:
            warm_up.cancel()
            # Abwarten, sonst "Task was destroyed but it is pending!" — analog zu
            # EngineRuntime.stop_idle_watcher().
            with contextlib.suppress(asyncio.CancelledError):
                await warm_up
            await engine.shutdown()

    return create_app(engine, lifespan=lifespan)


def main() -> None:
    """Startet den Sidecar auf dem konfigurierten Socket."""
    configure_logging()
    cfg = EngineConfig()
    prepare_socket_path(cfg.socket_path)
    _log.info("Sidecar startet auf %s", cfg.socket_path)

    try:
        uvicorn.run(build_app(cfg), uds=str(cfg.socket_path), log_level=cfg.log_level.lower())
    finally:
        # uvicorn.run() räumt den UDS-Pfad bereits in seinem eigenen finally auf. Dieses
        # unlink() ist eine bewusste Absicherung gegen künftige uvicorn-Änderungen: Eine
        # liegengebliebene Datei darf kein Beweis für einen laufenden Sidecar sein — die
        # Swift-Shell (M3) prüft die Erreichbarkeit sonst an einer Leiche.
        cfg.socket_path.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
