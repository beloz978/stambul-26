#!/usr/bin/env bash
# utils.sh — общие функции для скриптов stambul-26.
# Подключение:  source "$(dirname "$0")/../utils.sh"   (или по абсолютному пути)

log()       { printf '\033[1m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
log_debug() { [ "${DEBUG:-0}" = "1" ] && printf '   [dbg] %s\n' "$*" >&2 || true; }
log_error() { printf '\033[31m[err]\033[0m %s\n' "$*" >&2; }
die()       { log_error "$*"; exit 1; }
assert()    { eval "$1" || die "${2:-assert failed: $1}"; }

# Корень репозитория (работает и из worktree)
repo_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }

# Загрузка конфигов: сперва шаблон с дефолтами (${VAR:-…} раскрываются шеллом),
# затем секреты проекта, затем глобальные секреты (~/.ai/.env.secrets — TG_BOT_TOKEN и т.п.)
load_env() {
  local root; root=$(repo_root)
  set -a
  # shellcheck disable=SC1091
  [ -f "$root/config/.env.config.template" ] && . "$root/config/.env.config.template"
  [ -f "$root/config/.env.config" ]          && . "$root/config/.env.config"
  [ -f "$root/config/.env.secrets" ]         && . "$root/config/.env.secrets"
  [ -f "$HOME/.ai/.env.secrets" ]            && . "$HOME/.ai/.env.secrets"
  set +a
}
