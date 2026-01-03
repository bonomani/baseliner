# AdminScheduleAdminTasks.ps1
# PowerShell 5.1
# COM-based Task Scheduler registration

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

$startTime = [datetime]::Now

# ------------------------------------------------------------
# Contract counters (TARGET = task)
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
# Load configuration
# ------------------------------------------------------------
try {
    $config = Get-ScriptConfig `
        -ScriptName     $ScriptName `
        -ConfigPath     $ConfigPath `
        -RequiredFields @("Tasks") `
        -Logger         $Logger `
        -Context        $Context
}
catch {
    $Stats.Failed = 1

    $Logger.WrapLog(
        "Configuration loading failed",
        "ERROR",
        $Context
    )
    exit 1
}

# ------------------------------------------------------------
# Scheduler service (COM)
# ------------------------------------------------------------
$service = New-Object -ComObject "Schedule.Service"
$service.Connect()
$rootFolder = $service.GetFolder("\")
$SYSTEM_SID = 'S-1-5-18'

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
function Convert-IsoDelayToTaskDelay {
    param ([string]$Delay)
    if (-not $Delay) { return $null }
    $m = [regex]::Match($Delay, '^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$')
    if (-not $m.Success) { return $null }
    $hours = [int]($m.Groups[1].Value)
    $mins = [int]($m.Groups[2].Value)
    $secs = [int]($m.Groups[3].Value)
    $totalSeconds = ($hours * 3600) + ($mins * 60) + $secs
    if ($totalSeconds -le 0) { return $null }
    return "PT${totalSeconds}S"
}

function Get-TaskSnapshot {
    param (
        $Definition
    )

    $trigger = $Definition.Triggers.Item(1)
    $action = $Definition.Actions.Item(1)

    return [PSCustomObject]@{
        TriggerType               = $trigger.Type
        TriggerDelay              = $trigger.Delay
        ActionPath                = $action.Path
        ActionArguments           = $action.Arguments
        PrincipalUserId           = $Definition.Principal.UserId
        PrincipalLogonType        = $Definition.Principal.LogonType
        PrincipalRunLevel         = $Definition.Principal.RunLevel
        Enabled                   = $Definition.Settings.Enabled
        Hidden                    = $Definition.Settings.Hidden
        RunOnlyIfIdle             = $Definition.Settings.RunOnlyIfIdle
        DisallowStartIfOnBatteries = $Definition.Settings.DisallowStartIfOnBatteries
        StopIfGoingOnBatteries    = $Definition.Settings.StopIfGoingOnBatteries
    }
}

# ------------------------------------------------------------
# Scheduled tasks (TARGET = task)
# ------------------------------------------------------------
foreach ($task in $config.Tasks) {

    $result = @{
        Observed = 0
        Applied   = 0
        Changed   = 0
        Failed    = 0
        Skipped   = 0
        Reason    = ""
    }

    if (-not $task.Name -or -not $task.Script) {
        $result.Skipped = 1
        $result.Reason = "invalid_definition"

        $Logger.WrapLog(
            "Task skipped: missing Name or Script",
            "WARN",
            $Context
        )
        $Logger.WrapLog(
            "Task '$($task.Name)' skipped | Reason=$($result.Reason) | observed=$($result.Observed) applied=$($result.Applied) changed=$($result.Changed) failed=$($result.Failed) skipped=$($result.Skipped)",
            "NOTICE",
            $Context
        )
        foreach ($k in @('Observed','Applied','Changed','Failed','Skipped')) { $Stats[$k] += $result[$k] }
        continue
    }

    $result.Observed = 1

    $taskName   = $task.Name
    $scriptPath = Expand-TemplateValue $task.Script

    if (-not (Test-Path $scriptPath)) {
        $result.Skipped = 1
        $result.Reason = "invalid_definition"

        $Logger.WrapLog(
            "Task '$taskName' failed: script not found ($scriptPath)",
            "ERROR",
            $Context
        )
        $Logger.WrapLog(
            "Task '$taskName' skipped | Reason=$($result.Reason) | observed=$($result.Observed) applied=$($result.Applied) changed=$($result.Changed) failed=$($result.Failed) skipped=$($result.Skipped)",
            "NOTICE",
            $Context
        )
        foreach ($k in @('Observed','Applied','Changed','Failed','Skipped')) { $Stats[$k] += $result[$k] }
        continue
    }

    $triggerType = if ($task.Trigger -eq "AtStartup") { 8 } else { 9 }
    $runLevel = if ($task.RunLevel -match '^High$|^Highest$') { 1 } else { 0 }
    $delay = Convert-IsoDelayToTaskDelay -Delay $task.Delay

    $Logger.WrapLog(
        "Set scheduled task '$taskName'.",
        "INFO",
        $Context
    )

    try {
        $existingTask = $null
        try {
            $existingTask = $rootFolder.GetTask("\$taskName")
        } catch {}

        if ($existingTask) {
            $desiredDefinition = $service.NewTask(0)
            $desiredDefinition.Settings.Enabled = if ($task.Enabled -eq $false) { $false } else { $true }
            $desiredDefinition.Settings.Hidden = if ($task.Hidden -eq $true) { $true } else { $false }
            $desiredDefinition.Settings.RunOnlyIfIdle = if ($task.RunOnlyIfIdle -eq $true) { $true } else { $false }
            $desiredDefinition.Settings.DisallowStartIfOnBatteries = if ($task.DisallowStartIfOnBatteries -eq $true) { $true } else { $false }
            $desiredDefinition.Settings.StopIfGoingOnBatteries = if ($task.StopIfGoingOnBatteries -eq $true) { $true } else { $false }
            $desiredDefinition.Settings.StartWhenAvailable = $true

            $principal = $desiredDefinition.Principal
            $principal.UserId    = $SYSTEM_SID
            $principal.LogonType = 5
            $principal.RunLevel  = $runLevel

            $trigger = $desiredDefinition.Triggers.Create($triggerType)
            if ($delay) { $trigger.Delay = $delay }

            $action = $desiredDefinition.Actions.Create(0)
            $action.Path      = 'powershell.exe'
            $action.Arguments = "-ExecutionPolicy Bypass -File `"$scriptPath`""

            $currentSnapshot = Get-TaskSnapshot -Definition $existingTask.Definition | ConvertTo-Json -Depth 5
            $desiredSnapshot = Get-TaskSnapshot -Definition $desiredDefinition | ConvertTo-Json -Depth 5

            if ($currentSnapshot -eq $desiredSnapshot) {
                $result.Reason = "match"
                $Logger.WrapLog(
                    "Scheduled task already compliant: '$taskName' | Reason=$($result.Reason) | observed=$($result.Observed) applied=$($result.Applied) changed=$($result.Changed) failed=$($result.Failed) skipped=$($result.Skipped)",
                    "NOTICE",
                    $Context
                )
                foreach ($k in @('Observed','Applied','Changed','Failed','Skipped')) { $Stats[$k] += $result[$k] }
                continue
            }
        }

        $definition = $service.NewTask(0)

        $definition.Settings.Enabled = if ($task.Enabled -eq $false) { $false } else { $true }
        $definition.Settings.Hidden = if ($task.Hidden -eq $true) { $true } else { $false }
        $definition.Settings.RunOnlyIfIdle = if ($task.RunOnlyIfIdle -eq $true) { $true } else { $false }
        $definition.Settings.DisallowStartIfOnBatteries = if ($task.DisallowStartIfOnBatteries -eq $true) { $true } else { $false }
        $definition.Settings.StopIfGoingOnBatteries = if ($task.StopIfGoingOnBatteries -eq $true) { $true } else { $false }
        $definition.Settings.StartWhenAvailable = $true

        $principal = $definition.Principal
        $principal.UserId    = $SYSTEM_SID
        $principal.LogonType = 5
        $principal.RunLevel  = $runLevel

        $trigger = $definition.Triggers.Create($triggerType)
        if ($delay) { $trigger.Delay = $delay }

        $action = $definition.Actions.Create(0)
        $action.Path      = 'powershell.exe'
        $action.Arguments = "-ExecutionPolicy Bypass -File `"$scriptPath`""

        if (-not $WhatIf) {
            $rootFolder.RegisterTaskDefinition(
                $taskName,
                $definition,
                6,
                $null,
                $null,
                5
            ) | Out-Null
        }

        $result.Applied = 1
        $result.Changed = 1
        $result.Reason = if ($existingTask) { "mismatch" } else { "missing" }

        $Logger.WrapLog(
            "Task '$taskName' registered successfully | Reason=$($result.Reason) | observed=$($result.Observed) applied=$($result.Applied) changed=$($result.Changed) failed=$($result.Failed) skipped=$($result.Skipped)",
            "NOTICE",
            $Context
        )
    }
    catch {
        $result.Applied = 1
        $result.Failed = 1
        $result.Reason = "exception"

        $Logger.WrapLog(
            "Failed to register task '$taskName': $_",
            "ERROR",
            $Context
        )
        $Logger.WrapLog(
            "Task '$taskName' failed | Reason=$($result.Reason) | observed=$($result.Observed) applied=$($result.Applied) changed=$($result.Changed) failed=$($result.Failed) skipped=$($result.Skipped)",
            "NOTICE",
            $Context
        )
    }
    foreach ($k in @('Observed','Applied','Changed','Failed','Skipped')) { $Stats[$k] += $result[$k] }
}

# ------------------------------------------------------------
# Script final observable state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$($Stats.Observed) applied=$($Stats.Applied) changed=$($Stats.Changed) failed=$($Stats.Failed) skipped=$($Stats.Skipped)",
    "NOTICE",
    $Context
)

if ($Stats.Failed -gt 0) { exit 1 }
exit 0
