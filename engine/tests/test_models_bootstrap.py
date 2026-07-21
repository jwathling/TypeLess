from __future__ import annotations

from typeless_engine.config import EngineConfig
from typeless_engine.server import models_bootstrap as mb

# Referenz auf die ECHTE Funktion, eingefroren beim Modul-Import (vor jeder Fixture). Die
# autouse-Fixture ``_modelle_gelten_als_bereits_gecacht`` in conftest.py patcht
# ``mb.models_cached`` für die gesamte restliche Suite auf eine feste Lambda (True) — die
# beiden direkten Tests unten wollen aber genau die echte Implementierung prüfen. ``snapshot_
# download`` wird trotzdem korrekt aufgelöst: Python schlägt Modul-Globals zur Laufzeit über
# ``__globals__`` nach, nicht beim ``def`` — ``monkeypatch.setattr(mb, "snapshot_download",
# ...)`` in den Tests unten wirkt also auch auf diese eingefrorene Referenz.
_real_models_cached = mb.models_cached


def test_required_model_ids_kommen_aus_der_config():
    cfg = EngineConfig(stt_model="stt/repo", llm_model="llm/repo")
    assert mb.required_model_ids(cfg) == ["stt/repo", "llm/repo"]


def test_download_models_meldet_fortschritt_und_schliesst_mit_total(monkeypatch):
    cfg = EngineConfig(stt_model="stt/repo", llm_model="llm/repo")
    monkeypatch.setattr(mb, "total_download_bytes", lambda config: 1000)

    # snapshot_download durch ein Fake ersetzen, das die tqdm_class wie huggingface_hub bedient:
    # pro Repo 250 Bytes in zwei Häppchen laden.
    def fake_snapshot(repo_id, *, tqdm_class, **kwargs):
        bar = tqdm_class(total=250, unit="B")
        bar.update(100)
        bar.update(150)
        bar.close()

    monkeypatch.setattr(mb, "snapshot_download", fake_snapshot)

    calls: list[tuple[int, int]] = []
    mb.download_models(cfg, lambda d, t: calls.append((d, t)))

    # Zwischenstände monoton steigend, Gesamt immer 1000, Abschluss exakt (1000, 1000).
    assert calls[0] == (100, 1000)
    assert [d for d, _ in calls] == sorted(d for d, _ in calls)
    assert all(t == 1000 for _, t in calls)
    assert calls[-1] == (1000, 1000)


def test_models_cached_true_wenn_alle_repos_lokal_vorhanden(monkeypatch):
    cfg = EngineConfig(stt_model="stt/repo", llm_model="llm/repo")

    def fake_snapshot(repo_id, *, local_files_only):
        return f"/fake/cache/{repo_id}"

    monkeypatch.setattr(mb, "snapshot_download", fake_snapshot)

    assert _real_models_cached(cfg) is True


def test_models_cached_false_wenn_ein_repo_fehlt(monkeypatch):
    """Direkter Test, weil die HF-Cache-Oberfläche schon einmal überrascht hat (Xet-Doppelzählung
    oben). ``LocalEntryNotFoundError`` ist der Fehler, den ``snapshot_download(local_files_only=
    True)`` für einen nicht gecachten Repo tatsächlich wirft."""
    from huggingface_hub.errors import LocalEntryNotFoundError

    cfg = EngineConfig(stt_model="stt/repo", llm_model="llm/repo")

    def fake_snapshot(repo_id, *, local_files_only):
        if repo_id == "llm/repo":
            raise LocalEntryNotFoundError("nicht im Cache")
        return f"/fake/cache/{repo_id}"

    monkeypatch.setattr(mb, "snapshot_download", fake_snapshot)

    assert _real_models_cached(cfg) is False


def test_total_download_bytes_summiert_ueber_alle_konfigurierten_repos(monkeypatch):
    cfg = EngineConfig(stt_model="stt/repo", llm_model="llm/repo")

    class FakeSibling:
        def __init__(self, size):
            self.size = size

    class FakeModelInfo:
        def __init__(self, siblings):
            self.siblings = siblings

    infos = {
        "stt/repo": FakeModelInfo([FakeSibling(100), FakeSibling(200)]),
        "llm/repo": FakeModelInfo([FakeSibling(500)]),
    }

    class FakeHfApi:
        def model_info(self, repo_id, *, files_metadata=True):
            return infos[repo_id]

    monkeypatch.setattr("huggingface_hub.HfApi", FakeHfApi)

    assert mb.total_download_bytes(cfg) == 800


def test_total_download_bytes_behandelt_fehlende_siblings_und_groessen_als_null(monkeypatch):
    """Deckt die beiden Guards ``(info.siblings or [])`` und ``(sibling.size or 0)`` ab — die
    HF-/Xet-Oberfläche liefert in der Praxis gelegentlich ``siblings=None`` bzw. ein Sibling ohne
    ``size``."""
    cfg = EngineConfig(stt_model="stt/repo", llm_model="llm/repo")

    class FakeSibling:
        def __init__(self, size):
            self.size = size

    class FakeModelInfo:
        def __init__(self, siblings):
            self.siblings = siblings

    infos = {
        "stt/repo": FakeModelInfo(None),  # kein siblings-Feld -> wie leere Liste behandeln
        "llm/repo": FakeModelInfo([FakeSibling(None), FakeSibling(50)]),  # eine Datei ohne Größe
    }

    class FakeHfApi:
        def model_info(self, repo_id, *, files_metadata=True):
            return infos[repo_id]

    monkeypatch.setattr("huggingface_hub.HfApi", FakeHfApi)

    assert mb.total_download_bytes(cfg) == 50


def test_download_models_clampt_ueberschuss_durch_xet_doppelzaehlung(monkeypatch):
    """Xet-beschleunigtes huggingface_hub meldet pro Datei zwei tqdm-Phasen (Downloading +
    Reconstructing), die beide update() rufen — der rohe Akkumulator überschießt real bis
    ~172 % von total. Der an on_progress gemeldete Wert muss trotzdem nie über total steigen."""
    cfg = EngineConfig(stt_model="stt/repo", llm_model="llm/repo")
    monkeypatch.setattr(mb, "total_download_bytes", lambda config: 1000)

    def fake_snapshot(repo_id, *, tqdm_class, **kwargs):
        bar = tqdm_class(total=1000, unit="B")
        # Zwei Phasen melden je 800 Bytes — roh 1600, doppelt so viel wie total.
        bar.update(800)
        bar.update(800)
        bar.close()

    monkeypatch.setattr(mb, "snapshot_download", fake_snapshot)

    calls: list[tuple[int, int]] = []
    mb.download_models(cfg, lambda d, t: calls.append((d, t)))

    assert all(d <= 1000 for d, _ in calls)
    assert calls[-1] == (1000, 1000)
