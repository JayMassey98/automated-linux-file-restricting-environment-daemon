# Run in an elevated Windows PowerShell session.
$ErrorActionPreference = "Stop"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run PowerShell as Administrator."
}

Write-Host "Enabling Windows Subsystem for Linux..."
dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
if ($LASTEXITCODE -ne 0) { throw "Failed to enable WSL." }

Write-Host "Enabling Virtual Machine Platform..."
dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
if ($LASTEXITCODE -ne 0) { throw "Failed to enable Virtual Machine Platform." }

wsl.exe --update
if ($LASTEXITCODE -ne 0) { throw "wsl --update failed." }

wsl.exe --set-default-version 2
if ($LASTEXITCODE -ne 0) { throw "Could not set WSL 2 as the default version." }

$installed = @(wsl.exe --list --quiet 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($installed -notcontains "Ubuntu-24.04") {
    Write-Host "Installing Ubuntu 24.04..."
    wsl.exe --install --distribution Ubuntu-24.04 --no-launch
    if ($LASTEXITCODE -ne 0) { throw "Ubuntu-24.04 installation failed." }
} else {
    Write-Host "Ubuntu-24.04 already exists; leaving it untouched."
}

wsl.exe --set-default Ubuntu-24.04
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Could not set Ubuntu-24.04 as the default distro. Check 'wsl --list --verbose'."
}

Write-Host ""
Write-Host "Host preparation complete."
Write-Host "Install/update the AMD Windows graphics driver manually, reboot if requested, then launch Ubuntu once to create its Linux user."
