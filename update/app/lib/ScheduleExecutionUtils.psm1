# ScheduleExecutionUtils.psm1
# Compatible PowerShell 5.1

function Get-NextRunDate {
    param (
        [string]   $Schedule,
        [datetime] $LastRun
    )
    switch ($Schedule.ToLower()) {
        'daily'   { return $LastRun.AddDays(1) }
        'weekly'  { return $LastRun.AddDays(7) }
        'monthly' { return $LastRun.AddMonths(1) }
        'once'    { return [datetime]::MaxValue }
        'always'  { return $LastRun }
        default   { throw "Unknown schedule: $Schedule" }
    }
}

function Get-ScheduleDatabase {
    param (
        [string] $Path,
        [string] $User,
        [object] $Logger,
        [object] $Context
    )

    $entries = @()
    if (Test-Path $Path) {
        $Logger.WrapLog("Loading schedule file: '$Path'", "DEBUG", $Context)
        $json = Get-Content $Path -Raw | ConvertFrom-Json
        foreach ($item in $json) {
            $entries += [PSCustomObject]@{
                Script  = $item.Script
                User    = $item.User
                LastRun = if ($item.LastRun) { [datetime]$item.LastRun } else { $null }
                NextRun = if ($item.NextRun) { [datetime]$item.NextRun } else { $null }
            }
        }
    } else {
        $Logger.WrapLog("No existing schedule found at '$Path'", "DEBUG", $Context)
    }

    return ,$entries
}

function Set-ScheduleDatabase {
    param (
        [string] $Path,
        [array]  $Entries
    )

    $Entries |
        ForEach-Object {
            $_.LastRun = if ($_.LastRun -is [datetime]) { $_.LastRun.ToString("o") } else { $null }
            $_.NextRun = if ($_.NextRun -is [datetime]) { $_.NextRun.ToString("o") } else { $null }
            $_
        } | ConvertTo-Json -Depth 10 | Set-Content -Path $Path
}

function Get-ScheduleIndex {
    param (
        [array]  $Schedules,
        [string] $Script,
        [string] $User
    )

    for ($i = 0; $i -lt $Schedules.Count; $i++) {
        if ($Schedules[$i].Script -eq $Script -and $Schedules[$i].User -eq $User) {
            return $i
        }
    }
    return -1
}

function Remove-ScheduleEntryIfAlways {
    param (
        [array]  $Schedules,
        [string] $Script,
        [string] $User,
        [string] $Schedule
    )

    if ($Schedule -eq 'always') {
        return $Schedules | Where-Object {
            $_.Script -ne $Script -or $_.User -ne $User
        }
    }
    return $Schedules
}

function New-ScheduleEntry {
    param (
        [string]   $Script,
        [string]   $User,
        [datetime] $StartTime
    )

    return [PSCustomObject]@{
        Script  = $Script
        User    = $User
        LastRun = $null
        NextRun = $StartTime
    }
}

function Initialize-ScheduleEntry {
    param (
        [array]    $Schedules,
        [string]   $Script,
        [string]   $User,
        [datetime] $StartTime
    )

    $index = Get-ScheduleIndex -Schedules $Schedules -Script $Script -User $User
    if ($index -ge 0) {
        $entry = $Schedules[$index]
        $entry.LastRun = if ($entry.LastRun) { [datetime]$entry.LastRun } else { $null }
        $entry.NextRun = if ($entry.NextRun) { [datetime]$entry.NextRun } else { $StartTime }
        return @{ Entry = $entry; Index = $index; Exists = $true }
    }

    $newEntry = New-ScheduleEntry -Script $Script -User $User -StartTime $StartTime
    return @{ Entry = $newEntry; Index = -1; Exists = $false }
}

function Test-ShouldExecuteScript {
    param (
        [object]   $Entry,
        [string]   $Schedule,
        [datetime] $Now
    )

    return ($Entry.NextRun -le $Now -or $Schedule -eq 'always')
}

function Update-ScheduleCollection {
    param (
        [array]   $Schedules,
        [object]  $Entry,
        [int]     $Index,
        [string]  $Schedule,
        [string]  $Script,
        [string]  $User
    )

    $Schedules = Remove-ScheduleEntryIfAlways -Schedules $Schedules -Script $Script -User $User -Schedule $Schedule

    if ($Schedule -ne 'always') {
        if ($Index -ge 0) {
            $Schedules[$Index] = $Entry
        } else {
            $Schedules += $Entry
        }
    }

    return ,$Schedules
}

function Test-ScheduleEntry {
    param (
        [object] $ScriptEntry,
        [object] $Logger,
        [object] $Context
    )

    if (-not $ScriptEntry.Name) {
        $Logger.WrapLog("Script entry missing 'Name' property.", "ERROR", $Context)
        return $false
    }

    $schedule = if ($ScriptEntry.Schedule) { $ScriptEntry.Schedule } else { 'always' }
    if ($schedule -notin @("daily", "weekly", "monthly", "once", "always")) {
        $Logger.WrapLog("Invalid schedule value '$schedule' for script '$($ScriptEntry.Name)'", "ERROR", $Context)
        return $false
    }

    return $true
}

function Invoke-ScheduleEvaluation {
    param (
        [string]   $ScriptPath,
        [string]   $Schedule,
        [object]   $Entry,
        [datetime] $Now,
        [object]   $Logger,
        [object]   $Context
    )

    $Logger.WrapLog("Evaluating script '$ScriptPath' with schedule '$Schedule'", "DEBUG", $Context)

    if (Test-ShouldExecuteScript -Entry $Entry -Schedule $Schedule -Now $Now) {
        return $true
    }

    $Logger.WrapLog("Skipping script '$ScriptPath', scheduled for $($Entry.NextRun)", "DEBUG", $Context)
    return $false
}

Export-ModuleMember -Function `
    Get-NextRunDate,
    Get-ScheduleDatabase,
    Set-ScheduleDatabase,
    Get-ScheduleIndex,
    Remove-ScheduleEntryIfAlways,
    New-ScheduleEntry,
    Initialize-ScheduleEntry,
    Test-ShouldExecuteScript,
    Update-ScheduleCollection,
    Test-ScheduleEntry,
    Invoke-ScheduleEvaluation
