# ALFRED

ALFRED is a Windows + WSL2 setup workflow for an isolated Ubuntu 24.04 environment with AMD ROCm 7.14 and llama.cpp.

Start with the [ALFRED setup guide](scripts/README.md). It explains prerequisites, the consolidated PowerShell and Bash entry points, setup stages, model downloads, and safety boundaries.

The setup is intentionally non-destructive toward existing WSL distributions: it does not unregister, reset, or delete them. It does disable Windows-drive automount and Windows interop inside the configured Ubuntu distro.
