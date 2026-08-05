#!/usr/bin/env bash
# ============================================================================
#  cf.sh — Cloudflare-интеграция stambul-26.
#  Порядок инструментов: 1) wrangler CLI  2) Cloudflare REST API (curl)
#                        3) MCP — только вручную, как последний fallback.
#
#  Команды:
#    bash scripts/prj-tools/cf.sh auth            # запросить токен/account id (GUI-диалог)
#    bash scripts/prj-tools/cf.sh check           # деполнота окружения + верификация токена
#    bash scripts/prj-tools/cf.sh whoami          # кто я (CLI → API)
#    bash scripts/prj-tools/cf.sh status          # живость сайта + version.json + деплой-история
#    bash scripts/prj-tools/cf.sh deploy          # локальный деплой: build → wrangler deploy (+TG)
#    bash scripts/prj-tools/cf.sh deploy-via-git  # fallback-деплой: push в main → дашборд-CI
#    bash scripts/prj-tools/cf.sh tail            # живые логи воркера
#    bash scripts/prj-tools/cf.sh rollback        # откат на предыдущую версию (+TG)
#    bash scripts/prj-tools/cf.sh secrets         # список секретов воркера
#    bash scripts/prj-tools/cf.sh secret-put KEY  # записать секрет воркера (значение — скрытый ввод)
#    bash scripts/prj-tools/cf.sh kv-list         # KV namespaces аккаунта
#    bash scripts/prj-tools/cf.sh kv-create NAME  # создать namespace (для SYNC-кэша)
# ============================================================================
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$HERE/../utils.sh"
load_env

CMD="${1:-check}"; shift || true
ROOT=$(repo_root)
API="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"
NAME="${WORKER_NAME:-stambul-26}"
URL="${WORKER_URL:-https://stambul-26.pkvxmch86y.workers.dev}"

# wrangler читает эти переменные сам — не нужен wrangler login
export CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
export CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"

api() { # api METHOD PATH [curl-args…] — REST-запрос с токеном
  local m="$1" p="$2"; shift 2
  [ -n "$CLOUDFLARE_API_TOKEN" ] || die "нет CLOUDFLARE_API_TOKEN — запустите: cf.sh auth"
  curl -sS -X "$m" "$API$p" -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
       -H 'Content-Type: application/json' "$@"
}

need_account() {
  [ -n "$CLOUDFLARE_ACCOUNT_ID" ] && return 0
  # попытка автоопределения: у токена уровня account виден ровно один аккаунт
  local id
  id=$(api GET "/accounts?per_page=5" | python3 -c \
    'import json,sys;r=json.load(sys.stdin)["result"];print(r[0]["id"] if len(r)==1 else "")' 2>/dev/null)
  [ -n "$id" ] && { export CLOUDFLARE_ACCOUNT_ID="$id"; log_debug "account id: $id (auto)"; return 0; }
  die "нет CLOUDFLARE_ACCOUNT_ID (и не удалось определить автоматически) — cf.sh auth"
}

wr() { (cd "$ROOT" && npx --yes wrangler "$@"); }

tg() { # tg STATUS TEXT — не роняет основной сценарий
  bash "$HERE/tg-notify.sh" "$@" || log_error "TG-уведомление не ушло (продолжаем)"
}

# ---------- команды ----------
do_auth() {
  local ask=~/.ai/skills/_scripts/utils/ask-secret-gui.sh
  bash "$ask" CLOUDFLARE_API_TOKEN "https://dash.cloudflare.com/profile/api-tokens" \
    --env-file "$ROOT/config/.env.secrets" \
    --prompt "Cloudflare API Token (шаблон «Edit Cloudflare Workers»): https://dash.cloudflare.com/profile/api-tokens" \
    || die "токен не получен"
  bash "$ask" CLOUDFLARE_ACCOUNT_ID "https://dash.cloudflare.com/?to=/:account/workers-and-pages" \
    --env-file "$ROOT/config/.env.secrets" \
    --prompt "Cloudflare Account ID (Workers & Pages → правый сайдбар). Если токен видит один аккаунт — можно Cancel, определится сам." \
    || log "Account ID пропущен — попробуем автоопределение"
  load_env; do_check
}

verify_token() {
  api GET "/user/tokens/verify" | python3 -c \
    'import json,sys;d=json.load(sys.stdin);print("OK" if d.get("success") else "FAIL:"+json.dumps(d.get("errors")))'
}

do_check() {
  log "🔍 Проверка окружения"
  for c in node npx curl python3 git; do command -v "$c" >/dev/null || die "нет $c"; done
  echo "   node $(node -v) · npx $(npx --version)"
  [ -n "$CLOUDFLARE_API_TOKEN" ] || { log_error "CLOUDFLARE_API_TOKEN не задан → cf.sh auth"; exit 2; }
  local v; v=$(verify_token)
  [ "$v" = "OK" ] || die "токен невалиден: $v"
  log "✅ токен валиден"
  need_account && log "✅ account: $CLOUDFLARE_ACCOUNT_ID"
  # ловим «токен не от того аккаунта»: воркер должен существовать на этом аккаунте
  local ok; ok=$(api GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$NAME/settings" \
    | python3 -c 'import json,sys;print("yes" if json.load(sys.stdin).get("success") else "no")' 2>/dev/null)
  [ "$ok" = "yes" ] || die "воркер '$NAME' НЕ найден на аккаунте $CLOUDFLARE_ACCOUNT_ID — токен от другого Cloudflare-аккаунта (нужен beloz978)!"
  log "✅ воркер '$NAME' найден на аккаунте"
}

do_whoami() {
  wr whoami 2>/dev/null || { log "wrangler не ответил — пробую API"; api GET "/user/tokens/verify" | python3 -m json.tool; }
}

do_status() {
  log "🌍 $URL"
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' "$URL/")
  echo "   HTTP $code"
  echo "   version.json: $(curl -s "$URL/version.json" || echo '—')"
  if [ -n "$CLOUDFLARE_API_TOKEN" ]; then
    need_account
    log "📜 Последние деплои ($NAME)"
    api GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$NAME/deployments" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for x in (d.get("result") or {}).get("deployments", [])[:5]:
    m=x.get("annotations") or {}
    print(f"   {x.get(\"created_on\",\"?\")[:19]}  {x.get(\"id\",\"\")[:8]}  {m.get(\"workers/triggered_by\",\"\")} {m.get(\"workers/message\",\"\")}")' \
      2>/dev/null || wr deployments list --name "$NAME" 2>/dev/null || log_error "история деплоев недоступна"
  else
    log "…токена нет — история деплоев пропущена (cf.sh auth)"
  fi
}

do_deploy() {
  do_check
  log "📦 Сборка"
  (cd "$ROOT" && bash deploy.sh build) || { tg failed "локальная сборка упала"; die "сборка упала"; }
  log "🚀 wrangler deploy"
  if wr deploy; then
    local v; v=$(curl -s "$URL/version.json" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("version","?"))' 2>/dev/null)
    tg success "задеплоено локально (wrangler) · версия $v · $URL"
    log "✅ версия $v"
  else
    tg failed "wrangler deploy упал (ветка $(git -C "$ROOT" branch --show-current))"
    die "wrangler deploy упал"
  fi
}

do_deploy_via_git() {
  # fallback-путь: дашборд Cloudflare сам собирает и деплоит по push в main
  local b; b=$(git -C "$ROOT" branch --show-current)
  [ "$b" = "main" ] || die "деплой-через-git идёт только с main (сейчас: $b) — смёржите ветку"
  git -C "$ROOT" push origin main || die "push не прошёл"
  tg success "push в main — деплой запущен дашбордом Cloudflare · $URL"
  log "✅ push в main; дашборд задеплоит сам (проверка: cf.sh status)"
}

do_rollback() {
  do_check
  wr rollback --name "$NAME" "$@" && tg success "rollback выполнен · $URL" || { tg failed "rollback не прошёл"; die "rollback не прошёл"; }
}

do_secrets() { do_check; wr secret list --name "$NAME" 2>/dev/null || api GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/workers/scripts/$NAME/secrets" | python3 -m json.tool; }

do_secret_put() {
  local key="${1:?нужно имя секрета, напр. OPENAI_API_KEY}"
  do_check
  # значение — скрытый ввод, не попадает в argv/историю
  wr secret put "$key" --name "$NAME"
}

do_kv_list() { do_check; api GET "/accounts/$CLOUDFLARE_ACCOUNT_ID/storage/kv/namespaces" | python3 -m json.tool; }

do_kv_create() {
  local n="${1:?нужно имя namespace, напр. stambul-sync}"
  do_check
  api POST "/accounts/$CLOUDFLARE_ACCOUNT_ID/storage/kv/namespaces" --data "{\"title\":\"$n\"}" | python3 -m json.tool
  log "→ впишите полученный id в wrangler.jsonc (kv_namespaces) и раскомментируйте"
}

case "$CMD" in
  auth)           do_auth ;;
  check)          do_check ;;
  whoami)         do_whoami ;;
  status)         do_status ;;
  deploy)         do_deploy ;;
  deploy-via-git) do_deploy_via_git ;;
  tail)           do_check; wr tail --name "$NAME" ;;
  rollback)       do_rollback "$@" ;;
  secrets)        do_secrets ;;
  secret-put)     do_secret_put "$@" ;;
  kv-list)        do_kv_list ;;
  kv-create)      do_kv_create "$@" ;;
  *) die "неизвестная команда: $CMD (auth|check|whoami|status|deploy|deploy-via-git|tail|rollback|secrets|secret-put|kv-list|kv-create)" ;;
esac
