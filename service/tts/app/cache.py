"""Файловый кэш аудио. Ключ — sha256(provider|model|voice|speed|format|text).

Идемпотентность: один и тот же текст никогда не оплачивается дважды.
Запись атомарная (tmp + rename), поэтому параллельные запросы не читают половину файла.
"""

from __future__ import annotations

import hashlib
import os
import tempfile
from pathlib import Path

from app.config import settings


def cache_key(provider: str, model: str, voice: str, speed: float, fmt: str, text: str) -> str:
    raw = f"{provider}|{model}|{voice}|{speed}|{fmt}|{text}"
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


class AudioCache:
    """Кэш на диске. Шардинг по первым двум символам ключа — чтобы не класть
    десятки тысяч файлов в один каталог."""

    def __init__(self, root: Path | None = None, enabled: bool | None = None) -> None:
        self.root = Path(root if root is not None else settings.cache_dir)
        self.enabled = settings.cache_enabled if enabled is None else enabled

    def path_for(self, key: str, fmt: str = "mp3") -> Path:
        return self.root / key[:2] / f"{key}.{fmt}"

    def get(self, key: str, fmt: str = "mp3") -> bytes | None:
        if not self.enabled:
            return None
        path = self.path_for(key, fmt)
        try:
            data = path.read_bytes()
        except (FileNotFoundError, NotADirectoryError):
            return None
        # Пустой файл — след неудачной записи: считаем промахом и перезапишем.
        return data or None

    def put(self, key: str, data: bytes, fmt: str = "mp3") -> None:
        if not self.enabled or not data:
            return
        path = self.path_for(key, fmt)
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=path.parent, suffix=".part")
        try:
            with os.fdopen(fd, "wb") as fh:
                fh.write(data)
            os.replace(tmp, path)  # атомарная подмена в пределах одной ФС
        except BaseException:
            Path(tmp).unlink(missing_ok=True)
            raise
