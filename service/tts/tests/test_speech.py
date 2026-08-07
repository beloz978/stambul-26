"""Формат ответа, совместимость с OpenAI и приём формы, которую шлёт PWA."""

from __future__ import annotations

import pytest

from tests.conftest import MP3


@pytest.mark.respx(assert_all_called=False)
def test_openai_shape_returns_mp3(client, openai_route):
    r = client.post(
        "/v1/audio/speech",
        json={"model": "gpt-4o-mini-tts", "input": "Галатская башня", "voice": "alloy"},
    )
    assert r.status_code == 200
    assert r.headers["content-type"] == "audio/mpeg"
    assert r.headers["X-Cache"] == "MISS"
    assert r.headers["X-Provider"] == "openai"
    assert r.headers["Cache-Control"] == "public, max-age=31536000, immutable"
    assert r.headers["ETag"]
    assert r.content == MP3


@pytest.mark.respx(assert_all_called=False)
def test_pwa_shape_text_alias(client, openai_route):
    """PWA в режиме «proxy» шлёт {text,...} — сервис обязан это принять,
    иначе живому приложению понадобится релиз."""
    r = client.post("/v1/audio/speech", json={"text": "Айя-София", "model": "tts-1"})
    assert r.status_code == 200
    assert r.content == MP3
    sent = openai_route.calls.last.request
    assert b"\\u0410\\u0439\\u044f" in sent.content or "Айя-София".encode() in sent.content


@pytest.mark.respx(assert_all_called=False)
def test_worker_path_alias(client, openai_route):
    """Путь воркера /api/tts обслуживается тем же обработчиком."""
    r = client.post("/api/tts", json={"text": "тест"})
    assert r.status_code == 200
    assert r.headers["X-Provider"] == "openai"


def test_empty_text_400(client):
    r = client.post("/v1/audio/speech", json={"input": "   "})
    assert r.status_code == 400


def test_too_long_413(client):
    r = client.post("/v1/audio/speech", json={"input": "я" * 4001})
    assert r.status_code == 413
    assert "4000" in r.json()["detail"]


def test_non_mp3_format_400(client):
    r = client.post("/v1/audio/speech", json={"input": "тест", "response_format": "opus"})
    assert r.status_code == 400
    assert "mp3" in r.json()["detail"]


@pytest.mark.respx(assert_all_called=False)
def test_if_none_match_304(client, openai_route):
    first = client.post("/v1/audio/speech", json={"input": "повтор"})
    etag = first.headers["ETag"]

    again = client.post(
        "/v1/audio/speech", json={"input": "повтор"}, headers={"If-None-Match": etag}
    )
    assert again.status_code == 304
    assert again.content == b""


def test_healthz(client):
    r = client.get("/healthz")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert {p["name"] for p in body["providers"]} == {"openai"}


def test_models_listing(client):
    r = client.get("/v1/models")
    assert r.status_code == 200
    data = r.json()["data"]
    assert data and data[0]["object"] == "model"
    assert any(m["id"] == "gpt-4o-mini-tts" for m in data)
