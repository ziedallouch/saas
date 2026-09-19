#Requires -RunAsAdministrator
<#
    Installs WSL2 + Ubuntu on this Windows machine.

    Run from an ELEVATED PowerShell:
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
        D:\NP\erp-deploy\scripts\setup-wsl.ps1

    Safe to re-run. It reports what is already present instead of reinstalling.
#>

$ErrorActionPreference = 'Stop'

function Say($msg)  { Write-Host "  $msg" }
function Head($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Warn($msg) { Write-Host "  ! $msg" -ForegroundColor Yellow }

Head "Checking Windows version"
$build = [System.Environment]::OSVersion.Version.Build
Say "Windows build $build"
if ($build -lt 19041) {
    Warn "WSL2 needs build 19041 or later. This machine cannot run it."
    Warn "Alternative: install Ansible and Terraform on erp-node-1 and work from there."
    exit 1
}

Head "Checking for an existing WSL installation"
$wslPresent = $false
try {
    $null = wsl.exe --status 2>&1
    if ($LASTEXITCODE -eq 0) { $wslPresent = $true }
} catch { }

if ($wslPresent) {
    Say "WSL is already installed. Updating the kernel."
    wsl.exe --update
} else {
    Say "WSL is not installed yet."
}

Head "Checking for an existing Ubuntu distribution"
$distros = @()
try { $distros = (wsl.exe --list --quiet) -replace "`0", "" } catch { }

if ($distros -match 'Ubuntu') {
    Say "Ubuntu is already installed. Nothing to do here."
} else {
    Say "Installing Ubuntu. This downloads a few hundred MB."
    # --no-launch so the script does not block on the interactive first-run setup.
    wsl.exe --install -d Ubuntu --no-launch
}

Head "Setting WSL2 as the default version"
wsl.exe --set-default-version 2

Head "Done"
Say "If this was a first-time WSL install, REBOOT now."
Say ""
Say "After the reboot:"
Say "  1. Launch 'Ubuntu' from the Start menu."
Say "  2. Create your Linux username and password when prompted."
Say "  3. In that Ubuntu window, run:"
Say ""
Say "       bash /mnt/d/NP/erp-deploy/scripts/setup-toolchain.sh"
Say ""
