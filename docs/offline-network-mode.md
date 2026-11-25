# ALFRED online/offline network mode design

**Status: design only, with Linux runtime check available.** The Windows PowerShell verification wrapper was found to contain malformed code and has been removed pending repair. The commands that change networking modes (offline and online) are not implemented.

ALFRED needs two explicit operating modes:

- **Online:** WSL may use the network for approved downloads, updates, model retrieval, and package installation.
- **Offline:** WSL networking is disconnected. ALFRED must use only locally staged models, source bundles, packages, and installers. A failed or inconclusive isolation check must stop ALFRED rather than silently continue.

## Intended operator interface

The proposed Windows PowerShell interface is:

\`\`\`powershell
.\scripts\alfred.ps1 -Stage offline
.\scripts\alfred.ps1 -Stage verify-network
.\scripts\alfred.ps1 -Stage online
\`\`\`

No PowerShell offline, online, or verify-network stage is currently implemented. The Linux-only command `bash scripts/alfred.sh verify-network` checks interface addresses and routes; it does not verify Windows policy or effective host networking controls. Do not use the proposed PowerShell commands until a tested implementation is merged.

## Enforcement design

1. Before changing anything, capture the exact bytes and existence state of the user's \`%UserProfile%\\.wslconfig\`, plus the active WSL Hyper-V firewall settings. Store a versioned recovery record in the user's local ALFRED state directory. Never overwrite an existing recovery record.
2. Set \`[wsl2] networkingMode=none\`. Microsoft documents \`none\` as disconnecting the WSL network.
3. Enable the WSL Hyper-V firewall and set default inbound and outbound actions to Block. Disable host/guest loopback. These are defense-in-depth controls; they do not replace the disconnected-network setting.
4. Shut down WSL so the global configuration is reloaded.
5. Verify the effective configuration and runtime state. If the Windows policy overrides the requested mode, the WSL version does not support it, the firewall state cannot be read, or any check fails, report failure and do not claim isolation.
6. Online mode restores the exact saved configuration and firewall values, then shuts down WSL. It must not guess if the recovery record is absent or invalid.

## Scope and limitations

- \`.wslconfig\` is global to all WSL 2 distributions for the Windows user. Offline mode therefore affects every WSL 2 distribution for that user, not just ALFRED.
- \`wsl --shutdown\` stops all running WSL distributions.
- Windows enterprise policy (GPO/Intune), privileged host processes, and host-level compromise may override or bypass local settings. ALFRED cannot promise an absolute air gap inside WSL.
- This mode is a practical local network-disconnection control, not a substitute for employer-approved endpoint controls or a formally isolated machine. If policy requires a guaranteed air gap, use an approved disconnected environment.
- GPU compute is expected to remain available through WSL GPU paravirtualization, but this must be tested on both the NVIDIA work PC and AMD ROCm machine; networking changes must not be assumed harmless to every driver/runtime combination.

## Implemented verification checks

The currently available Linux-only verifier checks non-loopback Linux IP addresses and IPv4/IPv6 default routes. It does not inspect `.wslconfig`, Windows firewall policy, Hyper-V allow rules, or whether Windows has effectively disconnected WSL. A previous PowerShell verifier was malformed and has been removed pending a safe replacement. No settings are changed.

These checks are necessary but not sufficient to prove an absolute air gap. In particular, they do not protect against a privileged or compromised Windows host, nor do they establish that employer policy permits the configuration.

## Required verification before release

- Test on supported Windows/WSL versions, including policy-managed Windows where available.
- Confirm \`networkingMode=none\` is effective after \`wsl --shutdown\`, not merely present in the file.
- Inspect Linux interfaces, addresses, and routes; test IPv4, IPv6, DNS, public internet, LAN, Windows host gateway, and localhost/host services. A refused connection to a closed port is not proof of isolation.
- Confirm all outbound traffic paths are unavailable, including DNS tunnelling and proxy-assisted paths.
- Confirm the active Hyper-V firewall policy and loopback state; detect explicit allow rules and policy merges rather than assuming default actions alone are sufficient.
- Test fail-closed behavior when firewall cmdlets are missing, elevation is unavailable, settings are policy-controlled, backups are malformed, or WSL fails to restart.
- Test exact restoration of an existing UTF-8/UTF-16 \`.wslconfig\`, including comments, line endings, and a file that did not previously exist.
- Test repeated offline/online transitions and interrupted transitions without losing the original recovery record.
- Verify CUDA on the managed NVIDIA work PC and ROCm on the AMD main PC while offline.
- Audit every ALFRED stage and runtime process for hidden download/update fallbacks. Offline mode must never attempt an internet fallback.

## Microsoft references

- [WSL advanced settings](https://learn.microsoft.com/en-us/windows/wsl/wsl-config) — documents the global scope of \`.wslconfig\` and \`networkingMode=none\`.
- [WSL networking](https://learn.microsoft.com/en-us/windows/wsl/networking) — documents WSL networking and host connectivity.
- [Hyper-V firewall](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/hyper-v-firewall) — documents the WSL VM creator ID and active firewall settings.
