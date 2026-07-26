#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ReadAsMe"
BUNDLE_ID="com.godgardensguns.ReadAsMe"
APP_VERSION="0.2.2"
BUILD_VERSION="7"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
SCRATCH_DIR="$ROOT_DIR/.build-readasme"
SWIFT_CACHE_DIR="$ROOT_DIR/.swiftpm-cache-readasme"
CLANG_CACHE_DIR="$ROOT_DIR/.build-readasme/clang-module-cache"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_RUNTIME="$APP_RESOURCES/Runtime"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_FILE="$ROOT_DIR/Resources/AppIcon.icns"
ICON_SET="$ROOT_DIR/Resources/AppIcon.iconset"
RUNTIME_DIR="$ROOT_DIR/Runtime"
CONVERTER_SOURCE="$ROOT_DIR/../repos/Qwen3-Audiobook-Converter"
VENDOR_PYTHON_DIR="$ROOT_DIR/Vendor/python"
PROJECT_LICENSE="$ROOT_DIR/../LICENSE"

mkdir -p "$SWIFT_CACHE_DIR" "$CLANG_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$CLANG_CACHE_DIR"

SWIFT_BUILD_ARGS=(
  --configuration release
  --scratch-path "$SCRATCH_DIR"
  --cache-path "$SWIFT_CACHE_DIR"
  --manifest-cache local
)

swift build "${SWIFT_BUILD_ARGS[@]}"
BUILD_BINARY="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)/$APP_NAME"

/usr/bin/python3 "$ROOT_DIR/script/build_app_icon.py" "$ICON_SET" "$ICON_FILE"

ensure_vendor_python() {
  local python_bin
  python_bin="$(find "$VENDOR_PYTHON_DIR" -path '*/bin/python3.12' -type f -perm +111 -print -quit 2>/dev/null || true)"
  if [[ -n "$python_bin" ]]; then
    return
  fi

  if ! command -v uv >/dev/null 2>&1; then
    echo "uv is required to prepare the bundled Python runtime." >&2
    echo "Install uv from https://docs.astral.sh/uv/ or run this build on a machine where uv is available." >&2
    exit 1
  fi

  mkdir -p "$VENDOR_PYTHON_DIR"
  uv python install 3.12 --install-dir "$VENDOR_PYTHON_DIR"
}

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if [[ -f "$ICON_FILE" ]]; then
  cp "$ICON_FILE" "$APP_RESOURCES/AppIcon.icns"
fi

if [[ -f "$PROJECT_LICENSE" ]]; then
  cp "$PROJECT_LICENSE" "$APP_RESOURCES/LICENSE-GPL-3.0.txt"
fi

mkdir -p "$APP_RUNTIME"
ditto "$RUNTIME_DIR" "$APP_RUNTIME"

FFMPEG_SOURCE_BIN="${READASME_FFMPEG_BIN_DIR:-/opt/homebrew/bin}"
/usr/bin/python3 "$ROOT_DIR/script/bundle_ffmpeg.py" "$FFMPEG_SOURCE_BIN" "$APP_RUNTIME"
"$APP_RUNTIME/bin/ffmpeg" -L >"$APP_RUNTIME/FFMPEG-LICENSE.txt" 2>&1 || true

ensure_vendor_python
VENDOR_PYTHON_BIN="$(find "$VENDOR_PYTHON_DIR" -path '*/bin/python3.12' -type f -perm +111 -print -quit)"
VENDOR_PYTHON_HOME="$(cd "$(dirname "$VENDOR_PYTHON_BIN")/.." && pwd)"
ditto "$VENDOR_PYTHON_HOME" "$APP_RUNTIME/python"
find "$APP_RUNTIME/python" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
find "$APP_RUNTIME/python" -type d -name '__pycache__' -empty -delete
SYSCONFIG_FILE="$(find "$APP_RUNTIME/python/lib/python3.12" -name '_sysconfigdata__darwin_darwin.py' -type f -print -quit)"
if [[ -f "$SYSCONFIG_FILE" ]]; then
  perl -0pi -e "s|\\Q$VENDOR_PYTHON_HOME\\E|__QWEN_BUNDLED_PYTHON__|g" "$SYSCONFIG_FILE"
  cat >>"$SYSCONFIG_FILE" <<'PYCONFIG'

import sys as _qwen_runtime_sys
for _qwen_key, _qwen_value in list(build_time_vars.items()):
    if isinstance(_qwen_value, str):
        build_time_vars[_qwen_key] = _qwen_value.replace(
            "__QWEN_BUNDLED_PYTHON__",
            _qwen_runtime_sys.prefix,
        )
PYCONFIG
fi

if [[ -d "$CONVERTER_SOURCE" ]]; then
  rsync -a --delete \
    --exclude '.git' \
    --exclude '__pycache__' \
    --exclude 'audiobooks' \
    --exclude 'book_to_convert' \
    --exclude 'sample' \
    "$CONVERTER_SOURCE/" "$APP_RUNTIME/Qwen3-Audiobook-Converter/"
else
  echo "missing converter source: $CONVERTER_SOURCE" >&2
  exit 1
fi

# Source-tree tests may leave bytecode behind. Never ship local cache artifacts.
find "$APP_RUNTIME" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete
find "$APP_RUNTIME" -type d -name '__pycache__' -empty -delete

chmod +x \
  "$APP_RUNTIME/bootstrap_runtime.sh" \
  "$APP_RUNTIME/bootstrap_audit_runtime.sh" \
  "$APP_RUNTIME/start_qwen_tts_server.sh" \
  "$APP_RUNTIME/audiobook_quality.py" \
  "$APP_RUNTIME/bin/ffmpeg" \
  "$APP_RUNTIME/bin/ffprobe"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>ReadAsMe</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -lint "$INFO_PLIST" >/dev/null
/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  --build|build)
    ;;
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [build|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
