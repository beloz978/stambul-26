#!/usr/bin/env bash
# tg-notify.sh — уведомление о деплое/статусе в Telegram.
#   Цель: «My pets projects», тред https://t.me/c/2281796095/1519
#   Использует канонический notify-tg.py (~/.ai) + TG_BOT_TOKEN из ~/.ai/.env.secrets.
# Usage: tg-notify.sh success|failed|blocked "текст"
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$HERE/../utils.sh"
load_env

STATUS="${1:?status: success|failed|blocked}"
TEXT="${2:-}"
NOTIFY=~/.ai/skills/_scripts/integrations/telegram/notify-tg.py

[ -f "$NOTIFY" ] || die "нет $NOTIFY"
python3 "$NOTIFY" --status "$STATUS" \
  --text "stambul-26: $TEXT" \
  --chat  "${TG_CHAT_ID:--1002281796095}" \
  --topic "${TG_THREAD_ID:-1519}" \
  --branch "$(git -C "$(repo_root)" branch --show-current 2>/dev/null || echo '?')"
