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

## Ветки

- `main` — деплой-триггер (push = прод-деплой дашбордом)
- `feat/*` — работа в git-worktree, мёрж в `main` = релиз
