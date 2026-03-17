# AdminSetup.ps1
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

Import-Module "$lib\GeneralUtil.psm1"            -ErrorAction Stop -Force
Import-Module "$lib\LoadScriptConfig.psm1"       -ErrorAction Stop -Force
Import-Module "$lib\FileOperationUtils.psm1"     -ErrorAction Stop -Force
Import-Module "$lib\RegistryOperationUtils.psm1" -ErrorAction Stop -Force
Import-Module "$lib\ScheduleExecutionUtils.psm1" -ErrorAction Stop -Force

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
$DataRoot   = $init.DataRoot
$ConfigPath = $init.ConfigPath
$ScriptName = $init.ScriptName

$currentUser = $env:USERNAME
$startTime   = [datetime]::Now

# ------------------------------------------------------------
# Contract counters (multi TARGET)
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
# Script TARGET taken in charge (orchestrator)
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
        -RequiredFields @("Script") `
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

$schedulesPath   = Join-Path $DataRoot "schedules.json"
$scriptBlock     = $config.Script
$scriptList      = $scriptBlock.Scripts
$defaultFolder   = Expand-TemplateValue $scriptBlock.Folder
$defaultSchedule = if ($scriptBlock.Schedule) { $scriptBlock.Schedule } else { 'always' }

if (-not $defaultFolder) {
    $Stats.Failed = 1

    $Logger.WrapLog(
        "Script $ScriptName failed: default folder not resolved",
        "ERROR",
        $Context
    )
    exit 1
}

# ------------------------------------------------------------
# Load schedule database (implementation detail)
# ------------------------------------------------------------
$existingSchedules = Get-ScheduleDatabase `
    -Path    $schedulesPath `
    -User    $currentUser `
    -Logger  $Logger `
    -Context $Context

# ------------------------------------------------------------
# Execute scheduled scripts (TARGET = script)
# ------------------------------------------------------------
foreach ($scriptEntry in $scriptList) {

    if (-not (Test-ScheduleEntry -ScriptEntry $scriptEntry -Logger $Logger -Context $Context)) {
        continue
    }

    $Stats.Observed++

    $scriptPath = Join-Path $defaultFolder "$($scriptEntry.Name).ps1"
    $schedule   = if ($scriptEntry.Schedule) { $scriptEntry.Schedule } else { $defaultSchedule }

    $initEntry = Initialize-ScheduleEntry `
        -Schedules $existingSchedules `
        -Script    $scriptPath `
        -User      $currentUser `
        -StartTime $startTime

    $entry = $initEntry.Entry
    $index = $initEntry.Index

    if (Invoke-ScheduleEvaluation `
            -ScriptPath $scriptPath `
            -Schedule   $schedule `
            -Entry      $entry `
            -Now        $startTime `
            -Logger     $Logger `
            -Context    $Context) {

        $Stats.Applied++

        $Logger.WrapLog(
            "Invoke child script '$($scriptEntry.Name)'.",
            "INFO",
            $Context
        )

        $result = Invoke-Script `
            -AppCommand     $scriptPath `
            -TimeoutSeconds 20 `
            -Context        $Context `
            -Logger         $Logger

        if (-not $result) {
            $Stats.Failed++
        }

        $entry.LastRun = $startTime
        $entry.NextRun = Get-NextRunDate -Schedule $schedule -LastRun $startTime
    }
    else {
        $Stats.Skipped++
    }

    $existingSchedules = Update-ScheduleCollection `
        -Schedules $existingSchedules `
        -Entry     $entry `
        -Index     $index `
        -Schedule  $schedule `
        -Script    $scriptPath `
        -User      $currentUser
}

# ------------------------------------------------------------
# Persist schedules (implementation detail)
# ------------------------------------------------------------
if ($existingSchedules.Count -gt 0) {
    Set-ScheduleDatabase -Path $schedulesPath -Entries $existingSchedules
}

# ------------------------------------------------------------
# Script final observable state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)
$scope = "mixed"

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$($Stats.Observed) applied=$($Stats.Applied) changed=$($Stats.Changed) failed=$($Stats.Failed) skipped=$($Stats.Skipped) | scope=$scope",
    "NOTICE",
    $Context
)

if ($Stats.Failed -gt 0) { exit 1 }
exit 0
