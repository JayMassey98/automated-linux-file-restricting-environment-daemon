[CmdletBinding()]
param(
    [ValidateSet("host", "configure", "detect", "verify", "verify-network", "install", "install-cuda", "prepare", "build", "serve", "all")]
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
function Invoke-VerifyNetwork {
    Assert-Administrator
    $configPath = Join-Path $env:USERPROFILE ".wslconfig"
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "No .wslconfig exists. Offline networking cannot be verified."
    }
    $inWsl2 = $false
    $networkingMode = $null
    foreach ($line in [System.IO.File]::ReadAllLines($configPath)) {
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
            $inWsl2 = ($Matches[1] -ieq "wsl2")
            continue
        }
        if ($inWsl2 -and $line -match '^\s*networkingMode\s*=\s*(.*?)\s*(?:#.*)?
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
) {
            $networkingMode = $Matches[1].Trim().ToLowerInvariant()
        }
    }
    if ($networkingMode -ne "none") {
        throw "The active .wslconfig does not explicitly set [wsl2] networkingMode=none. Found: '$networkingMode'."
    }
    Write-Host "[OK]   .wslconfig explicitly sets WSL networkingMode=none."

    $creatorId = "{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}"
    foreach ($cmd in @("Get-NetFirewallHyperVVMSetting", "Get-NetFirewallHyperVRule")) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            throw "Required Windows firewall cmdlet '$cmd' is unavailable. Offline verification cannot continue."
        }
    }
    $fw = Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore -Name $creatorId -ErrorAction Stop
    $checks = @(
        @{ Name = "Hyper-V firewall enabled"; Pass = ([string]$fw.Enabled -eq "True") },
        @{ Name = "Default inbound blocked"; Pass = ([string]$fw.DefaultInboundAction -eq "Block") },
        @{ Name = "Default outbound blocked"; Pass = ([string]$fw.DefaultOutboundAction -eq "Block") },
        @{ Name = "Host/guest loopback disabled"; Pass = ([string]$fw.LoopbackEnabled -eq "False") }
    )
    foreach ($check in $checks) {
        if ($check.Pass) { Write-Host "[OK]   $($check.Name)" }
        else { throw "Offline verification failed: $($check.Name). Effective value does not match the required setting." }
    }

    $allowRules = @(Get-NetFirewallHyperVRule -VMCreatorId $creatorId -ErrorAction Stop |
        Where-Object { ([string]$_.Enabled -eq "True") -and ([string]$_.Action -eq "Allow") })
    if ($allowRules.Count -gt 0) {
        $names = ($allowRules | ForEach-Object { $_.DisplayName }) -join ", "
        throw "Offline verification found enabled Hyper-V allow rule(s): $names. Review them with your administrator; ALFRED will not modify existing firewall rules."
    }
    Write-Host "[OK]   No enabled Hyper-V allow rules were returned for WSL."
    Invoke-LinuxStage "verify-network"
    Write-Host "Windows policy and Linux runtime checks passed. This is not a formal air gap and does not protect against a privileged or compromised Windows host."
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
