# stambul-tts — сервис озвучки (FastAPI)

OpenAI-совместимый прокси к `/v1/audio/speech` с кэшем на диске и фолбэком провайдеров.

**Зачем.** Браузеру нельзя ходить в OpenAI напрямую: запрос режет CORS, а ключ,
положенный в клиент, виден любому пользователю приложения. Ключ живёт здесь,
клиент знает только адрес сервиса.

## Быстрый старт

```bash
cd service/tts
./RUN                      # venv + config + uvicorn на :8080 с автоперезагрузкой
```

Первый запуск создаст `config/.env.config` и `config/.env.secrets` — впишите
`TTS_OPENAI_API_KEY` во второй. Без ключа сервис всё равно работает: синтезирует
бесплатный `edge`-провайдер.

Docker:

```bash
docker compose up --build          # из service/tts/
```

## Эндпоинты

| Метод | Путь | Назначение |
|---|---|---|
| POST | `/v1/audio/speech` | синтез, формат тела как у OpenAI |
| POST | `/api/tts` | тот же обработчик под путём воркера |
| GET | `/v1/models` | модели и голоса в формате OpenAI |
| GET | `/healthz` | готовность провайдеров, кэш, режим авторизации |
| GET | `/docs` | Swagger |

Тело запроса — `{model, input, voice, response_format, speed}`. Поле `text`
принимается как алиас `input`: именно так шлёт PWA в режиме «proxy», поэтому
приложение работает с сервисом без единой правки клиента.

Ответ — `audio/mpeg` с заголовками `X-Cache: HIT|MISS`, `X-Provider`, `ETag`,
`Cache-Control: public, max-age=31536000, immutable`. Повторный запрос
с `If-None-Match` получает `304` без тела.

```bash
B=http://127.0.0.1:8080
curl -s -X POST $B/v1/audio/speech -H 'content-type: application/json' \
  -d '{"model":"gpt-4o-mini-tts","input":"Галатская башня","voice":"alloy"}' \
  -o out.mp3 -D - | grep -i 'x-cache\|x-provider'
```

## Провайдеры и фолбэк

`TTS_PROVIDERS` задаёт цепочку: первый доступный синтезирует, при ошибке —
следующий, `X-Provider` показывает фактического.

| Провайдер | Ключ | Замечания |
|---|---|---|
| `openai` | `TTS_OPENAI_API_KEY` | `gpt-4o-mini-tts`, `tts-1`, `tts-1-hd` |
| `edge` | не нужен | бесплатный, `ru-RU-DmitryNeural`; ставится `uv sync --extra edge` |

Голоса приводятся к тому, что понимает провайдер: `alloy` у `edge` не существует,
поэтому подставляется `TTS_EDGE_DEFAULT_VOICE`.

## Кэш

Ключ — `sha256(provider|model|voice|speed|format|text)`, файл на диске
(`TTS_CACHE_DIR`, шардинг по первым двум символам). Запись атомарная,
поэтому параллельные запросы не читают половину файла.

Один и тот же текст не оплачивается дважды. Кэш просматривается по всей цепочке
провайдеров, так что результат, полученный фолбэком, переиспользуется и не
дёргает упавшего первым.

## Доступ

`TTS_API_KEYS` — список ключей через запятую. Пусто → проверка выключена; так
удобно локально, но **для публичного адреса ключи задать обязательно**, иначе
чужие запросы пойдут за ваш счёт.

Ключ принимается тремя способами: заголовок `X-API-Key`, `Authorization: Bearer`
и query-параметр `?key=`. Последний нужен потому, что PWA в режиме «proxy» умеет
задать только URL и не ставит заголовки.

## Настройки

Несекретные — `config/.env.config.template`, секреты — `config/.env.secrets.demo.template`.
Рендер плоских файлов: `bash config/.env-render.sh [config|secrets]`.

Ключевые переменные: `TTS_PROVIDERS`, `TTS_DEFAULT_MODEL`, `TTS_DEFAULT_VOICE`,
`TTS_EDGE_DEFAULT_VOICE`, `TTS_CACHE_DIR`, `TTS_CACHE_ENABLED`, `TTS_API_KEYS`,
`TTS_CORS_ORIGINS`, `TTS_MAX_CHARS`, `TTS_LOG_LEVEL`, `TTS_LOG_JSON`.

## Как подключить приложение

Правок клиента не требуется. В приложении: **Настройки → Озвучка**

1. провайдер — «через ваш Worker» (`proxy`);
2. адрес — `https://<ваш-хост>/api/tts`, а если сервис за ключом —
   `https://<ваш-хост>/api/tts?key=<ключ>`;
3. модель — `gpt-4o-mini-tts`.

Проверить, что всё сошлось, можно по логу озвучки в приложении: строка
`⬅️ Ответ 200` и тип `audio/mpeg`.

## Тесты

```bash
uv run pytest -q          # 35 тестов
uv run ruff check .
```

Покрыты: формат ответа и совместимость с OpenAI, приём формы `{text}` от PWA,
попадание в кэш при повторе, разделение записей по голосу и скорости, фолбэк
провайдера и кэширование его результата, `413`, `400`, `304`, все три способа
авторизации. Сеть замокана через `respx` — тесты не ходят наружу.

## Деплой

Сервис не входит в сборку Cloudflare-воркера: тот публикует только `dist/`
и `server.js`. Python здесь не запускается — нужен отдельный хост.

```bash
# Fly.io
fly launch --dockerfile Dockerfile --no-deploy
fly secrets set TTS_OPENAI_API_KEY=sk-... TTS_API_KEYS=<ключ-группы>
fly volumes create tts_cache --size 1     # чтобы кэш переживал рестарты
fly deploy

# любой VM с docker
docker compose up -d --build
```

Кэш обязан лежать на постоянном томе — иначе после каждого рестарта аудио
синтезируется (и оплачивается) заново.

## Что осталось за рамками

Сознательно не реализовано в этой версии: пакетная генерация
(`/v1/audio/speech/batch` + опрос job), `manifest-audio.json`, Redis, S3/R2,
`/metrics` Prometheus, провайдер `piper` и скрипт предгенерации 91 фрагмента
экскурсий. Полное ТЗ — в приложении: **Инфо → Промпты для Claude Code → 🎧
Сервис озвучки экскурсий**.
