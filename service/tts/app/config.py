"""Конфигурация сервиса. Все значения — из переменных окружения (префикс TTS_).

Шаблоны: config/.env.config.template (несекретное) и config/.env.secrets.demo.template (ключи).
"""

from __future__ import annotations

from pathlib import Path
from typing import Annotated

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict

# NoDecode отключает JSON-разбор списков в источнике настроек: без него
# pydantic-settings попытается прочитать «openai,edge» как JSON и упадёт
# ещё до наших валидаторов. Списки задаём через запятую — так удобнее в .env.
CsvList = Annotated[list[str], NoDecode]


def _split_csv(value: str | list[str]) -> list[str]:
    """«a, b ,c» → ['a','b','c']. Пустые элементы отбрасываются."""
    if isinstance(value, list):
        return [str(v).strip() for v in value if str(v).strip()]
    return [part.strip() for part in str(value).split(",") if part.strip()]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="TTS_",
        env_file=("config/.env.config", "config/.env.secrets"),
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # ── провайдеры ───────────────────────────────────────────────────────────
    # Порядок = цепочка фолбэка: первый доступный синтезирует, при ошибке — следующий.
    providers: CsvList = Field(default=["openai", "edge"])

    openai_api_key: str = ""
    openai_base_url: str = "https://api.openai.com/v1"
    openai_timeout_sec: float = 60.0

    default_model: str = "gpt-4o-mini-tts"
    default_voice: str = "alloy"
    # Голос edge-tts, если клиент прислал openai-голос (alloy и т.п. там не существуют).
    edge_default_voice: str = "ru-RU-DmitryNeural"

    # ── кэш ──────────────────────────────────────────────────────────────────
    cache_dir: Path = Path("./.cache/tts")
    cache_enabled: bool = True

    # ── доступ ───────────────────────────────────────────────────────────────
    # Пусто → авторизация выключена (сервис открыт). Для публичного деплоя задайте ключи.
    api_keys: CsvList = Field(default_factory=list)
    cors_origins: CsvList = Field(default=["*"])

    # ── лимиты ───────────────────────────────────────────────────────────────
    max_chars: int = 4000

    # ── прочее ───────────────────────────────────────────────────────────────
    log_level: str = "INFO"
    log_json: bool = True

    @field_validator("providers", "api_keys", "cors_origins", mode="before")
    @classmethod
    def _csv(cls, v: object) -> list[str]:
        if v is None or v == "":
            return []
        return _split_csv(v)  # type: ignore[arg-type]

    @property
    def auth_enabled(self) -> bool:
        return bool(self.api_keys)


settings = Settings()
