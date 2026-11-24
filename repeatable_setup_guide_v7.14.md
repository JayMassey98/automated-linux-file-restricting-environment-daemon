# Qwen 3.6 on WSL2 (7900 XTX) — Repeatable Setup Guide

**What this gets you** - Qwen3.6-27B-Q4_K_S, running fully isolated from your real Windows files, served over a local OpenAI-compatible API at `http://localhost:8080`, with a ~200k token context window. Confirmed working at ~19.5 tokens/sec generation.

# 1. Prepare the Windows Host

These steps prepare the Windows host for WSL GPU workloads, which require the WSL 2 architecture.

This setup procedure was validated against the following environment:

```text
WSL version:      2.7.10.0
Kernel version:   6.18.33.2-2
WSLg version:     1.0.73.2
MSRDC version:    1.2.6676
Direct3D version: 1.611.1-81528511
DXCore version:   10.0.26100.1-240331-1435.ge-release
Windows version:  10.0.19045.7548
```

These version numbers was generated from running:

```powershell
wsl --version
```


## 1.1. Enable Required Windows Features

Run **PowerShell** as **Administrator**, then:
- Enable **Windows Subsystem for Linux**
- Enable **Virtual Machine Platform**
- Restart Windows (required to fully activate the features above)

```powershell
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
shutdown /r /t 0
```


## 1.2. Install WSL

Ensure WSL is updated to the modern Microsoft Store version:

```powershell
wsl --update
```

**Expected Output A** *(on most modern systems)*

```text
Checking for updates.
The most recent version of Windows Subsystem for Linux is already installed.
```

**Expected Output B** *(on systems migrating from WSL 1)*

```text
Downloading: Windows Subsystem for Linux
Installing: Windows Subsystem for Linux
Windows Subsystem for Linux has been installed.
```

Install the WSL framework without a Linux distribution:

```powershell
wsl --install --no-distribution
```

**Expected Output**

```text
The operation completed successfully.
```


## 1.3. Install AMD Graphics Driver

The AMD graphics driver is installed only on the Windows host; WSL does not use a separate one on Linux.

Instead, WSL GPU acceleration is provided through the Windows AMD driver exposed into Linux through the /dev/dxg virtual GPU interface.

Download and install the latest **AMD Software: Adrenalin Edition** suite from:

https://www.amd.com/en/support/download/drivers.html

This setup procedure was validated against the following environment:

```text
Target GPU:                      AMD Radeon RX 7900 XTX
AMD Software: Adrenalin Edition: 26.6.3
Windows Driver Store Version:    32.0.31021.4001
```

Verify the target GPU is detected.

Open:

```text
Device Manager
 └── Display adapters
      └── <Target GPU>
```

The target GPU should be listed cleanly without any yellow warning icons.


# 2. Install the Fresh Ubuntu Distribution

This guide requires a dedicated, clean WSL 2 distribution of Ubuntu.

This guide was validated against the following items:

```text
Ubuntu: Ubuntu-24.04
```

A previously created Ubuntu installation must **not** be reused.

Existing instances may contain stale components that break environmental reproducibility, including:

- Older ROCm / HIP packages
- Modified shell environment variables
- Cached build artifacts / custom compiler settings
- Unrelated application packages

The unregister operation only removes the WSL virtual disk; it does not remove Windows files outside the distribution.


## 2.1. Check Existing WSL Distributions

Run **PowerShell** as **Administrator** to list the current environment:

```powershell
wsl --list --verbose
```

Example output:

```text
  NAME             STATE      VERSION
* Ubuntu-24.04     Stopped    2
  docker-desktop   Stopped    2
```

Only the Ubuntu distribution created for this guide is relevant.

Do not remove unrelated distributions (such as `docker-desktop`) unless they are no longer required.


## 2.2. Remove Existing Ubuntu Installation

If an existing Ubuntu distribution exists and needs to be cleared, follow these steps.

Stop all WSL instances:

```powershell
wsl --shutdown
```

Unregister the target distribution to wipe it (assuming Ubuntu-24.04 is used):

```powershell
wsl --unregister Ubuntu-24.04
```

> **Warning**
>
> This permanently deletes the distribution, destroying all packages, configurations, and user data; it does not affect your Windows host files.

If your legacy distribution uses a different name, pass that exact string to the unregister command instead:

```powershell
wsl --unregister <distribution-name>
```

Verify that the old environment has been removed successfully:

```powershell
wsl --list --verbose
```


## 2.3. Install the Fresh Ubuntu Distribution

Update WSL:

```powershell
wsl --update
```

Install the specific target Ubuntu distribution explicitly:

```powershell
wsl --install -d Ubuntu-24.04
```

> **Note** 
>
> Do not use a bare `wsl --install` command. That installs the default fallback distribution profile (`Ubuntu`), which will not match the reproducible `Ubuntu-24.04` environment required for this guide.

After the installation completes, the Ubuntu terminal environment will launch automatically.


## 2.4. Create the Linux User Account

Upon initialization, the Ubuntu terminal will prompt you to set up your primary credentials:

```text
Create a default Unix user account:
```

Create a Linux username and password of your choosing for the local account.

Throughout this guide, replace `user` with your own username wherever it appears.

Enter your desired username, your desired password, then retype the password to confirm it.

Once complete, you will land at the Linux command prompt:

```bash
user@USERS-PC:/mnt/c/Windows/system32$
```

Exit the active Linux session to return to your administrative Windows host environment:

```bash
exit
```


## 2.5. Set the Default WSL Distribution

From your **PowerShell** window, Enforce WSL 2 as the global structural format standard:

```powershell
wsl --set-default-version 2
```

**Expected output**

```text
For information on key differences with WSL 2 please visit https://aka.ms/wsl2
The operation completed successfully.
```

Bind `Ubuntu-24.04` as the default system environment:

```powershell
wsl --set-default Ubuntu-24.04
```

**Expected output**

```text
The operation completed successfully.
```


## 2.6. Verify the Ubuntu Installation

Confirm that your distribution states and defaults are set correctly:

```powershell
wsl --list --verbose
```

**Expected output**

```text
  NAME             STATE      VERSION
* Ubuntu-24.04     Stopped    2
```

Confirm the global subsystem status:

```powershell
wsl --status
```

**Expected output**

```text
Default Distribution: Ubuntu-24.04
Default Version: 2
```


## 2.7. Verify WSL GPU Interface

Boot into your new Ubuntu environment:

```powershell
wsl -d Ubuntu-24.04
```

Check for the presence of the virtualized Direct X graphics kernel node:

```bash
ls -l /dev/dxg
```

**Expected output**

```text
crw-rw-rw- 1 root root ... /dev/dxg
```

The presence of `/dev/dxg` confirms that the host's graphics driver and the WSL kernel abstraction layer are communicating flawlessly.

This means that the Ubuntu environment is ready for ROCm installation.


# 3. Configure the WSL Isolation Boundary

This step configures Ubuntu to operate as an isolated Linux environment rather than a transparent extension of the Windows host.

The goals are:

- prevent automatic access to Windows drives
- prevent execution of Windows applications from within WSL
- prevent the Windows `PATH` from being injected into Linux
- enable `systemd`
- ensure Vulkan support works correctly
- create a predictable, reproducible environment for ROCm, llama.cpp, and future investigations

## 3.1. Create the WSL Configuration File

Inside the Ubuntu terminal, create the WSL configuration file:

```bash
sudo nano /etc/wsl.conf
```

Enter the account password.

Replace the contents with exactly the following:

```ini
[automount]
enabled = false

[boot]
systemd = true

[interop]
enabled = false
appendWindowsPath = false

[user]
default = user
```

Before saving this file, replace "default = user" with your username if it is different. Leave the `[user]` header as is.

### Explanation

- `[automount] enabled = false` disables automatic mounting of Windows drives under `/mnt`.
- `[boot] systemd = true` enables the standard Linux init system required by some tooling.
- `[interop] enabled = false` prevents Linux processes from launching Windows executables.
- `[interop] appendWindowsPath = false` prevents Windows directories from being added to the Linux `PATH`.
- `[user] default = user` sets the default Linux account created during Step 1.

Save and exit:

1. Press `Ctrl + X`
2. Press `Y`
3. Press `Enter`

From this point on, this setup guide will assume the account password never needs to be inputted again. However, by default, if 15 minutes pass without any sudo commands OR if Ubuntu is restarted, you will be asked to input the password again whenever re-authentication is required. This is just something to keep in mind when following with these steps manually.


## 3.2. Restart WSL

Exit Ubuntu:

```bash
exit
```

Noitce how it now outputs:

```text
logout
```

Instead of:

```text
exit
```

This means that the WSL VM is still running.

In the **PowerShell** window, run:

```powershell
wsl --shutdown
```

Wait several seconds for the WSL vm to stop completely.

Start Ubuntu again:

```powershell
wsl -d Ubuntu-24.04
```

The /etc/wsl.conf file is only read when the WSL virtual machine starts.

Exiting the Linux shell is insufficient because the WSL VM can remain running in the background.

A complete wsl --shutdown forces WSL to recreate the VM and apply the new configuration.

## 3.3. Validate the WSL Isolation Configuration

This step verifies that automatic access to the Windows filesystem through WSL drive mounts is disabled.

WSL may still create empty directories under `/mnt` matching the drive letters on the Windows host.

These directories are only empty placeholders and do not provide access to the Windows filesystem.

The following WSL-managed directories are expected to exist and may contain WSL runtime files:

- `/mnt/wsl`
- `/mnt/wslg`

Their contents are managed by WSL and may vary depending on the installed version.

To validate this, copy and paste the following code into Ubuntu, then run it:

> FAR-FUTURE TODO - Move this validation logic into a reusable `verify-wsl-environment.sh` script:

```bash
echo "Checking WSL environment..."

failed=0

if [ ! -d /mnt ]; then
    echo "[FAIL] /mnt does not exist"
    exit 1
fi

echo
echo "Checking WSL host drives..."

for mount in /mnt/[a-zA-Z]/; do
    if [ -d "$mount" ]; then
        if [ -n "$(ls -A "$mount" 2>/dev/null)" ]; then
            echo "[FAIL] $(basename "$mount"): unexpected contents detected"
            ls -A "$mount"
            failed=1
        else
            echo "[ OK ] $(basename "$mount"): empty"
        fi
    fi
done

echo
echo "Checking WSL runtime directories..."

for dir in /mnt/wsl /mnt/wslg; do
    if [ -d "$dir" ]; then
        echo "[ OK ] $dir exists"
    else
        echo "[FAIL] $dir not found"
        failed=1
    fi
done

echo
echo "Checking Linux PATH..."

if echo "$PATH" | grep -qE '(^|:)/mnt/[a-zA-Z]/'; then
    echo "[FAIL] Windows paths detected in PATH"
    echo "$PATH"
    failed=1
else
    echo "[ OK ] No Windows paths detected"
fi

echo
echo "Checking Windows executable interop..."

if cmd.exe /c echo test >/dev/null 2>&1; then
    echo "[FAIL] Windows executable interop is enabled"
    failed=1
else
    echo "[ OK ] Windows executable interop is disabled"
fi

echo
echo "Checking systemd..."

if systemctl --version >/dev/null 2>&1; then
    echo "[ OK ] systemd is available"
else
    echo "[FAIL] systemd is not available"
    failed=1
fi

echo
echo "Checking WSL GPU bridge..."

if [ -c /dev/dxg ]; then
    echo "[ OK ] /dev/dxg exists"
else
    echo "[FAIL] /dev/dxg not found"
    failed=1
fi

echo
echo "Checking WSL version..."

if grep -qi microsoft /proc/version; then
    echo "[ OK ] Running inside WSL"
else
    echo "[FAIL] Not running inside WSL"
    failed=1
fi

echo
if [ "$failed" -eq 0 ]; then
    echo "WSL environment checks passed."
else
    echo "WSL environment checks failed."
    echo "Review the messages above before continuing."
fi

exit $failed
```

**Expected output** (WSL host drives may vary):

```TEXT
Checking WSL environment...

Checking WSL host drives...
[ OK ] c: empty
[ OK ] d: empty
[ OK ] e: empty

Checking WSL runtime directories...
[ OK ] /mnt/wsl exists
[ OK ] /mnt/wslg exists

Checking Linux PATH...
[ OK ] No Windows paths detected

Checking Windows executable interop...
[ OK ] Windows executable interop is disabled

Checking systemd...
[ OK ] systemd is available

Checking WSL GPU bridge...
[ OK ] /dev/dxg exists

Checking WSL version...
[ OK ] Running inside WSL

WSL environment checks passed.
```


## 3.4. Verify Windows Interoperability Is Disabled

Run:

```bash
cmd.exe /c echo hello
```

Expected output:

```text
cmd.exe: command not found
```

This confirms that Windows executables cannot be launched from WSL.

## 3.5. Verify the GPU Interface Still Exists

Even with Windows interoperability disabled, the WSL GPU bridge should remain available.

Verify:

```bash
ls -l /dev/dxg
```

Expected output:

```text
crw-rw-rw- 1 root root ... /dev/dxg
```

The presence of `/dev/dxg` confirms that GPU virtualization is still operational.

Successful completion of this step confirms that:

- Windows drive access is disabled
- Windows executable interoperability is disabled
- Linux `PATH` contamination is disabled
- `systemd` is enabled
- Vulkan prerequisites are in place
- WSL GPU bridge remains available

The environment is now isolated yet fully functional for our intended purposes.


## 3.6. Update Ubuntu

Update and upgrade the package lists:

```bash
sudo apt update
sudo apt upgrade -y
```

Ubuntu is now ready for installing the ROCm GPU Compute Stack.


# 4. Install the ROCm GPU Compute Stack (ROCm Core SDK + ROCDXG)

This step installs the complete ROCm GPU compute software stack required to build and run HIP applications inside WSL2.

The stack consists of two components:

- **ROCm Core SDK 7.14.0** — Provides the HIP compiler, runtime, development headers and user-space libraries.
- **ROCDXG** — Provides the WSL GPU compute bridge that allows the ROCm runtime to communicate with the Windows AMD graphics driver through `/dev/dxg`.

Both components are required.

Installing only the ROCm Core SDK is insufficient because the HIP runtime expects the ROCDXG bridge to be present before GPU compute applications can communicate with the Windows GPU driver.

Unlike native Linux ROCm installations, WSL2 does **not** use a Linux AMD GPU kernel driver.

The Windows AMD Adrenalin Edition driver remains the authoritative GPU driver.

This version of ROCm communicates with the GPU through the WSL `/dev/dxg` interface using the ROCDXG user-space bridge.

This guide was validated using:

```text
Windows:
10

WSL:
Ubuntu-24.04

ROCm Core SDK:
7.14.0

ROCDXG:
1.2.1

GPU:
AMD Radeon RX 7900 XTX

GPU Architecture:
gfx1100
```

The completed software stack will have the following architecture:

```text
Windows AMD Adrenalin Edition Driver
        |
        v
WSL2 (/dev/dxg)
        |
        v
ROCDXG WSL GPU Compute Bridge
        |
        v
ROCm Core SDK 7.14.0
        |
        v
HIP
        |
        v
GPU Applications
```


## 4.1. Install the ROCm Core SDK

### 4.1.1. Register the AMD ROCm Repository

Create the apt keyring directory:

```bash
sudo mkdir --parents --mode=0755 /etc/apt/keyrings
```

Download and install the AMD repository signing key:

```bash
wget https://repo.amd.com/rocm/packages-multi-arch/gpg/rocm.gpg -O - | \
    gpg --dearmor | sudo tee /etc/apt/keyrings/amdrocm.gpg > /dev/null
```

Add the ROCm package repository:

```bash
sudo tee /etc/apt/sources.list.d/rocm.list << EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://repo.amd.com/rocm/packages-multi-arch/ubuntu2404 stable main
EOF
```

Update package information:

```bash
sudo apt update
```

### 4.1.2. Verify the Repository

Verify that the repository is available:

```bash
apt policy amdrocm-core-sdk7.14
```

Expected output (contents may vary):

```text
amdrocm-core-sdk7.14:
  Installed: (none)
  Candidate: 7.14.0-3
  Version table:
     7.14.0-3 500
        500 https://repo.amd.com/rocm/packages-multi-arch/ubuntu2404 stable/main amd64 Packages
```


### 4.1.3. Install the ROCm Core SDK

Install the ROCm Core SDK:

```bash
sudo apt install -y amdrocm-core-sdk7.14
```

This package provides:

- HIP compiler tooling
- ROCm headers
- ROCm runtime libraries
- Development libraries required to build HIP applications

The full SDK package is intentionally used here.

A future optimisation pass may evaluate architecture-specific packages, but the initial setup keeps the ROCm installation generic and reproducible.


### 4.1.4. Verify the ROCm Installation

Verify that the installation directory exists:

```bash
ls -la /opt/rocm
```

**Expected Result**

The directory should contain symbolic links managed by update-alternatives, together with the installed ROCm Core SDK version; something like:

```bash
amdgcn -> /etc/alternatives/rocm-amdgcn
bin -> /etc/alternatives/rocm-bin
core -> /etc/alternatives/core
core-7 -> /etc/alternatives/core-7
core-7.14
include -> /etc/alternatives/rocm-include
lib -> /etc/alternatives/rocm-lib
libexec -> /etc/alternatives/rocm-libexec
llvm -> /etc/alternatives/rocm-llvm
share -> /etc/alternatives/rocm-share
```

Verify the active ROCm installation:

```bash
ls -la /opt/rocm/core-7.14
```

**Expected Result**

The installation directory should contain the standard ROCm Core SDK layout; something like:

```bash
.info
.kpack
amdgcn -> lib/llvm/amdgcn
bin
etc
include
lib
libexec
llvm -> lib/llvm
share
```


### 4.1.5. Verify HIP Compiler Installation

Verify that the HIP compiler exists:

```bash
readlink -f $(which hipcc)
```

Expected output:

```text
/opt/rocm/core-7.14/bin/hipcc
```

At this stage, the ROCm compiler and libraries are installed, but the WSL GPU bridge is not present.

GPU runtime validation is therefore not expected to succeed until ROCDXG has been installed.


### 4.1.6. Verify ROCm Libraries

Confirm that the HIP runtime library exists:

```bash
find /opt/rocm -name "libamdhip64.so*"
```

Expected output (output may vary):

```text
/opt/rocm/core-7.14/lib/libamdhip64.so.7.14.60850-0000000
/opt/rocm/core-7.14/lib/libamdhip64.so
/opt/rocm/core-7.14/lib/libamdhip64.so.7
```


## 4.2. Install ROCDXG WSL GPU Compute Bridge

ROCDXG serves as the WSL-specific user-space bridge between the ROCm runtime and the Windows AMD graphics driver, providing the necessary communication layer for ROCm workloads running through the WSL /dev/dxg interface.

ROCDXG connects:

Windows AMD Driver
        |
        v
/dev/dxg
        |
        v
librocdxg.so
        |
        v
ROCm Runtime


### 4.2.1. Download the ROCDXG Runtime Package

Download the ROCDXG runtime package:

```bash
wget https://github.com/ROCm/librocdxg/releases/download/v1.2.1/rocdxg-roct_1.2.1_amd64.deb
```

This guide was validated with ROCDXG 1.2.1.


### 4.2.2. Install ROCDXG Runtime Package

Install the package:

```bash
sudo dpkg -i rocdxg-roct_1.2.1_amd64.deb
```

**Expected Output** *(versions may vary)*

```text
Selecting previously unselected package rocdxg-roct.
(Reading database ... 84624 files and directories currently installed.)
Preparing to unpack rocdxg-roct_1.2.1_amd64.deb ...
Unpacking rocdxg-roct (1.2.1) ...
Setting up rocdxg-roct (1.2.1) ...
Processing triggers for libc-bin (2.39-0ubuntu8.7) ...
...
```


### 4.2.3. Verify ROCDXG Installation

Confirm that the ROCDXG library exists:

```bash
find / -name "librocdxg.so*" 2>/dev/null
```

Expected output:

```text
/opt/rocm/core-7.14/lib/librocdxg.so
/opt/rocm/core-7.14/lib/librocdxg.so.1.2.1
/opt/rocm/core-7.14/lib/librocdxg.so.1
```


## 4.3. Validate the ROCm GPU Compute Environment

At this point both components are installed:

```text
ROCm Core SDK 7.14.0
+
ROCDXG 1.2.1
```


### 4.3.1. Verify GPU Visibility

Confirm the GPU is now visible to ROCm:

```bash
rocminfo | grep -A3 gfx1100
```

Expected output:

```text
  Name:                    gfx1100
  Uuid:                    GPU-4642651462a3e4ff
  Marketing Name:          AMD Radeon RX 7900 XTX
  Vendor Name:             AMD
--
      Name:                    amdgcn-amd-amdhsa--gfx1100
      Machine Models:          HSA_MACHINE_MODEL_LARGE
      Profiles:                HSA_PROFILE_BASE
      Default Rounding Mode:   NEAR
```

This confirms:

- WSL GPU passthrough is active
- The ROCDXG layer is installed and accessible
- ROCm can communicate with the GPU


### 4.3.2. Verify the HIP compiler:

Now that the ROCDXG Runtime Package is installed, `librocdxg.so` is present and will no longer be flagged as missing when querying the HIP compiler version.

Confirm the HIP compiler outputs:

```bash
hipcc --version
```

**Expected Output** *(versions may vary)*

```text
HIP version: 7.14.60850-0000000
AMD clang version 23.0.0git (https://github.com/ROCm/llvm-project.git 46fcb339fb61119b337f973c7ca9e710a319fdd0+PATCHED:440716f8b87be9d8e20ed910e10e5b6d14d57cf6)
Target: x86_64-unknown-linux-gnu
Thread model: posix
InstalledDir: /opt/rocm/core-7.14/lib/llvm/bin
```

Confirm that no `librocdxg.so` loading errors appear in the output above.


### 4.3.3. Final Installed State

At the end of this step, the WSL environment should contain:

```text
Windows 10
└── WSL2
    └── Ubuntu
        ├── ROCm Core SDK
        │   ├── HIP compiler
        │   └── ROCm runtime libraries
        └── ROCDXG
            └── librocdxg.so
```

The ROCm GPU compute stack is now ready for building GPU-accelerated applications.


# 5. Prepare the llama.cpp Build Environment

To prepare the llama.cpp build environment, the following is performed:

- install the remaining build tools
- download the upstream source code
- prepare the build directory structure
- download the validation model
- verify the source tree is in a clean state

The goal is to keep the environment as reproducible as possible.

Only packages required for the base llama.cpp build process are installed here.

Additional dependencies required for hardware-accelerated backends (such as Vulkan) are installed later in the relevant build steps.

## 5.1. Install Build Toolchain

In Ubuntu, install the required build tools:

```bash
sudo apt install -y cmake ninja-build pipx
```

Add the user directory to PATH, then apply the change:

```bash
pipx ensurepath
source ~/.bashrc
```

**Expected Output** *(username directory may vary)*

```text
Success! Added /home/user/.local/bin to the PATH environment variable.

Consider adding shell completions for pipx. Run 'pipx completions' for instructions.

You will need to open a new terminal or re-login for the PATH changes to take effect.

Otherwise pipx is ready to go!
```

> **Note**
>
> Running source ~/.bashrc applies the PATH change to the current shell session immediately.
>
> Therefore, despite what it says above, opening a new terminal is not actually required.

Install the Hugging Face Hub tools through `pipx`:

```bash
pipx install huggingface_hub
```

**Expected Output** *(versions may vary)*

```text
  installed package huggingface-hub 1.24.0, installed using Python 3.12.3
  These apps are now globally available
    - hf
    - huggingface-cli
    - tiny-agents
done!
```

Confirm all build tools are present by running this command:

```bash
for tool in cmake ninja pipx hf; do
    echo "$tool"
    $tool --version
    echo
done
```

**Expected Output** *(versions may vary)*

```text
cmake
cmake version 3.28.3

CMake suite maintained and supported by Kitware (kitware.com/cmake).

ninja
1.11.1

pipx
1.4.3

hf
1.24.0
```

Confirm the correct directory is associated with `hf`:

```bash
which hf
```

**Expected Output** *(username directory may vary)*

```text
/home/user/.local/bin/hf
```


## 5.2. Create the llama.cpp Source Directory

Create a dedicated directory for source repositories:

```bash
mkdir -p ~/src
cd ~/src
```

This guide stores source code under `~/src` and keeps all generated build files in separate out-of-source build directories.

This allows multiple build configurations (CPU, Vulkan, HIP, debug, release, etc.) to coexist without modifying the source tree.


## 5.3. Clone llama.cpp

This guide was validated using the following upstream llama.cpp commit:

```text
bec4772f6a2527d371557b5d2032641e5ff7619c
```

Newer commits may also work, but have not been validated as part of this guide.

Clone the upstream llama.cpp repository:

```bash
git clone https://github.com/ggml-org/llama.cpp.git
```

Enter the repository:

```bash
cd ~/src/llama.cpp
```

> **Note**
>
> The `git clone` command above clones the latest upstream revision.
> 
> If you encounter problems using a newer revision, you can switch to the version used throughout this guide:
>
> ```bash
> git switch --detach bec4772f6a2527d371557b5d2032641e5ff7619c
> ```

Confirm the official upstream repository was cloned:

```bash
git remote -v
```

Expected output:

```text
origin  https://github.com/ggml-org/llama.cpp.git (fetch)
origin  https://github.com/ggml-org/llama.cpp.git (push)
```

Confirm the currently checked-out llama.cpp revision:

```bash
git log -1 --oneline
```

Expected output (when using the validated commit):

```text
bec4772f6 (HEAD, tag: b9913) Add Q2_0 quantization: type definition and CPU backend (#24448)
```


## 5.4. Verify the Source Tree Is Clean

Before creating builds, verify that llama.cpp has no unexpected modifications:

```bash
git status
```

Expected output:

```text
<current branch / tag displayed>
nothing to commit, working tree clean
```


## 5.5. Create Build Directory Structure

This guide keeps all generated CMake build files inside a dedicated `builds/` directory.

Create the directory:

```bash
mkdir -p builds
```

Each build follows this format:

```text
builds/<backend>-<configuration>
```

**Examples**

```text
builds/cpu-release
builds/vulkan-release
builds/hip-release
```


## 5.6. Download Validation Model

This guide uses a small Qwen2.5 1.5B GGUF model for build validation.

The purpose of this model is not performance testing, but confirming that each llama.cpp backend can:

- load a GGUF model successfully
- execute inference or benchmarks
- complete normally without runtime errors

Create the model directory:

```bash
mkdir -p ~/models/qwen2.5-1.5b
```

Download the validation model:

```bash
hf download \
    Qwen/Qwen2.5-1.5B-Instruct-GGUF \
    --include qwen2.5-1.5b-instruct-q4_k_m.gguf \
    --local-dir ~/models/qwen2.5-1.5b
```

> **Note**
>
> The `hf` command is provided by the `huggingface_hub` package installed through `pipx`.
>
> Many examples online use `huggingface-cli` instead of `hf`, but the former is now deprecated.

> TODO: The next note below did NOT occur last time this was run from beginning to end. It may not be needed, but don't delete it just yet; wait until the next few runs to see if this occurs again or not before deciding what to do with it.

> **Note**
>
> Hugging Face may display a warning about unauthenticated requests without a HF_TOKEN.
>
> This model can be downloaded without authentication; the only restriction is a lower rate limit.

Ensure the validation model is available:

```bash
VALIDATION_MODEL=~/models/qwen2.5-1.5b/qwen2.5-1.5b-instruct-q4_k_m.gguf
test -f "$VALIDATION_MODEL" && echo "Validation model available: $(basename "$VALIDATION_MODEL")"
```

**Expected Output**

```text
Validation model available: qwen2.5-1.5b-instruct-q4_k_m.gguf
```


## 5.7. Download Production Model

This guide uses the Qwen3.6 27B GGUF model for production usage.

Create the model directory:

```bash
mkdir -p ~/models/qwen3.6-27b
```

Download the validation model:

```bash
hf download \
    unsloth/Qwen3.6-27B-GGUF \
    --include "Qwen3.6-27B-Q4_K_M.gguf" \
    --local-dir ~/models/qwen3.6-27b
```

> **Note**
>
> Hugging Face may display a warning about unauthenticated requests without a HF_TOKEN.
>
> This model can be downloaded without authentication; the only restriction is a lower rate limit.

Ensure the validation model is available:

```bash
PRODUCTION_MODEL=~/models/qwen3.6-27b/Qwen3.6-27B-Q4_K_M.gguf
test -f "$PRODUCTION_MODEL" && echo "Production model available: $(basename "$PRODUCTION_MODEL")"
```

**Expected Output**

```text
Production model available: Qwen3.6-27B-Q4_K_M.gguf
```


## 5.8. Final State

At the end of this step:

```text
Ubuntu
└── ~/
    ├── models/
    │   ├── qwen2.5-1.5b/
    │   │   └── qwen2.5-1.5b-instruct-q4_k_m.gguf
    │   │
    │   └── qwen3.6-27b/
    │       └── Qwen3.6-27B-Q4_K_M.gguf
    │
    └── src/
        └── llama.cpp/
            └── builds/
```

The system now contains:

- The required build tools
- A clean upstream llama.cpp source tree
- A prepared `builds/` directory ready for out-of-source builds
- A validation GGUF model ready for backend testing
- A production GGUF model for real usage after testing

The environment is now ready to build each llama.cpp backend independently.


# 6. Build the CPU Backend

This section builds the CPU-only version of `llama.cpp`.

The CPU backend provides a known-good baseline before introducing GPU acceleration.

Unlike the Vulkan and HIP backends, this build does **not** require ROCm or access to the GPU. It allows the source tree, build environment, and model files to be validated independently of the GPU compute stack.


## 6.1. Configure the CPU Build

Change into the `llama.cpp` source directory:

```bash
cd ~/src/llama.cpp
```

Configure a dedicated CPU-only build:

```bash
cmake -B builds/cpu-release \
    -G Ninja \
    -DCMAKE_BUILD_TYPE=Release
```

The `-G Ninja` option selects Ninja as the build system instead of CMake's default Make generator.

Using Ninja provides faster incremental builds, and shall be used in all backend configurations for consistency.

This CPU configuration explicitly disables both the HIP and CUDA backends.

Although CUDA is not expected to be available on AMD hardware, disabling it ensures that only the CPU backend is compiled.


## 6.2. Build llama.cpp

Compile the project:

```bash
cmake --build builds/cpu-release
```

This compiles all of the standard `llama.cpp` executables using the CPU backend.


## 6.3. Verify the Build

Confirm that the expected executables were created successfully:

```bash
test -x builds/cpu-release/bin/llama-bench && echo "llama-bench exists"
test -x builds/cpu-release/bin/llama-cli && echo "llama-cli exists"
```

**Expected Output**

```text
llama-bench exists
llama-cli exists
```


## 6.4. Verify No HIP Runtime Dependency Exists

Confirm that the CPU build is not linked against the HIP runtime:

```bash
ldd builds/cpu-release/bin/llama-bench | grep amdhip
```

**Expected Output**

```text
<No output>
```

No output confirms that the executable has no dependency on the ROCm HIP runtime.


## 6.5. Run a CPU Benchmark

Run a benchmark using the validation model:

```bash
./builds/cpu-release/bin/llama-bench \
    -m ~/models/qwen2.5-1.5b/qwen2.5-1.5b-instruct-q4_k_m.gguf \
    -r 1
```

**Example Results** (Performance may vary depending on the CPU used)


| model                          |       size |     params | backend    | threads |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | ------: | --------------: | -------------------: |
| qwen2 1.5B Q4_K - Medium       |   1.04 GiB |     1.78 B | CPU        |       8 |           pp512 |        201.91 ± 0.00 |
| qwen2 1.5B Q4_K - Medium       |   1.04 GiB |     1.78 B | CPU        |       8 |           tg128 |         47.99 ± 0.00 |

The important result is that the benchmark:

- loads the validation model successfully
- completes normally with non-zero t/s values
- outputs a Git commit hash + build number
- returns to the command prompt without any issues


## 6.6. What This Confirms

Successful completion of this benchmark confirms that:

- the `llama.cpp` source tree builds successfully
- the CPU backend is functioning correctly
- the model file can be loaded successfully
- the benchmark completes successfully
- normal application shutdown and cleanup complete without errors

This establishes a known-good baseline before introducing GPU-accelerated backends.


## 6.7. Checkpoint

Successful completion of this section confirms:

- CPU backend compiled successfully
- `llama-cli` was built successfully
- `llama-bench` was built successfully
- No HIP runtime dependency exists
- CPU benchmark completed successfully

The environment is now ready to build the Vulkan backend.


# 7. Build the Vulkan Backend

This section builds the Vulkan-enabled version of `llama.cpp`.

The Vulkan backend provides GPU acceleration through the Vulkan compute API.

Unlike the CPU backend, this configuration requires a working Vulkan runtime environment and GPU access through the WSL graphics stack.

The Vulkan backend validates the complete GPU compute path through WSL:

```text
llama.cpp
    |
    | Vulkan compute backend
    |
Mesa DZN Vulkan driver
    |
    | Vulkan -> Direct3D 12 translation
    |
WSL dxg graphics bridge
    |
Windows WDDM GPU driver
    |
AMD GPU
```


## 7.1. Install Vulkan Runtime Components

The Vulkan backend requires a working Vulkan runtime environment.

WSL GPU acceleration uses Mesa's DZN (Dozen) Vulkan driver to translate Vulkan compute operations into Direct3D 12 commands through the WSL graphics layer.

Ubuntu's default Mesa packages may not include the required Mesa DZN Vulkan driver version for WSL GPU acceleration.

The Kisak Mesa PPA provides a newer Mesa stack containing the required Vulkan components.

Add the Kisak Mesa PPA:

```bash
sudo add-apt-repository ppa:kisak/kisak-mesa
sudo apt update
sudo apt upgrade -y
```

> **NOTE**
>
> The `apt upgrade` command is sufficient here because the Mesa packages can be upgraded without dependency changes. If Ubuntu reports packages being held back, use the `apt full-upgrade` command instead.

Install the Vulkan runtime and diagnostic tools:

```bash
sudo apt install -y \
    mesa-vulkan-drivers \
    vulkan-tools
```

These packages provide:

- `mesa-vulkan-drivers` - Mesa Vulkan runtime drivers, including the DZN Vulkan driver required for WSL GPU acceleration
- `vulkan-tools` - Diagnostic utilities used to verify the Vulkan installation

Verify that the Mesa DZN Vulkan driver was installed successfully:

dpkg -L mesa-vulkan-drivers | grep dzn

**Expected Output**

```test
/usr/lib/x86_64-linux-gnu/libvulkan_dzn.so
/usr/share/vulkan/icd.d/dzn_icd.json
```

Verify that Vulkan detects the target GPU through the Mesa DZN driver:

```bash
vulkaninfo --summary | grep -A10 "GPU0:" | grep -E "deviceType|deviceName|driverName"
```

**Expected Output** *(versions may vary)*

```text
        deviceType         = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU
        deviceName         = Microsoft Direct3D12 (AMD Radeon RX 7900 XTX)
        driverName         = Dozen
```

>**Note**
>
> When using Mesa DZN under WSL, `vulkaninfo` may display a warning saying it "is not a conformant Vulkan implementation" just yet, followed by a "testing use only" disclaimer and a dropped escape call. These messages are expected and do not indicate a failed Vulkan installation.


## 7.2. Install Vulkan Build Dependencies

Install the packages required to compile the Vulkan backend:

```bash
sudo apt install -y \
    glslc \
    libvulkan-dev \
    spirv-headers
```

These packages provide:

- `glslc` - Vulkan shader compiler
- `libvulkan-dev` - Vulkan headers and development files
- `spirv-headers` - SPIR-V headers required by Vulkan shaders


## 7.3. Configure the Vulkan Build

Change into the `llama.cpp` source directory:

```bash
cd ~/src/llama.cpp
```

Configure a dedicated Vulkan build:

```bash
cmake -B builds/vulkan-release \
    -G Ninja \
    -DGGML_VULKAN=ON \
    -DCMAKE_BUILD_TYPE=Release
```


## 7.4. Build llama.cpp

Compile the project:

```bash
cmake --build builds/vulkan-release
```

This compiles all of the standard `llama.cpp` executables with Vulkan backend support enabled.


## 7.5. Verify the Build

Confirm that the expected executables were created successfully:

```bash
test -x builds/vulkan-release/bin/llama-bench && echo "llama-bench exists"
test -x builds/vulkan-release/bin/llama-cli && echo "llama-cli exists"
```

**Expected Output**

```text
llama-bench exists
llama-cli exists
```


## 7.6. Verify the Vulkan Backend

Confirm that the Vulkan backend library was generated successfully:

```bash
test -f builds/vulkan-release/bin/libggml-vulkan.so.0 && echo "Vulkan backend exists"
```

**Expected Output**

```text
Vulkan backend exists
```

This confirms that the Vulkan backend was successfully compiled and linked into the build.


## 7.7. Run a Vulkan Benchmark

Run a benchmark using the validation model:

```bash
./builds/vulkan-release/bin/llama-bench \
    -m ~/models/qwen2.5-1.5b/qwen2.5-1.5b-instruct-q4_k_m.gguf \
    -r 1
```

The benchmark executes using the Vulkan backend and communicates with the GPU through the Vulkan runtime.

**Example Output**

```text
ggml_vulkan: Found 1 Vulkan devices:
ggml_vulkan: 0 = Microsoft Direct3D12 (AMD Radeon RX 7900 XTX) (Dozen) | uma: 0 | fp16: 1 | bf16: 0 | warp size: 32 | shared memory: 32768 | int dot: 0 | matrix cores: none
```

| model                          |       size |     params | backend    | ngl |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --------------: | -------------------: |
| qwen2 1.5B Q4_K - Medium       |   1.04 GiB |     1.78 B | Vulkan     |  -1 |           pp512 |       3675.94 ± 0.00 |
| qwen2 1.5B Q4_K - Medium       |   1.04 GiB |     1.78 B | Vulkan     |  -1 |           tg128 |        120.14 ± 0.00 |

```text
build: bec4772f6 (9913)
```

The important result is that the benchmark:

- loads the validation model successfully
- completes normally with non-zero t/s values
- outputs a Git commit hash and build number
- returns to the command prompt without errors


## 7.8. What This Confirms

Successful completion of this benchmark confirms that:

- the `llama.cpp` source tree builds successfully
- the Vulkan backend is functioning correctly
- the Vulkan runtime is configured correctly
- the GPU is detected through Vulkan
- the model file can be loaded successfully
- GPU workloads execute successfully
- normal application shutdown and cleanup complete without errors

This additionally confirms that:

- `llama.cpp` communicates with the GPU through the Vulkan API
- the Mesa DZN driver is active
- the WSL Vulkan translation layer is functioning correctly


## 7.9. Checkpoint

Successful completion of this section confirms:

- Vulkan runtime components installed successfully
- Mesa DZN Vulkan driver available
- Vulkan backend compiled successfully
- `libggml-vulkan.so` was generated successfully
- `llama-cli` was built successfully
- `llama-bench` was built successfully
- validation model loads successfully

Successful Vulkan benchmark completion additionally confirms:

- GPU detection through Vulkan
- Vulkan compute execution
- WSL Vulkan translation path functioning correctly

The environment is now ready to build the HIP backend.


# 8. Build the HIP Backend

This section builds the HIP-enabled version of `llama.cpp`.

The HIP backend provides GPU acceleration through AMD's ROCm HIP compute stack.

Unlike the CPU and Vulkan backends, this configuration uses the ROCm runtime directly:

```text
llama.cpp
    |
    | HIP compute backend
    |
ROCm HIP Runtime
    |
    | ROCDXG WSL GPU bridge
    |
WSL /dev/dxg interface
    |
Windows AMD WDDM Driver
    |
AMD Radeon RX 7900 XTX
```

This backend requires:

- ROCm Core SDK 7.14.0
- ROCDXG WSL GPU Compute Bridge
- A supported AMD GPU architecture

This guide was validated using:

```
GPU:
AMD Radeon RX 7900 XTX

Architecture:
gfx1100

ROCm:
7.14.0

HIP:
7.14.x
```

The purpose of this section is to verify that the complete ROCm HIP execution path is functional before testing the larger Qwen3.6-27B workload.


## 8.1. Configure the HIP Build

Configure a dedicated HIP build:

```bash
cmake -B builds/hip-release \
    -G Ninja \
    -DGGML_HIP=ON \
    -DCMAKE_BUILD_TYPE=Release
```

The `GGML_HIP` option enables the AMD ROCm HIP backend.


## 8.2. Build llama.cpp

Compile the project:

```bash
cmake --build builds/hip-release
```

This compiles all standard `llama.cpp` executables with HIP backend support enabled.


## 8.3. Verify the Build

Confirm that the expected executables were created successfully:

```bash
test -x builds/hip-release/bin/llama-bench && echo "llama-bench exists"
test -x builds/hip-release/bin/llama-cli && echo "llama-cli exists"
```

**Expected Output**

```text
llama-bench exists
llama-cli exists
```


## 8.4. Verify the HIP Backend Library

Confirm that the HIP backend library was generated successfully:

```bash
test -f builds/hip-release/bin/libggml-hip.so && echo "HIP backend exists"
```

**Expected Output**

```text
HIP backend exists
```

This confirms that the HIP backend was successfully compiled.


## 8.5. Verify ROCm HIP Runtime Linking

Confirm that the HIP build is linked against the ROCm HIP runtime:

```bash
ldd builds/hip-release/bin/llama-bench | grep amdhip
```

**Expected Output**

```text
        libamdhip64.so.7 => /opt/rocm/lib/libamdhip64.so.7 (0x00007e4723800000)
```

This confirms that the executable is using the ROCm HIP runtime supplied by the ROCm Core SDK.


## 8.6. Run a HIP Benchmark

Run a benchmark using the validation model:

```bash
./builds/hip-release/bin/llama-bench \
    -m ~/models/qwen2.5-1.5b/qwen2.5-1.5b-instruct-q4_k_m.gguf \
    -r 1
```

The benchmark executes using the ROCm HIP backend.

**Example Output**

```text
ggml_cuda_init: found 1 ROCm devices (Total VRAM: 24516 MiB):

<results>

build: bec4772f6 (9913)
```

**Example Results**

ggml_cuda_init: found 1 ROCm devices (Total VRAM: 24516 MiB):
  Device 0: AMD Radeon RX 7900 XTX, gfx1100 (0x1100), VMM: no, Wave Size: 32, VRAM: 24516 MiB
| model                          |       size |     params | backend    | ngl |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --------------: | -------------------: |
| qwen2 1.5B Q4_K - Medium       |   1.04 GiB |     1.78 B | ROCm       |  -1 |           pp512 |      12459.32 ± 0.00 |
| qwen2 1.5B Q4_K - Medium       |   1.04 GiB |     1.78 B | ROCm       |  -1 |           tg128 |        255.08 ± 0.00 |

The important result is that the benchmark:

- loads the validation model successfully
- detects the RX 7900 XTX through HIP
- completes GPU execution successfully
- outputs a Git commit hash and build number
- returns to the command prompt normally


## 8.7. What This Confirms

Successful completion of this benchmark confirms that:

- the llama.cpp source tree builds successfully with HIP enabled
- the HIP backend is functioning correctly
- ROCm Core SDK 7.14.0 is detected correctly
- llama.cpp is linked against the ROCm HIP runtime
- the RX 7900 XTX is detected through HIP
- GPU workloads execute successfully
- normal application shutdown completes successfully

This confirms the complete HIP execution path:

llama.cpp
    |
    v
GGML HIP Backend
    |
    v
ROCm HIP Runtime
    |
    v
ROCDXG
    |
    v
WSL /dev/dxg
    |
    v
Windows AMD Driver
    |
    v
RX 7900 XTX


## 8.8. Checkpoint

Successful completion of this section confirms:

- ROCm Core SDK 7.14.0 is installed correctly
- HIP compiler is available
- HIP backend compiled successfully
- libggml-hip.so was generated successfully
- llama-cli was built successfully
- llama-bench was built successfully
- ROCm HIP runtime linking is correct
- validation model loads successfully
- HIP GPU execution completes successfully

The environment is now ready for installing and testing the full Qwen3.6-27B model.




