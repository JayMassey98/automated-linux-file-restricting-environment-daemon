#!/usr/bin/env bash
set -euo pipefail

LLAMA_DIR=${LLAMA_DIR:-"$HOME/src/llama.cpp"}
MODEL_DIR=${MODEL_DIR:-"$HOME/models"}
JOBS=${JOBS:-$(nproc)}
VALIDATION_DIR=${VALIDATION_DIR:-"$MODEL_DIR/Qwen2.5-1.5B-Instruct-GGUF"}

[[ -d "$LLAMA_DIR" ]] || {
    echo "llama.cpp not found at $LLAMA_DIR; run 04-prepare-llama-cpp.sh first." >&2
    exit 1
}

cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build-cpu" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release
cmake --build "$LLAMA_DIR/build-cpu" --config Release --parallel "$JOBS"

sudo apt-get update
sudo apt-get install -y libvulkan-dev glslc vulkan-tools
cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build-vulkan" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON
cmake --build "$LLAMA_DIR/build-vulkan" --config Release --parallel "$JOBS"

command -v hipcc >/dev/null || {
    echo "hipcc is missing; install ROCm 7.14 first." >&2
    exit 1
}
cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build-hip" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DGGML_HIP=ON
cmake --build "$LLAMA_DIR/build-hip" --config Release --parallel "$JOBS"

for backend in cpu vulkan hip; do
    for executable in llama-cli llama-server; do
        path="$LLAMA_DIR/build-$backend/bin/$executable"
        [[ -x "$path" ]] || {
            echo "Missing executable: $path" >&2
            exit 1
        }
    done
done

model=""
if [[ -f "$VALIDATION_DIR" ]]; then
    model="$VALIDATION_DIR"
elif [[ -d "$VALIDATION_DIR" ]]; then
    model=$(find "$VALIDATION_DIR" -maxdepth 1 -type f -name '*.gguf' -print -quit)
fi

if [[ -n "$model" ]]; then
    "$LLAMA_DIR/build-cpu/bin/llama-cli" \
        -m "$model" -p "Reply with the word OK." -n 8 -ngl 0
else
    echo "No validation GGUF found under $VALIDATION_DIR; skipping CPU smoke test."
fi

echo "CPU, Vulkan, and HIP builds completed. Benchmark combinations manually."
