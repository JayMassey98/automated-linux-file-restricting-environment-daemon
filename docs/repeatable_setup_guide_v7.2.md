# Qwen 3.6 on WSL2 (7900 XTX) — Repeatable Setup Guide

**What this gets you:** Qwen3.6-27B-Q4_K_S, running fully isolated from your real Windows files, served over a local OpenAI-compatible API at `http://localhost:8080`, with a ~200k token context window. Confirmed working at ~19.5 tokens/sec generation.

# Prerequisites (one-time, on Windows itself)

These steps prepare the Windows host for WSL2 GPU workloads.

The versions recorded below are the versions used when creating this guide.


## 1. Enable Windows Optional Features

Run **PowerShell as Administrator**.

Enable **Windows Subsystem for Linux**:

```powershell
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
```

Enable **Virtual Machine Platform**:

```powershell
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
```

Restart Windows:

```powershell
shutdown /r /t 0
```

A reboot is required before the WSL2 components can be fully activated.


## 2. Install Windows SDK

The Windows SDK is not required by ROCm or llama.cpp directly.

It is installed here because it was present in the original investigation environment and keeps the Windows host environment consistent with the recorded baseline.

Install using WinGet:

```powershell
winget install Microsoft.WindowsSDK.10.0.28000
```

Version used to create this guide:

```text
Windows SDK:
10.0.28000.2114
```


## 3. Install WSL2 Components

Install the WSL2 framework without installing a Linux distribution yet:

```powershell
wsl --install --no-distribution
```

> Note:
>
> The `--no-distribution` option requires the newer WSL package.
>
> If the command is unavailable, update WSL first:
>
> ```powershell
> wsl --update
> ```
>
> Then rerun:
>
> ```powershell
> wsl --install --no-distribution
> ```

Verify the installation:

```powershell
wsl --version
```

Version used to create this guide:

```text
WSL version:      2.7.10.0
Kernel version:   6.18.33.2-2
WSLg version:     1.0.73.2
```

Additional information reported:

```text
MSRDC version:    1.2.6676
Direct3D version: 1.611.1-81528511
DXCore version:   10.0.26100.1-240331-1435.ge-release
Windows version:  10.0.19045.7417
```


## 4. Install AMD Adrenalin Edition Driver

The AMD driver is installed only on Windows.

WSL2 does not use a separate Linux AMD display driver. GPU access is provided through the Windows AMD driver via the WSL `/dev/dxg` GPU interface.

Install the latest AMD driver from:

https://www.amd.com/en/support/download/drivers.html

Version used to create this guide:

```text
AMD Software Adrenalin Edition:
26.6.3

Windows driver package:
32.0.31021.4001
```

Verify the GPU is detected.

Open:

```text
Device Manager
 └── Display adapters
      └── AMD Radeon RX 7900 XTX
```

The RX 7900 XTX should be listed without warning icons.

> **TODO** - Investigate how to automate the AMD driver download and installation via a script.


# Step 1 — Starting With a Fresh Ubuntu-24.04 WSL2 Distribution

This guide requires a dedicated, clean WSL2 distribution named:

```text
Ubuntu-24.04
```

The distribution name is part of the reproducibility baseline.

A previously created Ubuntu installation should **not** be reused.

Previous installations may contain:

- older ROCm packages
- previous HIP libraries
- modified environment variables
- cached build files
- custom compiler settings
- unrelated packages

Any of these could affect reproducibility.


## 1. Check Existing WSL Distributions

Run PowerShell as Administrator:

```powershell
wsl --list --verbose
```

Example:

```text
  NAME             STATE      VERSION
* Ubuntu-24.04     Stopped    2
```

A system may also contain unrelated WSL distributions.

Example:

```text
  NAME             STATE      VERSION
* Ubuntu-24.04     Stopped    2
  docker-desktop   Stopped    2
```

Only the Ubuntu distribution created for this guide is relevant.

Do not remove unrelated distributions such as:

```text
docker-desktop
```

unless they are specifically no longer required.


## 2. Remove Existing Ubuntu-24.04 Installation

If an existing `Ubuntu-24.04` distribution exists and is not required, remove it.

First stop all WSL instances:

```powershell
wsl --shutdown
```

Then unregister the old distribution:

```powershell
wsl --unregister Ubuntu-24.04
```

> Warning
>
> This permanently deletes the selected WSL distribution.
>
> It removes:
>
> - Linux filesystem
> - installed packages
> - configuration files
> - downloaded models
> - build directories
> - user data
>
> It does not affect Windows files.

If the distribution has a different name, use the exact name shown by:

```powershell
wsl --list --verbose
```

Then unregister using:

```powershell
wsl --unregister <distribution-name>
```

Verify the old distribution has been removed:

```powershell
wsl --list
```


## 3. Update WSL and Install Ubuntu-24.04

Update WSL:

```powershell
wsl --update
```

Install the required Ubuntu distribution explicitly:

```powershell
wsl --install -d Ubuntu-24.04
```

> Do not use:
>
> ```powershell
> wsl --install
> ```
>
> because this installs the default Ubuntu distribution name (`Ubuntu`), which may not match the required reproducible `Ubuntu-24.04` environment.

After installation completes, Ubuntu will launch automatically.


## 4. Create the Linux User Account

When Ubuntu starts:

Create the default Linux user account.

Use a consistent Linux username. This setup guide will use:

```text
user
```

When prompted:

```text
Create a default Unix user account:
```

Enter the username to use.

A password will then be asked for; input 1234 for this.

Confirm the password.

> A strong password is recommended. Although this guide uses a local development environment, the WSL instance should still be treated as a real Linux system.

At this point, the Linux VM will be ready to use, showing:

```bash
user@JAYS-PC:/mnt/c/Windows/system32$
```

Enter the following command:

```bash
user@JAYS-PC:/mnt/c/Windows/system32$ exit
```

This will return you back to the PowerShell window:

```powershell
exit
PS C:\Windows\system32>
```

## 5. Set Ubuntu-24.04 as the Default WSL Distribution

In a PowerShell window, set Ubuntu-24.04 as the default distribution:

```powershell
wsl --set-default Ubuntu-24.04
```

Set WSL2 as the default version:

```powershell
wsl --set-default-version 2
```


## 6. Verify the Ubuntu Installation

Check installed WSL distributions:

```powershell
wsl --list --verbose
```

Expected:

```text
  NAME             STATE      VERSION
* Ubuntu-24.04     Stopped    2
```

Confirm Ubuntu is the default WSL distribution:

```powershell
wsl --status
```

Expected:

```text
Default Distribution: Ubuntu-24.04
Default Version: 2
```


## 7. Verify WSL GPU Interface

Start Ubuntu:

```powershell
wsl -d Ubuntu-24.04
```

Check that the WSL GPU interface exists:

```bash
ls -l /dev/dxg
```

Expected:

```text
crw-rw-rw- 1 root root ... /dev/dxg
```

The presence of `/dev/dxg` confirms that the Windows AMD driver and WSL2 GPU virtualization layer are available. This means that the Ubuntu-24.04 WSL2 environment is ready for ROCm installation.

# Step 2 — Configure the WSL Isolation Boundary

This step configures Ubuntu to operate as an isolated Linux environment rather than a transparent extension of the Windows host.

The goals are:

- prevent automatic access to Windows drives
- prevent execution of Windows applications from within WSL
- prevent the Windows `PATH` from being injected into Linux
- enable `systemd`
- ensure Vulkan support works correctly
- create a predictable, reproducible environment for ROCm, llama.cpp, and future investigations

## 1. Create the WSL Configuration File

Inside the Ubuntu-24.04 terminal, create the WSL configuration file:

```bash
sudo nano /etc/wsl.conf
```

Enter the password 1234.

Replace the contents with exactly the following:

```ini
[automount]
enabled = false

[boot]
systemd = true
command = "modprobe vgem; umount -l /mnt/c 2>/dev/null || true"

[interop]
enabled = false
appendWindowsPath = false

[user]
default = user
```

Before saving this file, replace "default = user" with your username if it is different. Leave the [user] header as is.

### Explanation

- `enabled = false` disables automatic mounting of Windows drives under `/mnt`.
- `systemd = true` enables the standard Linux init system required by some tooling.
- `modprobe vgem` loads the `vgem` kernel module, which is required by the Vulkan path used later by the llama.cpp Vulkan backend.
- `umount -l /mnt/c` ensures the C: drive is not accessible if it was mounted before the new settings took effect.
- `enabled = false` under `[interop]` prevents Linux processes from launching Windows executables.
- `appendWindowsPath = false` prevents Windows directories from being added to the Linux `PATH`.
- `default = user` sets the default Linux account created during Step 1.

Save and exit:

1. Press `Ctrl + X`
2. Press `Y`
3. Press `Enter`

> **TODO** - Find a way to automate this file change, perhaps by changing the nano command to a different command?

## 2. Restart WSL

Exit Ubuntu:

```bash
exit
```

Return to the same **PowerShell** window and shut down WSL:

```powershell
wsl --shutdown
```

Wait approximately 10 seconds for the WSL virtual machine to stop completely.

Start Ubuntu again:

```powershell
wsl -d Ubuntu-24.04
```

## 3. Verify Windows Drives Are Not Automatically Mounted

Verify all mounted letter directories (pulled from the host Windows OS) are empty (besides the 4 nested directories listed below):

```bash
ls -la /mnt/
```

You should see something like:

```bash
total 28
drwxr-xr-x  9 root root 4096 Jul  8 00:34 .
drwxr-xr-x 23 root root 4096 Jul  8 01:01 ..
drwxrwxrwx  3 root root 4096 Jul  8 01:01 c
drwxrwxrwx  2 root root 4096 Jul  8 00:34 d
drwxrwxrwx  2 root root 4096 Jul  8 00:34 e
drwxrwxrwx  2 root root 4096 Jul  8 00:34 f
drwxrwxrwx  2 root root 4096 Jul  8 00:34 p
drwxrwxrwt  4 root root  100 Jul  8 01:01 wsl
drwxrwxrwt  7 root root  300 Jul  8 01:01 wslg
```

Confirm that each mounted letter corresponding to its hosted Windows OS drive is empty:


```bash
jay@JAYS-PC:~$ ls -la /mnt/c/
total 8
drwxrwxrwx 2 root root 4096 Jul  8 01:01 .
drwxr-xr-x 9 root root 4096 Jul  8 00:34 ..
jay@JAYS-PC:~$ ls -la /mnt/d/
total 8
drwxrwxrwx 2 root root 4096 Jul  8 00:34 .
drwxr-xr-x 9 root root 4096 Jul  8 00:34 ..
jay@JAYS-PC:~$ ls -la /mnt/e/
total 8
drwxrwxrwx 2 root root 4096 Jul  8 00:34 .
drwxr-xr-x 9 root root 4096 Jul  8 00:34 ..
jay@JAYS-PC:~$ ls -la /mnt/f/
total 8
drwxrwxrwx 2 root root 4096 Jul  8 00:34 .
drwxr-xr-x 9 root root 4096 Jul  8 00:34 ..
jay@JAYS-PC:~$ ls -la /mnt/p/
total 8
drwxrwxrwx 2 root root 4096 Jul  8 00:34 .
drwxr-xr-x 9 root root 4096 Jul  8 00:34 ..
```

Verify that `/mnt/wsl/` exists:

```bash
ls -la /mnt/wsl/
```

Expected output (contents may vary):

```text
resolv.conf
```

Verify that `/mnt/wslg/` exists:

```bash
ls -la /mnt/wslg/
```

Expected output (contents may vary):

```text
.X11-unix
PulseAudioRDPSink
PulseAudioRDPSource
PulseServer
distro
doc
pulseaudio.log
run
runtime-dir
stderr.log
versions.txt
weston.log
wlog.log
```

The exact file list may vary between WSL versions.

## 5. Verify Windows Interoperability Is Disabled

Run:

```bash
cmd.exe /c echo hi
```

Expected output:

```text
cmd.exe: command not found
```

This confirms that Windows executables cannot be launched from WSL.

## 6. Verify the GPU Interface Still Exists

Even with Windows interoperability disabled, the WSL GPU bridge should remain available.

Verify:

```bash
ls -l /dev/dxg
```

Expected output:

```text
crw-rw-rw- 1 root root ... /dev/dxg
```

The presence of `/dev/dxg` confirms that GPU virtualization remains functional.

## 7. Verify ROCm GPU Detection

Confirm that ROCm can still see the GPU:

```bash
rocminfo | grep -A3 gfx1100
```

Expected output:

```text
Name:                    gfx1100
Marketing Name:          AMD Radeon RX 7900 XTX
Vendor Name:             AMD
Feature:                 KERNEL_DISPATCH
--
      Name:                    amdgcn-amd-amdhsa--gfx1100
      Machine Models:          HSA_MACHINE_MODEL_LARGE
      Profiles:                HSA_PROFILE_BASE
      Default Rounding Mode:   NEAR
```

Successful completion of this step confirms that:

- Windows drive access is disabled
- Windows executable interoperability is disabled
- Linux `PATH` contamination is disabled
- `systemd` is enabled
- Vulkan prerequisites are in place
- the WSL GPU bridge remains available
- ROCm can still detect the RX 7900 XTX

The environment is now isolated and ready for ROCm installation and llama.cpp builds.

> **TODO** - Find a way to automate this entire step. This wil involve having a dynamic way of searching through all the drive letters, and not everyone will have the exact same C + D + E + F + P set up I have above.

# Step 3 — Install ROCm Core SDK 7.14.0

> **Draft Section — Requires validation before becoming the final guide version**
>
> This section documents the intended ROCm Core SDK 7.14.0 installation process.
>
> Before publishing the final version of this guide, the following items must be verified:
>
> - exact ROCm 7.14.0 package selection
> - whether `amdrocm-core-sdk7.14` or `amdrocm-core-sdk7.14-gfx110x` is preferred
> - whether the WSL-specific AMD driver bridge from Step 2 provides all required components
> - whether additional ROCm environment variables are required
> - whether llama.cpp builds correctly against this installation without additional packages
>
> These notes are intentionally retained during the investigation phase and will be removed or converted into normal documentation once validated.

## 1. Overview

This step installs:

```text
ROCm Core SDK 7.14.0
```

Inside:

```text
Ubuntu-24.04 (WSL2)
```

The target environment is:

```text
Windows 10
 └── WSL2
      └── Ubuntu-24.04
           └── ROCm Core SDK 7.14.0
                └── HIP
                     └── llama.cpp
                          └── AMD Radeon RX 7900 XTX
```

The purpose of this installation is to provide:

* HIP runtime libraries
* ROCm compiler tools
* ROCm development headers
* ROCm libraries required by llama.cpp
* ROCm diagnostic tools

## 2. Important ROCm 7.14.0 Changes

ROCm Core SDK 7.14.0 introduces a new packaging model based on the TheRock build system.

The previous ROCm installation layout was:

```text
/opt/rocm
```

The new internal installation path is:

```text
/opt/rocm/core
```

However, when installed through the Ubuntu package manager, compatibility symlinks should continue to provide the previous path for existing applications.

This guide uses the package manager installation method specifically because it provides the compatibility layer automatically.

## 3. Install ROCm Prerequisites

Inside the Ubuntu-24.04 terminal:

```bash
sudo apt update
<enter password>
sudo apt upgrade -y
```

-- Don't do this bit yet! : sudo apt install -y libatomic1 libquadmath0
-- Just keeping it here as a reminder in case it's needed!

Meta Note

The AMD documentation lists these packages as prerequisites.

Need to verify:

whether they are already installed by Ubuntu 24.04
whether ROCm installation fails without them
whether they should remain explicit in the final guide

## 4. SKIP THIS SECTION FOR NOW!!! Configure GPU Permissions

ROCm requires the Linux user account to have access to the GPU device groups.

Add the current user to the **render** and **video** groups:

```bash
sudo usermod -a -G render,video $LOGNAME
```

Apply the group change:

```bash
exit
```

Return to PowerShell:

wsl --shutdown

Restart Ubuntu:

wsl -d Ubuntu-24.04

Verify the groups:

groups

Expected output should contain:

render
video


Meta Note

Need to verify whether this is actually required under WSL2.

Previous ROCm-for-WSL installations may already provide access through:

/dev/dxg

However, AMD's ROCm 7.14 documentation still recommends this configuration.

Keep unless testing proves unnecessary.

## 5. Register the AMD ROCm Repository

Create the apt keyring directory:

```bash
sudo mkdir --parents --mode=0755 /etc/apt/keyrings
```

Download and install the AMD signing key:

```bash
wget https://repo.amd.com/rocm/packages-multi-arch/gpg/rocm.gpg -O - | \
    gpg --dearmor | sudo tee /etc/apt/keyrings/amdrocm.gpg > /dev/null
```

Add the ROCm repository:

```bash
sudo tee /etc/apt/sources.list.d/rocm.list << EOF
deb [arch=amd64 signed-by=/etc/apt/keyrings/amdrocm.gpg] https://repo.amd.com/rocm/packages-multi-arch/ubuntu2404 stable main
EOF
```

Update package information:

```bash
sudo apt update
```

Verify the repository is visible:

```bash
apt policy amdrocm7.14
```

Expected (Where x is either a minor number or a minor number + patch number):

```text
Candidate: 7.14.x
```

Meta Note - Actually Got:

```
user@JAYS-PC:~$ apt policy amdrocm7.14
amdrocm7.14:
  Installed: (none)
  Candidate: 7.14.0-3
  Version table:
     7.14.0-3 500
        500 https://repo.amd.com/rocm/packages-multi-arch/ubuntu2404 stable/main amd64 Packages
user@JAYS-PC:~$
```

## 6. Install ROCm Core SDK

Draft for gfx110x Optimised SDK

For the RX 7900 XTX:

###### NOTE: THIS ONE EXISTS according to AMD docs, BUT IT'S FOR THE PREVIOUS VERSION: sudo apt install -y amdrocm-core-sdk7.13-gfx110x
###### Since the above doesn't yet exist for 7.14, we will therefore, for the time being, use this command instead:
sudo apt install -y amdrocm-core-sdk7.14

Meta Note

The above command took ages due to downloading all GPU drivers when I only really needed gfx110x

The final guide should use the smallest package set that can successfully:

compile llama.cpp
link against HIP
run llama.cpp HIP backend
run rocminfo
run amd-smi

A clean test install should determine the final choice.

HOWEVER - I also want this to be generic so that over people with other graphics card *could* install this on their machine with minimal changes to the setup. This might be something to relook at in the near-future perhaps.

## 7. Verify ROCm Installation

### Verify ROCm Version

Run:

amd-smi version

Expected:

AMDSMI Tool: ...
ROCm version: 7.14.0

META NOTE - WHAT I ACTUALLY GOT:

```bash
... <RESULT OF PREVIOUS COMMAND STILL OUTPUTTING> ...
Setting up amdrocm-core-sdk7.14-gfx1032 (7.14.0-3) ...
Setting up amdrocm-core-sdk7.14-gfx1035 (7.14.0-3) ...
Setting up amdrocm-core-sdk7.14 (7.14.0-3) ...
Processing triggers for libc-bin (2.39-0ubuntu8.7) ...
Processing triggers for man-db (2.12.0-4build2) ...
user@JAYS-PC:~$ amd-smi version
ERROR:root:Drivers not loaded (amdgpu, amd_hsmp, ionic, bnxt_en drivers not found in modules)
user@JAYS-PC:~$ exit
logout
PS C:\Windows\system32> wsl -d Ubuntu-24.04
user@JAYS-PC:~$ amd-smi version
ERROR:root:Drivers not loaded (amdgpu, amd_hsmp, ionic, bnxt_en drivers not found in modules)
user@JAYS-PC:~$
```

### Verify GPU Detection

Run:

rocminfo

Confirm the following exists:

Name:                    gfx1100
Marketing Name:          AMD Radeon RX 7900 XTX
7.3 Verify HIP Compiler

Run:

hipcc --version

Expected:

HIP version: 7.14.x
7.4 Verify HIP Compiler Location

META NOTE - ACTUALLY GOT:

```bash
user@JAYS-PC:~$ hipcc --version
Cannot load librocdxg.so, failed:librocdxg.so: cannot open shared object file: No such file or directory
GetExportAddress failed: /opt/rocm/core-7.14/bin/../lib/libhsa-runtime64.so.1: undefined symbol: hsaKmtOpenKFD
HIP version: 7.14.60850-0000000
AMD clang version 23.0.0git (https://github.com/ROCm/llvm-project.git 46fcb339fb61119b337f973c7ca9e710a319fdd0+PATCHED:440716f8b87be9d8e20ed910e10e5b6d14d57cf6)
Target: x86_64-unknown-linux-gnu
Thread model: posix
InstalledDir: /opt/rocm/core-7.14/lib/llvm/bin
user@JAYS-PC:~$
```

Run:

readlink -f $(which hipcc)

Expected:

/opt/rocm/...

The path should resolve to the ROCm 7.14 installation.

META NOTE: ACUTALLY GOT:

```text
/opt/rocm/core-7.14/bin/hipcc
```

## Verify ROCm Installation Paths

Run:

ls -la /opt/rocm

Expected:

core
bin
lib

META NOTE: ACTUALLY GOT:

```bash
total 12
drwxr-xr-x  3 1004 1005 4096 Jul 16 23:17 .
drwxr-xr-x  3 root root 4096 Jul 16 23:14 ..
lrwxrwxrwx  1 root root   29 Jul 10 00:46 amdgcn -> /etc/alternatives/rocm-amdgcn
lrwxrwxrwx  1 root root   26 Jul 16 23:17 bin -> /etc/alternatives/rocm-bin
lrwxrwxrwx  1 root root   22 Jul 16 23:16 core -> /etc/alternatives/core
lrwxrwxrwx  1 root root   24 Jul 16 23:16 core-7 -> /etc/alternatives/core-7
drwxr-xr-x 10 1004 1005 4096 Jul 16 23:16 core-7.14
lrwxrwxrwx  1 root root   30 Jul 16 23:17 include -> /etc/alternatives/rocm-include
lrwxrwxrwx  1 root root   26 Jul 16 23:17 lib -> /etc/alternatives/rocm-lib
lrwxrwxrwx  1 root root   30 Jul 16 23:17 libexec -> /etc/alternatives/rocm-libexec
lrwxrwxrwx  1 root root   27 Jul 10 00:46 llvm -> /etc/alternatives/rocm-llvm
lrwxrwxrwx  1 root root   28 Jul 16 23:17 share -> /etc/alternatives/rocm-share
```

Verify the new internal location:

ls -la /opt/rocm/core

META NOTE: ACTUALLY GOT:

```bash
lrwxrwxrwx 1 root root 22 Jul 16 23:16 /opt/rocm/core -> /etc/alternatives/core
```

### Verify HIP Runtime Libraries

Run:

ldconfig -p | grep amdhip

Expected:

libamdhip64.so

META NOTE: ACTUALLY GOT:
nothing returned

## 8. Record the Installed ROCm State

Before continuing to llama.cpp installation, record:

rocminfo | head -100
amd-smi version
hipcc --version
readlink -f $(which hipcc)
echo $PATH
echo $LD_LIBRARY_PATH

META NOTE: ACTUALLY GOT:

```bash
user@JAYS-PC:~$ rocminfo | head -100
Cannot load librocdxg.so, failed:librocdxg.so: cannot open shared object file: No such file or directory
GetExportAddress failed: /opt/rocm/core-7.14/bin/../lib/libhsa-runtime64.so.1: undefined symbol: hsaKmtOpenKFD
WSL environment detected.
hsa_init Failed, possibly no supported GPU devices
user@JAYS-PC:~$ amd-smi version
ERROR:root:Drivers not loaded (amdgpu, amd_hsmp, ionic, bnxt_en drivers not found in modules)
user@JAYS-PC:~$ hipcc --version
Cannot load librocdxg.so, failed:librocdxg.so: cannot open shared object file: No such file or directory
GetExportAddress failed: /opt/rocm/core-7.14/bin/../lib/libhsa-runtime64.so.1: undefined symbol: hsaKmtOpenKFD
HIP version: 7.14.60850-0000000
AMD clang version 23.0.0git (https://github.com/ROCm/llvm-project.git 46fcb339fb61119b337f973c7ca9e710a319fdd0+PATCHED:440716f8b87be9d8e20ed910e10e5b6d14d57cf6)
Target: x86_64-unknown-linux-gnu
Thread model: posix
InstalledDir: /opt/rocm/core-7.14/lib/llvm/bin
user@JAYS-PC:~$ readlink -f $(which hipcc)
/opt/rocm/core-7.14/bin/hipcc
user@JAYS-PC:~$ echo $PATH
/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/usr/lib/wsl/lib:/snap/bin
user@JAYS-PC:~$ echo $LD_LIBRARY_PATH

user@JAYS-PC:~$
```

These values provide the baseline environment for all later troubleshooting.












## 9. Expected Final State

After completing this step:

Windows 10
 └── WSL2
      └── Ubuntu-24.04
           ├── ROCm Core SDK 7.14.0
           ├── HIP compiler
           ├── HIP runtime
           ├── rocminfo
           ├── amd-smi
           └── RX 7900 XTX detected as gfx1100

The system is now ready for:

```
Step 4 — Build llama.cpp
```

# Step 3 Meta Notes (Before Finalising This Step)

The following items still require confirmation:

Package Selection

Determine whether final installation should use:

amdrocm-core-sdk7.14

or:

amdrocm-core-sdk7.14-gfx110x
Environment Variables

Verify whether the package manager automatically configures:

PATH
LD_LIBRARY_PATH
ROCM_PATH
HIP_PATH

or whether the guide needs to add them manually.

WSL Specific Behaviour

Confirm whether:

sudo usermod -a -G render,video $LOGNAME

is required for WSL2.

llama.cpp Compatibility

After ROCm installation, confirm:

hipconfig -R

returns the expected ROCm 7.14 path before writing the llama.cpp build section.

Clean Install Requirement

The final published guide should be tested from:

Fresh Windows installation
        |
        v
Fresh WSL installation
        |
        v
Fresh Ubuntu-24.04 distribution
        |
        v
Fresh ROCm Core SDK 7.14.0 installation

No previous ROCm 7.2 packages should exist during validation.


---
---
---
---
---
---
---
---
---
---

## Step 6 — Build llama.cpp (HIP/ROCm Backend)

```bash
sudo apt install -y build-essential cmake git libcurl4-openssl-dev
<enter password>
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
cmake -S . -B build-hip -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1100 \
  -DCMAKE_BUILD_TYPE=Release -DGGML_HIP_ROCWMMA_FATTN=ON \
  -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON
cmake --build build-hip --config Release -j$(nproc) --target llama-cli llama-server llama-bench
```

*(You shouldn't see any `-Wnan-infinity-disabled` warnings scroll past during this, as this can cause issues later down the line)*

* *TODO: Find a way to verify the warnings mentioned above aren't being outputted somehow perhaps? Not against dropping this particular QoL idea if it's too hard to implement.*
* *TODO: Combine the HIPCXX command spanning multiple lines above into one singular line somehow.*

---

## Step 7 — Enable Vulkan

> **Why:** this setup uses the **Vulkan** build (`build-vulkan`) to actually run the model — it's the backend confirmed stable for generation on this hardware/environment combination. The HIP build above is kept for prompt-processing benchmarking. See the companion "What's Been Tried So Far" doc for the full story.

Install a Mesa build that includes WSL2's GPU-accelerated Vulkan driver ("Dozen"):
```bash
sudo add-apt-repository ppa:kisak/kisak-mesa -y
sudo apt update
sudo apt install --only-upgrade mesa-vulkan-drivers -y
sudo apt install vulkan-tools
vulkaninfo --summary
```

Confirm your actual GPU shows up somewhere in the command output (not just software `llvmpipe`):
```bash
WARNING: dzn is not a conformant Vulkan implementation, testing use only.
Dropped Escape call with ulEscapeCode : 0x03007703
==========
VULKANINFO
==========

Vulkan Instance Version: 1.3.275


Instance Extensions: count = 25
-------------------------------
VK_EXT_acquire_drm_display             : extension revision 1
VK_EXT_acquire_xlib_display            : extension revision 1
VK_EXT_debug_report                    : extension revision 10
VK_EXT_debug_utils                     : extension revision 2
VK_EXT_direct_mode_display             : extension revision 1
VK_EXT_display_surface_counter         : extension revision 1
VK_EXT_headless_surface                : extension revision 1
VK_EXT_layer_settings                  : extension revision 2
VK_EXT_surface_maintenance1            : extension revision 1
VK_EXT_swapchain_colorspace            : extension revision 5
VK_KHR_device_group_creation           : extension revision 1
VK_KHR_display                         : extension revision 23
VK_KHR_external_fence_capabilities     : extension revision 1
VK_KHR_external_memory_capabilities    : extension revision 1
VK_KHR_external_semaphore_capabilities : extension revision 1
VK_KHR_get_display_properties2         : extension revision 1
VK_KHR_get_physical_device_properties2 : extension revision 2
VK_KHR_get_surface_capabilities2       : extension revision 1
VK_KHR_portability_enumeration         : extension revision 1
VK_KHR_surface                         : extension revision 25
VK_KHR_surface_protected_capabilities  : extension revision 1
VK_KHR_wayland_surface                 : extension revision 6
VK_KHR_xcb_surface                     : extension revision 6
VK_KHR_xlib_surface                    : extension revision 6
VK_LUNARG_direct_driver_loading        : extension revision 1

Instance Layers: count = 5
--------------------------
VK_LAYER_INTEL_nullhw       INTEL NULL HW                                                1.1.73   version 1
VK_LAYER_MESA_anti_lag      Open-source implementation of the VK_AMD_anti_lag extension. 1.4.303  version 1
VK_LAYER_MESA_device_select Linux device selection layer                                 1.4.303  version 1
VK_LAYER_MESA_overlay       Mesa Overlay layer                                           1.4.303  version 1
VK_LAYER_MESA_screenshot    Mesa Screenshot layer                                        1.4.303  version 1

Devices:
========
GPU0:
        apiVersion         = 1.2.354
        driverVersion      = 26.1.4
        vendorID           = 0x1002
        deviceID           = 0x744c
        deviceType         = PHYSICAL_DEVICE_TYPE_DISCRETE_GPU
        deviceName         = Microsoft Direct3D12 (AMD Radeon RX 7900 XTX)
        driverID           = DRIVER_ID_MESA_DOZEN
        driverName         = Dozen
        driverInfo         = Mesa 26.1.4 - kisak-mesa PPA
        conformanceVersion = 0.0.0.0
        deviceUUID         = ff4423b5-22cc-c09f-49cc-ec01246647d7
        driverUUID         = 2cdde3df-0e66-1395-7d0c-91c3a968d1b6
GPU1:
        apiVersion         = 1.4.354
        driverVersion      = 26.1.4
        vendorID           = 0x10005
        deviceID           = 0x0000
        deviceType         = PHYSICAL_DEVICE_TYPE_CPU
        deviceName         = llvmpipe (LLVM 20.1.8, 256 bits)
        driverID           = DRIVER_ID_MESA_LLVMPIPE
        driverName         = llvmpipe
        driverInfo         = Mesa 26.1.4 - kisak-mesa PPA (LLVM 20.1.8)
        conformanceVersion = 1.3.1.1
        deviceUUID         = 6d657361-3236-2e31-2e34-202d206b6900
        driverUUID         = 6c6c766d-7069-7065-5555-494400000000
```

Look for `Microsoft Direct3D12 (AMD Radeon RX 7900 XTX)` as a `DISCRETE_GPU`.

* *TODO: Find a way to automate the verification above.*

Install the Vulkan SDK (needed to *compile* llama.cpp's Vulkan backend):
```bash
wget -qO- https://packages.lunarg.com/lunarg-signing-key-pub.asc | sudo tee /etc/apt/trusted.gpg.d/lunarg.asc
sudo wget -qO /etc/apt/sources.list.d/lunarg-vulkan-noble.list https://packages.lunarg.com/vulkan/lunarg-vulkan-noble.list
sudo apt update
sudo apt install vulkan-sdk -y
```

Build:
```bash
cmake -S . -B build-vulkan -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build-vulkan --config Release -j$(nproc) --target llama-server llama-bench
```

---

## Step 8 — Download the Model

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
export PATH="$HOME/.local/bin:$PATH"
pip install -U "huggingface_hub[cli]" --break-system-packages
hf download unsloth/Qwen3.6-27B-MTP-GGUF --include "Qwen3.6-27B-Q4_K_S.gguf" --local-dir ~/models
```
~16GB download.

---

## Step 9 — Launch the Server

```bash
./build-vulkan/bin/llama-server -m ~/models/Qwen3.6-27B-Q4_K_S.gguf -ngl 99 -c 200000 -fa on -np 1 --cache-type-k q4_0 --cache-type-v q4_0 --host 0.0.0.0 --port 8080
```
Leave this running in the terminal; it's a server, not a one-shot command.

From a **different** terminal (a Windows PowerShell administrator terminal), test it:
```powershell
PS C:\Windows\system32> curl.exe http://localhost:8080/v1/models
<TODO - Add output here>
PS C:\Windows\system32> curl.exe http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d --% "{\"messages\":[{\"role\":\"system\",\"content\":\"Respond directly without any thinking process.\"},{\"role\":\"user\",\"content\":\"Say hello in five words.\"}], \"max_tokens\": 50}"

```

**Confirmed working state:** ~19.5 tokens/sec sustained generation, 200k context window available, clean responses. Thinking works when allowed (TODO - Confirm this above somehow perhaps?).

---

## Not Yet Done (natural next steps)

- **MTP speculative decoding** — untested so far. Add `--spec-type draft-mtp --spec-draft-n-max 2` to the Step 9 launch command to try it.
- **Wiring up an actual coding agent** — the sandbox container pattern from Step 5 is ready to reuse; just point the agent at `http://localhost:8080/v1` as its OpenAI-compatible endpoint.
- **Disk space housekeeping** — this setup pulls in several GB of build tools, two compiled builds, and driver packages. Worth periodically checking `df -h /` inside WSL and `sudo apt clean && sudo apt autoremove -y` if space gets tight, plus compacting the WSL virtual disk from PowerShell (`diskpart` → `select vdisk file="<path to your ext4.vhdx>"` → `compact vdisk`) since deleting files inside WSL doesn't shrink it automatically.

## Next Steps Done:

<Restarted a new Ubuntu terminal>
sudo amdgpu-install --uninstall --rocmrelease=all
<enter password>
<press Enter to automatically submit Y>
sudo apt purge amdgpu-install
<press Enter to automatically submit Y>
sudo apt autoremove
<press Enter to automatically submit Y>
exit

In a PowerShell Window:
wsl --shutdown
wsl -d Ubuntu-24.04

wget https://repo.radeon.com/amdgpu-install/7.2.4/ubuntu/noble/amdgpu-install_7.2.4.70204-1_all.deb
sudo apt install ./amdgpu-install_7.2.4.70204-1_all.deb
<enter password>
sudo apt update
sudo amdgpu-install --usecase=wsl,rocm --no-dkms -y

That gave me:

```bash
jay@JAYS-PC:~$ sudo amdgpu-install --usecase=wsl,rocm --no-dkms -y
ERROR: Usecase implementation 'wsl' is not supported or invalid
jay@JAYS-PC:~$
```

So as a result I did:

```bash
sudo amdgpu-install --uninstall
sudo apt autoremove -y
sudo amdgpu-install --usecase=workstation,rocm --no-dkms -y
exit
```

In a PowerShell Window:
```powershell
wsl --shutdown
wsl -d Ubuntu-24.04
```

Followed by:

```bash
jay@JAYS-PC:~$ rocminfo
WSL environment detected.
hsa_init Failed, possibly no supported GPU devices
jay@JAYS-PC:~$ exit
logout
PS C:\Windows\system32> wsl --shutdown
PS C:\Windows\system32> wsl -d Ubuntu-24.04
jay@JAYS-PC:~$ rocminfo
WSL environment detected.
hsa_init Failed, possibly no supported GPU devices
jay@JAYS-PC:~$ exit
logout
PS C:\Windows\system32> wsl --shutdown
PS C:\Windows\system32> wsl -d Ubuntu-24.04
jay@JAYS-PC:~$ sudo usermod -aG render,video $USER
[sudo] password for jay:
jay@JAYS-PC:~$ rocminfo
WSL environment detected.
hsa_init Failed, possibly no supported GPU devices
jay@JAYS-PC:~$ exit
logout
PS C:\Windows\system32> wsl --shutdown
PS C:\Windows\system32> wsl -d Ubuntu-24.04
jay@JAYS-PC:~$ nano ~/.bashrc
```

Scroll to the very bottom and add the following lines to map your paths and turn on detection
```bash
export ROCM_HOME=/opt/rocm
export PATH=$ROCM_HOME/bin:$PATH
export LD_LIBRARY_PATH=$ROCM_HOME/lib:$LD_LIBRARY_PATH
export HSA_ENABLE_DXG_DETECTION=1
```
Save and exit (Ctrl+O, Enter, then Ctrl+X).

Reload the profile into your current window:
```bash
jay@JAYS-PC:~$ source ~/.bashrc
```

Recheck:
```bash
jay@JAYS-PC:~$ rocminfo
WSL environment detected.
Cannot load librocdxg.so, failed:librocdxg.so: cannot open shared object file: No such file or directory
dlsym failed: /opt/rocm/lib/libhsa-runtime64.so.1: undefined symbol: hsaKmtOpenKFD
Segmentation fault (core dumped)

this was done via:
wget https://github.com/ROCm/librocdxg/releases/download/v1.2.1/rocdxg-roct_1.2.1_amd64.deb

sudo apt install ./rocdxg-roct_1.2.1_amd64.deb -y
<enter password>
```

Check the GPU agent is present:

```bash
jay@JAYS-PC:~$ rocminfo
WSL environment detected.
=====================
HSA System Attributes
=====================
Runtime Version:         1.18
Runtime Ext Version:     1.15
System Timestamp Freq.:  1000.000000MHz
Sig. Max Wait Duration:  18446744073709551615 (0xFFFFFFFFFFFFFFFF) (timestamp count)
Machine Model:           LARGE
System Endianness:       LITTLE
Mwaitx:                  DISABLED
XNACK enabled:           NO
DMAbuf Support:          YES
VMM Support:             YES

==========
HSA Agents
==========
*******
Agent 1
*******
  Name:                    AMD Ryzen 7 5700X3D 8-Core Processor
  Uuid:                    CPU-XX
  Marketing Name:          AMD Ryzen 7 5700X3D 8-Core Processor
  Vendor Name:             CPU
  Feature:                 None specified
  Profile:                 FULL_PROFILE
  Float Round Mode:        NEAR
  Max Queue Number:        0(0x0)
  Queue Min Size:          0(0x0)
  Queue Max Size:          0(0x0)
  Queue Type:              MULTI
  Node:                    0
  Device Type:             CPU
  Cache Info:
    L1:                      32768(0x8000) KB
  Chip ID:                 0(0x0)
  Cacheline Size:          64(0x40)
  BDFID:                   0
  Internal Node ID:        0
  Compute Unit:            16
  SIMDs per CU:            0
  Shader Engines:          0
  Shader Arrs. per Eng.:   0
  Memory Properties:
  Features:                None
  Pool Info:
    Pool 1
      Segment:                 GLOBAL; FLAGS: FINE GRAINED
      Size:                    16332440(0xf93698) KB
      Allocatable:             TRUE
      Alloc Granule:           4KB
      Alloc Recommended Granule:4KB
      Alloc Alignment:         4KB
      Accessible by all:       TRUE
    Pool 2
      Segment:                 GLOBAL; FLAGS: EXTENDED FINE GRAINED
      Size:                    16332440(0xf93698) KB
      Allocatable:             TRUE
      Alloc Granule:           4KB
      Alloc Recommended Granule:4KB
      Alloc Alignment:         4KB
      Accessible by all:       TRUE
    Pool 3
      Segment:                 GLOBAL; FLAGS: KERNARG, FINE GRAINED
      Size:                    16332440(0xf93698) KB
      Allocatable:             TRUE
      Alloc Granule:           4KB
      Alloc Recommended Granule:4KB
      Alloc Alignment:         4KB
      Accessible by all:       TRUE
    Pool 4
      Segment:                 GLOBAL; FLAGS: COARSE GRAINED
      Size:                    16332440(0xf93698) KB
      Allocatable:             TRUE
      Alloc Granule:           4KB
      Alloc Recommended Granule:4KB
      Alloc Alignment:         4KB
      Accessible by all:       TRUE
  ISA Info:
*******
Agent 2
*******
  Name:                    gfx1100
  Uuid:                    GPU-4642651462a3e4ff
  Marketing Name:          AMD Radeon RX 7900 XTX
  Vendor Name:             AMD
  Feature:                 KERNEL_DISPATCH
  Profile:                 BASE_PROFILE
  Float Round Mode:        NEAR
  Max Queue Number:        128(0x80)
  Queue Min Size:          64(0x40)
  Queue Max Size:          131072(0x20000)
  Queue Type:              MULTI
  Node:                    1
  Device Type:             GPU
  Cache Info:
    L1:                      32(0x20) KB
    L2:                      6144(0x1800) KB
    L3:                      98304(0x18000) KB
  Chip ID:                 29772(0x744c)
  Cacheline Size:          64(0x40)
  Max Clock Freq. (MHz):   2482
  BDFID:                   12032
  Internal Node ID:        1
  Compute Unit:            96
  SIMDs per CU:            2
  Shader Engines:          6
  Shader Arrs. per Eng.:   2
  Coherent Host Access:    FALSE
  Memory Properties:
  Features:                KERNEL_DISPATCH
  Fast F16 Operation:      TRUE
  Wavefront Size:          32(0x20)
  Workgroup Max Size:      1024(0x400)
  Workgroup Max Size per Dimension:
    x                        1024(0x400)
    y                        1024(0x400)
    z                        1024(0x400)
  Max Waves Per CU:        32(0x20)
  Max Work-item Per CU:    1024(0x400)
  Grid Max Size:           4294967295(0xffffffff)
  Grid Max Size per Dimension:
    x                        2147483647(0x7fffffff)
    y                        65535(0xffff)
    z                        65535(0xffff)
  Max fbarriers/Workgrp:   32
  Packet Processor uCode:: 632
  SDMA engine uCode::      27
  IOMMU Support::          None
  Pool Info:
    Pool 1
      Segment:                 GLOBAL; FLAGS: COARSE GRAINED
      Size:                    25105384(0x17f13e8) KB
      Allocatable:             TRUE
      Alloc Granule:           4KB
      Alloc Recommended Granule:2048KB
      Alloc Alignment:         4KB
      Accessible by all:       FALSE
    Pool 2
      Segment:                 GLOBAL; FLAGS: EXTENDED FINE GRAINED
      Size:                    25105384(0x17f13e8) KB
      Allocatable:             TRUE
      Alloc Granule:           4KB
      Alloc Recommended Granule:2048KB
      Alloc Alignment:         4KB
      Accessible by all:       FALSE
    Pool 3
      Segment:                 GROUP
      Size:                    64(0x40) KB
      Allocatable:             FALSE
      Alloc Granule:           0KB
      Alloc Recommended Granule:0KB
      Alloc Alignment:         0KB
      Accessible by all:       FALSE
  ISA Info:
    ISA 1
      Name:                    amdgcn-amd-amdhsa--gfx1100
      Machine Models:          HSA_MACHINE_MODEL_LARGE
      Profiles:                HSA_PROFILE_BASE
      Default Rounding Mode:   NEAR
      Default Rounding Mode:   NEAR
      Fast f16:                TRUE
      Workgroup Max Size:      1024(0x400)
      Workgroup Max Size per Dimension:
        x                        1024(0x400)
        y                        1024(0x400)
        z                        1024(0x400)
      Grid Max Size:           4294967295(0xffffffff)
      Grid Max Size per Dimension:
        x                        2147483647(0x7fffffff)
        y                        65535(0xffff)
        z                        65535(0xffff)
      FBarrier Max Size:       32
    ISA 2
      Name:                    amdgcn-amd-amdhsa--gfx11-generic
      Machine Models:          HSA_MACHINE_MODEL_LARGE
      Profiles:                HSA_PROFILE_BASE
      Default Rounding Mode:   NEAR
      Default Rounding Mode:   NEAR
      Fast f16:                TRUE
      Workgroup Max Size:      1024(0x400)
      Workgroup Max Size per Dimension:
        x                        1024(0x400)
        y                        1024(0x400)
        z                        1024(0x400)
      Grid Max Size:           4294967295(0xffffffff)
      Grid Max Size per Dimension:
        x                        2147483647(0x7fffffff)
        y                        65535(0xffff)
        z                        65535(0xffff)
      FBarrier Max Size:       32
*** Done ***
jay@JAYS-PC:~$
```

The following commands were then run:

```bash
# 3. Confirm the WSL-specific runtime package landed, not the conflicting one:
jay@JAYS-PC:~$ dpkg -l | grep rocr4wsl
jay@JAYS-PC:~$
```

*<META NOTE: No output from the comment above! Due to this, the following items #4 and #5 from the Claude documentation steps have been noted but NOT performed:>*

```bash
# POSSIBLE TODO - 4. Build librocdxg from the develop branch, not a tagged release — one source documents an as-of-recently-merged fix there for VRAM pool-size reporting under WSL (the primary evidence for that specific fix is on an APU/shared-memory chip, not your discrete 7900 XTX, but there's no reason to avoid it either):
bashcd ~
git clone https://github.com/ROCm/librocdxg.git
cd librocdxg
git checkout develop
export win_sdk='/mnt/c/Program Files (x86)/Windows Kits/10/Include/10.0.28000.0'
mkdir -p build && cd build
cmake .. -DWIN_SDK="${win_sdk}/shared"
make
sudo make install

# POSSIBLE TODO - 5. Persist the required environment variables to ~/.bashrc (the DXG-detection var is a manual requirement until ROCm 7.13, which isn't out yet):
bashecho 'export HSA_ENABLE_DXG_DETECTION=1' >> ~/.bashrc
source ~/.bashrc
```

Instead, this command was simply run:

```bash
# 6. Verify:
rocminfo | grep -A3 gfx1100
jay@JAYS-PC:~$ rocminfo | grep -A3 gfx1100
  Name:                    gfx1100
  Uuid:                    GPU-4642651462a3e4ff
  Marketing Name:          AMD Radeon RX 7900 XTX
  Vendor Name:             AMD
--
      Name:                    amdgcn-amd-amdhsa--gfx1100
      Machine Models:          HSA_MACHINE_MODEL_LARGE
      Profiles:                HSA_PROFILE_BASE
      Default Rounding Mode:   NEAR
jay@JAYS-PC:~$
```

Then:

```bash
jay@JAYS-PC:~/llama.cpp$ rm -rf build-hip
jay@JAYS-PC:~/llama.cpp$ HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" cmake -S . -B build-hip -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1100 -DCMAKE_BUILD_TYPE=Release -DGGML_HIP_ROCWMMA_FATTN=ON -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=ON
-- The C compiler identification is GNU 13.3.0
-- The CXX compiler identification is GNU 13.3.0
-- Detecting C compiler ABI info
-- Detecting C compiler ABI info - done
-- Check for working C compiler: /usr/bin/cc - skipped
-- Detecting C compile features
-- Detecting C compile features - done
-- Detecting CXX compiler ABI info
-- Detecting CXX compiler ABI info - done
-- Check for working CXX compiler: /usr/bin/c++ - skipped
-- Detecting CXX compile features
-- Detecting CXX compile features - done
CMAKE_BUILD_TYPE=Release
-- Found Git: /usr/bin/git (found version "2.43.0")
-- The ASM compiler identification is GNU
-- Found assembler: /usr/bin/cc
-- Performing Test CMAKE_HAVE_LIBC_PTHREAD
-- Performing Test CMAKE_HAVE_LIBC_PTHREAD - Success
-- Found Threads: TRUE
-- Warning: ccache not found - consider installing it for faster compilation or disable this warning with GGML_CCACHE=OFF
-- CMAKE_SYSTEM_PROCESSOR: x86_64
-- GGML_SYSTEM_ARCH: x86
-- Found OpenMP_C: -fopenmp (found version "4.5")
-- Found OpenMP_CXX: -fopenmp (found version "4.5")
-- Found OpenMP: TRUE (found version "4.5")
-- Including CPU backend
-- x86 detected
-- Adding CPU backend variant ggml-cpu: -march=native
-- The HIP compiler identification is Clang 22.0.0
-- Detecting HIP compiler ABI info
-- Detecting HIP compiler ABI info - done
-- Check for working HIP compiler: /opt/rocm-7.2.4/lib/llvm/bin/clang - skipped
-- Detecting HIP compile features
-- Detecting HIP compile features - done
-- HIP and hipBLAS found
-- Including HIP backend
-- ggml version: 0.15.3
-- ggml commit:  bec4772f6
-- Could NOT find OpenSSL, try to set the path to OpenSSL root folder in the system variable OPENSSL_ROOT_DIR (missing: OPENSSL_CRYPTO_LIBRARY OPENSSL_INCLUDE_DIR)
CMake Warning at vendor/cpp-httplib/CMakeLists.txt:152 (message):
  OpenSSL not found, HTTPS support disabled


-- Generating embedded license file for target: llama-app
-- Configuring done (2.7s)
-- Generating done (0.3s)
-- Build files have been written to: /home/jay/llama.cpp/build-hip
jay@JAYS-PC:~/llama.cpp$ cmake --build build-hip --config Release -j$(nproc) --target llama-cli llama-server
[  0%] Building CXX object common/CMakeFiles/llama-common-base.dir/build-info.cpp.o
# <... Long build process here ...>
[100%] Built target llama-server
jay@JAYS-PC:~/llama.cpp$
```

Then:

```bash
# META-NOTE: Had to add this "Pre-8" sub-step here, otherwise I got "-bash: ./build-hip/bin/llama-bench: No such file or directory"!
jay@JAYS-PC:~/llama.cpp$ cmake --build build-hip --config Release -j$(nproc) --target llama-bench
[  0%] Built target llama-common-base
[  0%] Built target cpp-httplib
[  3%] Built target ggml-base
[  7%] Built target ggml-cpu
[ 45%] Built target ggml-hip
[ 45%] Built target ggml
[ 90%] Built target llama
[100%] Built target llama-common
[100%] Building CXX object tools/llama-bench/CMakeFiles/llama-bench-impl.dir/llama-bench.cpp.o
[100%] Linking CXX shared library ../../bin/libllama-bench-impl.so
[100%] Built target llama-bench-impl
[100%] Building CXX object tools/llama-bench/CMakeFiles/llama-bench.dir/main.cpp.o
[100%] Linking CXX executable ../../bin/llama-bench
[100%] Built target llama-bench

# 8. Retest — small model first, for a fast, cheap first signal, then the 27B baseline if that's clean:
jay@JAYS-PC:~/llama.cpp$ ./build-hip/bin/llama-bench -m ~/models/qwen2.5-1.5b/qwen2.5-1.5b-instruct-q4_k_m.gguf -fa 1
ggml_cuda_init: found 1 ROCm devices (Total VRAM: 24516 MiB):
  Device 0: AMD Radeon RX 7900 XTX, gfx1100 (0x1100), VMM: no, Wave Size: 32, VRAM: 24516 MiB
| model                          |       size |     params | backend    | ngl |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --: | --------------: | -------------------: |
| qwen2 1.5B Q4_K - Medium       |   1.04 GiB |     1.78 B | ROCm       |  -1 |   1 |           pp512 |   12207.61 ± 1009.56 |
| qwen2 1.5B Q4_K - Medium       |   1.04 GiB |     1.78 B | ROCm       |  -1 |   1 |           tg128 |        248.81 ± 5.88 |

build: bec4772f6 (9913)
jay@JAYS-PC:~/llama.cpp$
```

The second command from #8 was run...:
./build-hip/bin/llama-bench -m ~/models/Qwen3.6-27B-Q4_K_S.gguf -fa 1
... and it did generate a table similar to the one above, with an actual t/s for both pp512 (already working in the past) but now also for the tg128!
Unfortunately, just after this Qwen3.6-27B-Q4_K_S result of the tg128 was printed to the screen, the Windows OS crashed with a DRIVER_IRQL_NOT_LESS_OR_EQUAL error.
It's possible too much VRAM was being used? I can't say yes or no to this right now, since I didn't have Task Manager up at the time.

The following day, I went to continue testing, so run the following commands and saw the following outputs:

```
PowerShell 7.6.3
PS C:\Windows\System32> wsl -d Ubuntu-24.04
Welcome to Ubuntu 24.04.4 LTS (GNU/Linux 6.18.33.2-microsoft-standard-WSL2 x86_64)

 * Documentation:  https://help.ubuntu.com
 * Management:     https://landscape.canonical.com
 * Support:        https://ubuntu.com/pro

 System information as of Fri Jul 10 10:40:21 BST 2026

  System load:  0.0                 Processes:             73
  Usage of /:   5.2% of 1006.85GB   Users logged in:       0
  Memory usage: 3%                  IPv4 address for eth0: 172.31.189.98
  Swap usage:   0%

  => There is 1 zombie process.

 * Strictly confined Kubernetes makes edge and IoT secure. Learn how MicroK8s
   just raised the bar for easy, resilient and secure K8s cluster deployment.

   https://ubuntu.com/engage/secure-kubernetes-at-the-edge

This message is shown once a day. To disable it please create the
/home/jay/.hushlogin file.
jay@JAYS-PC:$cd llama.cpp
jay@JAYS-PC:./build-hip/bin/llama-bench -m ~/models/Qwen3.6-27B-Q4_K_S.gguf -fa 1
```

This crashed my whole PC again the same way the same way just after the second test (tg128) was outputted. This time though, I had Task Manager open, and could see the VRAM level do this:

<Start of tests - 24.0 GB TOTAL>
16.0 GB in use
17.1 GB in use
16.1 GB in use <- Somewhere around here (either just before or just after) the second test was outputted
8.3 GB in use <- The VRAM started dropping every couple seconds or so from this point
6.3 GB in use
4.3 GB in use
1.9 GB in use <- This one appears for not even a full second before I got the same Windows OS driver crash error message from before, and the whole PC had to reboot after the BSOD.

I then tested:
HSA_ENABLE_SDMA=0 ./build-hip/bin/llama-bench -m ~/models/Qwen3.6-27B-Q4_K_S.gguf -fa 1

But that crashed as well, so then I did:

rm -rf build-hip
HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" cmake -S . -B build-hip -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1100 -DCMAKE_BUILD_TYPE=Debug -DCMAKE_CXX_FLAGS="-fsanitize=address,undefined" -DCMAKE_C_FLAGS="-fsanitize=address,undefined"
cmake --build build-hip --config Debug -j$(nproc) --target llama-bench
./build-hip/bin/llama-bench -m ~/models/Qwen3.6-27B-Q4_K_S.gguf -fa 1

Which gave me:

jay@JAYS-PC:~/llama.cpp$ ./build-hip/bin/llama-bench -m ~/models/Qwen3.6-27B-Q4_K_S.gguf -fa 1
=================================================================
==5684==ERROR: AddressSanitizer: odr-violation (0x79acdfd35e60):
  [1] size=1 'piecewise_construct' /usr/include/c++/13/bits/stl_pair.h:83:53 in /home/jay/llama.cpp/build-hip/bin/libllama.so.0
  [2] size=1 'piecewise_construct' /usr/include/c++/13/bits/stl_pair.h:83:53 in /home/jay/llama.cpp/build-hip/bin/libggml-base.so.0
These globals were registered at these points:
  [1]:
    #0 0x79ace805306f in __asan_register_globals ../../../../src/libsanitizer/asan/asan_globals.cpp:350
    #1 0x79acdf8ebab8 in _sub_I_00099_1.217856 (/home/jay/llama.cpp/build-hip/bin/libllama.so.0+0x38ebab8) (BuildId: dbb8fc8c87324625ad3d61588f7ecec9b211cc19)
    #2 0x79ace882d71e in call_init elf/dl-init.c:74
    #3 0x79ace882d823 in call_init elf/dl-init.c:120
    #4 0x79ace882d823 in _dl_init elf/dl-init.c:121
    #5 0x79ace884759f  (/lib64/ld-linux-x86-64.so.2+0x1f59f) (BuildId: da07864eb4c1b06504b8688d25d7e84759fe708d)

  [2]:
    #0 0x79ace805306f in __asan_register_globals ../../../../src/libsanitizer/asan/asan_globals.cpp:350
    #1 0x79acd1eda06c in _sub_I_00099_1.36015 (/home/jay/llama.cpp/build-hip/bin/libggml-base.so.0+0x6da06c) (BuildId: bd293a934db93a449a91598fc1ec79f9a7e2dcd8)
    #2 0x79ace882d71e in call_init elf/dl-init.c:74
    #3 0x79ace882d823 in call_init elf/dl-init.c:120
    #4 0x79ace882d823 in _dl_init elf/dl-init.c:121
    #5 0x79ace884759f  (/lib64/ld-linux-x86-64.so.2+0x1f59f) (BuildId: da07864eb4c1b06504b8688d25d7e84759fe708d)

==5684==HINT: if you don't care about these errors you may set ASAN_OPTIONS=detect_odr_violation=0
SUMMARY: AddressSanitizer: odr-violation: global 'piecewise_construct' at /usr/include/c++/13/bits/stl_pair.h:83:53 in /home/jay/llama.cpp/build-hip/bin/libllama.so.0
==5684==ABORTING
jay@JAYS-PC:~/llama.cpp$

So I did:

ASAN_OPTIONS=detect_odr_violation=0 ./build-hip/bin/llama-bench -m ~/models/Qwen3.6-27B-Q4_K_S.gguf -fa 1

I got (outside of my Linux machine, in my real Windows OS):

AMD Bug Report Tool

AMD software detected that a driver timeout has occurred on your system. An issue report has been created that can be sent to AMD to help us improve our software. Would you like to report this issue?
Close / Report Issue

This box has never appeared before. The models are also still "running", but I can tell that it's stopped working.

So, I then did:
New-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\GraphicsDrivers" -Name "TdrDelay" -Value 10 -PropertyType DWORD -Force

Restarted my enitre PC.

jay@JAYS-PC:~/llama.cpp$ ASAN_OPTIONS=detect_odr_violation=0 ./build-hip/bin/llama-bench -m ~/models/Qwen3.6-27B-Q4_K_S.gguf -fa 1
warning: asserts enabled, performance may be affected
warning: debug build, performance may be affected
warning: sanitizer enabled, performance may be affected
ggml_cuda_init: found 1 ROCm devices (Total VRAM: 24516 MiB):
  Device 0: AMD Radeon RX 7900 XTX, gfx1100 (0x1100), VMM: no, Wave Size: 32, VRAM: 24516 MiB
register_backend: registered backend ROCm (1 devices)
register_device: registered device ROCm0 (AMD Radeon RX 7900 XTX)
register_backend: registered backend CPU (1 devices)
register_device: registered device CPU (AMD Ryzen 7 5700X3D 8-Core Processor)
load_backend: failed to find ggml_backend_init in /home/jay/llama.cpp/build-hip/bin/libggml-hip.so
load_backend: failed to find ggml_backend_init in /home/jay/llama.cpp/build-hip/bin/libggml-cpu.so
| model                          |       size |     params | backend    | ngl |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --: | --------------: | -------------------: |
AddressSanitizer:DEADLYSIGNAL
=================================================================
==483==ERROR: AddressSanitizer: SEGV on unknown address (pc 0x748472ab931f bp 0x7fff4ef6e6e0 sp 0x7fff4ef6e650 T0)
==483==The signal is caused by a READ memory access.
==483==Hint: this fault was caused by a dereference of a high value address (see register values below).  Disassemble the provided pc to learn which register was used.
    #0 0x748472ab931f  (/opt/rocm/lib/libamdhip64.so.7+0x2b931f) (BuildId: db1aaf11568a2d99249b8c24ff700694ff6857dd)
    #1 0x748472ab9b73  (/opt/rocm/lib/libamdhip64.so.7+0x2b9b73) (BuildId: db1aaf11568a2d99249b8c24ff700694ff6857dd)
    #2 0x748472b0f814  (/opt/rocm/lib/libamdhip64.so.7+0x30f814) (BuildId: db1aaf11568a2d99249b8c24ff700694ff6857dd)
    #3 0x748472aba6dd  (/opt/rocm/lib/libamdhip64.so.7+0x2ba6dd) (BuildId: db1aaf11568a2d99249b8c24ff700694ff6857dd)
    #4 0x748472ad258d  (/opt/rocm/lib/libamdhip64.so.7+0x2d258d) (BuildId: db1aaf11568a2d99249b8c24ff700694ff6857dd)
    #5 0x748480c991f4 in mul_mat_vec_q_switch_type(void const*, ggml_type, void const*, int const*, ggml_cuda_mm_fusion_args_device, float*, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, int, ihipStream_t*) /home/jay/llama.cpp/ggml/src/ggml-cuda/common.cuh
    #6 0x748480c652d5 in ggml_cuda_mul_mat_vec_q(ggml_backend_cuda_context&, ggml_tensor const*, ggml_tensor const*, ggml_tensor const*, ggml_tensor*, ggml_cuda_mm_fusion_args_host const*) /home/jay/llama.cpp/ggml/src/ggml-cuda/mmvq.cu:1262
    #7 0x748480bbe31a in ggml_cuda_compute_forward(ggml_backend_cuda_context&, ggml_tensor*) /home/jay/llama.cpp/ggml/src/ggml-cuda/ggml-cuda.cu:2120
    #8 0x748480bbe31a in ggml_cuda_graph_evaluate_and_capture(ggml_backend_cuda_context*, ggml_cgraph*, bool, bool, void const*) /home/jay/llama.cpp/ggml/src/ggml-cuda/ggml-cuda.cu:3920
    #9 0x748480bb919a in ggml_backend_cuda_graph_compute(ggml_backend*, ggml_cgraph*) /home/jay/llama.cpp/ggml/src/ggml-cuda/ggml-cuda.cu:4040
    #10 0x74847868231c in ggml_backend_graph_compute_async /home/jay/llama.cpp/ggml/src/ggml-backend.cpp:452
    #11 0x74847869cb83 in ggml_backend_sched_compute_splits /home/jay/llama.cpp/ggml/src/ggml-backend.cpp:1678
    #12 0x7484786a1fe7 in ggml_backend_sched_graph_compute_async /home/jay/llama.cpp/ggml/src/ggml-backend.cpp:1901
    #13 0x74848539885c in llama_context::graph_compute(ggml_cgraph*, bool) /home/jay/llama.cpp/src/llama-context.cpp:2444
    #14 0x74848537b95c in llama_context::process_ubatch(llama_ubatch const&, llm_graph_type, llama_memory_context_i*, ggml_status&) /home/jay/llama.cpp/src/llama-context.cpp:1364
    #15 0x7484853856da in llama_context::decode(llama_batch const&) /home/jay/llama.cpp/src/llama-context.cpp:1843
    #16 0x7484853b7a67 in llama_decode /home/jay/llama.cpp/src/llama-context.cpp:4061
    #17 0x74848e3790f6 in test_prompt /home/jay/llama.cpp/tools/llama-bench/llama-bench.cpp:2109
    #18 0x74848e37db8c in llama_bench(int, char**) /home/jay/llama.cpp/tools/llama-bench/llama-bench.cpp:2336
    #19 0x5f1e258671ac in main /home/jay/llama.cpp/tools/llama-bench/main.cpp:4
    #20 0x74847722a1c9 in __libc_start_call_main ../sysdeps/nptl/libc_start_call_main.h:58
    #21 0x74847722a28a in __libc_start_main_impl ../csu/libc-start.c:360
    #22 0x5f1e258670c4 in _start (/home/jay/llama.cpp/build-hip/bin/llama-bench+0x10c4) (BuildId: 344f58cea80eda7bc95c94c0d8b39d81e9450614)

AddressSanitizer can not provide additional info.
SUMMARY: AddressSanitizer: SEGV (/opt/rocm/lib/libamdhip64.so.7+0x2b931f) (BuildId: db1aaf11568a2d99249b8c24ff700694ff6857dd)
==483==ABORTING
jay@JAYS-PC:~/llama.cpp$

