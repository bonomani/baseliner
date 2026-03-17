# AdminDisableOptionalFeatures.ps1
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
# Contract counters (TARGET = feature)
# ------------------------------------------------------------
$Stats = @{
    Observed = 0
    Applied  = 0
    Changed  = 0
    Failed   = 0
    Skipped  = 0
}

# ------------------------------------------------------------
# Administrator requirement
# ------------------------------------------------------------
if (-not (Test-IsAdministrator)) {
    $Stats.Failed = 1

    $Logger.WrapLog(
        "Script $ScriptName cannot start: administrator privileges required",
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
# Configuration
# ------------------------------------------------------------
try {
    $config = Get-ScriptConfig `
        -ScriptName     $ScriptName `
        -ConfigPath     $ConfigPath `
        -RequiredFields @("features") `
        -Logger         $Logger `
        -Context        $Context
}
catch {
    $Stats.Failed = 1

    $Logger.WrapLog(
        "Script $ScriptName failed: configuration loading error",
        "ERROR",
        $Context
    )
    exit 1
}

$Logger.WrapLog(
    "Start ${ScriptName} targets=$($config.features.Count) scope=features",
    "DEBUG",
    $Context
)

# ------------------------------------------------------------
# Disable optional features (TARGET = feature)
# ------------------------------------------------------------
foreach ($featureName in $config.features) {

    $Stats.Observed++

    $Logger.WrapLog(
        "Disable optional feature '$featureName'.",
        "INFO",
        $Context
    )

    $feature = Get-WindowsOptionalFeature -Online -FeatureName $featureName -ErrorAction SilentlyContinue

    if (-not $feature) {
        $Logger.WrapLog(
            "Feature '$featureName' not found (noop) | Reason=not_applicable",
            "NOTICE",
            $Context
        )
        continue
    }

    if ($feature.State -eq 'Disabled') {
        $Logger.WrapLog(
            "Feature '$featureName' already disabled (noop) | Reason=match",
            "NOTICE",
            $Context
        )
        continue
    }

    try {
        $Stats.Applied++

        if (-not $WhatIf) {
            Disable-WindowsOptionalFeature -Online -FeatureName $featureName -NoRestart -ErrorAction Stop | Out-Null
        }

        $Stats.Changed++

        $Logger.WrapLog(
            "Feature '$featureName' disabled | Reason=present",
            "NOTICE",
            $Context
        )
    }
    catch {
        $Stats.Failed++

        $Logger.WrapLog(
            "Feature '$featureName' failed to disable",
            "ERROR",
            $Context
        )
    }
}

# ------------------------------------------------------------
# Script final observable state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)
$scope = "features"

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$($Stats.Observed) applied=$($Stats.Applied) changed=$($Stats.Changed) failed=$($Stats.Failed) skipped=$($Stats.Skipped) | scope=$scope",
    "NOTICE",
    $Context
)

if ($Stats.Failed -gt 0) { exit 1 }
exit 0
