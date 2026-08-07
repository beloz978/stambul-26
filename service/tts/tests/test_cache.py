"""Идемпотентность: один и тот же текст не оплачивается дважды."""

from __future__ import annotations

import pytest

from app.cache import AudioCache, cache_key
from tests.conftest import MP3


@pytest.mark.respx(assert_all_called=False)
def test_second_identical_request_is_a_hit(client, openai_route):
    body = {"model": "tts-1", "input": "Босфор", "voice": "alloy"}

    first = client.post("/v1/audio/speech", json=body)
    second = client.post("/v1/audio/speech", json=body)

    assert first.headers["X-Cache"] == "MISS"
    assert second.headers["X-Cache"] == "HIT"
    assert second.content == first.content == MP3
    assert openai_route.call_count == 1, "провайдер должен быть вызван ровно один раз"


@pytest.mark.respx(assert_all_called=False)
def test_different_voice_is_a_separate_entry(client, openai_route):
    client.post("/v1/audio/speech", json={"input": "Босфор", "voice": "alloy"})
    r = client.post("/v1/audio/speech", json={"input": "Босфор", "voice": "nova"})

    assert r.headers["X-Cache"] == "MISS"
    assert openai_route.call_count == 2


@pytest.mark.respx(assert_all_called=False)
def test_speed_changes_the_key(client, openai_route):
    client.post("/v1/audio/speech", json={"input": "Босфор", "speed": 1.0})
    r = client.post("/v1/audio/speech", json={"input": "Босфор", "speed": 1.25})

    assert r.headers["X-Cache"] == "MISS"
    assert openai_route.call_count == 2


def test_key_is_stable_and_field_sensitive():
    base = cache_key("openai", "tts-1", "alloy", 1.0, "mp3", "текст")
    assert base == cache_key("openai", "tts-1", "alloy", 1.0, "mp3", "текст")
    assert base != cache_key("edge", "tts-1", "alloy", 1.0, "mp3", "текст")
    assert base != cache_key("openai", "tts-1", "alloy", 1.0, "mp3", "текст ")


def test_put_get_roundtrip(tmp_path):
    cache = AudioCache(root=tmp_path, enabled=True)
    key = cache_key("openai", "tts-1", "alloy", 1.0, "mp3", "привет")

    assert cache.get(key) is None
    cache.put(key, MP3)
    assert cache.get(key) == MP3
    assert not list(tmp_path.rglob("*.part")), "временные файлы не должны оставаться"


def test_disabled_cache_stores_nothing(tmp_path):
    cache = AudioCache(root=tmp_path, enabled=False)
    key = cache_key("openai", "tts-1", "alloy", 1.0, "mp3", "привет")

    cache.put(key, MP3)
    assert cache.get(key) is None
