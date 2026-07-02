#!/usr/bin/env bash
set -euo pipefail

APP_SUPPORT="${1:?missing app support path}"
BUNDLED_RUNTIME="${2:?missing bundled runtime path}"
VERSION_FILE="$BUNDLED_RUNTIME/runtime-version.txt"
INSTALLED_VERSION_FILE="$APP_SUPPORT/runtime-version.txt"
CONVERTER_VENV="$APP_SUPPORT/venvs/qwen-converter"
QWEN_TTS_VENV="$APP_SUPPORT/venvs/qwen-tts"
BUNDLED_PYTHON="$BUNDLED_RUNTIME/python/bin/python3.12"

export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_CACHE_DIR="$APP_SUPPORT/cache/pip"

mkdir -p "$APP_SUPPORT/venvs" "$APP_SUPPORT/cache" "$PIP_CACHE_DIR"

find_python() {
  local candidate
  if [[ -x "$BUNDLED_PYTHON" ]]; then
    echo "$BUNDLED_PYTHON"
    return 0
  fi

  for candidate in \
    /opt/homebrew/opt/python@3.12/bin/python3.12 \
    /opt/homebrew/bin/python3.12 \
    /usr/local/opt/python@3.12/bin/python3.12 \
    /usr/local/bin/python3.12 \
    python3.12 \
    python3
  do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

PYTHON="$(find_python || true)"
if [[ -z "$PYTHON" ]]; then
  echo "[ERROR] Python was not found."
  echo "[ERROR] This release should include a bundled Python runtime."
  exit 1
fi

PYTHON_VERSION="$("$PYTHON" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))')"
PYTHON_MAJOR_MINOR="$("$PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
echo "[INFO] Python: $PYTHON ($PYTHON_VERSION)"

case "$PYTHON_MAJOR_MINOR" in
  3.10|3.11|3.12) ;;
  *)
    echo "[ERROR] Python $PYTHON_MAJOR_MINOR is not supported for this runtime."
    echo "[ERROR] Use the bundled Python 3.12 runtime from the release app."
    exit 1
    ;;
esac

if ! "$PYTHON" -m venv --help >/dev/null 2>&1; then
  echo "[ERROR] Python venv support is missing from $PYTHON"
  exit 1
fi

should_install=false
if [[ ! -x "$CONVERTER_VENV/bin/python" || ! -x "$QWEN_TTS_VENV/bin/qwen-tts-demo" ]]; then
  should_install=true
elif [[ -f "$VERSION_FILE" ]]; then
  if [[ ! -f "$INSTALLED_VERSION_FILE" ]] || ! cmp -s "$VERSION_FILE" "$INSTALLED_VERSION_FILE"; then
    should_install=true
  fi
fi

if [[ "$should_install" != true ]]; then
  echo "[OK] Runtime is already installed."
  exit 0
fi

ensure_venv() {
  local venv_path="$1"
  local requirements_file="$2"
  local label="$3"

  if [[ ! -x "$venv_path/bin/python" ]]; then
    echo "[INFO] Creating $label environment..."
    "$PYTHON" -m venv "$venv_path"
  fi

  echo "[INFO] Installing $label packages..."
  "$venv_path/bin/python" -m pip install --upgrade pip setuptools wheel
  "$venv_path/bin/python" -m pip install -r "$requirements_file"
}

ensure_venv "$CONVERTER_VENV" "$BUNDLED_RUNTIME/requirements-converter.txt" "converter"
ensure_venv "$QWEN_TTS_VENV" "$BUNDLED_RUNTIME/requirements-qwen-tts.txt" "Qwen TTS"
"$QWEN_TTS_VENV/bin/python" "$BUNDLED_RUNTIME/patch_qwen_tts.py"

if [[ -f "$VERSION_FILE" ]]; then
  cp "$VERSION_FILE" "$INSTALLED_VERSION_FILE"
fi

echo "[OK] Runtime setup complete."
