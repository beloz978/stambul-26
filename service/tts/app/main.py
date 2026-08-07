"""FastAPI-сервис озвучки: OpenAI-совместимый прокси с кэшем и фолбэком провайдеров.

Эндпоинты
    POST /v1/audio/speech   {model, input|text, voice, response_format, speed} → audio/mpeg
    POST /api/tts           тот же обработчик — путь совместим с воркером stambul-26
    GET  /v1/models         список моделей/голосов в формате OpenAI
    GET  /healthz           состояние провайдеров и кэша
    GET  /                  краткая справка

Зачем сервис: браузеру нельзя ходить в OpenAI напрямую — CORS и ключ, лежащий
в клиенте. Ключ живёт здесь, клиент знает только адрес сервиса.

Совместимость с фронтом: приложение в режиме «proxy» шлёт {text, model, voice}
и не умеет ставить заголовки, поэтому принимаем и `text` как алиас `input`,
и ключ доступа через ?key= наравне с X-API-Key.
"""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, model_validator

from app import __version__
from app.cache import AudioCache, cache_key
from app.config import settings
from app.logger import logger, setup_logging
from app.providers import TTSError, available_chain, build_chain
from app.providers.edge_provider import EDGE_VOICES
from app.providers.openai_provider import OPENAI_MODELS, OPENAI_VOICES

setup_logging()

app = FastAPI(
    title="Стамбул-диспетчер · сервис озвучки",
    version=__version__,
    description="OpenAI-совместимый TTS-прокси с кэшем на диске.",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=False,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["content-type", "accept", "x-api-key", "authorization"],
    expose_headers=["X-Cache", "X-Provider", "ETag"],
)

cache = AudioCache()


# ── модель запроса ───────────────────────────────────────────────────────────
class SpeechRequest(BaseModel):
    model: str = ""
    input: str = ""
    text: str = ""  # алиас `input` — так шлёт PWA в режиме «proxy»
    voice: str = ""
    response_format: str = "mp3"
    speed: float = Field(default=1.0, ge=0.25, le=4.0)

    @model_validator(mode="after")
    def _merge_text_alias(self) -> SpeechRequest:
        if not self.input and self.text:
            self.input = self.text
        return self

    @property
    def resolved_model(self) -> str:
        return self.model or settings.default_model

    @property
    def resolved_voice(self) -> str:
        return self.voice or settings.default_voice


# ── доступ ───────────────────────────────────────────────────────────────────
def require_api_key(
    x_api_key: Annotated[str | None, Header(alias="X-API-Key")] = None,
    authorization: Annotated[str | None, Header()] = None,
    key: Annotated[str | None, Query()] = None,
) -> None:
    """Ключ принимается тремя способами: X-API-Key, Bearer и ?key=.

    Query-вариант нужен, потому что PWA в режиме «proxy» умеет задать только URL.
    Пустой TTS_API_KEYS выключает проверку — так удобно локально, но не в интернете.
    """
    if not settings.auth_enabled:
        return

    presented = x_api_key or key
    if not presented and authorization and authorization.lower().startswith("bearer "):
        presented = authorization[7:].strip()

    if presented not in settings.api_keys:
        raise HTTPException(status_code=401, detail="неверный или отсутствующий ключ доступа")


# ── синтез ───────────────────────────────────────────────────────────────────
async def _synthesize(req: SpeechRequest) -> tuple[bytes, str, str, bool]:
    """→ (аудио, провайдер, ключ кэша, попадание_в_кэш). Бросает HTTPException."""
    text = req.input.strip()
    model, voice, speed = req.resolved_model, req.resolved_voice, req.speed

    chain = available_chain()
    if not chain:
        configured = ", ".join(settings.providers) or "—"
        raise HTTPException(
            status_code=503,
            detail=(
                f"ни один провайдер не готов (настроены: {configured}). "
                "Задайте TTS_OPENAI_API_KEY или установите edge-tts."
            ),
        )

    # Кэш смотрим по всей цепочке: результат мог быть получен фолбэком.
    keys = [cache_key(p.name, model, p.resolve_voice(voice), speed, "mp3", text) for p in chain]
    for provider, key in zip(chain, keys, strict=True):
        hit = cache.get(key)
        if hit is not None:
            return hit, provider.name, key, True

    errors: list[str] = []
    for provider, key in zip(chain, keys, strict=True):
        try:
            audio = await provider.synth(text, voice, model, speed)
        except TTSError as exc:
            errors.append(str(exc))
            logger.warning("провайдер не сработал, иду дальше | {}", str(exc)[:200])
            continue
        cache.put(key, audio)
        return audio, provider.name, key, False

    raise HTTPException(
        status_code=502, detail={"error": "все провайдеры отказали", "details": errors}
    )


async def _speech(request: Request, req: SpeechRequest) -> Response:
    text = req.input.strip()
    if not text:
        raise HTTPException(status_code=400, detail="пустой текст: ожидается поле input или text")
    if len(text) > settings.max_chars:
        raise HTTPException(
            status_code=413,
            detail=(
                f"текст {len(text)} символов, лимит {settings.max_chars}. "
                "Разбейте на части и склейте аудио на клиенте."
            ),
        )
    if req.response_format != "mp3":
        raise HTTPException(
            status_code=400,
            detail=f"поддерживается только response_format=mp3, получено «{req.response_format}»",
        )

    audio, provider, key, cached = await _synthesize(req)

    etag = f'"{key}"'
    headers = {
        "X-Cache": "HIT" if cached else "MISS",
        "X-Provider": provider,
        "ETag": etag,
        "Cache-Control": "public, max-age=31536000, immutable",
    }

    logger.info(
        "озвучка | provider={} cache={} chars={} bytes={} key={}",
        provider,
        "HIT" if cached else "MISS",
        len(text),
        len(audio),
        key[:12],
    )

    # Клиент уже держит это аудио — не гоняем мегабайты повторно.
    if request.headers.get("if-none-match") == etag:
        return Response(status_code=304, headers=headers)

    return Response(content=audio, media_type="audio/mpeg", headers=headers)


@app.post("/v1/audio/speech", dependencies=[Depends(require_api_key)])
async def speech(request: Request, req: SpeechRequest) -> Response:
    return await _speech(request, req)


@app.post("/api/tts", dependencies=[Depends(require_api_key)])
async def speech_worker_path(request: Request, req: SpeechRequest) -> Response:
    """Тот же обработчик под путём воркера — чтобы адрес в настройках PWA
    можно было заменить, не думая о форме пути."""
    return await _speech(request, req)


# ── справочные эндпоинты ─────────────────────────────────────────────────────
@app.get("/v1/models")
async def list_models() -> JSONResponse:
    ready = {p.name for p in available_chain()}
    data = []
    for provider in build_chain():
        models = OPENAI_MODELS if provider.name == "openai" else ("edge-tts",)
        voices = OPENAI_VOICES if provider.name == "openai" else EDGE_VOICES
        for model in models:
            data.append(
                {
                    "id": model,
                    "object": "model",
                    "owned_by": provider.name,
                    "ready": provider.name in ready,
                    "voices": list(voices),
                }
            )
    return JSONResponse({"object": "list", "data": data})


@app.get("/healthz")
async def healthz() -> JSONResponse:
    providers = [
        {"name": p.name, "available": p.available()} for p in build_chain()
    ]
    ok = any(p["available"] for p in providers)
    return JSONResponse(
        status_code=200 if ok else 503,
        content={
            "status": "ok" if ok else "degraded",
            "version": __version__,
            "providers": providers,
            "cache": {"enabled": cache.enabled, "dir": str(cache.root)},
            "auth": "on" if settings.auth_enabled else "off",
            "max_chars": settings.max_chars,
        },
    )


@app.get("/")
async def root() -> JSONResponse:
    return JSONResponse(
        {
            "service": "stambul-tts",
            "version": __version__,
            "endpoints": ["/v1/audio/speech", "/api/tts", "/v1/models", "/healthz"],
            "docs": "/docs",
        }
    )
