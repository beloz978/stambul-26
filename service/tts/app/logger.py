"""Структурные логи (loguru, JSON в stdout).

Секреты в логи не попадают: пишем только длину текста и хэш, не сам текст.
"""

from __future__ import annotations

import sys

from loguru import logger

from app.config import settings


def setup_logging() -> None:
    logger.remove()
    logger.add(
        sys.stdout,
        level=settings.log_level.upper(),
        serialize=settings.log_json,
        backtrace=False,
        diagnose=False,  # diagnose=True печатает значения переменных — риск утечки ключей
        format="{time:YYYY-MM-DD HH:mm:ss} | {level: <7} | {message}",
    )


__all__ = ["logger", "setup_logging"]
