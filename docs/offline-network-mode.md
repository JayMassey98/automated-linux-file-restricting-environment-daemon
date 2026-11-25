# ALFRED online/offline network mode design

**Status: design only, with Linux runtime check and read-only Windows audit available.** The commands that change networking modes (offline and online) are not implemented.

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

No PowerShell offline, online, or `verify-network` stage is currently implemented. A read-only PowerShell inventory is available:

```powershell
.\scripts\alfred.ps1 -Stage audit-network
```

It reports `.wslconfig` existence, contents and SHA256; WSL version/status and registered distributions; WSL policy registry indicators; the WSL Hyper-V VM settings in ActiveStore and PersistentStore; active Hyper-V firewall profiles; and WSL-specific Hyper-V rules. It does not mutate the host. Query failures are warnings, not evidence that a setting or policy is absent. This is an inventory aid, not a verification verdict.

The Linux-only command `bash scripts/alfred.sh verify-network` checks interface addresses and routes; it does not verify Windows policy or effective host networking controls. Do not use the proposed PowerShell offline/online commands until a separately tested implementation is merged.

## Enforcement design

1. Before changing anything, capture the exact bytes and existence state of the user's \`%UserProfile%\\.wslconfig\`, plus the active WSL Hyper-V firewall settings. Store a versioned recovery record in the user's local ALFRED state directory. Never overwrite an existing recovery record.
2. Set \`[wsl2] networkingMode=none\`. Microsoft documents \`none\` as disconnecting the WSL network.
3. Enable the WSL Hyper-V firewall and set default inbound and outbound actions to Block. Disable host/guest loopback. These are defense-in-depth controls; they do not replace the disconnected-network setting.
4. Shut down WSL so the global configuration is reloaded.
5. Verify the effective configuration and runtime state. If the Windows policy overrides the requested mode, the WSL version does not support it, the firewall state cannot be read, or any check fails, report failure and do not claim isolation.
6. Online mode restores the exact saved configuration and firewall values, then shuts down WSL. It must not guess if the recovery record is absent or invalid.

## Windows-version-specific isolation paths

Windows 10 remains a supported ALFRED host for WSL setup, GPU compute, model execution, and other functionality that is available on that platform. The Windows 11 networking controls described here are not prerequisites for using ALFRED generally.

Microsoft documents the WSL Hyper-V firewall feature and the WSL `networkingMode` setting (including `none`) for Windows 11 22H2 and later, with a sufficiently recent WSL release. These controls must not be assumed to exist on Windows 10. On Windows 10, the audit should report unavailable Hyper-V firewall cmdlets as capability information—not as a verdict that Windows 10 or ALFRED is unsupported.

The enforcement sequence above is therefore the proposed Windows 11 path only.

### Windows 10 findings (research; no enforcement implemented)

Windows 10 WSL2 uses the traditional NAT architecture. The WSL VM has its own virtual Ethernet interface and reaches external networks through host-managed NAT/shared-access components. Microsoft documents this NAT model and describes host-side DNS forwarding through the shared-access service. See [WSL networking](https://learn.microsoft.com/en-us/windows/wsl/networking) and [WSL networking troubleshooting](https://learn.microsoft.com/en-us/windows/wsl/troubleshooting).

A Windows Defender Firewall rule attached to the physical outbound adapter, or an inbound rule attached to `vEthernet (WSL)`, must **not** be treated as a proven WSL egress block. A WSL project report reproduced a case where WSL2 traffic still reached an external address despite those rules; the report is not a Microsoft security guarantee, but it is enough to reject that rule pattern as an assumed solution. See [WSL issue #6936](https://github.com/microsoft/WSL/issues/6936).

Consequently, ALFRED must not implement Windows 10 offline mode by simply adding interface-scoped `New-NetFirewallRule` rules, changing the Windows firewall default outbound action, editing undocumented HNS state, or deleting Linux routes. Those approaches either lack a demonstrated enforcement boundary, can affect the whole host, depend on undocumented implementation details, or are controlled from inside the guest.

The Windows 10 path remains an open design item. Viable directions to investigate are:
- **Externally enforced isolation:** use an employer-approved network control (for example, a dedicated isolated VLAN/network policy) or physically disconnect the host's network interfaces for the offline session. This isolates the host as well as WSL and is not a WSL-only toggle.
- **A supported host filtering product/driver:** only consider a Windows Filtering Platform (WFP) or equivalent product if its vendor explicitly supports filtering forwarded/NAT traffic from WSL2 on the exact Windows 10 build, and packet-level tests verify IPv4, IPv6, DNS, LAN, host-gateway, VPN, and alternate-adapter paths.
- **A future ALFRED-managed host-wide disconnect mode:** investigate separately, with explicit operator consent, complete adapter inventory, reversible state capture, drift detection, and tests for Wi-Fi, Ethernet, USB tethering, VPN and virtual adapters. Do not implement this as part of the current per-WSL offline mode.

Until one of these options has a documented enforcement boundary and repeatable tests, ALFRED must report Windows 10 per-WSL offline isolation as **unavailable**, while continuing to support Windows 10 for WSL setup, GPU compute, model execution, and ordinary online/offline staged workflows. If the requirement is a guarantee that the host and WSL cannot communicate with any network, use an employer-approved disconnected environment.

## Scope and limitations

- \`.wslconfig\` is global to all WSL 2 distributions for the Windows user. Offline mode therefore affects every WSL 2 distribution for that user, not just ALFRED.
- \`wsl --shutdown\` stops all running WSL distributions.
- Windows enterprise policy (GPO/Intune), privileged host processes, and host-level compromise may override or bypass local settings. ALFRED cannot promise an absolute air gap inside WSL.
- This mode is a practical local network-disconnection control, not a substitute for employer-approved endpoint controls or a formally isolated machine. If policy requires a guaranteed air gap, use an approved disconnected environment.
- GPU compute is expected to remain available through WSL GPU paravirtualization, but this must be tested on both the NVIDIA work PC and AMD ROCm machine; networking changes must not be assumed harmless to every driver/runtime combination.

## Implemented verification checks

The Linux verifier checks non-loopback Linux IP addresses and IPv4/IPv6 default routes. The PowerShell `audit-network` stage is read-only and inventories `.wslconfig`, WSL policy registry indicators, WSL Hyper-V VM settings, profiles and rules. It does not prove the effective networking mode, infer absence of all enterprise policy, test packet reachability, or decide whether explicit allow rules create a path. Neither check changes settings.

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
