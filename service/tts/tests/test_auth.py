"""Авторизация: три способа передать ключ + открытый режим."""

from __future__ import annotations

import pytest

from app.config import settings


@pytest.fixture
def guarded(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(settings, "api_keys", ["secret-1", "secret-2"])
    return settings


def test_open_when_no_keys_configured(client, openai_route):
    """Пустой TTS_API_KEYS → проверки нет (локальный режим)."""
    assert settings.auth_enabled is False
    r = client.post("/v1/audio/speech", json={"input": "открыто"})
    assert r.status_code == 200


def test_rejects_missing_key(client, guarded):
    r = client.post("/v1/audio/speech", json={"input": "нельзя"})
    assert r.status_code == 401


def test_rejects_wrong_key(client, guarded):
    # Значение заголовка должно быть ASCII — кириллица в HTTP-заголовок не влезает.
    r = client.post(
        "/v1/audio/speech", json={"input": "нельзя"}, headers={"X-API-Key": "no-such-key"}
    )
    assert r.status_code == 401


@pytest.mark.respx(assert_all_called=False)
def test_accepts_x_api_key(client, guarded, openai_route):
    r = client.post(
        "/v1/audio/speech", json={"input": "можно"}, headers={"X-API-Key": "secret-1"}
    )
    assert r.status_code == 200


@pytest.mark.respx(assert_all_called=False)
def test_accepts_bearer(client, guarded, openai_route):
    r = client.post(
        "/v1/audio/speech",
        json={"input": "можно"},
        headers={"Authorization": "Bearer secret-2"},
    )
    assert r.status_code == 200


@pytest.mark.respx(assert_all_called=False)
def test_accepts_query_key(client, guarded, openai_route):
    """PWA умеет задать только URL — ключ должен проходить через ?key=."""
    r = client.post("/v1/audio/speech?key=secret-1", json={"input": "можно"})
    assert r.status_code == 200


def test_healthz_is_public(client, guarded):
    assert client.get("/healthz").status_code == 200
    assert client.get("/v1/models").status_code == 200
