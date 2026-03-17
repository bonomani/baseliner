# AdminUserSetupFromActiveSetup.ps1
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

Import-Module (Join-Path $lib 'GeneralUtil.psm1')      -ErrorAction Stop -Force
Import-Module (Join-Path $lib 'LoadScriptConfig.psm1') -ErrorAction Stop -Force

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

$ScriptRoot = $init.ScriptRoot

# ------------------------------------------------------------
# Administrator requirement
# ------------------------------------------------------------
if (-not (Test-IsAdministrator)) {
    $Logger.WrapLog(
        "This script must be run as Administrator",
        "ERROR",
        $Context
    )
    exit 1
}

# ------------------------------------------------------------
# Script start
# ------------------------------------------------------------
$Logger.WrapLog(
    "Start script '$ScriptName'.",
    "INFO",
    $Context
)

# ------------------------------------------------------------
# Contract counters (single TARGET)
# ------------------------------------------------------------
$Stats = @{
    Observed = 0
    Applied   = 0
    Changed   = 0
    Failed    = 0
    Skipped   = 0
}

$HasFatalError = $false

# ------------------------------------------------------------
# Load configuration
# ------------------------------------------------------------
$RequiredFields = @("PauseDuration", "AdditionalScriptName")

try {
    $Config = Get-ScriptConfig `
        -ScriptName     $ScriptName `
        -ConfigPath     $ConfigPath `
        -RequiredFields $RequiredFields `
        -Logger         $Logger `
        -Context        $Context

    $Stats.Observed = 1
}
catch {
    $Stats.Observed = 1
    $Stats.Failed    = 1
    $HasFatalError   = $true

    $Logger.WrapLog(
        "Failed to load configuration file",
        "ERROR",
        $Context
    )
}

# ------------------------------------------------------------
# Optional pause (no state change)
# ------------------------------------------------------------
if (-not $HasFatalError -and $Config.PauseDuration -gt 0) {
    $Logger.WrapLog(
        "Pause applied",
        "DEBUG",
        $Context
    )
    Start-Sleep -Seconds $Config.PauseDuration
}

# ------------------------------------------------------------
# Execute additional script
# ------------------------------------------------------------
if (-not $HasFatalError) {

    $AdditionalScriptName = $Config.AdditionalScriptName
    $AdditionalScriptPath = Join-Path $ScriptRoot $AdditionalScriptName

    if (-not (Test-Path $AdditionalScriptPath)) {
        $Stats.Applied = 1
        $Stats.Failed  = 1
        $HasFatalError = $true

        $Logger.WrapLog(
            "Additional script not found",
            "ERROR",
            $Context
        )
    }
}

if (-not $HasFatalError) {

    $Logger.WrapLog(
        "Invoke child script '$AdditionalScriptName'.",
        "INFO",
        $Context
    )

    $Stats.Applied = 1

    $Result = Invoke-Script `
        -AppCommand $AdditionalScriptPath `
        -Context    $Context `
        -Logger     $Logger

    if ($Result) {
        $Stats.Changed = 1
    }
    else {
        $Stats.Failed = 1
    }
}

# ------------------------------------------------------------
# Final observable state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)
$scope = "mixed"

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$($Stats.Observed) applied=$($Stats.Applied) changed=$($Stats.Changed) failed=$($Stats.Failed) skipped=$($Stats.Skipped) | scope=$scope",
    "NOTICE",
    $Context
)

if ($Stats.Failed -eq 0) {
    exit 0
}

exit 1
