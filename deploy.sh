#!/usr/bin/env bash
# ============================================================================
#  Стамбул-диспетчер — сборка и деплой. Единственный скрипт в репозитории.
# ============================================================================
#
#  В Cloudflare → Settings → Build:
#      Build command:   bash deploy.sh build
#      Deploy command:  bash deploy.sh deploy
#
#  РАБОТАЕТ С ЛЮБОЙ СХЕМОЙ — переходить можно постепенно:
#      старая:   stambul-app.zip                       (как было)
#      смешанная: stambul-app.zip + 1.83.zip           (инкремент поверх старого)
#      новая:    base-1.82.zip + 1.83.zip + 1.84.zip   (слои)
#
#  КАК ВЫПУСТИТЬ РЕЛИЗ
#      Положить один файл — инкремент вида 1.83.zip — в корень или в releases/
#      и закоммитить. Больше ничего менять не нужно.
#
#  ПЕРЕХОД БЕЗ ИЗМЕНЕНИЙ В ДАШБОРДЕ
#      Команды Cloudflare можно не трогать. Достаточно в wrangler.jsonc
#      добавить хук, который выполнится при npx wrangler deploy:
#          "build": { "command": "bash deploy.sh build --soft" }
#      Тогда старая команда распакует stambul-app.zip как раньше,
#      а перед деплоем скрипт пересоберёт dist из слоёв.
#      Флаг --soft означает: при любой проблеме оставить прежнюю сборку
#      и не ломать деплой.
#
#  КОМАНДЫ
#      bash deploy.sh build      собрать dist/
#      bash deploy.sh deploy     выкатить (соберёт, если нужно)
#      bash deploy.sh list       показать слои и итоговую версию
#      bash deploy.sh check      проверить окружение, ничего не менять
#      bash deploy.sh migrate    stambul-app.zip → base-<версия>.zip
#      bash deploy.sh pack СТАРАЯ_ПАПКА НОВАЯ_ПАПКА 1.85   собрать инкремент
#
#  ПУБЛИКАЦИЯ ИСХОДНИКОВ (само включится, когда появятся права)
#      После деплоя скрипт пробует положить собранный сайт в папку site/
#      репозитория. Прав нет — тихо пропускает, деплой не страдает.
#      Появятся права (токен или доступный на запись origin) — начнёт сам.
#      Проверить состояние: bash deploy.sh check
#
#  ПЕРЕМЕННЫЕ (Settings → Variables, все необязательные)
#      OUT_DIR      папка сборки, по умолчанию dist
#      ONLY         собрать не выше версии: ONLY=1.84 — быстрый откат
#      PUSH_SITE    auto (по умолчанию) | off — выключить | build — пушить и при сборке
#      PUSH_BRANCH  ветка для site/, по умолчанию main
#      GIT_TOKEN    токен с правом contents:write — если решите включить вручную
#      GIT_REPO     owner/repo, например beloz978/stambul-26
#
#  СЕКРЕТЫ (Settings → Variables and Secrets)
#      ANTHROPIC_API_KEY  — ИИ-гид через /api/ask
#      OPENAI_API_KEY     — озвучка через /api/tts
#      KV: Storage & Databases → KV → создать namespace, ID вписать
#          в wrangler.jsonc в kv_namespaces и раскомментировать.
#
#  КАК СОБИРАЕТСЯ
#      Базовый слой: base-*.zip самой большой версии, иначе stambul-app.zip.
#      Поверх — все инкременты с версией больше базовой, по возрастанию.
#      Порядок задан именами файлов, отдельного манифеста нет.
#      Удаление файлов — строки в .remove внутри инкремента.
#      Результат в dist/ + version.json с историей слоёв.
# ----------------------------------------------------------------------------

set -uo pipefail

CMD="${1:-build}"; shift || true
SOFT=0; for a in "$@"; do [ "$a" = "--soft" ] && SOFT=1; done
OUT_DIR="${OUT_DIR:-dist}"
ONLY="${ONLY:-}"
LEGACY="stambul-app.zip"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '   \033[33m%s\033[0m\n' "$*"; }
die()  { printf '\n\033[31m❌ %s\033[0m\n\n' "$*" >&2; exit 1; }

# где лежат слои: releases/ приоритетнее, иначе корень
layer_dir() { [ -d releases ] && [ -n "$(ls releases/*.zip 2>/dev/null)" ] && echo releases || echo .; }
# все zip-архивы слоёв (без аудио)
list_zips() { { ls "$(layer_dir)"/*.zip 2>/dev/null || true; } | grep -v 'tours-audio' || true; }
# версия из имени: 1.83.zip → 1.83 ; base-1.82.zip → 1.82
ver_of() { basename "$1" .zip | sed 's/^base-//'; }
# версия приложения из index.html внутри архива
ver_inside() {
  unzip -p "$1" index.html 2>/dev/null | LC_ALL=C grep -ao '"version": *"[0-9][0-9.]*"' | head -1 |
    LC_ALL=C sed 's/[^0-9.]//g;s/^\.*//;s/\.*$//'
}


# ---------- выбор слоёв ----------
resolve_layers() {
  BASE=""; BASE_V=""; INCS=()
  local zips; zips=$(list_zips)

  # самый свежий base-*.zip
  local b; b=$(echo "$zips" | grep '/base-[0-9]' | sort -V | tail -1 || true)
  if [ -n "$b" ]; then
    BASE="$b"; BASE_V=$(ver_of "$b")
  elif [ -f "$LEGACY" ]; then
    BASE="$LEGACY"; BASE_V=$(ver_inside "$LEGACY"); [ -n "$BASE_V" ] || BASE_V="0"
  else
    soft_exit "не найден ни base-<версия>.zip, ни $LEGACY"
  fi

  # инкременты: имя = чистая версия, больше базовой
  local f v
  while read -r f; do
    [ -n "$f" ] || continue
    v=$(basename "$f" .zip)
    echo "$v" | grep -qE '^[0-9]+(\.[0-9]+)*$' || continue
    [ "$(printf '%s\n%s\n' "$BASE_V" "$v" | sort -V | tail -1)" = "$v" ] || continue
    [ "$v" = "$BASE_V" ] && continue
    if [ -n "$ONLY" ]; then
      [ "$(printf '%s\n%s\n' "$v" "$ONLY" | sort -V | tail -1)" = "$ONLY" ] || continue
    fi
    INCS+=("$f")
  done < <(echo "$zips" | sort -V)
}

apply_removals() {
  local f="$OUT_DIR/.remove"
  [ -f "$f" ] || return 0
  local p n=0
  while read -r p; do
    p=$(echo "$p" | tr -d '\r' | sed 's/^ *//;s/ *$//')
    case "$p" in ''|'#'*) continue;; esac
    if [ -e "$OUT_DIR/$p" ]; then rm -rf "${OUT_DIR:?}/$p"; n=$((n+1)); fi
  done < "$f"
  rm -f "$f"
  [ "$n" -gt 0 ] && info "удалено файлов: $n"
  return 0
}

# ---------- команды ----------
do_check() {
  say "🔍 Проверка окружения"
  for c in node unzip zip; do
    if command -v "$c" >/dev/null 2>&1; then info "✅ $c"; else warn "❌ $c не найден"; fi
  done
  info "node $(node -v 2>/dev/null || echo '—')"
  local n; n=$(list_zips | grep -c . || true)
  if [ "$n" -gt 0 ]; then info "✅ архивов со слоями: $n (в $(layer_dir))"; else warn "❌ архивов не найдено"; fi
  [ -f "$LEGACY" ] && warn "⚠️  найден $LEGACY — старая схема, см. «bash deploy.sh migrate»"
  if [ -f wrangler.jsonc ]; then info "✅ wrangler.jsonc"; else warn "⚠️  нет wrangler.jsonc"; fi
  if [ -f server.js ]; then info "✅ server.js"; else warn "⚠️  нет server.js"; fi
  say "⬆️  Публикация исходников"
  if can_push; then info "✅ права есть (${PUSH_WHY}) — site/ будет обновляться при деплое"
  else info "⏸ пока пропускается: ${PUSH_WHY}"; fi
  do_list
}

do_list() {
  resolve_layers
  say "🧩 Слои"
  info "основа:     $(basename "$BASE")  → версия $BASE_V"
  if [ ${#INCS[@]} -eq 0 ]; then info "инкрементов нет"; else
    for f in "${INCS[@]}"; do info "инкремент:  $(basename "$f")"; done
  fi
  local last="$BASE_V"
  [ ${#INCS[@]} -gt 0 ] && last=$(ver_of "${INCS[${#INCS[@]}-1]}")
  info "итоговая:   $last"
  [ -n "$ONLY" ] && info "ограничение ONLY=$ONLY"
  return 0
}

# в мягком режиме не валим деплой: если слои собрать нельзя,
# оставляем то, что уже распаковано старой командой Cloudflare
soft_exit() {
  if [ "$SOFT" = "1" ] && [ -f "$OUT_DIR/index.html" ]; then
    warn "$1"
    warn "оставляю уже собранный $OUT_DIR — деплой продолжится"
    exit 0
  fi
  die "$1"
}

do_build() {
  command -v unzip >/dev/null || soft_exit "нет unzip"
  resolve_layers
  say "📦 Сборка → $OUT_DIR/"
  [ "$SOFT" = "1" ] && info "мягкий режим: при сбое останется прежняя сборка"
  rm -rf "${OUT_DIR:?}"; mkdir -p "$OUT_DIR"

  info "основа: $(basename "$BASE") (версия $BASE_V)"
  unzip -oq "$BASE" -d "$OUT_DIR" || soft_exit "не распаковался $BASE"
  apply_removals

  local applied=1 f
  for f in "${INCS[@]:-}"; do
    [ -n "$f" ] || continue
    info "инкремент: $(basename "$f")"
    unzip -oq "$f" -d "$OUT_DIR" || soft_exit "не распаковался $f"
    apply_removals
    applied=$((applied+1))
  done

  # необязательный слой с озвучкой экскурсий
  local audio; audio=$( { ls tours-audio*.zip 2>/dev/null || true; } | head -1 )
  if [ -n "$audio" ]; then
    mkdir -p "$OUT_DIR/tours"
    unzip -oq "$audio" -d "$OUT_DIR/tours" && info "аудио: $audio → $OUT_DIR/tours/"
  fi

  [ -f "$OUT_DIR/index.html" ] || die "после сборки нет index.html — проверьте архивы"

  local v; v=$(ver_inside "$BASE")
  [ ${#INCS[@]} -gt 0 ] && v=$(ver_of "${INCS[${#INCS[@]}-1]}")
  [ -n "$v" ] || v="$BASE_V"

  local cnt size
  cnt=$(find "$OUT_DIR" -type f | wc -l)
  size=$(du -sh "$OUT_DIR" | cut -f1)
  printf '{"version":"%s","builtAt":"%s","layers":%s,"files":%s}\n' \
    "$v" "$(date -u +%FT%TZ)" "$applied" "$cnt" > "$OUT_DIR/version.json"

  say "✅ Собрано: версия $v · слоёв $applied · файлов $cnt · $size"
  [ "${PUSH_SITE:-auto}" = "build" ] && do_push_site "$v"
  return 0
}

# ---------- публикация исходников: пробуем, но никогда не роняем деплой ----------
# Работает только если Cloudflare (или локальный запуск) имеет права на запись.
# Пока прав нет — тихо пропускаем. Ничего настраивать заранее не нужно:
# как только появится токен (GIT_TOKEN) или git-remote с доступом, пуш начнётся сам.
can_push() {
  command -v git >/dev/null 2>&1 || { PUSH_WHY="нет git"; return 1; }
  git rev-parse --git-dir >/dev/null 2>&1 || { PUSH_WHY="не git-репозиторий"; return 1; }
  [ "${PUSH_SITE:-auto}" = "off" ] && { PUSH_WHY="выключено (PUSH_SITE=off)"; return 1; }

  # 1) явный токен
  if [ -n "${GIT_TOKEN:-}" ] && [ -n "${GIT_REPO:-}" ]; then
    PUSH_URL="https://x-access-token:${GIT_TOKEN}@github.com/${GIT_REPO}.git"
    PUSH_WHY="токен GIT_TOKEN"; return 0
  fi
  # 2) уже настроенный remote с доступом (например, если Cloudflare когда-нибудь его даст)
  local remote; remote=$(git remote get-url --push origin 2>/dev/null || true)
  [ -n "$remote" ] || { PUSH_WHY="нет remote origin"; return 1; }
  if git ls-remote --exit-code origin >/dev/null 2>&1; then
    # проверка именно записи: пробный push несуществующей ветки в dry-run
    if git push --dry-run origin HEAD:refs/heads/__probe__ >/dev/null 2>&1; then
      PUSH_URL="origin"; PUSH_WHY="права у origin"; return 0
    fi
    PUSH_WHY="origin доступен только на чтение"; return 1
  fi
  PUSH_WHY="origin недоступен"; return 1
}

do_push_site() {
  local v="${1:-unknown}"
  PUSH_URL=""; PUSH_WHY=""
  if ! can_push; then
    info "публикация исходников пропущена: ${PUSH_WHY}"
    return 0
  fi
  say "⬆️  Публикация исходников в site/ (${PUSH_WHY})"
  ( set +e
    git config user.name  "cloudflare-build"  >/dev/null 2>&1
    git config user.email "build@stambul.local" >/dev/null 2>&1
    git fetch --unshallow >/dev/null 2>&1 || git fetch --depth=50 >/dev/null 2>&1 || true
    rm -rf site && mkdir -p site && cp -r "$OUT_DIR"/. site/ 2>/dev/null
    git add -A site >/dev/null 2>&1
    if git diff --cached --quiet 2>/dev/null; then
      printf '   %s\n' "изменений в site/ нет"
      exit 0
    fi
    # [skip ci] обязателен: иначе коммит запустит новую сборку и получится цикл
    git commit -q -m "site: $v [skip ci]" >/dev/null 2>&1
    if git push -q "${PUSH_URL}" "HEAD:${PUSH_BRANCH:-main}" >/dev/null 2>&1; then
      printf '   %s\n' "✅ site/ обновлён до $v"
    else
      printf '   %s\n' "⚠️  push не прошёл — деплой продолжается как обычно"
      git reset --soft HEAD~1 >/dev/null 2>&1 || true
    fi
  ) || true
  return 0
}

do_deploy() {
  [ -f "$OUT_DIR/index.html" ] || { info "сборки нет — собираю"; do_build; }
  say "🚀 Деплой"
  npx wrangler deploy "$@" || die "wrangler deploy не прошёл"
  local v; v=$(grep -o '"version":"[^"]*"' "$OUT_DIR/version.json" | head -1 | cut -d'"' -f4)
  say "✅ Выкачено: версия $v"
  do_push_site "$v"
  info "на телефоне потяните вниз — версия в шапке должна смениться"
}

do_migrate() {
  say "🔄 Переход на схему слоёв"
  [ -f "$LEGACY" ] || { info "$LEGACY не найден — вероятно, переход уже сделан"; do_list; return 0; }
  local v; v=$(ver_inside "$LEGACY")
  [ -n "$v" ] || die "не удалось определить версию внутри $LEGACY"
  local target="base-$v.zip"
  if [ -f "$target" ]; then
    info "$target уже есть — просто удалите $LEGACY"
  else
    cp "$LEGACY" "$target" && info "создан $target (копия $LEGACY)"
  fi
  echo
  info "Дальше в репозитории:"
  info "  1. удалить $LEGACY"
  info "  2. закоммитить $target"
  info "  3. следующие релизы класть одним файлом: 1.83.zip, 1.84.zip …"
  echo
  do_list
}

do_pack() {
  local prev="${1:-}" next="${2:-}" version="${3:-}"
  [ -n "$prev" ] && [ -n "$next" ] && [ -n "$version" ] ||
    die "нужно: bash deploy.sh pack СТАРАЯ_ПАПКА НОВАЯ_ПАПКА 1.85"
  command -v zip >/dev/null || die "нет zip"
  say "📤 Инкремент $version"
  local tmp=".pack-tmp"; rm -rf "$tmp"; mkdir -p "$tmp"
  local changed=0 removed=0 rel

  while read -r f; do
    rel="${f#$next/}"
    if [ ! -f "$prev/$rel" ] || ! cmp -s "$f" "$prev/$rel"; then
      mkdir -p "$tmp/$(dirname "$rel")"; cp "$f" "$tmp/$rel"; changed=$((changed+1))
      [ "$changed" -le 8 ] && info "изменён: $rel"
    fi
  done < <(find "$next" -type f ! -name version.json)

  : > "$tmp/.remove"
  while read -r f; do
    rel="${f#$prev/}"
    [ -f "$next/$rel" ] || { echo "$rel" >> "$tmp/.remove"; removed=$((removed+1)); info "удалён: $rel"; }
  done < <(find "$prev" -type f ! -name version.json)
  [ "$removed" -eq 0 ] && rm -f "$tmp/.remove"

  if [ "$changed" -eq 0 ] && [ "$removed" -eq 0 ]; then
    rm -rf "$tmp"; info "изменений нет — инкремент не нужен"; return 0
  fi

  local out; out="$(layer_dir)/$version.zip"
  ( cd "$tmp" && zip -qr "../$out" . )
  rm -rf "$tmp"
  say "✅ $out · изменено $changed · удалено $removed · $(du -h "$out" | cut -f1)"
}

case "$CMD" in
  build)   do_build ;;
  deploy)  do_deploy "$@" ;;
  all)     do_build; do_deploy "$@" ;;
  list)    do_list ;;
  check)   do_check ;;
  migrate) do_migrate ;;
  pack)    do_pack "$@" ;;
  push)    do_push_site "$(grep -o '"version":"[^"]*"' "$OUT_DIR/version.json" 2>/dev/null | head -1 | cut -d'"' -f4)" ;;
  *)       die "неизвестная команда: $CMD (build | deploy | all | list | check | migrate | pack | push)" ;;
esac
