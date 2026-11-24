#!/usr/bin/env bash
set -euo pipefail

LLAMA_DIR=${LLAMA_DIR:-"$HOME/src/llama.cpp"}
MODEL_DIR=${MODEL_DIR:-"$HOME/models"}
PIN="bec4772f6a2527d371557b5d2032641e5ff7619c"

sudo apt-get update
sudo apt-get install -y build-essential cmake ninja-build git libcurl4-openssl-dev pipx

pipx ensurepath
if ! command -v hf >/dev/null 2>&1; then
    pipx install huggingface_hub
fi
export PATH="$HOME/.local/bin:$PATH"

mkdir -p "$(dirname "$LLAMA_DIR")" "$MODEL_DIR"
if [[ -d "$LLAMA_DIR/.git" ]]; then
    git -C "$LLAMA_DIR" fetch --all --tags
else
    git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
fi

git -C "$LLAMA_DIR" checkout --detach "$PIN"
actual=$(git -C "$LLAMA_DIR" rev-parse HEAD)
if [[ "$actual" != "$PIN" ]]; then
    echo "llama.cpp pin verification failed: expected $PIN, got $actual" >&2
    exit 1
fi

command -v hf >/dev/null || {
    echo "Hugging Face CLI not found. Ensure ~/.local/bin is on PATH and rerun." >&2
    exit 1
}

hf download Qwen/Qwen2.5-1.5B-Instruct-GGUF \
    --local-dir "$MODEL_DIR/Qwen2.5-1.5B-Instruct-GGUF"
hf download Qwen/Qwen3.6-27B-GGUF \
    --local-dir "$MODEL_DIR/Qwen3.6-27B-GGUF"

printf 'Pinned llama.cpp at %s\nModels stored under %s\n' "$actual" "$MODEL_DIR"
