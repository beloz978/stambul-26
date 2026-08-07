# Сервис озвучки «Стамбул-диспетчер». Сборка: docker build -t stambul-tts service/tts
FROM python:3.12-slim AS builder

COPY --from=ghcr.io/astral-sh/uv:0.5.11 /uv /usr/local/bin/uv

WORKDIR /build
ENV UV_LINK_MODE=copy UV_PROJECT_ENVIRONMENT=/opt/venv

# Слой зависимостей отдельно от кода — правка app/ не пересобирает venv.
COPY pyproject.toml README.md ./
COPY app/__init__.py app/__init__.py
RUN uv sync --extra edge --no-dev --no-editable


FROM python:3.12-slim AS runtime

# Непривилегированный пользователь: контейнер пишет только в кэш.
RUN useradd --create-home --uid 10001 app

COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    TTS_CACHE_DIR=/data/cache

WORKDIR /srv
COPY app ./app

RUN mkdir -p /data/cache && chown -R app:app /data
USER app

EXPOSE 8080
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=4).status==200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
