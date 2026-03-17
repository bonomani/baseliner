# AdminUserSetup.ps1
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

Import-Module (Join-Path $lib 'GeneralUtil.psm1')            -ErrorAction Stop -Force
Import-Module (Join-Path $lib 'LoadScriptConfig.psm1')       -ErrorAction Stop -Force
Import-Module (Join-Path $lib 'ScheduleExecutionUtils.psm1') -ErrorAction Stop -Force

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
# Contract counters
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
try {
    $Config = Get-ScriptConfig `
        -ScriptName     $ScriptName `
        -ConfigPath     $ConfigPath `
        -RequiredFields @("Script") `
        -Logger         $Logger `
        -Context        $Context

    $Stats.Observed++
}
catch {
    $Stats.Observed++
    $Stats.Failed++
    $HasFatalError = $true

    $Logger.WrapLog(
        "Failed to load configuration file",
        "ERROR",
        $Context
    )
}

# ------------------------------------------------------------
# Scheduling & execution
# ------------------------------------------------------------
if (-not $HasFatalError) {

    $schedulesPath   = Join-Path $DataRoot 'schedules.json'
    $scriptBlock     = $Config.Script
    $scriptList      = $scriptBlock.Scripts
    $defaultFolder   = Expand-TemplateValue $scriptBlock.Folder
    $defaultSchedule = if ($scriptBlock.Schedule) { $scriptBlock.Schedule } else { 'always' }

    if (-not $defaultFolder) {
        $Stats.Failed++
        $HasFatalError = $true

        $Logger.WrapLog(
            "Default folder not resolved",
            "ERROR",
            $Context
        )
    }
}

if (-not $HasFatalError) {

    $existingSchedules = Get-ScheduleDatabase `
        -Path    $schedulesPath `
        -User    $currentUser `
        -Logger  $Logger `
        -Context $Context

    foreach ($scriptEntry in $scriptList) {

        if (-not (Test-ScheduleEntry -ScriptEntry $scriptEntry -Logger $Logger -Context $Context)) {
            $Stats.Skipped++
            continue
        }

        $scriptPath = Join-Path $defaultFolder "$($scriptEntry.Name).ps1"
        $schedule   = if ($scriptEntry.Schedule) { $scriptEntry.Schedule } else { $defaultSchedule }

        $initEntry = Initialize-ScheduleEntry `
            -Schedules $existingSchedules `
            -Script    $scriptPath `
            -User      $currentUser `
            -StartTime $startTime

        $entry = $initEntry.Entry
        $index = $initEntry.Index

        $Stats.Observed++

        if (Invoke-ScheduleEvaluation `
            -ScriptPath $scriptPath `
            -Schedule   $schedule `
            -Entry      $entry `
            -Now        $startTime `
            -Logger     $Logger `
            -Context    $Context
        ) {

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

            if ($result) {
                $Stats.Changed++
            }
            else {
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

    if ($existingSchedules.Count -gt 0) {
        Set-ScheduleDatabase -Path $schedulesPath -Entries $existingSchedules
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
