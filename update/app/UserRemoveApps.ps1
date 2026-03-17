# UserRemoveApps.ps1
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

Import-Module (Join-Path $lib 'GeneralUtil.psm1')       -ErrorAction Stop -Force
Import-Module (Join-Path $lib 'LoadScriptConfig.psm1')  -ErrorAction Stop -Force

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
# Script start
# ------------------------------------------------------------
$Logger.WrapLog(
    "Start script '$ScriptName'.",
    "INFO",
    $Context
)

# ------------------------------------------------------------
# Load configuration
# ------------------------------------------------------------
$RequiredFields = @("apps")

try {
    $Config = Get-ScriptConfig `
        -ScriptName     $ScriptName `
        -ConfigPath     $ConfigPath `
        -RequiredFields $RequiredFields `
        -Logger         $Logger `
        -Context        $Context
}
catch {
    $Logger.WrapLog(
        "Failed to load configuration file",
        "ERROR",
        $Context
    )
    exit 1
}

# ------------------------------------------------------------
# Contract counters (aggregate)
# ------------------------------------------------------------
$Stats = @{
    Observed = 0
    Applied   = 0
    Changed   = 0
    Failed    = 0
    Skipped   = 0
}

# ------------------------------------------------------------
# Execution (each app is a TARGET)
# ------------------------------------------------------------
foreach ($AppName in $Config.apps) {

    $Logger.WrapLog(
        "Remove application '$AppName'.",
        "INFO",
        $Context
    )

    $Stats.Observed++

    $Pkg = Get-AppxPackage -Name $AppName -ErrorAction SilentlyContinue

    if (-not $Pkg) {
        $Logger.WrapLog(
            "Application '$AppName' already absent | Reason=missing",
            "NOTICE",
            $Context
        )
        continue
    }

    $Stats.Applied++

    try {
        Remove-AppxPackage -Package $Pkg.PackageFullName -ErrorAction Stop
        $Logger.WrapLog(
            "Application '$AppName' removed | Reason=present",
            "NOTICE",
            $Context
        )
        $Stats.Changed++
    }
    catch {
        $Logger.WrapLog(
            "Failed to remove application '$AppName'",
            "ERROR",
            $Context
        )
        $Stats.Failed++
    }
}

# ------------------------------------------------------------
# Final observable state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)
$scope = "apps"

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$($Stats.Observed) applied=$($Stats.Applied) changed=$($Stats.Changed) failed=$($Stats.Failed) skipped=$($Stats.Skipped) | scope=$scope",
    "NOTICE",
    $Context
)

if ($Stats.Failed -eq 0) {
    exit 0
}

exit 1
