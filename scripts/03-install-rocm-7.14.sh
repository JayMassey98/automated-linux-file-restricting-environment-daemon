#!/usr/bin/env bash
set -euo pipefail

if ! grep -qi microsoft /proc/version; then
    echo "Run inside WSL Ubuntu." >&2
    exit 1
fi
if [[ $EUID -eq 0 ]]; then
    echo "Run as a normal user; this script invokes sudo." >&2
    exit 1
fi

. /etc/os-release
if [[ ${VERSION_ID:-} != "24.04" ]]; then
    echo "Ubuntu 24.04 is required; detected ${PRETTY_NAME:-unknown}." >&2
    exit 1
fi

sudo apt-get update
sudo apt-get install -y ca-certificates wget gpg
sudo install -d -m 0755 /etc/apt/keyrings

wget -qO- https://repo.radeon.com/rocm/rocm.gpg.key \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/rocm.gpg >/dev/null

echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/7.14 noble main" \
    | sudo tee /etc/apt/sources.list.d/rocm.list >/dev/null

sudo apt-get update
sudo apt-get install -y amdrocm-core-sdk7.14

# ROCDXG 1.2.1 package referenced by the 7.14 guide.
ROCDXG_DEB_URL="https://repo.radeon.com/rocm/rocdxg/1.2.1/ubuntu/24.04/rocdxg_1.2.1_amd64.deb"
deb=$(mktemp --suffix=.deb)
trap 'rm -f "$deb"' EXIT
wget -O "$deb" "$ROCDXG_DEB_URL"
sudo apt-get install -y "$deb"

[[ -d /opt/rocm/core-7.14 ]] || {
    echo "Expected /opt/rocm/core-7.14 was not found." >&2
    exit 1
}

command -v hipcc >/dev/null || {
    echo "hipcc was not found after SDK installation." >&2
    exit 1
}
hipcc --version

if command -v rocminfo >/dev/null; then
    rocminfo | grep -E 'Name:|gfx[0-9]+' | head -n 30 || true
fi

ldconfig -p | grep -i rocdxg || \
    echo "ROCDXG library not listed by ldconfig; inspect the installed package paths."
