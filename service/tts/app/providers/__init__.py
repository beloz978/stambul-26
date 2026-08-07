"""Реестр провайдеров и цепочка фолбэка."""

from __future__ import annotations

from app.config import settings
from app.providers.base import TTSError, TTSProvider
from app.providers.edge_provider import EdgeProvider
from app.providers.openai_provider import OpenAIProvider

REGISTRY: dict[str, type[TTSProvider]] = {
    OpenAIProvider.name: OpenAIProvider,
    EdgeProvider.name: EdgeProvider,
}


def build_chain(names: list[str] | None = None) -> list[TTSProvider]:
    """Провайдеры в порядке TTS_PROVIDERS. Неизвестные имена игнорируются.

    Недоступные (нет ключа / нет пакета) здесь НЕ отсеиваются — фильтрует вызывающий,
    чтобы /healthz мог показать причину недоступности.
    """
    wanted = names if names is not None else settings.providers
    return [REGISTRY[n]() for n in wanted if n in REGISTRY]


def available_chain(names: list[str] | None = None) -> list[TTSProvider]:
    return [p for p in build_chain(names) if p.available()]


__all__ = [
    "REGISTRY",
    "EdgeProvider",
    "OpenAIProvider",
    "TTSError",
    "TTSProvider",
    "available_chain",
    "build_chain",
]
