# AdminInstallOpenSSH.ps1
# Compatible PowerShell 5.1

param (
    [string]$ConfigPath,

    [ValidateSet("DEBUG","INFO","NOTICE","WARN","ERROR")]
    [string]$LogLevel = "INFO",

    [int]$RetryCount   = 1,
    [int]$DelaySeconds = 0,

    [ValidateSet('Continue','Stop','SilentlyContinue','Inquire')]
    [string]$ErrorAction = 'Continue',

    [switch]$WhatIf,
    [switch]$Confirm,
    [switch]$Force,
    [switch]$Verbose,
    [switch]$Debug
)

# ------------------------------------------------------------
# Core imports
# ------------------------------------------------------------
$lib = Join-Path $PSScriptRoot 'lib'

Import-Module "$lib\GeneralUtil.psm1"      -ErrorAction Stop -Force
Import-Module "$lib\LoadScriptConfig.psm1" -ErrorAction Stop -Force

# ------------------------------------------------------------
# Bootstrap
# ------------------------------------------------------------
$init = Initialize-Script `
    -ScriptPath   $PSCommandPath `
    -ConfigPath   $ConfigPath `
    -LogLevel     $LogLevel `
    -RetryCount   $RetryCount `
    -DelaySeconds $DelaySeconds `
    -ErrorAction  $ErrorAction `
    -WhatIf:$WhatIf `
    -Confirm:$Confirm `
    -Force:$Force `
    -Verbose:$Verbose `
    -Debug:$Debug

$Logger     = $init.Logger
$Context    = $init.Context
$ConfigPath = $init.ConfigPath
$ScriptName = $init.ScriptName

$startTime = [datetime]::Now

# ------------------------------------------------------------
# Contract counters (TARGET = capability / service)
# ------------------------------------------------------------
$Stats = @{
    Observed = 0
    Applied  = 0
    Changed  = 0
    Failed   = 0
    Skipped  = 0
}

$HasFatalError = $false

# ------------------------------------------------------------
# Administrator requirement
# ------------------------------------------------------------
if (-not (Test-IsAdministrator)) {
    $Stats.Failed = 1
    $Logger.WrapLog("Script $ScriptName cannot start: administrator privileges required", "ERROR", $Context)
    exit 1
}

$Logger.WrapLog("Start script '$ScriptName'.", "INFO", $Context)

# ------------------------------------------------------------
# Install OpenSSH Server capability (TARGET = capability)
# ------------------------------------------------------------
$Stats.Observed++

$caps = Get-WindowsCapability -Online | Where-Object { $_.Name -like 'OpenSSH.Server*' }

if (-not $caps) {
    $Stats.Failed++
    $HasFatalError = $true
    $Logger.WrapLog("OpenSSH.Server capability not found on this OS (not supported)", "ERROR", $Context)
}

if (-not $HasFatalError) {
    $installed = $caps | Where-Object { $_.State -eq 'Installed' } | Select-Object -First 1

    if ($installed) {
        $Stats.Skipped++
        $Logger.WrapLog("OpenSSH Server capability already installed '$($installed.Name)' (noop) | Reason=match", "NOTICE", $Context)
    } else {
        $candidate = $caps | Sort-Object Name -Descending | Select-Object -First 1

        $Logger.WrapLog("Installing OpenSSH Server capability '$($candidate.Name)'", "INFO", $Context)

        try {
            $Stats.Applied++

            if (-not $WhatIf) {
                Add-WindowsCapability -Online -Name $candidate.Name -ErrorAction Stop | Out-Null
                $Stats.Changed++
                $Logger.WrapLog("OpenSSH Server capability installed | Reason=absent", "NOTICE", $Context)
            } else {
                $Logger.WrapLog("WhatIf: would install capability '$($candidate.Name)'", "INFO", $Context)
            }
        }
        catch {
            $Stats.Failed++
            $HasFatalError = $true
            $Logger.WrapLog("Failed to install OpenSSH Server capability: $_", "ERROR", $Context)
        }
    }
}

# ------------------------------------------------------------
# Configure sshd service startup (TARGET = service)
# ------------------------------------------------------------
if (-not $HasFatalError) {
    $Stats.Observed++

    $svc = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue

    if (-not $svc) {
        $Stats.Failed++
        $HasFatalError = $true
        $Logger.WrapLog("sshd service not found after capability install", "ERROR", $Context)
    } else {
        if ($svc.StartType -ne 'Automatic') {
            $Logger.WrapLog("Setting sshd startup type to Automatic (was '$($svc.StartType)')", "INFO", $Context)
            if (-not $WhatIf) {
                Set-Service -Name 'sshd' -StartupType Automatic -ErrorAction Stop
                $Stats.Applied++
                $Stats.Changed++
            } else {
                $Logger.WrapLog("WhatIf: would set sshd StartupType to Automatic", "INFO", $Context)
            }
        } else {
            $Stats.Skipped++
            $Logger.WrapLog("sshd startup type already Automatic (noop) | Reason=match", "NOTICE", $Context)
        }
    }
}

# ------------------------------------------------------------
# Start sshd service (TARGET = service running)
# ------------------------------------------------------------
if (-not $HasFatalError) {
    $Stats.Observed++

    $svc = Get-Service -Name 'sshd' -ErrorAction SilentlyContinue

    if ($svc.Status -eq 'Running') {
        $Stats.Skipped++
        $Logger.WrapLog("sshd service already running (noop) | Reason=match", "NOTICE", $Context)
    } else {
        $Logger.WrapLog("Starting sshd service (was '$($svc.Status)')", "INFO", $Context)
        if (-not $WhatIf) {
            try {
                Start-Service -Name 'sshd' -ErrorAction Stop
                $Stats.Applied++
                $Stats.Changed++
                $Logger.WrapLog("sshd service started | Reason=not_running", "NOTICE", $Context)
            }
            catch {
                $Stats.Failed++
                $Logger.WrapLog("Failed to start sshd service: $_", "ERROR", $Context)
            }
        } else {
            $Logger.WrapLog("WhatIf: would start sshd service", "INFO", $Context)
        }
    }
}

# ------------------------------------------------------------
# Final observable state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)
$scope = "capability,service"

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$($Stats.Observed) applied=$($Stats.Applied) changed=$($Stats.Changed) failed=$($Stats.Failed) skipped=$($Stats.Skipped) | scope=$scope",
    "NOTICE",
    $Context
)

if ($Stats.Failed -gt 0) { exit 1 }
exit 0
