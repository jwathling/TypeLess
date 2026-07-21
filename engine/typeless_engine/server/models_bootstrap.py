"""Modell-Bootstrap: lädt die von der Konfiguration benötigten Modell-Dateien in den HF-Cache,
bevor STT/LLM sie in den RAM laden, und meldet dabei Byte-Fortschritt. Lädt selbst NICHTS in den
RAM — das bleibt Sache von ``warm_up``/``preload``.

huggingface_hub wird lazy importiert: Der Kern muss ohne installierte Modelle importierbar bleiben.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from ..config import EngineConfig
from ..logging_ import get_logger

_log = get_logger(__name__)


def required_model_ids(config: EngineConfig) -> list[str]:
    """Die HF-Repo-IDs, die die aktuell konfigurierten Backends brauchen.

    Bewusst aus der Config, nicht aus den Backend-Interfaces: Der Austauschbarkeits-Vertrag
    (``transcribe``/``refine``) bleibt frei von Infrastruktur. Ein Backend, das andere Modelle
    braucht, bringt sie über dieselbe Config-Achse mit.
    """
    return [config.stt_model, config.llm_model]


def _snapshot_download(*args: Any, **kwargs: Any) -> Any:
    from huggingface_hub import snapshot_download  # noqa: PLC0415 (lazy)

    return snapshot_download(*args, **kwargs)


# Nach außen als Modulattribut sichtbar, damit Tests es mit monkeypatch ersetzen können.
snapshot_download = _snapshot_download


def models_cached(config: EngineConfig) -> bool:
    """Liegen alle benötigten Modelle bereits vollständig im lokalen HF-Cache? (kein Netz)"""
    from huggingface_hub.errors import LocalEntryNotFoundError  # noqa: PLC0415 (lazy)

    for repo in required_model_ids(config):
        try:
            snapshot_download(repo, local_files_only=True)
        except (LocalEntryNotFoundError, FileNotFoundError):
            return False
    return True


def total_download_bytes(config: EngineConfig) -> int:
    """Erwartete Gesamtgröße aller benötigten Modelle in Bytes (HF-Metadaten, braucht Netz)."""
    from huggingface_hub import HfApi  # noqa: PLC0415 (lazy)

    api = HfApi()
    total = 0
    for repo in required_model_ids(config):
        info = api.model_info(repo, files_metadata=True)
        total += sum((sibling.size or 0) for sibling in (info.siblings or []))
    return total


def download_models(config: EngineConfig, on_progress: Callable[[int, int], None]) -> None:
    """Lädt alle benötigten Modell-Dateien in den Cache und meldet ``(downloaded, total)`` laufend.

    Der Fortschritt kommt über eine ``tqdm``-Unterklasse: huggingface_hub instanziiert sie pro Datei
    und ruft ``update(n)`` mit der Anzahl gerade geladener Bytes. Wir summieren diese über alle
    Dateien/Repos. Bereits gecachte Dateien lösen kein ``update`` aus — deshalb am Ende genau ein
    ``on_progress(total, total)``, damit der Balken auch bei teilweise vollem Cache sauber schließt.
    """
    import tqdm as tqdm_mod  # noqa: PLC0415 (lazy — nur beim echten Download nötig)

    total = total_download_bytes(config)
    downloaded = 0

    class _ProgressTqdm(tqdm_mod.tqdm):  # type: ignore[misc]
        def update(self, n: float | None = 1) -> None:
            nonlocal downloaded
            downloaded += int(n or 0)
            # Xet-beschleunigtes huggingface_hub instanziiert pro Datei mehrere tqdm-Phasen
            # ("Downloading bytes" + "Reconstructing"), die BEIDE update() melden — der rohe
            # Akkumulator überschießt dadurch real bis ~172 % von total. Nach außen wird daher
            # bei total geclampt; roh weiterzählen bleibt nötig für super().update(n).
            on_progress(min(downloaded, total), total)
            super().update(n)

    for repo in required_model_ids(config):
        _log.info("Lade Modell in den Cache: %s", repo)
        snapshot_download(repo, tqdm_class=_ProgressTqdm)

    on_progress(total, total)
