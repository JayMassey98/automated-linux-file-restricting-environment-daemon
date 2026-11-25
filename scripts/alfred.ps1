[CmdletBinding()]
param(
    [ValidateSet("host", "configure", "detect", "verify", "online", "offline", "verify-network", "install", "install-cuda", "prepare", "build", "serve", "all")]
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
$WslCreatorId = "{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}"
$AlfredStateDir = Join-Path $env:LOCALAPPDATA "ALFRED"
$NetworkStatePath = Join-Path $AlfredStateDir "network-state.json"
$WslConfigPath = Join-Path $env:USERPROFILE ".wslconfig"

function Get-WslFirewallSetting {
    $setting = Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore -Name $WslCreatorId -ErrorAction Stop
    if (-not $setting) { throw "Windows did not return an active Hyper-V firewall policy for WSL." }
    return $setting
}
function Set-WslNetworkingMode([string]$Mode) {
    if ($Mode -notin @("none", "nat")) { throw "Unsupported ALFRED networking mode: $Mode" }
    $lines = @()
    if (Test-Path -LiteralPath $WslConfigPath) {
        $lines = @(Get-Content -LiteralPath $WslConfigPath)
    }
    $out = [System.Collections.Generic.List[string]]::new()
    $inWsl2 = $false
    $foundSection = $false
    $keyWritten = $false
    foreach ($line in $lines) {
        if ($line -match '^\s*\[([^\]]+)\]\s*
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
    "offline" { Invoke-OfflineMode }
    "online" { Invoke-OnlineMode }
    "verify-network" { Invoke-VerifyNetwork }
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
) {
            if ($inWsl2 -and -not $keyWritten) {
                $out.Add("networkingMode=$Mode")
                $keyWritten = $true
            }
            $inWsl2 = ($Matches[1] -ieq "wsl2")
            if ($inWsl2) { $foundSection = $true }
            $out.Add($line)
            continue
        }
        if ($inWsl2 -and $line -match '^\s*networkingMode\s*=') {
            if (-not $keyWritten) {
                $out.Add("networkingMode=$Mode")
                $keyWritten = $true
            }
            continue
        }
        $out.Add($line)
    }
    if ($foundSection) {
        if (-not $keyWritten) { $out.Add("networkingMode=$Mode") }
    } else {
        if ($out.Count -gt 0 -and $out[$out.Count - 1] -ne "") { $out.Add("") }
        $out.Add("[wsl2]")
        $out.Add("networkingMode=$Mode")
    }
    Set-Content -LiteralPath $WslConfigPath -Value $out -Encoding ascii
}
function Invoke-OfflineMode {
    Assert-Administrator
    if (-not (Get-Command Get-NetFirewallHyperVVMSetting -ErrorAction SilentlyContinue)) {
        throw "Hyper-V firewall PowerShell cmdlets are unavailable. Offline mode cannot be enforced on this Windows installation."
    }
    if (-not (Test-Path -LiteralPath $NetworkStatePath)) {
        $existing = Test-Path -LiteralPath $WslConfigPath
        $config = if ($existing) { [System.IO.File]::ReadAllText($WslConfigPath) } else { $null }
        $fw = Get-WslFirewallSetting
        New-Item -ItemType Directory -Force -Path $AlfredStateDir | Out-Null
        $state = [ordered]@{
            version = 1
            configExisted = $existing
            configContent = $config
            firewallEnabled = [string]$fw.Enabled
            inbound = [string]$fw.DefaultInboundAction
            outbound = [string]$fw.DefaultOutboundAction
            loopback = [string]$fw.LoopbackEnabled
        }
        $state | ConvertTo-Json | Set-Content -LiteralPath $NetworkStatePath -Encoding UTF8
    }
    Write-Host "Applying WSL offline restrictions. This affects ALL WSL2 distributions for this Windows user."
    Set-WslNetworkingMode "none"
    Set-NetFirewallHyperVVMSetting -Name $WslCreatorId -Enabled True -DefaultInboundAction Block -DefaultOutboundAction Block -LoopbackEnabled False -ErrorAction Stop | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not apply WSL network restrictions." }
    Write-Host "Shutting down WSL so the global networking change takes effect..."
    wsl.exe --shutdown
    if ($LASTEXITCODE -ne 0) { throw "wsl --shutdown failed. Offline configuration is written, but its effective state is not yet verified." }
    Invoke-VerifyNetwork
}
function Invoke-OnlineMode {
    Assert-Administrator
    if (-not (Test-Path -LiteralPath $NetworkStatePath)) {
        throw "No ALFRED network-state backup exists. Refusing to guess your original .wslconfig or firewall settings. Run online mode only after an ALFRED offline-mode backup has been created, or restore settings manually."
    }
    $state = Get-Content -LiteralPath $NetworkStatePath -Raw | ConvertFrom-Json
    if ($state.version -ne 1) { throw "Unsupported ALFRED network-state backup version." }
    if ($state.configExisted) {
        Set-Content -LiteralPath $WslConfigPath -Value $state.configContent -Encoding ascii -NoNewline
    } else {
        Remove-Item -LiteralPath $WslConfigPath -Force -ErrorAction SilentlyContinue
    }
    Set-NetFirewallHyperVVMSetting -Name $WslCreatorId -Enabled ([System.Convert]::ToBoolean($state.firewallEnabled)) -DefaultInboundAction $state.inbound -DefaultOutboundAction $state.outbound -LoopbackEnabled ([System.Convert]::ToBoolean($state.loopback)) -ErrorAction Stop | Out-Null
    wsl.exe --shutdown
    if ($LASTEXITCODE -ne 0) { throw "WSL shutdown failed after restoring online settings." }
    Write-Host "Original WSL configuration and Hyper-V firewall settings restored. Verify the result with -Stage verify-network."
}
function Invoke-VerifyNetwork {
    Assert-Administrator
    $errors = 0
    $mode = "unknown"
    if (Test-Path -LiteralPath $WslConfigPath) {
        $content = Get-Content -LiteralPath $WslConfigPath -Raw
        if ($content -match '(?im)^\s*networkingMode\s*=\s*none\s*
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
) { $mode = "none" }
        elseif ($content -match '(?im)^\s*networkingMode\s*=\s*nat\s*
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
) { $mode = "nat" }
        else { $mode = "default/other" }
    } else { $mode = "default (NAT)" }
    Write-Host "Configured WSL networkingMode: $mode"
    try {
        $fw = Get-WslFirewallSetting
        $checks = @(
            @{ Name = "Hyper-V firewall enabled"; Pass = ([string]$fw.Enabled -eq "True") },
            @{ Name = "Default inbound blocked"; Pass = ([string]$fw.DefaultInboundAction -eq "Block") },
            @{ Name = "Default outbound blocked"; Pass = ([string]$fw.DefaultOutboundAction -eq "Block") },
            @{ Name = "Host/guest loopback disabled"; Pass = ([string]$fw.LoopbackEnabled -eq "False") }
        )
        foreach ($check in $checks) {
            if ($check.Pass) { Write-Host "[OK]   $($check.Name)" }
            else { Write-Host "[FAIL] $($check.Name)"; $errors++ }
        }
    } catch {
        Write-Host "[FAIL] Could not read active Hyper-V firewall settings: $($_.Exception.Message)"
        $errors++
    }
    if ($mode -ne "none") {
        Write-Host "[FAIL] WSL networkingMode is not none."
        $errors++
    } else { Write-Host "[OK]   WSL networkingMode is none" }
    if ($errors -gt 0) {
        throw "$errors offline network verification check(s) failed. ALFRED must not be treated as isolated."
    }
    Write-Host "Windows-side offline configuration checks passed. This verifies configuration, not a formal air gap or protection from a privileged/compromised Windows host."
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
