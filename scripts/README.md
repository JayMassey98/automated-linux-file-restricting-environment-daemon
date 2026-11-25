# ALFRED setup: Windows, WSL2, ROCm/CUDA and llama.cpp

ALFRED provides two entry points:

- scripts/alfred.ps1 — Windows host and WSL orchestration.
- scripts/alfred.sh — Linux-side WSL, ROCm/CUDA, model and llama.cpp setup.

The PowerShell entry point transfers the Linux script into a temporary file inside WSL and removes it after the stage exits. This keeps stdin available for interactive confirmation and sudo password prompts. It also avoids relying on a Windows-mounted path after isolation disables drive automount and Windows interop.

## Prerequisites

- Windows 10 or Windows 11 with WSL2 support. Network-isolation capabilities differ by Windows version; see the network audit and isolation design notes below.
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
- `.\scripts\alfred.ps1 -Stage audit-network` — read-only Windows/WSL networking and Hyper-V firewall inventory; it changes nothing.
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

**CUDA Toolkit — `-UseSuppliedInstallCUDAToolkit` (NVIDIA WSL repository)**

For WSL, use NVIDIA's **WSL-Ubuntu repository**, not the ordinary `ubuntu2404` repository. NVIDIA's CUDA 12.8 installation guide has a separate WSL local-repository procedure and requires enrolling the repository's GPG keyring. ALFRED follows that WSL-specific path.

For the current managed NVIDIA workstation (Ubuntu 24.04.5 amd64, WSL-visible driver 573.76), ALFRED selects `cuda-toolkit-12-8`. On an internet-connected **Ubuntu 24.04.5 amd64 staging environment with a clean base matching the target**, prepare these files:

1. From the NVIDIA CUDA 12.8 archive, select **WSL-Ubuntu**, **x86_64**, **12.8.0**, **deb (local)** and download the local repository installer named:

       cuda-repo-wsl-ubuntu-12-8-local_12.8.0-1_amd64.deb

2. Download NVIDIA's WSL repository pin file:

       https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-wsl-ubuntu.pin

3. Install the local repository on the connected staging environment, enroll its keyring and pin file, then download the complete APT dependency set:

       mkdir -p ~/alfred-cuda-staging/cuda-deps
       cd ~/alfred-cuda-staging
       wget https://developer.download.nvidia.com/compute/cuda/12.8.0/local_installers/cuda-repo-wsl-ubuntu-12-8-local_12.8.0-1_amd64.deb
       wget https://developer.download.nvidia.com/compute/cuda/repos/wsl-ubuntu/x86_64/cuda-wsl-ubuntu.pin
       sudo dpkg -i cuda-repo-wsl-ubuntu-12-8-local_12.8.0-1_amd64.deb
       sudo cp /var/cuda-repo-wsl-ubuntu-12-8-local/cuda-*-keyring.gpg /usr/share/keyrings/
       sudo install -D -m 0644 cuda-wsl-ubuntu.pin /etc/apt/preferences.d/cuda-repository-pin-600
       sudo apt-get update
       sudo apt-get install --download-only --no-install-recommends cuda-toolkit-12-8
       sudo cp /var/cache/apt/archives/*.deb ~/alfred-cuda-staging/cuda-deps/
       sudo chown -R "$USER":"$USER" ~/alfred-cuda-staging

The staging environment must match the target Ubuntu release/architecture and should be a clean base with no additional development or CUDA packages preinstalled; APT does not download packages it already considers installed. If the staging environment is more fully provisioned than the target, its download cache may omit dependencies the target needs.

Transfer the following into the target WSL user's `~/alfred-supplied/` directory, preserving the directory structure:

    ~/alfred-supplied/
      cuda-repo-wsl-ubuntu-12-8-local_12.8.0-1_amd64.deb
      cuda-wsl-ubuntu.pin
      cuda-deps/
        (all downloaded .deb dependency files)

On the offline Work PC, run:

    .\scripts\alfred.ps1 -Stage install-cuda -UseSuppliedInstallCUDAToolkit

ALFRED installs the WSL local-repository package, enrolls the bundled GPG keyring, installs the bundled pin file, refreshes APT metadata from that local repository only, and prints the simulated toolkit transaction using the supplied dependency .debs. It rejects recognised NVIDIA driver and kernel-module packages. It then asks for explicit confirmation before installation. Review the complete `Inst` list and answer `y` only if it contains toolkit/runtime development components and no driver packages. The final install uses `--no-download` and the supplied .debs; it does not contact Ubuntu or NVIDIA repositories. If the staged dependency set is incomplete or incompatible, APT must fail rather than download missing packages. ALFRED never installs a Linux NVIDIA display driver or changes the Windows host driver.

**Ubuntu build dependencies — `-UseSuppliedInstallUbuntuBuildDependencies`**

This supplies the complete Ubuntu package set needed by the prepare stage. On a **clean Ubuntu 24.04 amd64** staging machine with internet access, run:

    sudo apt-get update
    sudo apt-get clean
    sudo apt-get install --download-only -y build-essential cmake ninja-build git pkg-config libcurl4-openssl-dev libvulkan-dev mesa-vulkan-drivers vulkan-tools glslc pipx python3-venv
    mkdir -p ~/alfred-supplied/ubuntu-build-deps
    sudo cp /var/cache/apt/archives/*.deb ~/alfred-supplied/ubuntu-build-deps/
    sudo chown -R "$USER":"$USER" ~/alfred-supplied/ubuntu-build-deps

Copy the entire `ubuntu-build-deps` directory into the target WSL user's `~/alfred-supplied/` directory. Include the complete set of downloaded .deb files; do not copy only the top-level packages. The command above includes `pipx` and `python3-venv` for the normal online-model/Hugging Face path. If you will always use `-UseSuppliedModels`, those two packages are not needed, but including them is harmless.

Run:

    .\scripts\alfred.ps1 -Stage prepare -UseSuppliedInstallUbuntuBuildDependencies

ALFRED passes the supplied .deb files directly to APT with `--no-download`. APT resolves dependencies using the supplied files and packages already installed in Ubuntu. If a required dependency is missing, the stage stops instead of attempting an internet download.

**Combining the options**

For a staged NVIDIA work PC with all four offline alternatives:

    .\scripts\alfred.ps1 -Stage install-cuda -UseSuppliedInstallCUDAToolkit
    .\scripts\alfred.ps1 -Stage prepare -UseSuppliedInstallLlama -UseSuppliedModels -UseSuppliedInstallUbuntuBuildDependencies
    .\scripts\alfred.ps1 -Stage build

For direct execution inside WSL, the equivalent environment variables are:

    USE_SUPPLIED_MODELS=1 bash scripts/alfred.sh prepare
    USE_SUPPLIED_INSTALL_LLAMA=1 bash scripts/alfred.sh prepare
    USE_SUPPLIED_INSTALL_UBUNTU_BUILD_DEPENDENCIES=1 bash scripts/alfred.sh prepare
    USE_SUPPLIED_INSTALL_CUDA_TOOLKIT=1 bash scripts/alfred.sh install-cuda

The Ubuntu dependency bundle should be prepared for Ubuntu 24.04 amd64. APT will not download missing packages in supplied mode, but packages already installed on the target system can satisfy dependencies. The supplied bundle replaces the prepare-stage Ubuntu build-dependency installation only; it does not supply ROCm packages, CUDA repository packages, WSL itself, or other system dependencies used by separate stages.

## WSL isolation behaviour

The ALFRED configuration sets:

- automount.enabled = false
- boot.systemd = true
- interop.enabled = false
- interop.appendWindowsPath = false
- the current Linux user as the default user

This intentionally disables /mnt/c automount and Windows executable interop for this Ubuntu distro. It does not unregister, reset, or delete any WSL distribution. It does not change Windows TDR registry settings. An existing /etc/wsl.conf is backed up before replacement.

### Read-only offline network verification

The Linux-side network check is available inside WSL:

    bash scripts/alfred.sh verify-network

It checks that Linux has no non-loopback IP addresses and no IPv4 or IPv6 default route. It requires iproute2.

The Windows-side read-only audit is available from PowerShell (firewall query permissions may vary):

    .\scripts\alfred.ps1 -Stage audit-network

It reports WSL version/status and distributions, the `.wslconfig` file and SHA256, WSL policy registry indicators, registered Hyper-V VM creators, WSL Hyper-V VM settings from ActiveStore and PersistentStore, active Hyper-V profiles, and WSL-specific Hyper-V firewall rules. It reports which Hyper-V firewall query cmdlets are available on the current Windows installation. These cmdlets and WSL `networkingMode=none` are documented for Windows 11 22H2 and later; their absence on Windows 10 is expected and does not make Windows 10 unusable for ALFRED. It does not change files, registry values, firewall policy, or WSL state. Query failures are reported as warnings rather than treated as proof that a control is absent.

The audit is inventory only: `.wslconfig` contents do not prove the effective runtime mode, registry inspection cannot prove that all GPO/MDM policy is absent, and rule/profile output still requires review for explicit allow rules and policy merges. It does not test packet reachability or prove an air gap.

Offline/online mode switching is not implemented. Do not assume that this check enables isolation or changes firewall settings. **Windows 10 is supported for normal ALFRED operation**, including WSL2 setup, supported GPU compute, builds, model execution, and workflows using locally staged assets. Windows 10 users do not need managed network isolation for everyday use. ALFRED's first planned isolation provider targets Windows 11 22H2+ and documented WSL/Hyper-V firewall controls; that provider is still design work and is not yet implemented. Windows 10 managed per-WSL isolation is an optional future capability, not a prerequisite for Windows 10 support. The Windows 11 controls cannot be assumed on Windows 10, and ALFRED must not weaken host firewall policy or claim parity through unverified workarounds. A future platform provider must be capability-detected, preserve enterprise policy, share a common verification contract, and fail closed if its controls cannot be proven. A successful Linux-side result is only a runtime check, not a formal air gap or protection against a privileged/compromised Windows host. Do not infer isolation from a failed ping or a refused connection to a closed port.

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


### Managed NVIDIA workstations: use the existing Windows driver

ALFRED must use the NVIDIA driver already installed and managed on the Windows host. **Do not install, update, replace, or sideload a Windows NVIDIA driver, and do not install a Linux NVIDIA display driver inside WSL.** The Windows driver exposes the WSL GPU interface; the Linux distribution needs a compatible CUDA Toolkit only when compiling CUDA applications.

After you have installed WSL and Ubuntu yourself, and completed Ubuntu first-run setup, use the read-only detection stage first:

    .\scripts\alfred.ps1 -Stage detect

Inside Ubuntu, the corresponding checks are:

    nvidia-smi
    ls -l /dev/dxg

Keep the complete nvidia-smi output, including GPU model and driver version. If nvidia-smi cannot enumerate the GPU or /dev/dxg is absent, stop and contact IT. Do not try to repair this by installing a Linux driver or changing the managed Windows driver.

Only after the existing host driver is visible should you consider:

    .\scripts\alfred.ps1 -Stage install-cuda

The CUDA installer selects from ALFRED's currently supported toolkit versions using the driver version reported inside WSL. It installs a CUDA Toolkit package, not a Windows or Linux GPU driver. Before either online or supplied-media installation, ALFRED simulates the APT transaction and refuses to proceed if the proposed package transaction contains recognised NVIDIA driver packages. This is an additional safeguard, not a substitute for reviewing package changes; if APT proposes any driver, kernel-module, or host integration package, stop and ask IT.

The toolkit compatibility table is deliberately conservative and must be revisited against the exact driver version and current NVIDIA release notes when the workstation is ready. Do not infer the work PC's GPU model or compatible toolkit from “mobile RTX 4000-series” alone. The actual WSL-reported driver version is required.

Official references:
- [NVIDIA CUDA on WSL User Guide](https://docs.nvidia.com/cuda/wsl-user-guide/) — Windows driver provides WSL GPU support; do not install a Linux display driver.
- [CUDA Toolkit release notes](https://docs.nvidia.com/cuda/cuda-toolkit-release-notes/) — minimum driver compatibility is toolkit-release-specific.


### Windows-side NVIDIA inventory (works before WSL is installed)

The Windows `preflight-network` stage now includes a read-only NVIDIA inventory. It queries Windows Plug and Play driver metadata and display-adapter metadata, then checks the standard NVIDIA NVSMI executable location. If it finds an executable with a valid Authenticode signature attributable to NVIDIA, it runs read-only `nvidia-smi` queries for GPU name, driver version, and current driver model.

Run from ordinary PowerShell:

    .\scripts\alfred.ps1 -Stage preflight-network

This works without a WSL distribution. It does not download or install `nvidia-smi`, install/update a driver, change GPU mode, or modify the device. If the NVIDIA utility is absent or its signature/query cannot be validated, the result is UNKNOWN; ALFRED does not try to repair it.

NVIDIA documents WSL CUDA GPU acceleration for GPUs using the WDDM driver model; TCC mode is not supported for this WSL use case. The preflight therefore reports WDDM as a prerequisite signal and TCC as unsupported. A WDDM result is **not** proof that WSL GPU passthrough will work: final confirmation still requires the WSL-visible `/dev/dxg` and `nvidia-smi` checks after you install WSL and Ubuntu yourself.

References:
- [NVIDIA CUDA on WSL User Guide](https://docs.nvidia.com/cuda/wsl-user-guide/) — GPU acceleration is supported for GeForce and RTX GPUs in WDDM mode, not TCC mode.
- [NVIDIA nvidia-smi query reference](https://docs.nvidia.com/deploy/nvidia-smi/) — queryable product name and driver version.
