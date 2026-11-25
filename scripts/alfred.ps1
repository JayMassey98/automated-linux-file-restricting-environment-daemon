[CmdletBinding()]
param(
    [ValidateSet("host", "configure", "detect", "verify", "audit-network", "install", "install-cuda", "prepare", "build", "serve", "all")]
    [string]$Stage = "all",
    [string]$Distro = "Ubuntu-24.04",
    [switch]$UseSuppliedModels,
    [switch]$UseSuppliedInstallLlama,
    [switch]$UseSuppliedInstallCUDAToolkit,
    [switch]$UseSuppliedInstallUbuntuBuildDependencies
)
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LinuxScript = Join-Path $ScriptDir "alfred.sh"

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Run this stage from an elevated PowerShell window (Run as Administrator)."
    }
}

function Invoke-NetworkAudit {
    # Read-only inventory. This function deliberately makes no firewall, WSL,
    # registry, or configuration changes.
    $creatorId = "{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}"
    $wslConfig = Join-Path $HOME ".wslconfig"
    Write-Host "=== ALFRED read-only Windows/WSL network audit ==="
    Write-Host "No settings will be changed."

    Write-Host "`n[WSL version and distributions]"
    & wsl.exe --version
    if ($LASTEXITCODE -ne 0) { Write-Warning "wsl --version is unavailable on this WSL installation." }
    & wsl.exe --status
    if ($LASTEXITCODE -ne 0) { Write-Warning "wsl --status could not be queried." }
    & wsl.exe --list --verbose
    if ($LASTEXITCODE -ne 0) { Write-Warning "Could not enumerate WSL distributions." }

    Write-Host "`n[.wslconfig]"
    if (Test-Path -LiteralPath $wslConfig -PathType Leaf) {
        $item = Get-Item -LiteralPath $wslConfig
        $hash = (Get-FileHash -LiteralPath $wslConfig -Algorithm SHA256).Hash
        Write-Host "Exists: yes"
        Write-Host "Path: $wslConfig"
        Write-Host "Length: $($item.Length) bytes"
        Write-Host "SHA256: $hash"
        Write-Host "Contents (read-only):"
        Get-Content -LiteralPath $wslConfig
        $raw = [System.IO.File]::ReadAllText($wslConfig)
        if ($raw -match '(?im)^\s*networkingMode\s*=\s*([^\r\n#;]+)') {
            Write-Host "Configured networkingMode: $($Matches[1].Trim())"
        } else {
            Write-Host "Configured networkingMode: not explicitly set (WSL default/policy applies)"
        }
    } else {
        Write-Host "Exists: no (WSL defaults and policy determine networking mode)"
    }
    Write-Host "Note: .wslconfig is global to this Windows user's WSL 2 distributions; file contents do not prove the effective runtime mode."

    Write-Host "`n[WSL policy registry indicators]"
    $policyPaths = @(
        "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Subsystem for Linux",
        "HKCU:\SOFTWARE\Policies\Microsoft\Windows\Windows Subsystem for Linux"
    )
    foreach ($path in $policyPaths) {
        if (Test-Path -LiteralPath $path) {
            Write-Host "Policy registry key present: $path"
            try { Get-ItemProperty -LiteralPath $path | Format-List * }
            catch { Write-Warning "Could not read policy key $path : $($_.Exception.Message)" }
        } else {
            Write-Host "No policy registry key at: $path"
        }
    }
    Write-Host "Registry inspection is an indicator only; absence does not prove that GPO/MDM policy is absent."

    Write-Host "`n[Hyper-V firewall cmdlet availability]"
    $required = @("Get-NetFirewallHyperVVMCreator", "Get-NetFirewallHyperVVMSetting",
                  "Get-NetFirewallHyperVRule", "Get-NetFirewallHyperVProfile")
    foreach ($name in $required) {
        if (Get-Command $name -ErrorAction SilentlyContinue) { Write-Host "[AVAILABLE] $name" }
        else { Write-Warning "[UNAVAILABLE] $name" }
    }

    if (Get-Command Get-NetFirewallHyperVVMCreator -ErrorAction SilentlyContinue) {
        Write-Host "`n[Registered Hyper-V VM creators]"
        try { Get-NetFirewallHyperVVMCreator | Format-List * }
        catch { Write-Warning "Could not enumerate VM creators: $($_.Exception.Message)" }
    }

    if (Get-Command Get-NetFirewallHyperVVMSetting -ErrorAction SilentlyContinue) {
        foreach ($store in @("ActiveStore", "PersistentStore")) {
            Write-Host "`n[WSL Hyper-V VM settings: $store]"
            try {
                $settings = @(Get-NetFirewallHyperVVMSetting -PolicyStore $store -Name $creatorId -ErrorAction Stop)
                if ($settings.Count -eq 0) { Write-Host "No settings returned." }
                else { $settings | Format-List * }
            } catch { Write-Warning "Could not read $store WSL VM settings: $($_.Exception.Message)" }
        }
    }

    if (Get-Command Get-NetFirewallHyperVProfile -ErrorAction SilentlyContinue) {
        Write-Host "`n[Hyper-V firewall profile settings: ActiveStore]"
        try { Get-NetFirewallHyperVProfile -PolicyStore ActiveStore -ErrorAction Stop | Format-List * }
        catch { Write-Warning "Could not read active Hyper-V firewall profiles: $($_.Exception.Message)" }
    }

    if (Get-Command Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
        Write-Host "`n[WSL Hyper-V firewall rules]"
        try {
            $rules = @(Get-NetFirewallHyperVRule -VMCreatorId $creatorId -ErrorAction Stop)
            if ($rules.Count -eq 0) { Write-Host "No WSL-specific Hyper-V rules returned." }
            else { $rules | Format-List * }
        } catch { Write-Warning "Could not enumerate WSL Hyper-V rules: $($_.Exception.Message)" }
    }

    Write-Host "`n[Audit interpretation]"
    Write-Host "- ActiveStore is the effective merged Hyper-V firewall policy; PersistentStore is local persistent policy."
    Write-Host "- Rule enumeration and profile policy must be reviewed for explicit allow rules and policy merges."
    Write-Host "- This audit does not prove that networkingMode=none is effective and does not test packet reachability."
    Write-Host "- No isolation status is granted by this audit. Do not use it as proof of an air gap."
    Write-Host "=== Audit complete; no changes made. ==="
}

function Invoke-HostSetup {
    Assert-Administrator
    Write-Host "Enabling Windows Subsystem for Linux..."
    dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
    if ($LASTEXITCODE -ne 0) { throw "Could not enable Windows Subsystem for Linux." }
    Write-Host "Enabling Virtual Machine Platform..."
    dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
    if ($LASTEXITCODE -ne 0) { throw "Could not enable Virtual Machine Platform." }
    wsl.exe --update
    if ($LASTEXITCODE -ne 0) { throw "wsl --update failed." }
    wsl.exe --set-default-version 2
    if ($LASTEXITCODE -ne 0) { throw "Could not set WSL 2 as the default version." }

    $installed = @(wsl.exe --list --quiet 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($installed -notcontains $Distro) {
        Write-Host "Installing $Distro without launching it..."
        wsl.exe --install --distribution $Distro --no-launch
        if ($LASTEXITCODE -ne 0) { throw "$Distro installation failed." }
        throw "$Distro has been installed. Launch it once with 'wsl -d $Distro', create your Linux username/password, then rerun this script."
    }
    wsl.exe --set-default $Distro
    if ($LASTEXITCODE -ne 0) { throw "Could not set $Distro as the default WSL distribution." }
    Write-Host "Checking that the Linux user has completed first-run setup..."
    wsl.exe --distribution $Distro --exec id -u
    if ($LASTEXITCODE -ne 0) { throw "Launch $Distro manually, create its Linux user, and rerun this script." }
    Write-Host "Windows/WSL host preparation is complete."
    Write-Host "Install the appropriate GPU vendor Windows driver manually if required; ALFRED does not install Windows GPU drivers."
}
function Invoke-LinuxStage([string]$LinuxStage) {
    if (-not (Test-Path -LiteralPath $LinuxScript -PathType Leaf)) { throw "Linux script not found: $LinuxScript" }
    $scriptText = [System.IO.File]::ReadAllText($LinuxScript)
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($scriptText))
    Write-Host "Running ALFRED Linux stage '$LinuxStage' in $Distro..."
    # Deliver the script as a temporary file so stdin remains attached to the
    # console for interactive confirmation and sudo password prompts.
    $suppliedModes = @()
    if ($LinuxStage -eq "prepare" -or $LinuxStage -eq "all") {
        if ($UseSuppliedModels) { $suppliedModes += "USE_SUPPLIED_MODELS=1" }
        if ($UseSuppliedInstallLlama) { $suppliedModes += "USE_SUPPLIED_INSTALL_LLAMA=1" }
        if ($UseSuppliedInstallUbuntuBuildDependencies) { $suppliedModes += "USE_SUPPLIED_INSTALL_UBUNTU_BUILD_DEPENDENCIES=1" }
    }
    if ($LinuxStage -eq "install-cuda" -and $UseSuppliedInstallCUDAToolkit) { $suppliedModes += "USE_SUPPLIED_INSTALL_CUDA_TOOLKIT=1" }
    $modePrefix = if ($suppliedModes.Count -gt 0) { ($suppliedModes -join " ") + " " } else { "" }
    $command = 'tmp=$(mktemp); printf "%s" "' + $encoded + '" | base64 -d > "$tmp"; ' + $modePrefix + 'bash "$tmp" ' + $LinuxStage + '; status=$?; rm -f "$tmp"; exit "$status"'
    & wsl.exe --distribution $Distro --exec bash -lc $command
    if ($LASTEXITCODE -ne 0) { throw "ALFRED Linux stage '$LinuxStage' failed with exit code $LASTEXITCODE." }
}
if ($UseSuppliedModels -and $Stage -ne "prepare" -and $Stage -ne "all") { throw "-UseSuppliedModels is supported with -Stage prepare or -Stage all only." }
if ($UseSuppliedInstallLlama -and $Stage -ne "prepare" -and $Stage -ne "all") { throw "-UseSuppliedInstallLlama is supported with -Stage prepare or -Stage all only." }
if ($UseSuppliedInstallCUDAToolkit -and $Stage -ne "install-cuda") { throw "-UseSuppliedInstallCUDAToolkit is supported with -Stage install-cuda only." }
if ($UseSuppliedInstallUbuntuBuildDependencies -and $Stage -ne "prepare" -and $Stage -ne "all") { throw "-UseSuppliedInstallUbuntuBuildDependencies is supported with -Stage prepare or -Stage all only." }
switch ($Stage) {
    "host" { Invoke-HostSetup }
    "configure" {
        Invoke-LinuxStage "configure"
        Write-Host "From Windows, run 'wsl --shutdown' before using the distro again."
    }
    "detect" { Invoke-LinuxStage "detect" }
    "verify" { Invoke-LinuxStage "verify" }
    "audit-network" { Invoke-NetworkAudit }
    "install" { Invoke-LinuxStage "install" }
    "install-cuda" { Invoke-LinuxStage "install-cuda" }
    "prepare" { Invoke-LinuxStage "prepare" }
    "build" { Invoke-LinuxStage "build" }
    "serve" { Invoke-LinuxStage "serve" }
    "all" {
        Invoke-HostSetup
        Invoke-LinuxStage "configure"
        Write-Host "Restarting WSL to apply /etc/wsl.conf..."
        wsl.exe --shutdown
        if ($LASTEXITCODE -ne 0) { throw "wsl --shutdown failed." }
        Invoke-LinuxStage "all"
        Write-Host ""
        Write-Host "ALFRED setup completed. To launch the server later, run:"
        Write-Host "  .\scripts\alfred.ps1 -Stage serve"
    }
}
