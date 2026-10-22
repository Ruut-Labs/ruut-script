#!/bin/bash
# Ruut Script — установка на macOS одним рядком (без Gatekeeper: усе приходить
# через curl, без quarantine). Потребує RUUT_TOKEN (ключ лише на читання
# приватного репо з релізами) — його вшиває сторінка установки в сам рядок.
#
#   RUUT_TOKEN=github_pat_… bash -c "$(curl -fsSL -H "Authorization: Bearer $RUUT_TOKEN" \
#       -H "Accept: application/vnd.github.raw" \
#       https://api.github.com/repos/Ruut-Labs/ruut-script/contents/tools/release/install.sh)"
#
# Куди: ~/Library/Application Support/Ruut Script (плоско: логіка, .py, ffmpeg,
# python/, models/, Library/) + панель у ~/Library/Application Support/Adobe/CEP/extensions.
set -euo pipefail

REPO="${RUUT_REPO:-Ruut-Labs/ruut-script}"
TOKEN="${RUUT_TOKEN:-}"
ROOT="$HOME/Library/Application Support/Ruut Script"
CEP="$HOME/Library/Application Support/Adobe/CEP/extensions/com.ruut.panel"
API="https://api.github.com"
UA="RuutScript-Installer"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
step() { printf '  \033[33m◐\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✕\033[0m %s\n' "$*" >&2; exit 1; }

say ""
say "Ruut Script — установка"
[ -n "$TOKEN" ] || die "немає ключа (RUUT_TOKEN). Скопіюй рядок установки зі сторінки ще раз — ключ усередині."
command -v curl >/dev/null || die "немає curl"
command -v python3 >/dev/null 2>&1 || true

ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  PLAT="mac-arm64" ;;
  x86_64) PLAT="mac-x64" ;;
  *) die "невідомий процесор: $ARCH" ;;
esac
OSV="$(sw_vers -productVersion)"
MAJOR="${OSV%%.*}"
[ "$MAJOR" -ge 13 ] || die "потрібна macOS 13 або новіша (у тебе $OSV)"
AE=""
for d in /Applications/Adobe\ After\ Effects\ 20*; do [ -d "$d" ] && AE="$d"; done
say "Mac · $PLAT · macOS $OSV · ${AE:+$(basename "$AE")}${AE:-After Effects не знайдено (панель усе одно поставлю)}"
if pgrep -x "After Effects" >/dev/null 2>&1; then
  say "  After Effects відкритий — закрий його і натисни Enter (або Ctrl+C, щоб перервати)"
  read -r _ </dev/tty || true
fi

gh_api() { curl -fsSL -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" -H "User-Agent: $UA" -H "X-GitHub-Api-Version: 2022-11-28" "$@"; }
gh_asset() { # $1 asset api url, $2 dest ; докачує з місця обриву
  curl -fL --retry 3 --retry-delay 2 -C - -H "Authorization: Bearer $TOKEN" -H "Accept: application/octet-stream" -H "User-Agent: $UA" --progress-bar -o "$2" "$1"
}

step "читаю останній реліз"
REL_JSON="$(gh_api "$API/repos/$REPO/releases/latest")" || die "не можу прочитати реліз (ключ правильний? інтернет є?)"
TAG="$(printf '%s' "$REL_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])')"
LATEST_URL="$(printf '%s' "$REL_JSON" | python3 -c 'import sys,json;a=[x for x in json.load(sys.stdin)["assets"] if x["name"]=="latest.json"];print(a[0]["url"] if a else "")')"
[ -n "$LATEST_URL" ] || die "у релізі $TAG немає latest.json"
mkdir -p "$ROOT/staging" "$ROOT/logs"
gh_asset "$LATEST_URL" "$ROOT/staging/latest.json" >/dev/null 2>&1
ok "реліз $TAG"

# компоненти цієї платформи
COMPS="$(python3 - "$ROOT/staging/latest.json" "$PLAT" <<'PY'
import json,sys
L=json.load(open(sys.argv[1])); plat=sys.argv[2]
for name in L["platforms"][plat]:
    c=L["components"].get(name)
    if c: print(name, c["asset"], c["sha256"], c["size"], c["target"])
PY
)"
[ -n "$COMPS" ] || die "у latest.json немає компонентів для $PLAT (збірка для мака ще не викладена)"

ASSETS_JSON="$(printf '%s' "$REL_JSON" | python3 -c 'import sys,json;print(json.dumps({a["name"]:a["url"] for a in json.load(sys.stdin)["assets"]}))')"
MAN_TMP="$ROOT/staging/manifest.new.json"
printf '{"version":"%s","platform":"%s","components":{' "${TAG#v}" "$PLAT" > "$MAN_TMP"
first=1
while read -r NAME ASSET SHA SIZE TARGET; do
  URL="$(printf '%s' "$ASSETS_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('$ASSET',''))")"
  [ -n "$URL" ] || die "у релізі немає файлу $ASSET"
  HAVE="$(python3 -c "import json,sys;m=json.load(open(sys.argv[1])) if __import__('os').path.exists(sys.argv[1]) else {};print(m.get('components',{}).get('$NAME',''))" "$ROOT/manifest.json" 2>/dev/null || true)"
  if [ "$HAVE" = "$SHA" ]; then ok "$NAME — уже стоїть"; else
    step "$NAME · $(( SIZE / 1048576 )) МБ"
    ZIP="$ROOT/staging/$ASSET"
    gh_asset "$URL" "$ZIP"
    GOT="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
    [ "$GOT" = "$SHA" ] || { rm -f "$ZIP"; die "$NAME: хеш не зійшовся — спробуй ще раз"; }
    UNP="$ROOT/staging/$NAME"; rm -rf "$UNP"; mkdir -p "$UNP"
    ditto -x -k "$ZIP" "$UNP"
    if [ "$NAME" = "cep" ]; then DEST="$CEP"; else DEST="$ROOT/${TARGET}"; fi
    mkdir -p "$DEST"
    ditto "$UNP" "$DEST"
    rm -rf "$UNP" "$ZIP"
    ok "$NAME"
  fi
  [ $first -eq 1 ] || printf ',' >> "$MAN_TMP"; first=0
  printf '"%s":"%s"' "$NAME" "$SHA" >> "$MAN_TMP"
done <<< "$COMPS"
printf '},"installed":"%s"}\n' "$(date +%F)" >> "$MAN_TMP"
mv "$MAN_TMP" "$ROOT/manifest.json"

step "налаштування"
chmod +x "$ROOT/python/bin/python3" "$ROOT/ffmpeg" "$ROOT/ffprobe" 2>/dev/null || true
xattr -dr com.apple.quarantine "$ROOT" "$CEP" 2>/dev/null || true
ESC_ROOT="$(printf '%s' "$ROOT" | sed 's/\\/\\\\/g; s/"/\\"/g')"
printf '{"panelJsx": "%s/Ruut Script 2.0.jsx", "toolsDir": "%s", "root": "%s", "repo": "%s", "token": "%s", "version": "%s"}\n' \
  "$ESC_ROOT" "$ESC_ROOT" "$ESC_ROOT" "$REPO" "$TOKEN" "${TAG#v}" > "$CEP/config.json"
if [ -f "$ROOT/Minor-Bold.ttf" ] && [ ! -f "$HOME/Library/Fonts/Minor-Bold.ttf" ]; then cp "$ROOT/Minor-Bold.ttf" "$HOME/Library/Fonts/"; ok "шрифт Minor-Bold"; fi
# стара панель 2.0 у папці користувача → редирект
OLD="$HOME/Library/Application Support/Ruut Script/panel/Ruut Script 2.0.jsx"
if [ -f "$OLD" ]; then mv "$OLD" "$OLD.before-3.0.bak"; printf '(function(){ alert("Панель переїхала: Window → Extensions → Ruut Script"); })();' > "$OLD"; fi
ok "конфіг записано"

step "самоперевірка на тестовому звуці"
if ( cd "$ROOT" && PYTHONIOENCODING=utf-8 "$ROOT/python/bin/python3" -X utf8 selftest.py ); then
  say ""
  say "Готово. Відкрий After Effects → Window → Extensions → Ruut Script."
  say "Перетягни панель, куди зручно, і збережи Workspace."
else
  say ""
  say "Установка завершена, але самоперевірка знайшла проблему (див. вище)."
  say "Скопіюй цей вивід і надішли Мирону."
  exit 2
fi
