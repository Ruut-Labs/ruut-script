#!/bin/bash
# Збирає mac-компоненти для релізу на GitHub Actions (macos-15 = arm64,
# macos-15-intel = x64): python-mac-<arch>.zip (вбудований CPython 3.12 з усіма
# пакетами) і ffmpeg-mac-<arch>.zip. Пише <name>.sha256.json поруч.
#
#   bash build_mac_component.sh <version> <arch: arm64|x64> <outdir>
set -euo pipefail
VERSION="$1"; ARCH="$2"; OUT="$3"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
PBS_TAG="${PBS_TAG:-20251014}"          # реліз python-build-standalone
PY_VER="${PY_VER:-3.12.12}"
case "$ARCH" in
  arm64) TRIPLE="aarch64-apple-darwin"; ORT_SPEC="onnxruntime==1.23.2" ;;   # 1.24+ лише macOS 14+; 1.23.2 — macOS 13+
  x64)   TRIPLE="x86_64-apple-darwin";  ORT_SPEC="onnxruntime==1.23.2" ;;   # останній з Intel-колесами
  *) echo "arch?"; exit 1 ;;
esac

echo "== python $PY_VER $TRIPLE"
curl -fsSL -o "$WORK/py.tar.gz" "https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_TAG/cpython-$PY_VER+$PBS_TAG-$TRIPLE-install_only.tar.gz"
mkdir -p "$WORK/python-root"
tar -xzf "$WORK/py.tar.gz" -C "$WORK/python-root"       # → python-root/python/{bin,lib,...}
PY="$WORK/python-root/python/bin/python3"
"$PY" -V
"$PY" -m pip install --upgrade pip wheel >/dev/null
# Ті самі пакети, що у Windows-збірці (tools/release/requirements-runtime.txt).
sed "s/^onnxruntime==.*/$ORT_SPEC/" "$(dirname "$0")/requirements-runtime.txt" > "$WORK/req.txt"
"$PY" -m pip install -r "$WORK/req.txt"
# прибрати зайве: кеш pip, тести numpy, .pyc — менший zip
find "$WORK/python-root/python" -name "__pycache__" -type d -prune -exec rm -rf {} + || true
rm -rf "$WORK/python-root/python/lib/python3.12/site-packages/numpy/tests" 2>/dev/null || true
"$PY" - <<'PY'
import onnxruntime, ctranslate2, numpy, PIL, faster_whisper, onnx_asr, av
print("ort", onnxruntime.__version__, "ct2", ctranslate2.__version__, "np", numpy.__version__)
PY
( cd "$WORK/python-root" && ditto -c -k --sequesterRsrc --keepParent python "$OUT/python-mac-$ARCH-$VERSION.zip" )

echo "== ffmpeg ($ARCH)"
"$PY" -m pip download --no-deps -d "$WORK/ff" --only-binary=:all: \
   --platform "macosx_11_0_$([ "$ARCH" = arm64 ] && echo arm64 || echo x86_64)" --platform "macosx_10_9_x86_64" imageio-ffmpeg >/dev/null
WHL="$(ls "$WORK"/ff/imageio_ffmpeg*.whl | head -1)"
mkdir -p "$WORK/ffx" && ( cd "$WORK/ffx" && unzip -q "$WHL" )
BIN="$(ls "$WORK"/ffx/imageio_ffmpeg/binaries/ffmpeg-macos-* | head -1)"
mkdir -p "$WORK/ffroot"; cp "$BIN" "$WORK/ffroot/ffmpeg"; chmod +x "$WORK/ffroot/ffmpeg"
"$WORK/ffroot/ffmpeg" -version | head -1
( cd "$WORK/ffroot" && ditto -c -k ffmpeg "$OUT/ffmpeg-mac-$ARCH-$VERSION.zip" )

echo "== sha256"
for f in "$OUT/python-mac-$ARCH-$VERSION.zip" "$OUT/ffmpeg-mac-$ARCH-$VERSION.zip"; do
  NAME="$(basename "$f" | sed "s/-$VERSION\.zip$//")"
  SHA="$(shasum -a 256 "$f" | cut -d' ' -f1)"; SIZE="$(stat -f%z "$f")"
  TARGET="python"; [ "$NAME" = "ffmpeg-mac-$ARCH" ] && TARGET=""
  printf '{"name":"%s","asset":"%s","sha256":"%s","size":%s,"target":"%s"}\n' "$NAME" "$(basename "$f")" "$SHA" "$SIZE" "$TARGET" > "$OUT/$NAME.sha256.json"
  cat "$OUT/$NAME.sha256.json"
done
rm -rf "$WORK"
