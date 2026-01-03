# AdminRemoveProvisionnedApps.ps1
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

Import-Module "$lib\GeneralUtil.psm1"            -ErrorAction Stop -Force
Import-Module "$lib\LoadScriptConfig.psm1"       -ErrorAction Stop -Force
Import-Module "$lib\FileOperationUtils.psm1"     -ErrorAction Stop -Force
Import-Module "$lib\RegistryOperationUtils.psm1" -ErrorAction Stop -Force

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
# Contract counters (TARGET = application)
# ------------------------------------------------------------
$Stats = @{
    Observed = 0
    Applied   = 0
    Changed   = 0
    Failed    = 0
    Skipped   = 0
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
# Script TARGET taken in charge
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
        -RequiredFields @("apps") `
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
    "Start ${ScriptName} targets=$($config.apps.Count) scope=apps",
    "DEBUG",
    $Context
)

# ------------------------------------------------------------
# Provisioned packages snapshot (implementation detail)
# ------------------------------------------------------------
$provisioned = Get-AppxProvisionedPackage -Online

# ------------------------------------------------------------
# Remove provisioned apps (TARGET = application)
# ------------------------------------------------------------
foreach ($appDisplayName in $config.apps) {

    $Stats.Observed++

    $Logger.WrapLog(
        "Remove provisioned application '$appDisplayName'.",
        "INFO",
        $Context
    )

    $match = $provisioned |
        Where-Object { $_.DisplayName -eq $appDisplayName }

    if (-not $match) {
        $Logger.WrapLog(
            "Application '$appDisplayName' not provisioned (noop) | Reason=not_applicable",
            "NOTICE",
            $Context
        )
        continue
    }

    try {
        $Stats.Applied++

        if (-not $WhatIf) {
            Remove-AppxProvisionedPackage `
                -Online `
                -PackageName $match.PackageName `
                -ErrorAction Stop
        }

        $Stats.Changed++

        $Logger.WrapLog(
            "Application '$appDisplayName' removed | Reason=present",
            "NOTICE",
            $Context
        )
    }
    catch {
        $Stats.Failed++

        $Logger.WrapLog(
            "Application '$appDisplayName' failed to remove",
            "ERROR",
            $Context
        )
    }
}

# ------------------------------------------------------------
# Script final observable state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)
$scope = "apps"

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$($Stats.Observed) applied=$($Stats.Applied) changed=$($Stats.Changed) failed=$($Stats.Failed) skipped=$($Stats.Skipped) | scope=$scope",
    "NOTICE",
    $Context
)

if ($Stats.Failed -gt 0) { exit 1 }
exit 0
