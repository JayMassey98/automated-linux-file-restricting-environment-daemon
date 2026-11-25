# ALFRED online/offline network mode design

**Status: design only, with Linux runtime check and read-only Windows audit available.** The commands that change networking modes (offline and online) are not implemented.

## Platform support policy

ALFRED's general platform support and its optional network-isolation capability are separate concerns:

- **Windows 10:** supported for normal ALFRED operation, including WSL2 setup, supported GPU compute, model preparation/execution, builds, and online workflows. Windows 10 users do not need to enable host or WSL isolation to use ALFRED.
- **Windows 11 22H2 and later:** the first target for an ALFRED-managed isolation provider, using documented WSL networking and Hyper-V firewall controls where the installed WSL version and effective policy support them. This provider is still design work; the presence of the underlying Windows controls does not mean ALFRED isolation is implemented.
- **Windows 10 isolation:** a separate, optional future provider. Its absence is not a blocker for Windows 10 support or ordinary ALFRED releases. Do not emulate Windows 11 controls or weaken host security to create superficial feature parity.

The intended architecture is capability-based: detect the host/WSL capabilities and applicable policy, select a platform-specific provider only when its prerequisites are proven, and apply a common isolation contract and verification suite. A provider must fail closed when a required control cannot be configured or independently verified. Unsupported isolation must be reported as unavailable, without preventing ordinary ALFRED workloads from running in their normal mode. Platform providers must preserve user and enterprise policy, avoid silent firewall changes, and provide exact, tested rollback before any state-changing implementation is accepted.

This policy does not promise a formal air gap. A privileged or compromised Windows host remains outside the protection boundary of guest-level controls.

## Isolation-provider architecture (design contract)

The shared orchestration layer owns the operator workflow and safety contract. A platform provider owns only the operating-system-specific discovery, configuration, verification evidence, and restoration needed to meet that contract. Providers must not redefine what ALFRED means by verified isolation.

### Provider outcomes

Capability discovery and every lifecycle operation must return an explicit structured outcome, not a Boolean that conflates unsupported, failed, and unknown states. The conceptual outcomes are:

- **Supported:** all required controls and query interfaces are present on this host.
- **Unsupported:** the platform or installed component does not expose a supported enforcement mechanism.
- **Blocked by policy:** a GPO, MDM, security product, or access restriction prevents a required operation.
- **Unknown:** discovery or verification could not obtain authoritative evidence.
- **Failed:** an attempted operation failed or produced a state different from the requested state.

Only a successful verification result may transition ALFRED into its verified-isolated state. Unsupported, blocked, unknown, and failed outcomes must never be represented as isolated.

### Common provider lifecycle

Each provider is expected to implement the following conceptual operations. These are design names, not existing commands or implemented PowerShell functions.

1. **Discover** — report OS build, WSL version, available control surfaces, relevant policy indicators, and provider identity/version. Read-only; no changes.
2. **Preflight** — check every prerequisite, permissions, policy constraints, conflicting configuration, and whether a global WSL shutdown will be required. Do not mutate state.
3. **Plan** — produce a human-readable list of exact changes, their scope, impact on other WSL distributions, and required restart/disruption. Require explicit operator confirmation before applying changes with host-wide or all-distro effects.
4. **Capture** — preserve the exact pre-change state and its existence/absence semantics in a versioned recovery record. Record provider/version, host and WSL identity, timestamps, and integrity metadata. Never overwrite an unresolved recovery record.
5. **Apply** — perform only documented, supported changes. Journal each completed step so an interrupted operation can be diagnosed and recovered. Repeated requests must not create duplicate rules or progressively alter state.
6. **Verify** — independently inspect effective host-side controls and guest runtime state, then perform bounded reachability tests. Verification must account for explicit allow rules, policy merges, IPv4, IPv6, DNS, LAN, host gateway, localhost/host services, VPN and alternate interfaces where applicable.
7. **Restore** — restore only the captured state, and only when current state still matches the values ALFRED changed or the operator explicitly resolves detected drift. Never overwrite subsequent user or administrator changes. If safe restoration cannot be established, stop and provide a precise recovery report rather than guessing.

A provider may expose additional operations, but it may not omit or weaken these shared lifecycle requirements.

### Shared verification contract

The shared verifier consumes provider evidence and guest observations. It must distinguish **configured**, **effective**, and **runtime-tested** controls; these are separate claims.

A verified-isolated result requires all of the following:

- The selected provider declares the exact host/WSL versions and control surfaces it supports.
- The requested enforcement settings are confirmed as effective, not merely present in a configuration file or successfully written.
- Effective policy and rule evaluation has been inspected for exceptions or allow paths that invalidate the intended boundary.
- The guest has no usable external, LAN, host-gateway, or unintended loopback path under the documented threat model.
- IPv4 and IPv6 interface, route, DNS, and bounded connection tests complete with expected results.
- No required evidence is missing, stale, contradictory, or inaccessible.
- The recovery record is valid and corresponds to the state being verified.

A timeout, failed ping, refused connection to a closed port, missing command, absent query result, or empty rule listing is not by itself proof of isolation. Tests must include known reachable test endpoints where available; a test failure caused by endpoint unavailability is **inconclusive**, not a pass.

The verifier must report the scope and limitations of its evidence. Even a successful result means practical isolation under the stated host/provider assumptions, not protection from a privileged or compromised host and not a formally certified air gap.

### State model and failure handling

The orchestrator should expose distinct states:

- **Normal** — no ALFRED-managed isolation is active.
- **Preflight complete** — prerequisites and impact have been checked; no changes have been made.
- **Applying** — a journaled transition is in progress; ALFRED must not claim isolation.
- **Isolated and verified** — every required verification condition passed.
- **Degraded / unknown** — state or evidence is incomplete, conflicting, or cannot be trusted. Offline-sensitive ALFRED stages must not proceed under an isolation guarantee.
- **Restoring** — captured state is being restored; ALFRED must not claim normal networking until restoration is verified.
- **Restore incomplete** — automatic restoration could not safely finish; operator action is required.

An interrupted transition must be detected on the next invocation. ALFRED must inspect the journal and actual machine state before attempting recovery; it must not blindly replay changes or assume the last requested mode succeeded.

### Provider selection policy

Provider selection is based on positive capability and policy evidence, not only the Windows version string:

- **Windows 11 provider:** first implementation target. It may proceed only when the documented WSL networking and Hyper-V firewall controls, supported WSL release, effective settings, permissions, and policy checks are all available.
- **Windows 10 provider:** currently unavailable. Normal ALFRED operation remains supported; isolation requests must return an explicit unsupported result.
- **Unknown or future Windows builds:** do not infer compatibility from a newer version number. Require an explicitly tested provider compatibility declaration.

The shared orchestrator must not silently switch providers after a provider fails. It must report the reason and require a deliberate operator decision before any different isolation boundary is considered.

### Recovery and user/enterprise policy protections

- Preserve the original .wslconfig byte-for-byte, including whether it existed, encoding, line endings, comments, and unrelated settings. Because it is global to the Windows user, explain that all WSL2 distributions are affected.
- Treat wsl --shutdown as a disruptive operation affecting all running WSL2 distributions; disclose this in the plan and obtain confirmation.
- Do not change Windows Firewall defaults, remove administrator-managed rules, edit undocumented HNS state, disable endpoint protection, or override GPO/MDM policy.
- Do not restore a stale snapshot over settings changed by the user or administrator after ALFRED applied its changes.
- Keep recovery records local, access-controlled, integrity-checked, and free of credentials or secrets. Define retention and manual recovery instructions before implementation.
- If rollback is incomplete, clearly identify which settings ALFRED changed, which settings remain uncertain, and the supported manual recovery path. Never report success.

### Implementation gates

No provider should be implemented until its supported Windows/WSL matrix, exact control semantics, policy interactions, rollback behavior, and test plan are documented. The Windows 11 provider must first pass non-production tests for normal transition, interruption at every mutation step, policy denial, missing permissions, explicit allow rules, configuration drift, repeated transitions, and exact restoration. The common verifier must be testable independently of the provider using known-good, known-bad, and inconclusive evidence fixtures.


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

The enforcement sequence above is therefore the proposed Windows 11 isolation provider only; it is not implemented yet. Windows 11 isolation is the first implementation target, not a prerequisite for ALFRED's general operation.

### Windows 10 findings (research; no enforcement implemented)

Windows 10 WSL2 uses the traditional NAT architecture. The WSL VM has its own virtual Ethernet interface and reaches external networks through host-managed NAT/shared-access components. Microsoft documents this NAT model and describes host-side DNS forwarding through the shared-access service. See [WSL networking](https://learn.microsoft.com/en-us/windows/wsl/networking) and [WSL networking troubleshooting](https://learn.microsoft.com/en-us/windows/wsl/troubleshooting).

A Windows Defender Firewall rule attached to the physical outbound adapter, or an inbound rule attached to `vEthernet (WSL)`, must **not** be treated as a proven WSL egress block. A WSL project report reproduced a case where WSL2 traffic still reached an external address despite those rules; the report is not a Microsoft security guarantee, but it is enough to reject that rule pattern as an assumed solution. See [WSL issue #6936](https://github.com/microsoft/WSL/issues/6936).

Consequently, ALFRED must not implement Windows 10 offline mode by simply adding interface-scoped `New-NetFirewallRule` rules, changing the Windows firewall default outbound action, editing undocumented HNS state, or deleting Linux routes. Those approaches either lack a demonstrated enforcement boundary, can affect the whole host, depend on undocumented implementation details, or are controlled from inside the guest.

The Windows 10 path remains an open design item. Viable directions to investigate are:
- **Externally enforced isolation:** use an employer-approved network control (for example, a dedicated isolated VLAN/network policy) or physically disconnect the host's network interfaces for the offline session. This isolates the host as well as WSL and is not a WSL-only toggle.
- **A supported host filtering product/driver:** only consider a Windows Filtering Platform (WFP) or equivalent product if its vendor explicitly supports filtering forwarded/NAT traffic from WSL2 on the exact Windows 10 build, and packet-level tests verify IPv4, IPv6, DNS, LAN, host-gateway, VPN, and alternate-adapter paths.
- **A future ALFRED-managed host-wide disconnect mode:** investigate separately, with explicit operator consent, complete adapter inventory, reversible state capture, drift detection, and tests for Wi-Fi, Ethernet, USB tethering, VPN and virtual adapters. Do not implement this as part of the current per-WSL offline mode.

Until one of these options has a documented enforcement boundary and repeatable tests, ALFRED must report Windows 10 managed per-WSL isolation as **unavailable**. This is an optional future capability, not a limitation on Windows 10's supported everyday ALFRED workflows (WSL setup, GPU compute, model execution, builds, and staged asset use). If the requirement is a guarantee that the host and WSL cannot communicate with any network, use an employer-approved disconnected environment.

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
