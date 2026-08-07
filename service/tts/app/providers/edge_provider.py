"""Провайдер edge-tts — бесплатный, без ключа. Используется как фолбэк.

Пакет опциональный: `uv sync --extra edge`. Без него провайдер просто недоступен
и цепочка фолбэка идёт дальше.
"""

from __future__ import annotations

import importlib.util

from app.config import settings
from app.providers.base import TTSError, TTSProvider

EDGE_VOICES = (
    "ru-RU-DmitryNeural",
    "ru-RU-SvetlanaNeural",
    "tr-TR-AhmetNeural",
    "tr-TR-EmelNeural",
    "en-US-AriaNeural",
)


def _speed_to_rate(speed: float) -> str:
    """1.0 → '+0%', 1.25 → '+25%', 0.8 → '-20%'."""
    pct = round((speed - 1.0) * 100)
    return f"{pct:+d}%"


class EdgeProvider(TTSProvider):
    name = "edge"

    def available(self) -> bool:
        return importlib.util.find_spec("edge_tts") is not None

    def resolve_voice(self, voice: str) -> str:
        # Клиент присылает openai-голоса (alloy…), которых у edge нет — берём русский дефолт.
        return voice if voice in EDGE_VOICES else settings.edge_default_voice

    async def synth(self, text: str, voice: str, model: str, speed: float = 1.0) -> bytes:
        if not self.available():
            raise TTSError(self.name, "пакет edge-tts не установлен")

        import edge_tts  # импорт внутри — пакет опциональный

        try:
            communicate = edge_tts.Communicate(
                text, self.resolve_voice(voice), rate=_speed_to_rate(speed)
            )
            chunks = [c["data"] async for c in communicate.stream() if c["type"] == "audio"]
        except Exception as exc:  # edge-tts бросает разнородные ошибки
            raise TTSError(self.name, str(exc)[:200]) from exc

        data = b"".join(chunks)
        if not data:
            raise TTSError(self.name, "пустой ответ")
        return data
