# AdminRegularAdminTasks.ps1
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
$DataRoot   = $init.DataRoot

# ------------------------------------------------------------
# DateTime normalization (CRITICAL)
# ------------------------------------------------------------
function Convert-ToDateTimeSafe {
    param ($Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [Array]) {
        $Value = $Value | Sort-Object | Select-Object -Last 1
    }

    try {
        return [datetime]$Value
    } catch {
        return $null
    }
}

# ------------------------------------------------------------
# Contract counters (TARGET = script entry)
# ------------------------------------------------------------
$Stats = @{
    Observed = 0
    Executed  = 0
    Skipped   = 0
    Failed    = 0
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
$Logger.WrapLog("Invoke script $ScriptName.", "INFO", $Context)

$currentUser = $env:USERNAME
$startTime   = [datetime]::Now

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
} catch {
    $Stats.Failed = 1
    $Logger.WrapLog(
        "Script $ScriptName failed: configuration loading error",
        "ERROR",
        $Context
    )
    exit 1
}

# ------------------------------------------------------------
# Scheduling helpers
# ------------------------------------------------------------
function Get-NextRunDate {
    param ([string]$Schedule, [datetime]$LastRun)

    switch ($Schedule.ToLower()) {
        'daily'   { $LastRun.AddDays(1) }
        'weekly'  { $LastRun.AddDays(7) }
        'monthly' { $LastRun.AddMonths(1) }
        'once'    { [datetime]::MaxValue }
        'always'  { [datetime]::MinValue  }
        default   { throw "Invalid schedule: $Schedule" }
    }
}

$schedulesPath   = Join-Path $DataRoot 'db\schedules.json'
$scriptBlock     = $config.Script
$scriptList      = $scriptBlock.Scripts
$defaultFolder   = Expand-TemplateValue $scriptBlock.Folder
$defaultSchedule = $scriptBlock.Schedule

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
# Load schedules database (ROBUST)
# ------------------------------------------------------------
$schedules = @()

if (Test-Path $schedulesPath) {
    $raw = Get-Content $schedulesPath -Raw | ConvertFrom-Json
    foreach ($item in $raw) {
        $schedules += [PSCustomObject]@{
            Script  = $item.Script
            User    = $item.User
            LastRun = Convert-ToDateTimeSafe $item.LastRun
            NextRun = Convert-ToDateTimeSafe $item.NextRun
        }
    }
}

# ------------------------------------------------------------
# Execute scheduled scripts
# ------------------------------------------------------------
foreach ($entryDef in $scriptList) {

    $Stats.Observed++

    if (-not $entryDef.Name) {
        $Stats.Skipped++
        $Logger.WrapLog("Script entry skipped: missing Name", "WARN", $Context)
        continue
    }

    $scriptKey  = $entryDef.Name
    $schedule   = if ($entryDef.Schedule) { $entryDef.Schedule } else { $defaultSchedule }
    $scriptPath = Join-Path $defaultFolder "$scriptKey.ps1"

    $entry = $schedules |
        Where-Object { $_.Script -eq $scriptPath -and $_.User -eq $currentUser } |
        Select-Object -First 1

    if (-not $entry) {
        $entry = [PSCustomObject]@{
            Script  = $scriptPath
            User    = $currentUser
            LastRun = $null
            NextRun = $startTime
        }
        $schedules += $entry
    }

    if ($schedule -ne 'always' -and $entry.NextRun -gt $startTime) {
        $Stats.Skipped++
        $Logger.WrapLog(
            "Script '$scriptKey' skipped (not due) | Reason=not_due",
            "NOTICE",
            $Context
        )
        continue
    }

    $Logger.WrapLog("Invoke child script '$scriptKey'.", "INFO", $Context)

    $ok = Invoke-Script `
        -AppCommand     $scriptPath `
        -TimeoutSeconds 20 `
        -Context        $Context `
        -Logger         $Logger

    if ($ok) {
        $Stats.Executed++
    } else {
        $Stats.Failed++
    }

    $entry.LastRun = $startTime
    $entry.NextRun = Get-NextRunDate -Schedule $schedule -LastRun $startTime
}

# ------------------------------------------------------------
# Persist schedules
# ------------------------------------------------------------
$schedules |
    ForEach-Object {
        $_.LastRun = if ($_.LastRun) { $_.LastRun.ToString("o") } else { $null }
        $_.NextRun = if ($_.NextRun) { $_.NextRun.ToString("o") } else { $null }
        $_
    } |
    ConvertTo-Json -Depth 10 |
    Set-Content -Path $schedulesPath

# ------------------------------------------------------------
# Final observable state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)
$observed = $Stats.Observed
$applied = $Stats.Executed
$changed = 0
$failed = $Stats.Failed
$skipped = $Stats.Skipped
$scope = "mixed"

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$observed applied=$applied changed=$changed failed=$failed skipped=$skipped | scope=$scope",
    "NOTICE",
    $Context
)

if ($Stats.Failed -gt 0) { exit 1 }
exit 0
