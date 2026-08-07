# stambul-26 — операции. Основное: just deploy / just status / just tail
set shell := ["bash", "-uc"]

default:
    @just --list

# запросить Cloudflare-токен и account id (GUI-диалог + браузер)
auth:
    bash scripts/prj-tools/cf.sh auth

# проверить окружение и валидность токена
check:
    bash scripts/prj-tools/cf.sh check

# живость сайта + версия + история деплоев
status:
    bash scripts/prj-tools/cf.sh status

# локальный деплой: сборка слоёв → wrangler deploy → TG-уведомление
deploy:
    bash scripts/prj-tools/cf.sh deploy

# fallback-деплой: push в main → дашборд Cloudflare собирает сам
deploy-via-git:
    bash scripts/prj-tools/cf.sh deploy-via-git

# живые логи воркера
tail:
    bash scripts/prj-tools/cf.sh tail

# откат на предыдущую версию воркера
rollback *ARGS:
    bash scripts/prj-tools/cf.sh rollback {{ARGS}}

# секреты воркера (ANTHROPIC_API_KEY, OPENAI_API_KEY)
secrets:
    bash scripts/prj-tools/cf.sh secrets

secret-put KEY:
    bash scripts/prj-tools/cf.sh secret-put {{KEY}}

# KV для облачного кэша (SYNC)
kv-list:
    bash scripts/prj-tools/cf.sh kv-list

kv-create NAME="stambul-sync":
    bash scripts/prj-tools/cf.sh kv-create {{NAME}}

# уведомление в TG-тред проекта вручную
tg STATUS TEXT:
    bash scripts/prj-tools/tg-notify.sh {{STATUS}} "{{TEXT}}"

# git-flow: деплой ветки dev во второй воркер stambul-26-v02
deploy-dev:
    CF_ENV=dev bash scripts/prj-tools/cf.sh deploy

status-dev:
    CF_ENV=dev bash scripts/prj-tools/cf.sh status

# ── сервис озвучки (service/tts, FastAPI) ───────────────────────────────────
# Деплоится отдельно от воркера: Python в Cloudflare Workers не запускается.

# поднять локально с автоперезагрузкой
tts-run PORT="8080":
    bash service/tts/RUN {{PORT}}

# тесты сервиса озвучки
tts-test:
    cd service/tts && uv run pytest -q

# линтер сервиса озвучки
tts-lint:
    cd service/tts && uv run ruff check .

# сервис озвучки в docker (кэш — в именованном томе)
tts-docker:
    cd service/tts && docker compose up --build

# готовность провайдеров и кэша
tts-health URL="http://127.0.0.1:8080":
    curl -s {{URL}}/healthz
