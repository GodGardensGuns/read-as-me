#!/usr/bin/env bash
set -euo pipefail

APP_SUPPORT="${1:?missing app support path}"
BUNDLED_RUNTIME="${2:?missing bundled runtime path}"
AUDIT_VENV="$APP_SUPPORT/venvs/parakeet-audit"
BUNDLED_PYTHON="$BUNDLED_RUNTIME/python/bin/python3.12"
REQUIREMENTS="$BUNDLED_RUNTIME/requirements-audit.txt"
STAMP="$AUDIT_VENV/.readasme-audit-version"
VERSION="$(cat "$BUNDLED_RUNTIME/runtime-version.txt")"

export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_CACHE_DIR="$APP_SUPPORT/cache/pip"
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$APP_SUPPORT/venvs" "$PIP_CACHE_DIR"

if [[ ! -x "$BUNDLED_PYTHON" ]]; then
  echo "[ERROR] The bundled Python runtime is missing."
  exit 1
fi

if [[ -x "$AUDIT_VENV/bin/python" && -f "$STAMP" && "$(cat "$STAMP")" == "$VERSION" ]]; then
  echo "[OK] Parakeet audit runtime is already installed."
  exit 0
fi

if [[ ! -x "$AUDIT_VENV/bin/python" ]]; then
  echo "[INFO] Creating Parakeet audit environment..."
  "$BUNDLED_PYTHON" -m venv "$AUDIT_VENV"
fi

echo "[INFO] Installing NVIDIA Parakeet audit packages..."
"$AUDIT_VENV/bin/python" -m pip install --upgrade pip setuptools wheel
"$AUDIT_VENV/bin/python" -m pip install -r "$REQUIREMENTS"
printf '%s' "$VERSION" >"$STAMP"
echo "[OK] Parakeet audit runtime is ready."
