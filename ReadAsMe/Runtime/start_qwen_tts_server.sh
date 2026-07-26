#!/usr/bin/env bash
set -euo pipefail

APP_SUPPORT="${READ_AS_ME_APP_SUPPORT:-${QWEN_AUDIOBOOK_APP_SUPPORT:-"$HOME/Library/Application Support/ReadAsMe"}}"
QWEN_TTS_BIN="${QWEN_TTS_BIN:-"$APP_SUPPORT/venvs/qwen-tts/bin/qwen-tts-demo"}"
QWEN_TTS_PYTHON="${QWEN_TTS_PYTHON:-"$APP_SUPPORT/venvs/qwen-tts/bin/python"}"
LOCK_DIR="$APP_SUPPORT/qwen-server.lock"
LOCK_OWNER="$LOCK_DIR/owner-pid"

export HF_HOME="${HF_HOME:-"$APP_SUPPORT/cache/huggingface"}"
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-"$APP_SUPPORT/cache"}"
export MPLCONFIGDIR="${MPLCONFIGDIR:-"$APP_SUPPORT/cache/matplotlib"}"
export NUMBA_CACHE_DIR="${NUMBA_CACHE_DIR:-"$APP_SUPPORT/cache/numba"}"
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"
export PYTORCH_ENABLE_MPS_FALLBACK="${PYTORCH_ENABLE_MPS_FALLBACK:-1}"

mkdir -p "$HF_HOME" "$MPLCONFIGDIR" "$NUMBA_CACHE_DIR"

acquire_lock() {
  local attempt existing_pid
  for attempt in 1 2; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" >"$LOCK_OWNER"
      return 0
    fi

    existing_pid="$(cat "$LOCK_OWNER" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      echo "[ERROR] Another ReadAsMe voice engine is already starting or running (PID $existing_pid)."
      return 1
    fi

    rm -f "$LOCK_OWNER"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  done

  echo "[ERROR] Could not acquire the ReadAsMe voice-engine lock."
  return 1
}

server_pid=""

cleanup() {
  rm -f "$LOCK_OWNER"
  rmdir "$LOCK_DIR" 2>/dev/null || true
}

forward_signal() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  exit 143
}

acquire_lock
trap cleanup EXIT
trap forward_signal INT TERM

QWEN_DEVICE="${QWEN_DEVICE:-$("$QWEN_TTS_PYTHON" -c 'import torch; print("mps" if torch.backends.mps.is_available() else "cpu")' 2>/dev/null || echo "cpu")}"
QWEN_TEMPERATURE="${QWEN_TEMPERATURE:-0.80}"
QWEN_TOP_K="${QWEN_TOP_K:-35}"
QWEN_TOP_P="${QWEN_TOP_P:-0.90}"
QWEN_SUBTALKER_TEMPERATURE="${QWEN_SUBTALKER_TEMPERATURE:-0.75}"
QWEN_SUBTALKER_TOP_K="${QWEN_SUBTALKER_TOP_K:-35}"
QWEN_SUBTALKER_TOP_P="${QWEN_SUBTALKER_TOP_P:-0.90}"

echo "[INFO] Qwen server launch: model=Qwen/Qwen3-TTS-12Hz-1.7B-Base device=$QWEN_DEVICE dtype=float32 temperature=$QWEN_TEMPERATURE"

if [[ ! -x "$QWEN_TTS_BIN" ]]; then
  echo "[ERROR] Missing qwen-tts-demo at $QWEN_TTS_BIN"
  echo "[ERROR] Run the app's first-run setup again."
  exit 1
fi

"$QWEN_TTS_BIN" \
  Qwen/Qwen3-TTS-12Hz-1.7B-Base \
  --device "$QWEN_DEVICE" \
  --dtype float32 \
  --no-flash-attn \
  --temperature "$QWEN_TEMPERATURE" \
  --top-k "$QWEN_TOP_K" \
  --top-p "$QWEN_TOP_P" \
  --subtalker-temperature "$QWEN_SUBTALKER_TEMPERATURE" \
  --subtalker-top-k "$QWEN_SUBTALKER_TOP_K" \
  --subtalker-top-p "$QWEN_SUBTALKER_TOP_P" \
  --ip 127.0.0.1 \
  --port 7860 \
  --concurrency 1 &

server_pid=$!
set +e
wait "$server_pid"
server_status=$?
set -e
exit "$server_status"
