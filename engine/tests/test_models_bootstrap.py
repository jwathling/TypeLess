from __future__ import annotations

from typeless_engine.config import EngineConfig
from typeless_engine.server import models_bootstrap as mb


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
