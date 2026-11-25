# ALFRED setup: Windows, WSL2, ROCm/CUDA and llama.cpp

ALFRED provides two entry points:

- scripts/alfred.ps1 — Windows host and WSL orchestration.
- scripts/alfred.sh — Linux-side WSL, ROCm/CUDA, model and llama.cpp setup.

The PowerShell entry point transfers the Linux script into a temporary file inside WSL and removes it after the stage exits. This keeps stdin available for interactive confirmation and sudo password prompts. It also avoids relying on a Windows-mounted path after isolation disables drive automount and Windows interop.

## Prerequisites

- Windows 11 with WSL2 support.
- Ubuntu 24.04 WSL distribution.
- For AMD, a GPU supported by the selected ROCm WSL configuration and a compatible AMD Adrenalin WSL driver. For NVIDIA, an RTX/GeForce GPU whose existing Windows driver exposes CUDA to WSL2. ALFRED never installs an NVIDIA driver.
- Internet access and enough disk space for ROCm, build outputs, and model files. The Qwen3.6 27B Q4_K_M model is approximately 20 GB.
- Review all scripts before running them. Linux package installation and system configuration use sudo.

Install the AMD Windows driver manually from the release appropriate for your GPU. Reboot if its installer requests it. ALFRED does not attempt to install Windows graphics drivers.

## Recommended one-command AMD setup

**This end-to-end `all` stage is ROCm-oriented. Do not run it on an NVIDIA-only work PC:** it installs the AMD ROCm stack. Use the CUDA-specific sequence below instead.

Open PowerShell as Administrator in the repository root and run:

    .\scripts\alfred.ps1 -Stage all

The first run enables the WSL Windows features, updates WSL, sets WSL 2 as the default, and installs Ubuntu 24.04 if it is not already present. If Ubuntu was newly installed, launch it once with wsl -d Ubuntu-24.04, create your Linux username and password, then rerun the ALFRED command.

For an existing Ubuntu 24.04 distro, the all stage:

1. Applies the WSL isolation configuration and backs up an existing /etc/wsl.conf.
2. Shuts WSL down and restarts the distro so the configuration takes effect.
3. Verifies WSL, systemd, disabled Windows interop/automount, and /dev/dxg.
4. Installs the ROCm 7.14 Core SDK and the ROCDXG plus AMD SMI WSL packages.
5. Installs build dependencies, pins llama.cpp, and downloads validation and production GGUF models.
6. Builds CPU and Vulkan, plus HIP and/or CUDA when their compilers are installed, then runs a CPU smoke test.

The initial setup can take a long time. The production model download is large.

## Individual stages

Run these from Windows PowerShell in the repository root:

- .\scripts\alfred.ps1 -Stage host — Windows features, WSL update and Ubuntu provisioning only.
- .\scripts\alfred.ps1 -Stage configure — write /etc/wsl.conf; then run wsl --shutdown manually.
- .\scripts\alfred.ps1 -Stage detect — report WSL GPU visibility and installed HIP/CUDA toolchains.
- .\scripts\alfred.ps1 -Stage verify — validate the WSL environment.
- .\scripts\alfred.ps1 -Stage install — install ROCm 7.14 and ROCDXG/AMD SMI.
- .\scripts\alfred.ps1 -Stage install-cuda — install a driver-compatible CUDA toolkit only; it never installs or changes an NVIDIA driver.
- .\scripts\alfred.ps1 -Stage prepare — install tools, pin llama.cpp and download models.
- .\scripts\alfred.ps1 -Stage build — build CPU and Vulkan, plus HIP and/or CUDA when their compilers are installed.
- .\scripts\alfred.ps1 -Stage serve — launch the configured inference server.

Linux stages can also be run directly from a clone stored inside the WSL filesystem, for example ~/src/alfred:

    bash scripts/alfred.sh configure
    # From Windows: wsl --shutdown
    bash scripts/alfred.sh all

Do not store the working clone only on a Windows drive if you intend to run the Linux script directly after applying the isolation configuration.

### Using supplied installation files (offline alternatives)

All supplied files are staged inside Ubuntu at:

    ~/alfred-supplied/

Copy them into that directory before running the corresponding stage. The switches below select local media instead of fetching the corresponding model/source/installer from the internet. They do not silently fall back to downloads: if the expected file is missing or unsuitable, ALFRED stops with an error.

**Models — `-UseSuppliedModels`**

The required production GGUF must be:

    ~/models/Qwen3.6-27B-GGUF/Qwen3.6-27B-Q4_K_M.gguf

The optional validation GGUF may be placed at:

    ~/models/Qwen2.5-1.5B-Instruct-GGUF/qwen2.5-1.5b-instruct-q4_k_m.gguf

Run:

    .\scripts\alfred.ps1 -Stage prepare -UseSuppliedModels

This skips Hugging Face CLI installation and both model downloads. If the optional validation model is absent, build-time inference smoke tests are skipped.

**llama.cpp source — `-UseSuppliedInstallLlama`**

Supply a Git bundle named exactly:

    ~/alfred-supplied/llama.cpp.bundle

Create it on a machine with internet access from a llama.cpp checkout that contains ALFRED's pinned commit:

    git fetch origin bec4772f6a2527d371557b5d2032641e5ff7619c
    git bundle create llama.cpp.bundle bec4772f6a2527d371557b5d2032641e5ff7619c

Copy `llama.cpp.bundle` into `~/alfred-supplied/`, then run:

    .\scripts\alfred.ps1 -Stage prepare -UseSuppliedInstallLlama

ALFRED clones from the local bundle and verifies that the exact pinned commit is present before checking it out. This avoids relying on a possibly newer source snapshot and keeps the build reproducible.

**CUDA Toolkit — `-UseSuppliedInstallCUDAToolkit`**

Download NVIDIA's **Ubuntu 24.04 x86_64 local-repository installer** on a machine with internet access. It is the large `cuda-repo-ubuntu2404-*-local_*.deb` package (not the small network-repository keyring package). Copy exactly one such file into:

    ~/alfred-supplied/

Then run:

    .\scripts\alfred.ps1 -Stage install-cuda -UseSuppliedInstallCUDAToolkit

ALFRED installs that local repository package, refreshes APT metadata from the local repository only, and installs the driver-compatible `cuda-toolkit-X-Y` package with APT downloads disabled. It will not install a Linux NVIDIA driver. The local repository must contain the toolkit version selected for the Windows host driver, and any OS-level dependencies not included in the local repository must already be installed/cached. If they are missing, installation fails rather than reaching out to the internet.

**Combining the options**

The switches apply to their respective stages. For a fully staged NVIDIA setup, run:

    .\scripts\alfred.ps1 -Stage install-cuda -UseSuppliedInstallCUDAToolkit
    .\scripts\alfred.ps1 -Stage prepare -UseSuppliedInstallLlama -UseSuppliedModels
    .\scripts\alfred.ps1 -Stage build

For direct execution inside WSL, the equivalent environment variables are:

    USE_SUPPLIED_MODELS=1 bash scripts/alfred.sh prepare
    USE_SUPPLIED_INSTALL_LLAMA=1 bash scripts/alfred.sh prepare
    USE_SUPPLIED_INSTALL_CUDA_TOOLKIT=1 bash scripts/alfred.sh install-cuda

The supplied media only replaces the corresponding model/source/CUDA-repository download. The prepare stage still installs Ubuntu build dependencies using APT, and a completely air-gapped machine also needs those OS packages supplied or already installed. The NVIDIA local repository installer may not contain every Ubuntu dependency required by the toolkit. This is therefore offline media support for these three components, not a claim that every ALFRED stage is fully air-gapped.

## WSL isolation behaviour

The ALFRED configuration sets:

- automount.enabled = false
- boot.systemd = true
- interop.enabled = false
- interop.appendWindowsPath = false
- the current Linux user as the default user

This intentionally disables /mnt/c automount and Windows executable interop for this Ubuntu distro. It does not unregister, reset, or delete any WSL distribution. It does not change Windows TDR registry settings. An existing /etc/wsl.conf is backed up before replacement.

## NVIDIA CUDA on WSL2

CUDA is an optional backend for machines whose existing Windows NVIDIA driver exposes the GPU to WSL2. Start by detecting what WSL can see:

    .\scripts\alfred.ps1 -Stage detect

For a CUDA-capable NVIDIA work PC, use this sequence:

    .\scripts\alfred.ps1 -Stage install-cuda
    .\scripts\alfred.ps1 -Stage prepare
    .\scripts\alfred.ps1 -Stage build

The CUDA installer reads the driver version reported by the WSL-visible `nvidia-smi`, then selects a compatible toolkit package. It installs an explicit `cuda-toolkit-X-Y` package from NVIDIA's Ubuntu 24.04 repository. It deliberately does **not** install `cuda`, `cuda-drivers`, `nvidia-open`, or any Linux NVIDIA display driver. The Windows driver remains the only GPU driver. If the detected driver is too old for ALFRED's supported toolkit choices, installation stops without attempting a driver update.

To launch the CUDA server, the default `BACKEND=auto` selects CUDA when a CUDA build and NVIDIA GPU are visible, then HIP, Vulkan, or CPU. To force CUDA when running the Linux script directly inside WSL:

    BACKEND=cuda bash scripts/alfred.sh serve

Windows PowerShell environment variables are not forwarded into the isolated WSL environment by the orchestration script. CUDA and HIP use independent `build-cuda` and `build-hip` directories.

NVIDIA references:

- CUDA on WSL User Guide: https://docs.nvidia.com/cuda/wsl-user-guide/
- CUDA Toolkit release notes and driver compatibility: https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/
- CUDA Toolkit installation guide: https://docs.nvidia.com/cuda/cuda-installation-guide-linux/

## ROCm 7.14 audit notes

The ROCm 7.2 Radeon-on-WSL guide used the amdgpu-install package and the wsl,rocm use case. ROCm 7.14 moved to unified installation documentation. For Ubuntu 24.04, the 7.14 package-manager instructions use the multi-architecture ubuntu2404 repository and the amdrocm-core-sdk7.14 meta-package. The WSL section separately installs rocdxg-roct and rocdxg-amd-smi-lib 1.2.1 packages. ALFRED follows the 7.14 instructions rather than carrying forward the older 7.2 installer flow.

References:

- AMD ROCm 7.14.0 install guide: https://rocm.docs.amd.com/en/docs-7.14.0/install/rocm.html
- AMD ROCm 7.2 Radeon WSL install guide: https://rocm.docs.amd.com/projects/radeon-ryzen/en/docs-7.2/docs/install/installrad/wsl/install-radeon.html
- ROCDXG project: https://github.com/ROCm/librocdxg
- llama.cpp pinned commit: https://github.com/ggml-org/llama.cpp/commit/bec4772f6a2527d371557b5d2032641e5ff7619c

## Paths, models and configuration

Defaults:

- llama.cpp: $HOME/src/llama.cpp
- Models: $HOME/models
- Builds: build-cpu, build-vulkan, build-hip, build-cuda
- Validation model: Qwen2.5 1.5B Instruct, Q4_K_M
- Production model: ggml-org/Qwen3.6-27B-GGUF, Q4_K_M

To override these defaults, edit the assignments near the top of alfred.sh, or export the variables when running alfred.sh directly from a clone inside WSL. Windows PowerShell environment variables are not automatically forwarded into the isolated Linux environment:

- LLAMA_DIR
- MODEL_DIR
- JOBS (defaults to 4 build jobs)
- BACKEND (auto, cuda, hip, vulkan, or cpu; defaults to auto)
- MODEL_PATH
- HOST (defaults to 127.0.0.1)
- PORT (defaults to 8080)
- CTX_SIZE (defaults to 32768)
- GPU_LAYERS

The server binds to localhost by default. Set HOST=0.0.0.0 only if you intentionally want to expose it to other machines on your network and have configured suitable firewall/access controls.

To test the API from Windows:

    curl.exe http://localhost:8080/v1/models

Stop the server with Ctrl+C in the PowerShell/WSL terminal.

## Troubleshooting and scope

- If /dev/dxg is absent, verify WSL2 and the relevant Windows GPU driver before attempting GPU setup.
- If nvidia-smi is unavailable in WSL, ALFRED cannot use the Windows NVIDIA driver; contact IT rather than installing a Linux driver.
- If CUDA installation stops because the driver is too old, ALFRED intentionally leaves the managed Windows driver untouched.
- If rocminfo cannot enumerate the GPU, check the supported GPU/driver matrix and the ROCDXG installation.
- If HIP configuration fails, confirm hipcc is on PATH and that the installed ROCm SDK supports your GPU architecture.
- If Vulkan is unavailable at runtime, verify WSL Vulkan support with vulkaninfo --summary; successful compilation alone does not prove GPU execution.
- The 27B model and 32768-token context can exceed available RAM/VRAM. Reduce CTX_SIZE, GPU_LAYERS, or choose a smaller GGUF if necessary.
- Historical crash traces, failed experiments and Windows TDR registry workarounds from the older guide are troubleshooting history, not automated setup actions.
