#!/bin/bash
# Ruut Script — установка на macOS одним рядком. Без Gatekeeper: усе приходить
# через curl, без позначки quarantine. Без токенів: релізи публічні, а наші
# компоненти (логіка, панель, Library зі шрифтом) зашифровані — ключ RUUT_KEY
# іде в самому рядку установки, який роздається приватно:
#
#   RUUT_KEY=<ключ> bash -c "$(curl -fsSL https://raw.githubusercontent.com/Ruut-Labs/ruut-script/main/tools/release/install.sh)"
#
# Куди: ~/Library/Application Support/Ruut Script (плоско: логіка, .py, ffmpeg,
# python/, models/, Library/) + панель у ~/Library/Application Support/Adobe/CEP/extensions.
# Повторний запуск = оновлення: качає лише те, що змінилось.
set -euo pipefail

REPO="${RUUT_REPO:-Ruut-Labs/ruut-script}"
KEY="${RUUT_KEY:-}"
ROOT="$HOME/Library/Application Support/Ruut Script"
CEP="$HOME/Library/Application Support/Adobe/CEP/extensions/com.ruut.panel"
UA="RuutScript-Installer"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
step() { printf '  \033[33m◐\033[0m %s\n' "$*"; }
die()  {
  printf '\n  \033[31m✕ %s\033[0m\n' "$*" >&2
  printf '  Нічого не зламано: запусти той самий рядок ще раз — докачає з місця обриву.\n  Не допомогло — скопіюй увесь текст у цьому вікні й надішли Мирону.\n' >&2
  exit 1
}

say ""
say "Ruut Script — установка"
[ -n "$KEY" ] || die "у рядку установки немає ключа. Скопіюй рядок ще раз повністю — він починається з RUUT_KEY="
command -v curl >/dev/null || die "немає curl"
command -v openssl >/dev/null || die "немає openssl"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  PLAT="mac-arm64" ;;
  x86_64) PLAT="mac-x64" ;;
  *) die "невідомий процесор: $ARCH" ;;
esac
OSV="$(sw_vers -productVersion)"
MAJOR="${OSV%%.*}"
[ "$MAJOR" -ge 13 ] || die "потрібна macOS 13 або новіша (у тебе $OSV). After Effects 2025 теж вимагає 13+."
AE=""
for d in /Applications/Adobe\ After\ Effects\ 20*; do [ -d "$d" ] && AE="$d"; done
say "Mac · $PLAT · macOS $OSV · ${AE:+$(basename "$AE")}${AE:-After Effects не знайдено (панель усе одно поставлю)}"

FREE_KB="$(df -k "$HOME" | awk 'NR==2{print $4}')"
[ "${FREE_KB:-0}" -ge 3800000 ] || die "мало місця на диску: вільно $((FREE_KB/1024)) МБ, потрібно близько 3.5 ГБ"

if pgrep -x "After Effects" >/dev/null 2>&1; then
  say "  After Effects відкритий — закрий його і натисни Enter (або Ctrl+C, щоб перервати)"
  read -r _ </dev/tty || true
  while pgrep -x "After Effects" >/dev/null 2>&1; do say "  ще відкритий… закрий і натисни Enter"; read -r _ </dev/tty || true; done
fi

dl() { # $1 url, $2 dest — з повторами і докачкою
  curl -fL --retry 5 --retry-delay 3 --retry-all-errors -C - -A "$UA" --progress-bar -o "$2" "$1"
}

mkdir -p "$ROOT/staging" "$ROOT/logs"
step "читаю останній реліз"
dl "https://github.com/$REPO/releases/latest/download/latest.json" "$ROOT/staging/latest.json" 2>/dev/null \
  || die "не можу прочитати реліз — перевір інтернет"
read -r VERSION <<<"$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$ROOT/staging/latest.json" 2>/dev/null \
  || sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$ROOT/staging/latest.json" | head -1)"
[ -n "$VERSION" ] || die "не розібрав latest.json"
ok "реліз v$VERSION"

# компоненти цієї платформи: name asset sha256 size target enc
COMPS="$(/usr/bin/python3 - "$ROOT/staging/latest.json" "$PLAT" <<'PY'
import json,sys
L=json.load(open(sys.argv[1])); plat=sys.argv[2]
for name in L["platforms"][plat]:
    c=L["components"].get(name)
    if c: print(name, c["asset"], c["sha256"], c["size"], c["target"] or "-", "1" if c.get("enc") else "0", c.get("tag") or "v" + L["version"])
PY
)" || die "не розібрав список компонентів (потрібен /usr/bin/python3 — він є в macOS; якщо ні: xcode-select --install)"
[ -n "$COMPS" ] || die "у релізі немає компонентів для $PLAT"

have_sha() { /usr/bin/python3 -c 'import json,sys,os
p=sys.argv[1]
print(json.load(open(p)).get("components",{}).get(sys.argv[2],"") if os.path.exists(p) else "")' "$ROOT/manifest.json" "$1" 2>/dev/null || true; }

MAN_TMP="$ROOT/staging/manifest.new.json"
printf '{"version":"%s","platform":"%s","components":{' "$VERSION" "$PLAT" > "$MAN_TMP"
first=1
while read -r NAME ASSET SHA SIZE TARGET ENC TAG; do
  [ "$TARGET" = "-" ] && TARGET=""
  if [ "$(have_sha "$NAME")" = "$SHA" ]; then ok "$NAME — уже стоїть"; else
    step "$NAME · $(( SIZE / 1048576 )) МБ"
    F="$ROOT/staging/$ASSET"
    dl "https://github.com/$REPO/releases/download/$TAG/$ASSET" "$F" || die "$NAME: не скачалось"
    GOT="$(shasum -a 256 "$F" | cut -d' ' -f1)"
    [ "$GOT" = "$SHA" ] || { rm -f "$F"; die "$NAME: файл пошкоджено при завантаженні"; }
    ZIP="$F"
    if [ "$ENC" = "1" ]; then
      ZIP="${F%.enc}"
      IV="$(head -c 16 "$F" | xxd -p | tr -d '\n')"
      tail -c +17 "$F" | openssl enc -d -aes-256-cbc -K "$KEY" -iv "$IV" -out "$ZIP" 2>/dev/null \
        || { rm -f "$ZIP"; die "$NAME: не розшифрувалось — ключ у рядку установки неповний"; }
    fi
    UNP="$ROOT/staging/$NAME"; rm -rf "$UNP"; mkdir -p "$UNP"
    ditto -x -k "$ZIP" "$UNP" || die "$NAME: не розпакувалось"
    if [ "$NAME" = "cep" ]; then DEST="$CEP"; rm -rf "$CEP"; else DEST="$ROOT/${TARGET}"; fi
    # архів міг прийти з зайвою верхньою папкою (python/python/…) — знімаємо її
    if [ -n "$TARGET" ] && [ -d "$UNP/$TARGET" ] && [ "$(ls -A "$UNP" | wc -l | tr -d ' ')" = "1" ]; then UNP="$UNP/$TARGET"; fi
    mkdir -p "$DEST"
    ditto "$UNP" "$DEST"
    rm -rf "$ROOT/staging/$NAME" "$ZIP" "$F"
    ok "$NAME"
  fi
  [ $first -eq 1 ] || printf ',' >> "$MAN_TMP"; first=0
  printf '"%s":"%s"' "$NAME" "$SHA" >> "$MAN_TMP"
done <<< "$COMPS"
printf '},"installed":"%s"}\n' "$(date +%F)" >> "$MAN_TMP"
mv "$MAN_TMP" "$ROOT/manifest.json"

step "налаштування"
chmod +x "$ROOT/python/bin/"* "$ROOT/ffmpeg" 2>/dev/null || true
xattr -dr com.apple.quarantine "$ROOT" "$CEP" 2>/dev/null || true
ESC_ROOT="$(printf '%s' "$ROOT" | sed 's/\\/\\\\/g; s/"/\\"/g')"
printf '{"panelJsx": "%s/Ruut Script 2.0.jsx", "toolsDir": "%s", "root": "%s", "repo": "%s", "key": "%s", "version": "%s"}\n' \
  "$ESC_ROOT" "$ESC_ROOT" "$ESC_ROOT" "$REPO" "$KEY" "$VERSION" > "$ROOT/config.json"
# у папці панелі config.json лежати не може — будь-який доданий файл ламає її підпис
rm -f "$CEP/config.json"
# шрифт: папки ~/Library/Fonts на «чистому» маку може не бути; помилка тут
# не має зривати установку — без шрифту працює все, крім його вигляду
if [ -f "$ROOT/Minor-Bold.ttf" ] && [ ! -f "$HOME/Library/Fonts/Minor-Bold.ttf" ]; then
  mkdir -p "$HOME/Library/Fonts" 2>/dev/null || true
  if cp "$ROOT/Minor-Bold.ttf" "$HOME/Library/Fonts/" 2>/dev/null; then ok "шрифт Minor-Bold"
  else say "  · шрифт не поставився сам — двічі клацни «Minor-Bold.ttf» у папці Ruut Script і натисни «Встановити»"; fi
fi
OLD="$HOME/Library/Application Support/Ruut Script/panel/Ruut Script 2.0.jsx"
if [ -f "$OLD" ]; then mv "$OLD" "$OLD.before-3.0.bak" 2>/dev/null && printf '(function(){ alert("Панель переїхала: Window → Extensions → Ruut Script"); })();' > "$OLD" || true; fi
ok "готово до перевірки"

if [ ! -x "$ROOT/python/bin/python3" ] && [ -x "$ROOT/python/python/bin/python3" ]; then
  mv "$ROOT/python" "$ROOT/python.nested" && mv "$ROOT/python.nested/python" "$ROOT/python" && rm -rf "$ROOT/python.nested"
fi
[ -x "$ROOT/python/bin/python3" ] || die "Python не розпакувався (немає python/bin/python3)"

step "самоперевірка на тестовому звуці"
if ( cd "$ROOT" && PYTHONIOENCODING=utf-8 "$ROOT/python/bin/python3" -X utf8 selftest.py ) > "$ROOT/logs/install-selftest.log" 2>&1; then
  ok "розпізнавання працює"
  say ""
  say "Готово. Відкрий After Effects → Window → Extensions → Ruut Script."
  say "Перетягни панель, куди зручно, і збережи Workspace."
else
  cat "$ROOT/logs/install-selftest.log"
  say ""
  say "Установка завершена, але самоперевірка знайшла проблему (див. вище)."
  say "Скопіюй увесь текст у цьому вікні й надішли Мирону."
  exit 2
fi
