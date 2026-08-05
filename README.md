# stambul-26

Стамбул-диспетчер (PWA) на Cloudflare Workers: статика из слоёв-архивов + `/api/kv`
(облачный кэш) + `/api/tts` (озвучка). Прод: <https://stambul-26.pkvxmch86y.workers.dev/>

## Деплой — два пути

| Путь | Как | Когда |
|---|---|---|
| **push в main** (основной) | `git push origin main` → дашборд Cloudflare сам соберёт (`bash deploy.sh build --soft`) и задеплоит | с любого устройства, включая iPhone/Claude-чат |
| **локальный** | `just deploy` (сборка слоёв → `wrangler deploy` → TG-уведомление) | когда нужен контроль/срочный фикс без коммита |

Сборка слоёв описана в шапке [`deploy.sh`](deploy.sh) (base-*.zip + инкременты `1.NN.zip`).

## Cloudflare-интеграция (`scripts/prj-tools/cf.sh`)

Порядок инструментов: **wrangler CLI → REST API (curl) → MCP только как ручной fallback**.

```bash
just auth        # запросить API-токен и Account ID (браузер + GUI-диалог, в чат не попадает)
just check       # окружение + валидность токена
just status      # HTTP-код, version.json, история деплоев
just deploy      # локальный деплой + TG
just deploy-via-git
just tail        # живые логи воркера
just rollback    # откат
just secrets     # секреты воркера (ANTHROPIC_API_KEY, OPENAI_API_KEY)
just kv-create   # KV namespace для SYNC-кэша
```

Секреты проекта: `config/.env.secrets` (git-ignored, 0600) по шаблону
[`config/.env.secrets.demo.template`](config/.env.secrets.demo.template).

## Telegram-информирование

Деплой/статус постятся в тред [«My pets projects» → stambul](https://t.me/c/2281796095/1519)
(chat `-1002281796095`, topic `1519`) через канонический `notify-tg.py`:

```bash
just tg success "текст"
```

## Проверка API через curl

```bash
B=https://stambul-26.pkvxmch86y.workers.dev
# ИИ-гид (JSON): {text}, заголовок X-Cache: HIT|MISS
curl -s -X POST $B/api/ask -H 'content-type: application/json' \
  -d '{"prompt":"Что посмотреть у Галатской башни за час?","code":"test1"}' | head -c 300
# ИИ-гид (SSE-стриминг)
curl -sN -X POST $B/api/ask -H 'content-type: application/json' -H 'accept: text/event-stream' \
  -d '{"prompt":"Привет!"}' | head -5
# Озвучка → mp3
curl -s -X POST $B/api/tts -H 'content-type: application/json' -d '{"text":"тест"}' -o /tmp/t.mp3 -w '%{http_code}\n'
# Облачный кэш
curl -s "$B/api/kv?code=test1&list=1"
```

Секреты воркера: `ANTHROPIC_API_KEY` (гид; при отсутствии — фолбэк на OpenAI),
`OPENAI_API_KEY` (озвучка + фолбэк). Ставятся: `just secret-put ANTHROPIC_API_KEY`.

## Ветки (git-flow)

- `main` — прод: push → дашборд деплоит воркер `stambul-26`
- `dev` — стейдж: `just deploy-dev` → воркер `stambul-26-v02` (URL: stambul-26-v02.pkvxmch86y.workers.dev)
- `feat/*` — фичи; критичные — в git-worktree, некритичные — в основном чекауте под session-lock
- Поток: `feat/*` → `dev` (обкатка на v02) → `main` (релиз)
