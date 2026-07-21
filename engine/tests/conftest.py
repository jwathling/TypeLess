"""Gemeinsame Fixtures für die gesamte Engine-Testsuite."""

from __future__ import annotations

import pytest

from typeless_engine.server import models_bootstrap


@pytest.fixture(autouse=True)
def _modelle_gelten_als_bereits_gecacht(monkeypatch: pytest.MonkeyPatch) -> None:
    """Default für die gesamte (bewusst Mock-basierte, netzfreie) Suite.

    Ohne diesen Default würde jeder ungemockte ``EngineRuntime.startup()``/``ensure_ready()``-
    Aufruf den *echten* ``models_bootstrap.models_cached`` treffen — und je nach Zustand des
    lokalen HF-Caches der jeweiligen Maschine sogar einen echten Mehr-Gigabyte-Download über
    ``total_download_bytes``/``download_models`` auslösen. Tests, die den Modell-Bootstrap selbst
    prüfen (``ensure_ready``), überschreiben das gezielt mit ihrem eigenen
    ``monkeypatch.setattr(rt.models_bootstrap, "models_cached", ...)``.
    """
    monkeypatch.setattr(models_bootstrap, "models_cached", lambda config: True)
