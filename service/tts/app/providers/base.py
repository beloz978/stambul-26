"""Единый интерфейс провайдера озвучки."""

from __future__ import annotations

from abc import ABC, abstractmethod


class TTSError(RuntimeError):
    """Провайдер не смог синтезировать. Повод перейти к следующему в цепочке."""

    def __init__(self, provider: str, message: str, status: int | None = None) -> None:
        super().__init__(f"{provider}: {message}")
        self.provider = provider
        self.status = status


class TTSProvider(ABC):
    name: str

    @abstractmethod
    async def synth(self, text: str, voice: str, model: str, speed: float = 1.0) -> bytes:
        """Вернуть mp3-байты либо бросить TTSError."""

    @abstractmethod
    def available(self) -> bool:
        """Готов ли провайдер (есть ключ / установлен пакет)."""

    def resolve_voice(self, voice: str) -> str:
        """Привести голос клиента к тому, что понимает провайдер."""
        return voice
