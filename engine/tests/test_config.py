"""Tests der Engine-Konfiguration."""

from __future__ import annotations

from pathlib import Path

import pytest

from typeless_engine.config import APP_SUPPORT_DIR, EngineConfig


def test_socket_path_defaults_next_to_dictionary() -> None:
    cfg = EngineConfig()

    assert cfg.socket_path == APP_SUPPORT_DIR / "typeless.sock"


def test_idle_unload_defaults_to_five_minutes() -> None:
    cfg = EngineConfig()

    assert cfg.idle_unload_seconds == 300.0
    assert cfg.idle_check_interval_seconds == 10.0


def test_socket_path_from_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TYPELESS_SOCKET_PATH", "/tmp/custom.sock")

    cfg = EngineConfig()

    assert cfg.socket_path == Path("/tmp/custom.sock")


def test_idle_unload_from_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TYPELESS_IDLE_UNLOAD_SECONDS", "42")

    cfg = EngineConfig()

    assert cfg.idle_unload_seconds == 42.0
