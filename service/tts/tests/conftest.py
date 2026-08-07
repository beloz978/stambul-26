"""Общие фикстуры. Настройки правим до импорта app.main, иначе CORS/кэш
успеют прочитать значения из окружения разработчика."""

from __future__ import annotations

import os
from pathlib import Path

import pytest

# Изолируем тесты от config/.env.* и от реального ключа в окружении.
os.environ.update(
    {
        "TTS_OPENAI_API_KEY": "sk-test-not-a-real-key",
        "TTS_PROVIDERS": "openai",
        "TTS_API_KEYS": "",
        "TTS_CACHE_ENABLED": "true",
    }
)

MP3 = b"ID3\x03\x00\x00\x00" + b"\xff\xfb\x90" * 32  # правдоподобные mp3-байты


@pytest.fixture
def tmp_cache(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    """Кэш в отдельном каталоге на каждый тест."""
    from app import main
    from app.cache import AudioCache

    cache = AudioCache(root=tmp_path / "cache", enabled=True)
    monkeypatch.setattr(main, "cache", cache)
    return cache


@pytest.fixture
def client(tmp_cache):
    from fastapi.testclient import TestClient

    from app.main import app

    with TestClient(app) as c:
        yield c


@pytest.fixture
def openai_route(respx_mock):
    """Мок OpenAI /v1/audio/speech, отдающий mp3 и считающий обращения."""
    import httpx

    return respx_mock.post("https://api.openai.com/v1/audio/speech").mock(
        return_value=httpx.Response(200, content=MP3, headers={"content-type": "audio/mpeg"})
    )
