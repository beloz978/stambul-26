#!/usr/bin/env bash
# Рендер плоских .env-файлов из шаблонов: раскрывает ${VAR:-default}.
#   bash config/.env-render.sh            → config/.env.config
#   bash config/.env-render.sh secrets    → config/.env.secrets (если ещё нет)
set -euo pipefail
cd "$(dirname "$0")/.."

render() {
  local src="$1" dst="$2"
  [[ -f $src ]] || {
    echo "нет шаблона $src" >&2
    return 1
  }
  # envsubst не умеет ${VAR:-default}, поэтому раскрываем через сам bash
  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*# ]] || [[ -z ${line// /} ]]; then
      printf '%s\n' "$line"
    else
      eval "printf '%s\n' \"${line//\"/\\\"}\""
    fi
  done <"$src" >"$dst"
  echo "→ $dst"
}

case "${1:-config}" in
  config) render config/.env.config.template config/.env.config ;;
  secrets)
    if [[ -f config/.env.secrets ]]; then
      echo "config/.env.secrets уже существует — не перезаписываю" >&2
    else
      render config/.env.secrets.demo.template config/.env.secrets
      chmod 600 config/.env.secrets
    fi
    ;;
  *)
    echo "usage: $0 [config|secrets]" >&2
    exit 2
    ;;
esac
