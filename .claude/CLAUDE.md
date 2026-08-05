# stambul-26 — правила для агентов

## Рабочий процесс
- **Commit + push часто**: после каждой законченной единицы работы, не копить до конца сессии.
- Ветки: `main` = деплой-триггер (push → Cloudflare dashboard собирает и деплоит сам);
  фичи — в git-worktree `../stambul-26--wt-<name>` на ветке `feat/<name>`; мёрж в `main` = релиз.
- Трекинг — GitHub Issues этого репозитория (не Jira).
- Информирование — TG-тред https://t.me/c/2281796095/1519: `just tg success|failed "текст"`.

## Cloudflare (порядок: wrangler CLI → REST API → MCP только как ручной fallback)
- Все операции через `scripts/prj-tools/cf.sh` / `Justfile`: `just check|status|deploy|tail|rollback`.
- Креды: `config/.env.secrets` (git-ignored): CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID,
  GIT_TOKEN (PAT beloz978 — локальные gh-аккаунты push-прав НЕ имеют).
  Запрос кредов — только через GUI-диалог: `just auth` (никогда не в чат).
- Секреты воркера (dashboard): ANTHROPIC_API_KEY, OPENAI_API_KEY; KV binding `SYNC` (опц.).

## Сборка
- Слои: `base-*.zip` + инкременты `1.NN.zip` (корень или releases/) — см. шапку `deploy.sh`.
- Релиз = положить один `1.NN.zip` и закоммитить; `dist/` не коммитится.

## Внешние SSoT
- `~/.ai/projects/stambul-26/README.md` — топология проекта
- `~/.ai/skills/.settings/op_api_mcp_fallback.yml` — журнал verified-исходов CF-операций

## Git-flow (с 2026-08-07)
- `main` → прод-воркер `stambul-26` (push = деплой дашбордом)
- `dev` → dev-воркер `stambul-26-v02` (`just deploy-dev`; cf.sh сам включает env dev на ветке dev)
- Фичи — ТОЛЬКО через новые ветки `feat/<name>` → мёрж в `dev` → обкатка на v02 → мёрж в `main`
- Некритичные изменения: работать в основном чекауте под session-lock (/agent-session-lock)
- Критичные изменения: отдельный git-worktree `../stambul-26--wt-<name>`
- Релизы контента: инкремент `X.Y.zip` с версией СТРОГО БОЛЬШЕ базовой (сейчас база 2.58 →
  следующий 2.59.zip); deploy.sh громко предупреждает об отфильтрованных. `_archive/` — для
  вытесненных артефактов, сборка её игнорирует.
