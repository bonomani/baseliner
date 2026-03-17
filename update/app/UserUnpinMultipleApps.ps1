# UserUnpinMultipleApps.ps1
# Compatible PowerShell 5.1

param (
    [string]$ConfigPath,

    [ValidateSet("DEBUG","INFO","NOTICE","WARN","ERROR")]
    [string]$LogLevel = "NOTICE",

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

Import-Module "$lib\GeneralUtil.psm1"             -ErrorAction Stop -Force
Import-Module "$lib\LoadScriptConfig.psm1"        -ErrorAction Stop -Force

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
# Start
# ------------------------------------------------------------
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
$RequiredFields = @("Applications")

try {
    $Config = Get-ScriptConfig `
        -ScriptName     $ScriptName `
        -ConfigPath     $ConfigPath `
        -RequiredFields $RequiredFields `
        -Logger         $Logger `
        -Context        $Context
}
catch {
    $Logger.WrapLog("Configuration loading failed", "ERROR", $Context)
    exit 1
}

$applications = $Config.Applications

$Logger.WrapLog(
    "Start ${ScriptName} targets=$($applications.Count) scope=apps",
    "DEBUG",
    $Context
)

# ------------------------------------------------------------
# Contract counters (per TARGET + aggregate)
# ------------------------------------------------------------
$Stats = @{
    Observed = 0
    Applied   = 0
    Changed   = 0
    Failed    = 0
    Skipped   = 0
}

$AppResults = @{}
foreach ($app in $applications) {
    $AppResults[$app] = @{
        Observed = 1
        Applied   = 0
        Changed   = 0
        Failed    = 0
        Skipped   = 0
    }
}

# ------------------------------------------------------------
# Helper
# ------------------------------------------------------------
function Mark-App {
    param(
        [string]$App,
        [string]$State
    )

    switch ($State) {
        'Changed' {
            $AppResults[$App].Applied = 1
            $AppResults[$App].Changed = 1
        }
        'Failed' {
            $AppResults[$App].Applied = 1
            $AppResults[$App].Failed  = 1
        }
    }
}

# ------------------------------------------------------------
# Unpin logic (unchanged, only marking results)
# ------------------------------------------------------------
function Try-Unpin {
    param([string[]]$Applications)

    try {
        $shell = New-Object -ComObject Shell.Application
        $taskbarItems = $shell.NameSpace(
            'shell:::{4234d49b-0245-4df3-b780-3893943456e1}'
        ).Items()

        foreach ($app in $Applications) {
            if ($AppResults[$app].Changed -or $AppResults[$app].Failed) { continue }

            foreach ($item in $taskbarItems) {
                if ($item.Name -ne $app) { continue }

                $verb = $item.Verbs() |
                    Where-Object { $_.Name -replace '&','' -match 'Unpin from taskbar' }

                if ($verb) {
                    $verb.DoIt()
                    Mark-App -App $app -State 'Changed'
                }
                break
            }
        }
    }
    catch {
        foreach ($app in $Applications) {
            if (-not $AppResults[$app].Changed) {
                Mark-App -App $app -State 'Failed'
            }
        }
    }
}

Try-Unpin -Applications $applications

# ------------------------------------------------------------
# Per-app final state logging
# ------------------------------------------------------------
foreach ($app in $applications) {

    $Logger.WrapLog(
        "Unpin app '$app' from taskbar.",
        "INFO",
        $Context
    )

    if ($AppResults[$app].Changed) {
        $Logger.WrapLog(
            "Application '$app' unpinned from taskbar | Reason=mismatch",
            "NOTICE",
            $Context
        )
    }
    elseif ($AppResults[$app].Failed) {
        $Logger.WrapLog(
            "Application '$app' failed to unpin from taskbar | Reason=exception",
            "NOTICE",
            $Context
        )
    }
    else {
        $Logger.WrapLog(
            "Application '$app' already absent from taskbar | Reason=match",
            "NOTICE",
            $Context
        )
    }

    foreach ($k in @('Observed','Applied','Changed','Failed','Skipped')) {
        $Stats[$k] += $AppResults[$app][$k]
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
