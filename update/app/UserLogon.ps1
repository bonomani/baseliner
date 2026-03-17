# User.Logon.ps1
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
# Core imports (NO Logger import)
# ------------------------------------------------------------
$lib = Join-Path $PSScriptRoot 'lib'

Import-Module (Join-Path $lib 'GeneralUtil.psm1')            -ErrorAction Stop -Force
Import-Module (Join-Path $lib 'LoadScriptConfig.psm1')       -ErrorAction Stop -Force
Import-Module (Join-Path $lib 'FileOperationUtils.psm1')     -ErrorAction Stop -Force
Import-Module (Join-Path $lib 'RegistryOperationUtils.psm1') -ErrorAction Stop -Force
Import-Module (Join-Path $lib 'ScheduleExecutionUtils.psm1') -ErrorAction Stop -Force

# ------------------------------------------------------------
# Bootstrap (paths, context, logger)
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

# ------------------------------------------------------------
# Script start (TARGET taken in charge)
# ------------------------------------------------------------
$CurrentUser = $env:USERNAME
$StartTime   = [datetime]::Now

$Logger.WrapLog(
    "Start script '$ScriptName'.",
    "INFO",
    $Context
)

# ------------------------------------------------------------
# Load configuration
# ------------------------------------------------------------
try {
    $Config = Get-ScriptConfig `
        -ScriptName     $ScriptName `
        -ConfigPath     $ConfigPath `
        -RequiredFields @("Script") `
        -Logger         $Logger
} catch {
    $Logger.WrapLog(
        "Failed to load configuration file",
        "ERROR",
        $Context
    )
    exit 1
}

# ------------------------------------------------------------
# Schedule execution
# ------------------------------------------------------------
$SchedulesPath   = Join-Path $DataRoot 'schedules.json'
$ScriptBlock     = $Config.Script
$ScriptList      = $ScriptBlock.Scripts
$DefaultFolder   = Expand-TemplateValue $ScriptBlock.Folder
$DefaultSchedule = if ($ScriptBlock.Schedule) { $ScriptBlock.Schedule } else { 'always' }

if (-not $DefaultFolder) {
    $Logger.WrapLog(
        "Default folder not resolved",
        "ERROR",
        $Context
    )
    exit 1
}

$ExistingSchedules = Get-ScheduleDatabase `
    -Path    $SchedulesPath `
    -User    $CurrentUser `
    -Logger  $Logger `
    -Context $Context

$Stats = @{
    Observed = 0
    Applied   = 0
    Changed   = 0
    Failed    = 0
    Skipped   = 0
}

foreach ($ScriptEntry in $ScriptList) {

    if (-not (Test-ScheduleEntry -ScriptEntry $ScriptEntry -Logger $Logger -Context $Context)) {
        continue
    }

    $ScriptPath = Join-Path $DefaultFolder "$($ScriptEntry.Name).ps1"
    $Schedule   = if ($ScriptEntry.Schedule) { $ScriptEntry.Schedule } else { $DefaultSchedule }

    $Init  = Initialize-ScheduleEntry `
        -Schedules $ExistingSchedules `
        -Script    $ScriptPath `
        -User      $CurrentUser `
        -StartTime $StartTime

    $Entry = $Init.Entry
    $Index = $Init.Index

    $Stats.Observed++

    if (Invoke-ScheduleEvaluation `
        -ScriptPath $ScriptPath `
        -Schedule   $Schedule `
        -Entry      $Entry `
        -Now        $StartTime `
        -Logger     $Logger `
        -Context    $Context
    ) {
        $Stats.Applied++

        $Logger.WrapLog(
            "Invoke child script '$($ScriptEntry.Name)'.",
            "INFO",
            $Context
        )

        $Result = Invoke-Script `
            -AppCommand      $ScriptPath `
            -TimeoutSeconds  20 `
            -Context         $Context `
            -Logger          $Logger

        if ($Result) {
            # Child script logs its own NOTICE.
        } else {
            $Stats.Failed++
            $Logger.WrapLog(
                "Script $($ScriptEntry.Name).ps1 failed",
                "DEBUG",
                $Context
            )
        }

        $Entry.LastRun = $StartTime
        $Entry.NextRun = Get-NextRunDate -Schedule $Schedule -LastRun $StartTime

        $Logger.WrapLog(
            "NextRun computed: next=$($Entry.NextRun) last=$($Entry.LastRun) schedule=$Schedule",
            "DEBUG",
            $Context
        )
    } else {
        $Stats.Skipped++
    }

    $ExistingSchedules = Update-ScheduleCollection `
        -Schedules $ExistingSchedules `
        -Entry     $Entry `
        -Index     $Index `
        -Schedule  $Schedule `
        -Script    $ScriptPath `
        -User      $CurrentUser
}

if ($ExistingSchedules.Count -gt 0) {
    Set-ScheduleDatabase -Path $SchedulesPath -Entries $ExistingSchedules
}

# ------------------------------------------------------------
# Final summary (observable final state)
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)
$scope = "mixed"

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$($Stats.Observed) applied=$($Stats.Applied) changed=$($Stats.Changed) failed=$($Stats.Failed) skipped=$($Stats.Skipped) | scope=$scope",
    "NOTICE",
    $Context
)

exit 0
