# ROCm 7.14 + llama.cpp setup scripts

Run these scripts in order:

1. **Windows PowerShell as Administrator:** `00-windows-host.ps1`
2. Launch Ubuntu 24.04 under WSL and create its Linux user.
3. **Inside WSL:** `01-configure-wsl-isolation.sh`
4. Exit WSL; from Windows run `wsl --shutdown`, then reopen Ubuntu.
5. **Inside WSL:** `02-verify-wsl-environment.sh`
6. **Inside WSL:** `03-install-rocm-7.14.sh`
7. **Inside WSL:** `04-prepare-llama-cpp.sh`
8. **Inside WSL:** `05-build-backends.sh`
9. Optionally, **Inside WSL:** `06-launch-qwen-server.sh`

## Before starting

- Install a current AMD Adrenalin driver on Windows that supports ROCm-on-WSL for your GPU. Driver installation is intentionally manual; use a release appropriate for your hardware and reboot if requested.
- Use Ubuntu 24.04 on WSL 2.
- Review the scripts before running them. Package installation and system configuration require elevated privileges where indicated.
- These scripts do **not** unregister, reset, or delete an existing WSL distribution, and do not edit Windows TDR registry settings.
- The WSL isolation configuration disables Windows-drive automount and Windows interop, enables systemd, and sets the current Linux user as the default user. This intentionally removes Windows path/interop convenience from that distro.

## Paths and models

Defaults:
- llama.cpp: `$HOME/src/llama.cpp`
- Models: `$HOME/models`
- Build directories: `build-cpu`, `build-vulkan`, `build-hip`

Export `LLAMA_DIR` and/or `MODEL_DIR` to override the defaults. llama.cpp is pinned to commit `bec4772f6a2527d371557b5d2032641e5ff7619c`. Hugging Face downloads may require accepting model access terms.

## Server

The optional launcher defaults to the Vulkan build, the Qwen3.6 27B GGUF model directory, context size 200000, and `0.0.0.0:8080`. Large models and context sizes may exceed available RAM/VRAM; lower `CTX_SIZE` if needed.

From Windows, test the API with:

```powershell
curl.exe http://localhost:8080/v1/models
```

Stop the server with Ctrl+C.

## Scope notes

The older 7.2 guide includes historical failed installation attempts, crash traces, and workarounds (including a TdrDelay registry tweak). Those are not automated: they are troubleshooting history, not safe default setup steps. The 7.14 guide does not fully specify a final server-launch procedure, so the optional launcher follows the earlier launch pattern. Review its model and context settings for your hardware.
