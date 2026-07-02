#!/usr/bin/env bash
set -euo pipefail

APP_SUPPORT="${QWEN_AUDIOBOOK_APP_SUPPORT:-"$HOME/Library/Application Support/Qwen Audiobook Maker"}"
QWEN_TTS_BIN="${QWEN_TTS_BIN:-"$APP_SUPPORT/venvs/qwen-tts/bin/qwen-tts-demo"}"
QWEN_TTS_PYTHON="${QWEN_TTS_PYTHON:-"$APP_SUPPORT/venvs/qwen-tts/bin/python"}"

export HF_HOME="${HF_HOME:-"$APP_SUPPORT/cache/huggingface"}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-"$APP_SUPPORT/cache"}"
export MPLCONFIGDIR="${MPLCONFIGDIR:-"$APP_SUPPORT/cache/matplotlib"}"
export PYTORCH_ENABLE_MPS_FALLBACK="${PYTORCH_ENABLE_MPS_FALLBACK:-1}"

mkdir -p "$HF_HOME" "$MPLCONFIGDIR"

QWEN_DEVICE="${QWEN_DEVICE:-$("$QWEN_TTS_PYTHON" -c 'import torch; print("mps" if torch.backends.mps.is_available() else "cpu")' 2>/dev/null || echo "cpu")}"

echo "[INFO] Qwen server launch: model=Qwen/Qwen3-TTS-12Hz-1.7B-Base device=$QWEN_DEVICE dtype=float32 max_new_tokens=model-default"

if [[ ! -x "$QWEN_TTS_BIN" ]]; then
  echo "[ERROR] Missing qwen-tts-demo at $QWEN_TTS_BIN"
  echo "[ERROR] Run the app's first-run setup again."
  exit 1
fi

exec "$QWEN_TTS_BIN" \
  Qwen/Qwen3-TTS-12Hz-1.7B-Base \
  --device "$QWEN_DEVICE" \
  --dtype float32 \
  --no-flash-attn \
  --ip 127.0.0.1 \
  --port 7860 \
  --concurrency 1
