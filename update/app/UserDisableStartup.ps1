# UserDisableStartup.ps1
# Compatible PowerShell 5.1

param (
    $Logger,
    $Context,

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
# Bootstrap (only if Logger / Context not injected)
# ------------------------------------------------------------
if (-not $Logger -or -not $Context) {

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
    $Config = Get-ScriptConfig `
        -ScriptName $ScriptName `
        -ConfigPath $ConfigPath `
        -Logger     $Logger `
        -Context    $Context
}
catch {
    $Logger.WrapLog(
        "Failed to load configuration file",
        "ERROR",
        $Context
    )
    exit 1
}

$Logger.WrapLog(
    "Start ${ScriptName} targets=$($Config.ProgramsToDisable.Count) scope=startup",
    "DEBUG",
    $Context
)

$keyPathApproved = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
$keyPathRun      = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"

if (-not (Test-Path $keyPathApproved)) {
    New-Item -Path $keyPathApproved -Force | Out-Null
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
# Execution (each startup entry is a TARGET)
# ------------------------------------------------------------
foreach ($programNamePattern in $Config.ProgramsToDisable) {

    $Logger.WrapLog(
        "Disable startup rule '$programNamePattern'.",
        "INFO",
        $Context
    )
    $runProps = Get-ItemProperty -Path $keyPathRun -ErrorAction SilentlyContinue
    if (-not $runProps) {
        continue
    }

    $Stats.Observed++

    $matchingProps = $runProps.PSObject.Properties |
        Where-Object { $_.Name -like $programNamePattern }

    if (-not $matchingProps) {
        continue
    }

    foreach ($prop in $matchingProps) {
        $programName = $prop.Name
        $Logger.WrapLog("Check startup entry '$programName'.", "DEBUG", $Context)

        try {
            $approvedProps = Get-ItemProperty -Path $keyPathApproved -ErrorAction SilentlyContinue
            $currentValue  = $approvedProps.PSObject.Properties |
                Where-Object { $_.Name -eq $programName } |
                Select-Object -ExpandProperty Value -ErrorAction SilentlyContinue

            if ($null -eq $currentValue) {

                $Stats.Applied++

                $disabledValue = [byte[]](
                    0x03,0x00,0x00,0x00,
                    0x00,0x00,0x00,0x00,
                    0x00,0x00,0x00,0x00
                )

                New-ItemProperty `
                    -Path $keyPathApproved `
                    -Name $programName `
                    -Value $disabledValue `
                    -PropertyType Binary `
                    -Force | Out-Null

                $Stats.Changed++
            }
            elseif ($currentValue[0] -eq 0x03) {
                # Already disabled -> noop success
                continue
            }
            else {

                $Stats.Applied++

                $currentValue[0] = 0x03
                Set-ItemProperty `
                    -Path $keyPathApproved `
                    -Name $programName `
                    -Value $currentValue | Out-Null

                $Stats.Changed++
            }
        }
        catch {
            $Stats.Applied++
            $Stats.Failed++

            $Logger.WrapLog(
                "Failed to disable startup entry $programName",
                "ERROR",
                $Context
            )
        }
    }
}

# ------------------------------------------------------------
# Final observable state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)
$scope = "startup"

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$($Stats.Observed) applied=$($Stats.Applied) changed=$($Stats.Changed) failed=$($Stats.Failed) skipped=$($Stats.Skipped) | scope=$scope",
    "NOTICE",
    $Context
)

if ($Stats.Failed -eq 0) {
    exit 0
}

exit 1
