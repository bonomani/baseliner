# UserSetMsnLanguage.ps1
# Compatible PowerShell 5.1
# Opens MSN at the fr-CH URL to set language preference, then closes the browser window.
# Scheduled as "once" via UserLogon - will never run again after first successful execution.

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

$Logger.WrapLog("Start script '$ScriptName'.", "INFO", $Context)

# ------------------------------------------------------------
# Contract counters (TARGET = browser session)
# ------------------------------------------------------------
$Stats = @{
    Observed = 0
    Applied  = 0
    Changed  = 0
    Failed   = 0
    Skipped  = 0
}

$HasFatalError = $false

# ------------------------------------------------------------
# Load configuration
# ------------------------------------------------------------
$url     = "https://www.msn.com/fr-ch"
$waitSec = 20

try {
    $Config = Get-ScriptConfig `
        -ScriptName     $ScriptName `
        -ConfigPath     $ConfigPath `
        -RequiredFields @() `
        -Logger         $Logger `
        -Context        $Context

    if ($Config.Url)     { $url     = $Config.Url }
    if ($Config.WaitSec) { $waitSec = $Config.WaitSec }
}
catch {
    # Config section optional - defaults apply
    $Logger.WrapLog("No config section found, using defaults (Url='$url', WaitSec=$waitSec)", "DEBUG", $Context)
}

$Logger.WrapLog("Target URL: '$url' | WaitSec: $waitSec", "DEBUG", $Context)

# ------------------------------------------------------------
# Open browser at MSN fr-CH (TARGET = browser session)
# ------------------------------------------------------------
$Stats.Observed++

$Logger.WrapLog("Opening browser at '$url'", "INFO", $Context)

$proc = $null

if (-not $WhatIf) {
    try {
        $proc = Start-Process $url -PassThru -ErrorAction Stop
        $Stats.Applied++
        $Logger.WrapLog("Browser process started (PID=$($proc.Id))", "DEBUG", $Context)
    }
    catch {
        $Stats.Failed++
        $HasFatalError = $true
        $Logger.WrapLog("Failed to open browser: $_", "ERROR", $Context)
    }
} else {
    $Logger.WrapLog("WhatIf: would open browser at '$url'", "INFO", $Context)
}

# ------------------------------------------------------------
# Wait for page to load and set language preference
# ------------------------------------------------------------
if (-not $HasFatalError -and -not $WhatIf) {
    $Logger.WrapLog("Waiting ${waitSec}s for page to load and language preference to be saved", "INFO", $Context)
    Start-Sleep -Seconds $waitSec
}

# ------------------------------------------------------------
# Close the browser window (TARGET = process closed)
# ------------------------------------------------------------
if (-not $HasFatalError -and $proc -and -not $WhatIf) {
    $Stats.Observed++

    if ($proc.HasExited) {
        $Stats.Skipped++
        $Logger.WrapLog("Browser process already closed (noop) | Reason=match", "NOTICE", $Context)
    } else {
        $Logger.WrapLog("Closing browser window (PID=$($proc.Id))", "INFO", $Context)
        try {
            $proc.CloseMainWindow() | Out-Null
            Start-Sleep -Seconds 3

            if (-not $proc.HasExited) {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }

            $Stats.Changed++
            $Logger.WrapLog("Browser window closed | Reason=present", "NOTICE", $Context)
        }
        catch {
            $Stats.Failed++
            $Logger.WrapLog("Failed to close browser process: $_", "ERROR", $Context)
        }
    }
} elseif ($WhatIf) {
    $Logger.WrapLog("WhatIf: would wait ${waitSec}s then close browser window", "INFO", $Context)
}

# ------------------------------------------------------------
# Final observable state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$($Stats.Observed) applied=$($Stats.Applied) changed=$($Stats.Changed) failed=$($Stats.Failed) skipped=$($Stats.Skipped) | scope=browser",
    "NOTICE",
    $Context
)

if ($Stats.Failed -gt 0) { exit 1 }
exit 0
