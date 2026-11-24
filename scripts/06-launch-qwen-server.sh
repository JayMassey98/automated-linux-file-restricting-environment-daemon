#!/usr/bin/env bash
set -euo pipefail

LLAMA_DIR=${LLAMA_DIR:-"$HOME/src/llama.cpp"}
MODEL_DIR=${MODEL_DIR:-"$HOME/models"}
BACKEND=${BACKEND:-vulkan}
MODEL_PATH=${MODEL_PATH:-"$MODEL_DIR/Qwen3.6-27B-GGUF"}
HOST=${HOST:-0.0.0.0}
PORT=${PORT:-8080}
CTX_SIZE=${CTX_SIZE:-200000}

case "$BACKEND" in
    cpu|vulkan|hip) ;;
    *)
        echo "BACKEND must be cpu, vulkan, or hip." >&2
        exit 2
        ;;
esac

server="$LLAMA_DIR/build-$BACKEND/bin/llama-server"
[[ -x "$server" ]] || {
    echo "Server binary not found: $server. Run 05-build-backends.sh." >&2
    exit 1
}

if [[ -f "$MODEL_PATH" ]]; then
    model="$MODEL_PATH"
elif [[ -d "$MODEL_PATH" ]]; then
    model=$(find "$MODEL_PATH" -maxdepth 1 -type f -name '*.gguf' -print -quit)
else
    model=""
fi

[[ -n "$model" && -f "$model" ]] || {
    echo "No GGUF file found at $MODEL_PATH. Set MODEL_PATH to a GGUF file or directory." >&2
    exit 1
}

echo "Starting $BACKEND llama-server with $model on $HOST:$PORT"
echo "Large model/context requirements may exceed available RAM/VRAM; lower CTX_SIZE if needed."

exec "$server" \
    -m "$model" \
    --host "$HOST" \
    --port "$PORT" \
    -c "$CTX_SIZE" \
    --flash-attn on \
    --parallel 1 \
    --cache-type-k q4_0 \
    --cache-type-v q4_0
