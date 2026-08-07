"""Фолбэк провайдеров и поведение при полном отказе."""

from __future__ import annotations

import httpx
import pytest

from app.providers import TTSError, available_chain, build_chain
from app.providers.base import TTSProvider
from app.providers.edge_provider import _speed_to_rate
from app.providers.openai_provider import OpenAIProvider
from tests.conftest import MP3


class FakeProvider(TTSProvider):
    """Заглушка второго провайдера в цепочке."""

    def __init__(self, name: str, payload: bytes | None = None, fail: str | None = None) -> None:
        self.name = name
        self.payload = payload or b"FAKE-AUDIO"
        self.fail = fail
        self.calls = 0

    def available(self) -> bool:
        return True

    async def synth(self, text: str, voice: str, model: str, speed: float = 1.0) -> bytes:
        self.calls += 1
        if self.fail:
            raise TTSError(self.name, self.fail)
        return self.payload


@pytest.mark.respx(assert_all_called=False)
def test_falls_back_to_next_provider(client, respx_mock, monkeypatch):
    """OpenAI отвечает 500 → синтезирует следующий, X-Provider показывает фактического."""
    from app import main

    respx_mock.post("https://api.openai.com/v1/audio/speech").mock(
        return_value=httpx.Response(500, text="upstream boom")
    )
    backup = FakeProvider("edge")
    monkeypatch.setattr(main, "available_chain", lambda names=None: [OpenAIProvider(), backup])

    r = client.post("/v1/audio/speech", json={"input": "фолбэк"})

    assert r.status_code == 200
    assert r.headers["X-Provider"] == "edge"
    assert r.content == b"FAKE-AUDIO"
    assert backup.calls == 1


@pytest.mark.respx(assert_all_called=False)
def test_all_providers_fail_502(client, respx_mock, monkeypatch):
    from app import main

    respx_mock.post("https://api.openai.com/v1/audio/speech").mock(
        return_value=httpx.Response(429, text="rate limited")
    )
    monkeypatch.setattr(
        main,
        "available_chain",
        lambda names=None: [OpenAIProvider(), FakeProvider("edge", fail="нет пакета")],
    )

    r = client.post("/v1/audio/speech", json={"input": "всё плохо"})

    assert r.status_code == 502
    detail = r.json()["detail"]
    assert len(detail["details"]) == 2


def test_no_provider_ready_503(client, monkeypatch):
    from app import main

    monkeypatch.setattr(main, "available_chain", lambda names=None: [])

    r = client.post("/v1/audio/speech", json={"input": "некому озвучивать"})
    assert r.status_code == 503


@pytest.mark.respx(assert_all_called=False)
def test_fallback_result_is_cached_under_its_own_provider(client, respx_mock, monkeypatch):
    """Повтор после фолбэка не должен снова дёргать упавшего первым OpenAI."""
    from app import main

    openai_route = respx_mock.post("https://api.openai.com/v1/audio/speech").mock(
        return_value=httpx.Response(500, text="boom")
    )
    backup = FakeProvider("edge")
    monkeypatch.setattr(main, "available_chain", lambda names=None: [OpenAIProvider(), backup])

    client.post("/v1/audio/speech", json={"input": "повтор после фолбэка"})
    second = client.post("/v1/audio/speech", json={"input": "повтор после фолбэка"})

    assert second.headers["X-Cache"] == "HIT"
    assert second.headers["X-Provider"] == "edge"
    assert backup.calls == 1
    assert openai_route.call_count == 1


def test_openai_unknown_voice_falls_back_to_default():
    p = OpenAIProvider(api_key="sk-x")
    assert p.resolve_voice("ru-RU-DmitryNeural") == "alloy"
    assert p.resolve_voice("nova") == "nova"


def test_openai_without_key_is_unavailable():
    assert OpenAIProvider(api_key="").available() is False


def test_chain_ignores_unknown_names():
    assert [p.name for p in build_chain(["openai", "нетакого"])] == ["openai"]


def test_available_chain_filters_unready():
    assert [p.name for p in available_chain(["openai"])] == ["openai"]


@pytest.mark.parametrize(
    ("speed", "rate"), [(1.0, "+0%"), (1.25, "+25%"), (0.8, "-20%"), (2.0, "+100%")]
)
def test_edge_speed_to_rate(speed, rate):
    assert _speed_to_rate(speed) == rate


@pytest.mark.respx(assert_all_called=False)
def test_openai_sends_expected_payload(client, openai_route):
    client.post(
        "/v1/audio/speech",
        json={"model": "tts-1-hd", "input": "проверка", "voice": "nova", "speed": 1.5},
    )
    import json

    sent = json.loads(openai_route.calls.last.request.content)
    assert sent == {
        "model": "tts-1-hd",
        "voice": "nova",
        "input": "проверка",
        "response_format": "mp3",
        "speed": 1.5,
    }
    assert openai_route.calls.last.request.headers["authorization"].startswith("Bearer ")
    assert MP3  # мок отдаёт именно эти байты
