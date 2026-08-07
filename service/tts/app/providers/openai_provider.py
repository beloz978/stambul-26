"""Провайдер OpenAI /v1/audio/speech."""

from __future__ import annotations

import httpx

from app.config import settings
from app.providers.base import TTSError, TTSProvider

# Голоса, которые принимает OpenAI. Чужой голос (например edge-шный) заменяем на дефолт.
OPENAI_VOICES = (
    "alloy", "ash", "ballad", "coral", "echo",
    "fable", "nova", "onyx", "sage", "shimmer",
)
OPENAI_MODELS = ("gpt-4o-mini-tts", "tts-1", "tts-1-hd")


class OpenAIProvider(TTSProvider):
    name = "openai"

    def __init__(self, api_key: str | None = None, base_url: str | None = None) -> None:
        self.api_key = api_key if api_key is not None else settings.openai_api_key
        self.base_url = (base_url or settings.openai_base_url).rstrip("/")

    def available(self) -> bool:
        return bool(self.api_key)

    def resolve_voice(self, voice: str) -> str:
        return voice if voice in OPENAI_VOICES else settings.default_voice

    async def synth(self, text: str, voice: str, model: str, speed: float = 1.0) -> bytes:
        if not self.available():
            raise TTSError(self.name, "не задан TTS_OPENAI_API_KEY")

        payload = {
            "model": model if model in OPENAI_MODELS else settings.default_model,
            "voice": self.resolve_voice(voice),
            "input": text,
            "response_format": "mp3",
        }
        if speed != 1.0:
            payload["speed"] = speed

        try:
            async with httpx.AsyncClient(timeout=settings.openai_timeout_sec) as client:
                resp = await client.post(
                    f"{self.base_url}/audio/speech",
                    headers={
                        "authorization": f"Bearer {self.api_key}",
                        "content-type": "application/json",
                    },
                    json=payload,
                )
        except httpx.HTTPError as exc:
            raise TTSError(self.name, f"сеть: {exc}") from exc

        if resp.status_code != 200:
            detail = resp.text[:200]
            raise TTSError(self.name, f"HTTP {resp.status_code}: {detail}", resp.status_code)

        data = resp.content
        if not data:
            raise TTSError(self.name, "пустой ответ")
        return data
