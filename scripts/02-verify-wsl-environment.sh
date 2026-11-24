#!/usr/bin/env bash
set -u

failures=0
check() {
    local label=$1
    shift
    if "$@"; then
        printf '[OK]   %s\n' "$label"
    else
        printf '[FAIL] %s\n' "$label"
        failures=$((failures + 1))
    fi
}

check "Running inside WSL" grep -qi microsoft /proc/version
check "systemd is active" systemctl is-system-running --quiet
check "Windows interop paths absent from PATH" bash -c '! grep -Eqi "WindowsApps|/mnt/[a-z]/Windows|/System32" <<<"$PATH"'
check "Windows C: drive is not automounted" bash -c '[[ ! -d /mnt/c/Windows ]]'
check "/dev/dxg exists" test -e /dev/dxg

if [[ -e /mnt/wslg ]]; then
    echo "[INFO] WSLg mount detected."
else
    echo "[INFO] WSLg mount not detected (not required for headless server use)."
fi

if [[ -r /etc/wsl.conf ]]; then
    echo "--- /etc/wsl.conf ---"
    cat /etc/wsl.conf
fi

if (( failures > 0 )); then
    printf '\n%d required check(s) failed. Review the WSL setup and configuration.\n' "$failures" >&2
    exit 1
fi

echo "WSL checks passed. ROCm-specific checks run after SDK installation."
