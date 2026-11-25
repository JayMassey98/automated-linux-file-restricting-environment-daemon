#!/usr/bin/env bash
set -Eeuo pipefail

STAGE="${1:-all}"
LLAMA_DIR="${LLAMA_DIR:-$HOME/src/llama.cpp}"
MODEL_DIR="${MODEL_DIR:-$HOME/models}"
JOBS="${JOBS:-4}"
LLAMA_PIN="bec4772f6a2527d371557b5d2032641e5ff7619c"
VALIDATION_MODEL="$MODEL_DIR/Qwen2.5-1.5B-Instruct-GGUF/qwen2.5-1.5b-instruct-q4_k_m.gguf"
PRODUCTION_MODEL_DIR="$MODEL_DIR/Qwen3.6-27B-GGUF"

log() { printf '\n[ALFRED] %s\n' "$*"; }
die() { printf '[ALFRED] ERROR: %s\n' "$*" >&2; exit 1; }
nvidia_smi_path() {
    if command -v nvidia-smi >/dev/null 2>&1; then
        command -v nvidia-smi
    elif [[ -x /usr/lib/wsl/lib/nvidia-smi ]]; then
        printf '%s\\n' /usr/lib/wsl/lib/nvidia-smi
    else
        return 1
    fi
}

detect_hardware() {
    require_wsl_user
    log "WSL GPU and backend detection"
    [[ -e /dev/dxg ]] && log "WSL GPU device /dev/dxg is present." || log "WARNING: /dev/dxg is absent."
    local smi
    if smi="$(nvidia_smi_path)"; then
        log "NVIDIA utility: $smi"
        "$smi" -L || log "WARNING: NVIDIA GPU enumeration failed."
        "$smi" --query-gpu=name,driver_version --format=csv,noheader || true
    else
        log "No NVIDIA nvidia-smi utility found in WSL."
    fi
    command -v nvcc >/dev/null 2>&1 && nvcc --version || log "CUDA toolkit not installed."
    command -v hipcc >/dev/null 2>&1 && log "HIP compiler: $(command -v hipcc)" || log "HIP compiler not installed."
}


require_wsl_user() {
    grep -qi microsoft /proc/version || die "Run this script inside WSL2."
    [[ "$EUID" -ne 0 ]] || die "Run as your normal Linux user; ALFRED uses sudo when required."
    [[ -f /etc/os-release ]] || die "Cannot identify the Linux distribution."
    . /etc/os-release
    [[ "$ID" == ubuntu && "$VERSION_ID" == "24.04" ]] || die "Ubuntu 24.04 is required; detected $PRETTY_NAME."
    [[ "$(dpkg --print-architecture)" == amd64 ]] || die "This setup currently supports amd64 only."
}

configure_wsl() {
    require_wsl_user
    local tmp
    tmp="$(mktemp)"
    cat >"$tmp" <<EOF
[automount]
enabled = false

[boot]
systemd = true

[interop]
enabled = false
appendWindowsPath = false

[user]
default = $USER
EOF
    if [[ -f /etc/wsl.conf ]] && cmp -s "$tmp" /etc/wsl.conf; then
        rm -f "$tmp"
        log "/etc/wsl.conf already matches the ALFRED isolation configuration."
        return
    fi
    log "The following configuration will replace /etc/wsl.conf:"
    cat "$tmp"
    printf '\nThis disables Windows-drive automount and Windows interop for this distro.\n'
    read -r -p "Apply it? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { rm -f "$tmp"; log "No changes made."; return; }
    if [[ -f /etc/wsl.conf ]]; then
        sudo cp -a /etc/wsl.conf "/etc/wsl.conf.alfred-backup.$(date +%Y%m%d%H%M%S)"
    fi
    sudo install -o root -g root -m 0644 "$tmp" /etc/wsl.conf
    rm -f "$tmp"
    log "Wrote /etc/wsl.conf. Exit WSL and run 'wsl --shutdown' from Windows before continuing."
}

verify_environment() {
    require_wsl_user
    local failures=0 state
    check() {
        local label="$1"
        shift
        if "$@"; then printf '[OK]   %s\n' "$label"
        else printf '[FAIL] %s\n' "$label"; failures=$((failures + 1))
        fi
    }
    state="$(systemctl is-system-running 2>/dev/null || true)"
    check "systemd is active" bash -c '[[ "$1" == running || "$1" == degraded ]]' _ "$state"
    check "Windows interop paths are absent from PATH" bash -c '! grep -Eqi "WindowsApps|/mnt/[a-z]/Windows|/System32" <<<"$1"' _ "$PATH"
    check "Windows C: drive is not automounted" bash -c '[[ ! -d /mnt/c/Windows ]]'
    check "WSL GPU device /dev/dxg exists" test -e /dev/dxg
    if [[ ! -r /etc/wsl.conf ]] ||
       ! grep -q 'enabled = false' /etc/wsl.conf ||
       ! grep -q 'systemd = true' /etc/wsl.conf ||
       ! grep -q 'appendWindowsPath = false' /etc/wsl.conf ||
       ! grep -q "default = $USER" /etc/wsl.conf; then
        printf '[FAIL] /etc/wsl.conf does not contain the expected ALFRED settings\n'
        failures=$((failures + 1))
    else
        printf '[OK]   /etc/wsl.conf contains the expected ALFRED settings\n'
    fi
    if (( failures > 0 )); then die "$failures required environment check(s) failed."; fi
    log "WSL environment checks passed."
}


install_cuda() {
    require_wsl_user
    [[ -e /dev/dxg ]] || die "WSL GPU device /dev/dxg is missing. Check WSL2 and the existing Windows NVIDIA driver."
    local smi driver package tmpdir
    smi="$(nvidia_smi_path)" || die "nvidia-smi is unavailable in WSL. ALFRED will not install a Linux NVIDIA driver."
    "$smi" -L >/dev/null 2>&1 || die "The Windows NVIDIA driver is not exposing a usable GPU to WSL."
    driver="$("$smi" --query-gpu=driver_version --format=csv,noheader | head -n 1 | tr -d '[:space:]')"
    [[ "$driver" =~ ^[0-9]+\.[0-9]+ ]] || die "Could not parse NVIDIA driver version: $driver"
    log "Detected Windows NVIDIA driver $driver through WSL."
    if [[ "$(printf '%s\\n' "$driver" "576.57" | sort -V | head -n1)" == "576.57" ]]; then
        package="cuda-toolkit-12-9"
    elif [[ "$(printf '%s\\n' "$driver" "570.26" | sort -V | head -n1)" == "570.26" ]]; then
        package="cuda-toolkit-12-8"
    elif [[ "$(printf '%s\\n' "$driver" "560.76" | sort -V | head -n1)" == "560.76" ]]; then
        package="cuda-toolkit-12-6"
    elif [[ "$(printf '%s\\n' "$driver" "551.61" | sort -V | head -n1)" == "551.61" ]]; then
        package="cuda-toolkit-12-4"
    else
        die "Driver $driver is below ALFRED's supported automatic toolkit floor. No driver update will be attempted; contact IT or use CPU/Vulkan."
    fi
    log "Installing $package only. No Linux NVIDIA driver package will be installed."
    sudo apt-get update
    sudo apt-get install -y ca-certificates wget
    tmpdir="$(mktemp -d)"
    wget -q https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb -O "$tmpdir/cuda-keyring.deb"
    sudo dpkg -i "$tmpdir/cuda-keyring.deb"
    rm -rf "$tmpdir"
    sudo apt-get update
    sudo apt-get install -y "$package"
    for cuda_bin in /usr/local/cuda/bin /usr/local/cuda-*/bin; do
        if [[ -x "$cuda_bin/nvcc" ]]; then export PATH="$cuda_bin:$PATH"; break; fi
    done
    command -v nvcc >/dev/null || die "CUDA toolkit installed but nvcc is not on PATH."
    nvcc --version
    "$smi" -L
    log "CUDA toolkit ready. Windows host driver was not modified."
}

install_rocm() {
    require_wsl_user
    log "Installing ROCm 7.14 Core SDK and documented WSL ROCDXG packages."
    sudo apt-get update
    sudo apt-get install -y ca-certificates wget gpg
    sudo install -d -m 0755 /etc/apt/keyrings
    wget -qO- https://repo.amd.com/rocm/packages-multi-arch/gpg/rocm.gpg \
        | gpg --dearmor \
        | sudo tee /etc/apt/keyrings/amdrocm.gpg >/dev/null
    printf '%s\n' 'deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://repo.amd.com/rocm/packages-multi-arch/ubuntu2404 stable main' \
        | sudo tee /etc/apt/sources.list.d/rocm.list >/dev/null
    sudo apt-get update
    sudo apt-get install -y amdrocm-core-sdk7.14

    local tmpdir
    tmpdir="$(mktemp -d)"
    wget -q https://github.com/ROCm/librocdxg/releases/download/v1.2.1/rocdxg-roct_1.2.1_amd64.deb \
        -O "$tmpdir/rocdxg-roct_1.2.1_amd64.deb"
    wget -q https://github.com/ROCm/librocdxg/releases/download/v1.2.1/rocdxg-amd-smi-lib_1.2.1_amd64.deb \
        -O "$tmpdir/rocdxg-amd-smi-lib_1.2.1_amd64.deb"
    sudo apt-get install -y python3-pip python3-wheel python3-argcomplete
    sudo apt-get install -y "$tmpdir/rocdxg-roct_1.2.1_amd64.deb" "$tmpdir/rocdxg-amd-smi-lib_1.2.1_amd64.deb"
    if [[ -f /etc/profile.d/rocdxg-amd-smi-lib.sh ]]; then
        # shellcheck disable=SC1091
        source /etc/profile.d/rocdxg-amd-smi-lib.sh
    fi
    for rocm_bin in /opt/rocm/bin /opt/rocm-7.14*/bin; do
        if [[ -x "$rocm_bin/hipcc" ]]; then export PATH="$rocm_bin:$PATH"; break; fi
    done
    command -v hipcc >/dev/null || die "ROCm installed, but hipcc is not on PATH. Inspect the package installation and ROCm environment."
    hipcc --version
    if command -v rocminfo >/dev/null; then
        rocminfo | grep -E 'Name:|gfx[0-9]+' | head -n 40 || true
    else
        log "rocminfo was not found; GPU runtime discovery still needs checking."
    fi
    rm -rf "$tmpdir"
    log "ROCm 7.14 and ROCDXG package installation completed."
}

prepare_llama() {
    require_wsl_user
    log "Installing build tools and Hugging Face CLI."
    sudo apt-get update
    sudo apt-get install -y build-essential cmake ninja-build git pkg-config libcurl4-openssl-dev \
        libvulkan-dev mesa-vulkan-drivers vulkan-tools glslc pipx python3-venv
    export PATH="$HOME/.local/bin:$PATH"
    if ! command -v hf >/dev/null 2>&1; then
        pipx install huggingface_hub
        export PATH="$HOME/.local/bin:$PATH"
    fi
    command -v hf >/dev/null || die "Hugging Face CLI 'hf' was not found. Add ~/.local/bin to PATH and rerun."
    mkdir -p "$(dirname "$LLAMA_DIR")" "$MODEL_DIR"
    if [[ -d "$LLAMA_DIR/.git" ]]; then
        [[ -z "$(git -C "$LLAMA_DIR" status --porcelain)" ]] || die "Existing llama.cpp checkout has local changes: $LLAMA_DIR. Commit or back them up before pinning."
        git -C "$LLAMA_DIR" fetch --depth=1 origin "$LLAMA_PIN"
    elif [[ -e "$LLAMA_DIR" ]]; then
        die "$LLAMA_DIR exists but is not a Git checkout. Move it or set LLAMA_DIR to another path."
    else
        git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
        git -C "$LLAMA_DIR" fetch --depth=1 origin "$LLAMA_PIN"
    fi
    git -C "$LLAMA_DIR" checkout --detach "$LLAMA_PIN"
    [[ "$(git -C "$LLAMA_DIR" rev-parse HEAD)" == "$LLAMA_PIN" ]] || die "llama.cpp commit pin verification failed."
    log "Downloading a small CPU validation model."
    hf download Qwen/Qwen2.5-1.5B-Instruct-GGUF \
        qwen2.5-1.5b-instruct-q4_k_m.gguf \
        --local-dir "$MODEL_DIR/Qwen2.5-1.5B-Instruct-GGUF"
    log "Downloading the Qwen3.6 27B Q4_K_M production model (about 20 GB)."
    hf download ggml-org/Qwen3.6-27B-GGUF \
        Qwen3.6-27B-Q4_K_M.gguf \
        --local-dir "$PRODUCTION_MODEL_DIR"
    log "llama.cpp pinned at $LLAMA_PIN; models stored under $MODEL_DIR."
}

build_backends() {
    require_wsl_user
    [[ -d "$LLAMA_DIR/.git" ]] || die "llama.cpp not found at $LLAMA_DIR; run the prepare stage first."
    if [[ -d /usr/local/cuda/bin ]]; then export PATH="/usr/local/cuda/bin:$PATH"; fi
    for cuda_bin in /usr/local/cuda-*/bin; do
        if [[ -x "$cuda_bin/nvcc" ]]; then export PATH="$cuda_bin:$PATH"; break; fi
    done
    log "Building CPU backend."
    cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build-cpu" -G Ninja -DCMAKE_BUILD_TYPE=Release
    cmake --build "$LLAMA_DIR/build-cpu" --parallel "$JOBS"
    log "Building Vulkan backend."
    cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build-vulkan" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON
    cmake --build "$LLAMA_DIR/build-vulkan" --parallel "$JOBS"
    if command -v hipcc >/dev/null 2>&1; then
        log "Building HIP backend."
        cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build-hip" -G Ninja \
            -DCMAKE_BUILD_TYPE=Release -DGGML_HIP=ON
        cmake --build "$LLAMA_DIR/build-hip" --parallel "$JOBS"
    else
        log "HIP compiler not found; skipping HIP backend."
    fi

    if command -v nvcc >/dev/null 2>&1; then
        log "Building CUDA backend."
        cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build-cuda" -G Ninja \
            -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON
        cmake --build "$LLAMA_DIR/build-cuda" --parallel "$JOBS"
    else
        log "CUDA compiler not found; skipping CUDA backend."
    fi

    local backend executable path
    for backend in cpu vulkan; do
        for executable in llama-cli llama-server; do
            path="$LLAMA_DIR/build-$backend/bin/$executable"
            [[ -x "$path" ]] || die "Expected executable was not produced: $path"
        done
    done
    for backend in hip cuda; do
        if [[ -d "$LLAMA_DIR/build-$backend" ]]; then
            for executable in llama-cli llama-server; do
                path="$LLAMA_DIR/build-$backend/bin/$executable"
                [[ -x "$path" ]] || die "Expected executable was not produced: $path"
            done
        fi
    done
    if [[ -f "$VALIDATION_MODEL" ]]; then
        log "Running a short CPU smoke test with the validation model."
        "$LLAMA_DIR/build-cpu/bin/llama-cli" -m "$VALIDATION_MODEL" \
            -p "Reply with the word OK." -n 8 -ngl 0
    else
        log "Validation model not found; skipping CPU smoke test."
    fi
    log "Available CPU, Vulkan, HIP and CUDA builds completed."
}

launch_server() {
    require_wsl_user
    local backend server model gpu_layers host port ctx
    backend="${BACKEND:-auto}"
    if [[ "$backend" == auto ]]; then
        if [[ -x "$LLAMA_DIR/build-cuda/bin/llama-server" ]] && smi="$(nvidia_smi_path)" && "$smi" -L >/dev/null 2>&1; then
            backend=cuda
        elif [[ -x "$LLAMA_DIR/build-hip/bin/llama-server" ]] && command -v rocminfo >/dev/null 2>&1; then
            backend=hip
        elif [[ -x "$LLAMA_DIR/build-vulkan/bin/llama-server" ]]; then
            backend=vulkan
        else
            backend=cpu
        fi
        log "Automatically selected backend: $backend"
    fi
    case "$backend" in cpu|vulkan|hip|cuda) ;; *) die "BACKEND must be auto, cuda, hip, vulkan, or cpu." ;; esac
    if [[ "$backend" == cuda ]]; then
        smi="$(nvidia_smi_path)" || die "nvidia-smi is unavailable; CUDA requires the Windows host driver exposed to WSL."
        "$smi" -L >/dev/null 2>&1 || die "No usable NVIDIA GPU is visible to WSL."
    fi
    server="$LLAMA_DIR/build-$backend/bin/llama-server"
    [[ -x "$server" ]] || die "Server binary not found: $server. Run the build stage first."
    model="${MODEL_PATH:-$PRODUCTION_MODEL_DIR}"
    if [[ -d "$model" ]]; then
        model="$(find "$model" -maxdepth 1 -type f -name 'Qwen3.6-27B-Q4_K_M.gguf' -print -quit)"
    fi
    [[ -n "$model" && -f "$model" ]] || die "GGUF model not found. Set MODEL_PATH to a GGUF file or directory."
    if [[ -n "${GPU_LAYERS:-}" ]]; then gpu_layers="$GPU_LAYERS"
    elif [[ "$backend" == cpu ]]; then gpu_layers=0
    else gpu_layers=99
    fi
    host="${HOST:-127.0.0.1}"
    port="${PORT:-8080}"
    ctx="${CTX_SIZE:-32768}"
    log "Starting $backend llama-server at $host:$port."
    log "Default context is 32768 tokens. Adjust CTX_SIZE for your memory and workload."
    "$server" -m "$model" --host "$host" --port "$port" -c "$ctx" -ngl "$gpu_layers" \
        --flash-attn on --parallel 1 --cache-type-k q4_0 --cache-type-v q4_0
}

case "$STAGE" in
    configure) configure_wsl ;;
    detect) detect_hardware ;;
    verify) verify_environment ;;
    install) install_rocm ;;
    install-cuda) install_cuda ;;
    prepare) prepare_llama ;;
    build) build_backends ;;
    serve) launch_server ;;
    all)
        verify_environment
        install_rocm
        prepare_llama
        build_backends
        ;;
    *) die "Usage: alfred.sh {configure|detect|verify|install|install-cuda|prepare|build|serve|all}" ;;
esac
