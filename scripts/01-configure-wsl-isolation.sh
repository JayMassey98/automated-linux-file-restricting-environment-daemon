#!/usr/bin/env bash
set -euo pipefail

if ! grep -qi microsoft /proc/version; then
    echo "Run this script inside WSL, not native Linux." >&2
    exit 1
fi
if [[ $EUID -eq 0 ]]; then
    echo "Run as your normal WSL user; sudo is used only to write /etc/wsl.conf." >&2
    exit 1
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

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

echo "The following configuration will replace /etc/wsl.conf:"
cat "$tmp"
read -r -p "Apply this WSL isolation configuration? [y/N] " answer
if [[ ! $answer =~ ^[Yy]$ ]]; then
    echo "No changes made."
    exit 0
fi

sudo install -o root -g root -m 0644 "$tmp" /etc/wsl.conf
echo "Written /etc/wsl.conf. Exit this distro and run 'wsl --shutdown' from Windows, then reopen it."
