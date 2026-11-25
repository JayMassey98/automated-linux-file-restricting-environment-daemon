[CmdletBinding()]
param(
    [ValidateSet("host", "configure", "detect", "verify", "audit-network", "preflight-network", "install", "install-cuda", "prepare", "build", "serve", "all")]
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
        else { Write-Host "[UNAVAILABLE] $name (not exposed by this Windows installation)" }
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

function Invoke-NetworkPreflight {
    # Read-only discovery. No system settings are changed and no distro is launched.
    $results = New-Object System.Collections.Generic.List[object]
    $creatorId = "{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}"
    function Add-PreflightResult([string]$Category,[string]$Status,[string]$Evidence) {
        $results.Add([pscustomobject]@{Category=$Category;Status=$Status;Evidence=$Evidence})
    }
    Write-Host "=== ALFRED read-only isolation preflight ==="
    $admin = $false
    try {
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        $principal=New-Object Security.Principal.WindowsPrincipal($identity)
        $admin=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {}
    Write-Host ("Elevated PowerShell: " + $admin)

    $build=0
    try {
        $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        [void][int]::TryParse([string]$os.BuildNumber,[ref]$build)
        $ev=("Caption={0}; Version={1}; Build={2}; Architecture={3}" -f $os.Caption,$os.Version,$os.BuildNumber,$os.OSArchitecture)
        if ($build -lt 22000) {
            Add-PreflightResult "Host platform" "UNSUPPORTED" $ev
            Add-PreflightResult "General ALFRED Windows support" "PASS" "Windows 10 is supported for ordinary online ALFRED operation."
        } elseif ($build -ge 22621) {
            Add-PreflightResult "Host platform" "UNKNOWN" ($ev + "; Windows 11 22H2+ candidate; project-tested provider matrix not declared.")
            Add-PreflightResult "General ALFRED Windows support" "PASS" "Windows 11 detected; ordinary operation is separate from isolation eligibility."
        } else {
            Add-PreflightResult "Host platform" "UNSUPPORTED" ($ev + "; below Windows 11 22H2 minimum.")
            Add-PreflightResult "General ALFRED Windows support" "UNKNOWN" "General support matrix for this older host is not declared here."
        }
    } catch {
        Add-PreflightResult "Host platform" "UNKNOWN" $_.Exception.Message
        Add-PreflightResult "General ALFRED Windows support" "UNKNOWN" "Could not identify Windows build."
    }

    # Do not invoke the inbox wsl.exe stub when WSL is absent: it can open an
    # interactive, elevation-requiring installation prompt. Require a positive
    # read-only installation signal before invoking the CLI.
    $wslInstalled=$false
    $wslSignals=@()
    try {
        # LxssManager may be registered as an inbox component even when the
        # WSL optional feature is not enabled. Do not treat its mere presence
        # as proof that the WSL CLI/runtime is installed.
        $service=Get-Service -Name "WslService" -ErrorAction SilentlyContinue
        if ($null -ne $service) {
            $wslInstalled=$true
            $wslSignals+="WslService service registered"
        }
    } catch {}
    try {
        $feature=Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -ErrorAction Stop
        if ([string]$feature.State -eq "Enabled") {
            $wslInstalled=$true
            $wslSignals+="Windows Subsystem for Linux optional feature enabled"
        }
    } catch {
        # Query may require permissions on managed hosts; unknown is not
        # treated as evidence that WSL is installed.
    }
    try {
        if (Get-AppxPackage -Name "MicrosoftCorporationII.WindowsSubsystemForLinux" -ErrorAction SilentlyContinue) {
            $wslInstalled=$true
            $wslSignals+="registered WSL Store package"
        }
    } catch {}
    try {
        if (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Lxss") {
            $wslInstalled=$true
            $wslSignals+="WSL machine registration key"
        }
    } catch {}
    if (-not $wslInstalled) {
        foreach ($name in @("WSL version","WSL status","WSL distributions")) {
            Add-PreflightResult $name "UNKNOWN" "WSL installation was not positively detected; wsl.exe was not invoked to avoid triggering the interactive installation prompt."
        }
        Add-PreflightResult "Target distribution" "UNKNOWN" "WSL is not detected; no distribution can be enumerated."
    } else {
        Add-PreflightResult "WSL installation detection" "PASS" ($wslSignals -join "; ")
        $wslEntries=@(
            [pscustomobject]@{Name="WSL version";Args=@("--version")},
            [pscustomobject]@{Name="WSL status";Args=@("--status")},
            [pscustomobject]@{Name="WSL distributions";Args=@("--list","--verbose")}
        )
        foreach ($entry in $wslEntries) {
            try {
                $arguments=$entry.Args
                $output=(& wsl.exe @arguments 2>&1 | Out-String).Trim()
                $exitCode=$LASTEXITCODE
                if ($exitCode -ne 0) { throw ("wsl.exe exit " + $exitCode + ": " + $output) }
                if ($entry.Name -eq "WSL distributions") {
                    $clean=($output -replace [char]0,"").Trim()
                    $found=$false
                    $generation=$null
                    foreach ($line in ($clean -split '\r?\n')) {
                        $candidate=$line.Trim()
                        if ($candidate -match ("^\*?\s*" + [regex]::Escape($Distro) + "\s+")) {
                            $found=$true
                            if ($candidate -match "\s([12])\s*$") {$generation=$Matches[1]}
                        }
                    }
                    if (-not $found) {Add-PreflightResult "Target distribution" "UNKNOWN" ("Could not confirm " + $Distro + ".")}
                    elseif ($generation -eq "2") {Add-PreflightResult "Target distribution" "PASS" ($Distro + " registered as WSL 2; not launched.")}
                    elseif ($generation -eq "1") {Add-PreflightResult "Target distribution" "UNSUPPORTED" ($Distro + " is WSL 1; design requires WSL 2.")}
                    else {Add-PreflightResult "Target distribution" "UNKNOWN" "Distro found; WSL generation could not be parsed."}
                    Add-PreflightResult $entry.Name "PASS" $clean
                } else {Add-PreflightResult $entry.Name "PASS" $output}
            } catch {
                Add-PreflightResult $entry.Name "UNKNOWN" $_.Exception.Message
                if ($entry.Name -eq "WSL distributions") {Add-PreflightResult "Target distribution" "UNKNOWN" "Could not enumerate distributions."}
            }
        }
    }

    $names=@("Get-NetFirewallHyperVVMCreator","Get-NetFirewallHyperVVMSetting","Get-NetFirewallHyperVRule","Get-NetFirewallHyperVProfile","Set-NetFirewallHyperVVMSetting","New-NetFirewallHyperVVMSetting","Remove-NetFirewallHyperVRule")
    $available=@{}
    foreach ($name in $names) {
        try {
            $cmd=Get-Command $name -ErrorAction Stop
            $available[$name]=$true
            Add-PreflightResult ("Cmdlet " + $name) "PASS" ("Available; parameters: " + (@($cmd.Parameters.Keys) -join ", "))
        } catch {
            $available[$name]=$false
            Add-PreflightResult ("Cmdlet " + $name) "UNKNOWN" "Not exposed here; underlying feature absence is not inferred."
        }
    }

    $creatorOK=$false
    if ($available["Get-NetFirewallHyperVVMCreator"]) {
        try {
            foreach ($item in @(Get-NetFirewallHyperVVMCreator -ErrorAction Stop)) {
                if (([string]$item.VMCreatorId).Trim("{}") -ieq $creatorId.Trim("{}")) {$creatorOK=$true}
            }
            if ($creatorOK) {Add-PreflightResult "WSL VM creator identity" "PASS" ("Matched " + $creatorId)}
            else {Add-PreflightResult "WSL VM creator identity" "UNKNOWN" ("Could not match " + $creatorId)}
        } catch {Add-PreflightResult "WSL VM creator identity" "UNKNOWN" $_.Exception.Message}
    } else {Add-PreflightResult "WSL VM creator identity" "UNKNOWN" "Creator query cmdlet unavailable."}

    if ($available["Get-NetFirewallHyperVVMSetting"] -and $creatorOK) {
        foreach ($store in @("ActiveStore","PersistentStore")) {
            try {
                $items=@(Get-NetFirewallHyperVVMSetting -PolicyStore $store -Name $creatorId -ErrorAction Stop)
                if ($items.Count -eq 0) {Add-PreflightResult ("VM settings " + $store) "UNKNOWN" "No settings object returned."}
                else {
                    $summary=@()
                    foreach ($item in $items) {
                        foreach ($p in @("Enabled","DefaultInboundAction","DefaultOutboundAction","LoopbackEnabled","AllowHostPolicyMerge")) {
                            if ($item.PSObject.Properties.Name -contains $p) {$summary+=($p + "=" + [string]$item.$p)}
                        }
                    }
                    Add-PreflightResult ("VM settings " + $store) "PASS" ($summary -join "; ")
                }
            } catch {Add-PreflightResult ("VM settings " + $store) "UNKNOWN" $_.Exception.Message}
        }
    } else {Add-PreflightResult "WSL VM settings" "UNKNOWN" "Cannot query settings without cmdlet and confirmed creator."}

    if ($available["Get-NetFirewallHyperVProfile"]) {
        try {
            $profiles=@(Get-NetFirewallHyperVProfile -PolicyStore ActiveStore -ErrorAction Stop)
            $summary=@()
            foreach ($item in $profiles) {
                foreach ($p in @("Name","Enabled","DefaultInboundAction","DefaultOutboundAction","AllowHostPolicyMerge")) {
                    if ($item.PSObject.Properties.Name -contains $p) {$summary+=($p + "=" + [string]$item.$p)}
                }
            }
            if ($profiles.Count) {Add-PreflightResult "Hyper-V profiles ActiveStore" "PASS" ($summary -join "; ")}
            else {Add-PreflightResult "Hyper-V profiles ActiveStore" "UNKNOWN" "No profile objects returned."}
        } catch {Add-PreflightResult "Hyper-V profiles ActiveStore" "UNKNOWN" $_.Exception.Message}
    } else {Add-PreflightResult "Hyper-V profiles ActiveStore" "UNKNOWN" "Profile query cmdlet unavailable."}

    if ($available["Get-NetFirewallHyperVRule"] -and $creatorOK) {
        try {
            $rules=@(Get-NetFirewallHyperVRule -VMCreatorId $creatorId -ErrorAction Stop)
            $summary=@("Rule count=" + $rules.Count)
            foreach ($item in $rules) {
                $parts=@()
                foreach ($p in @("Name","DisplayName","Direction","Action","Enabled","Protocol","LocalPorts","RemoteAddresses")) {
                    if ($item.PSObject.Properties.Name -contains $p) {$parts+=($p + "=" + [string]$item.$p)}
                }
                if ($parts.Count) {$summary+=($parts -join ", ")}
            }
            Add-PreflightResult "WSL Hyper-V rules" "PASS" ($summary -join " | ")
        } catch {Add-PreflightResult "WSL Hyper-V rules" "UNKNOWN" $_.Exception.Message}
    } else {Add-PreflightResult "WSL Hyper-V rules" "UNKNOWN" "Cannot query rules without cmdlet and confirmed creator."}

    $config=Join-Path $HOME ".wslconfig"
    try {
        if (Test-Path -LiteralPath $config -PathType Leaf) {
            $bytes=[IO.File]::ReadAllBytes($config)
            $sha=[Security.Cryptography.SHA256]::Create()
            try {$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-","")} finally {$sha.Dispose()}
            $raw=[Text.Encoding]::UTF8.GetString($bytes)
            $mode="not explicitly set"
            if ($raw -match "(?im)^\s*networkingMode\s*=\s*([^\r\n#;]+)") {$mode=$Matches[1].Trim()}
            $enc="No recognized BOM"
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) {$enc="UTF-8 BOM"}
            elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 255 -and $bytes[1] -eq 254) {$enc="UTF-16 LE BOM"}
            elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 254 -and $bytes[1] -eq 255) {$enc="UTF-16 BE BOM"}
            $ending="No newline detected"
            if ($raw.Contains(([string][char]13)+([string][char]10))) {$ending="CRLF present"}
            elseif ($raw.Contains([string][char]10)) {$ending="LF present"}
            Add-PreflightResult ".wslconfig" "PASS" ("Exists; bytes=" + $bytes.Length + "; SHA256=" + $hash + "; encoding=" + $enc + "; line endings=" + $ending + "; networkingMode=" + $mode + "; global to this user's WSL 2 distributions.")
        } else {Add-PreflightResult ".wslconfig" "PASS" "Absent; WSL defaults and policy apply. No file created."}
    } catch {Add-PreflightResult ".wslconfig" "UNKNOWN" $_.Exception.Message}

    foreach ($path in @("HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Subsystem for Linux","HKCU:\SOFTWARE\Policies\Microsoft\Windows\Windows Subsystem for Linux","HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\WindowsSubsystemForLinux")) {
        try {
            if (Test-Path -LiteralPath $path -ErrorAction Stop) {
                $key=Get-Item -LiteralPath $path -ErrorAction Stop
                Add-PreflightResult ("Policy indicator " + $path) "UNKNOWN" ("Key present; value names: " + (@($key.GetValueNames()) -join ", ") + ". Values not dumped.")
            } else {Add-PreflightResult ("Policy indicator " + $path) "PASS" "Key absent at this path only; GPO/MDM/CSP absence is not established."}
        } catch {Add-PreflightResult ("Policy indicator " + $path) "UNKNOWN" $_.Exception.Message}
    }

    Write-Host ""
    Write-Host "[Preflight results]"
    $results | Format-Table Category,Status,Evidence -Wrap -AutoSize
    Write-Host ""
    Write-Host "[Eligibility]"
    if ($build -gt 0 -and $build -lt 22000) {
        Write-Host "Isolation provider eligibility: UNSUPPORTED (Windows 10 provider not implemented)."
        Write-Host "General ALFRED Windows 10 operation: supported for normal online use."
    } elseif ($build -ge 22000) {
        Write-Host "Isolation provider eligibility: UNKNOWN / NOT APPROVED; no project-tested provider matrix is declared."
    } else {Write-Host "Isolation provider eligibility: UNKNOWN; host build could not be established."}
    Write-Host "Inventory only; not an isolation test or air-gap attestation. No changes made."
    Write-Host "=== Preflight complete ==="
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
    "preflight-network" { Invoke-NetworkPreflight }
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
