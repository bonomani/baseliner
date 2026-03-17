# UserRemoveApps-UCC.ps1
# BISS-RIG compliant — UCC semantics (explicit, convergent, retry-safe)
# PowerShell 5.1 compatible

param (
    [string]$ConfigPath,

    [ValidateSet("DEBUG","INFO","NOTICE","WARN","ERROR")]
    [string]$LogLevel = "INFO",

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
# Bootstrap
# ------------------------------------------------------------
$init = Initialize-Script `
    -ScriptPath  $PSCommandPath `
    -ConfigPath  $ConfigPath `
    -LogLevel    $LogLevel `
    -ErrorAction $ErrorAction `
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

$Logger.WrapLog(
    "Start script '$ScriptName' | Semantic=UCC | TargetState=ABSENT | RetrySafe=true",
    "INFO",
    $Context
)
# UCC DECLARATION: explicit, non-ambiguous

# ------------------------------------------------------------
# Load configuration
# ------------------------------------------------------------
$RequiredFields = @("apps")

try {
    $Config = Get-ScriptConfig `
        -ScriptName     $ScriptName `
        -ConfigPath     $ConfigPath `
        -RequiredFields $RequiredFields `
        -Logger         $Logger `
        -Context        $Context
}
catch {
    $Logger.WrapLog(
        "Failed to load configuration file",
        "ERROR",
        $Context
    )
    exit 1
}

# ------------------------------------------------------------
# UCC execution (each app is a TARGET)
# ------------------------------------------------------------
$Results = @()

foreach ($AppName in $Config.apps) {

    $Logger.WrapLog(
        "Evaluate application '$AppName'",
        "INFO",
        $Context
    )

    # --- Observe current state ---
    $Pkg = Get-AppxPackage -Name $AppName -ErrorAction SilentlyContinue

    if (-not $Pkg) {
        # ALREADY CONVERGED
        $Logger.WrapLog(
            "Application '$AppName' already absent",
            "NOTICE",
            $Context
        )

        $Results += @{
            target        = $AppName
            current_state = "ABSENT"
            target_state  = "ABSENT"
            status        = "ALREADY_CONVERGED"
        }
        continue
    }

    # --- Apply corrective action ---
    try {
        $Logger.WrapLog(
            "Application '$AppName' present | corrective action=REMOVE",
            "INFO",
            $Context
        )

        # CHANGE: corrective action wrapped with Invoke-Governed
        Invoke-Governed `
            -Intent "Remove AppX package '$AppName'" `
            -Action {
                Remove-AppxPackage -Package $Pkg.PackageFullName -ErrorAction Stop
            }
        # END CHANGE
    }
    catch {
        $Logger.WrapLog(
            "Corrective action failed for '$AppName'",
            "ERROR",
            $Context
        )

        $Results += @{
            target        = $AppName
            current_state = "PRESENT"
            target_state  = "ABSENT"
            status        = "NOT_CONVERGED"
            reason        = "REMOVE_FAILED"
        }
        continue
    }

    # --- Re-observe state (UCC mandatory) ---
    $PkgAfter = Get-AppxPackage -Name $AppName -ErrorAction SilentlyContinue

    if (-not $PkgAfter) {
        $Logger.WrapLog(
            "Application '$AppName' successfully removed",
            "NOTICE",
            $Context
        )

        $Results += @{
            target        = $AppName
            current_state = "ABSENT"
            target_state  = "ABSENT"
            status        = "CONVERGED"
        }
    }
    else {
        $Logger.WrapLog(
            "Application '$AppName' still present after corrective action",
            "ERROR",
            $Context
        )

        $Results += @{
            target        = $AppName
            current_state = "PRESENT"
            target_state  = "ABSENT"
            status        = "NOT_CONVERGED"
            reason        = "POST_CHECK_FAILED"
        }
    }
}

# ------------------------------------------------------------
# Final observable convergence state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)

$notConverged = ($Results | Where-Object { $_.status -eq "NOT_CONVERGED" }).Count

$Logger.WrapLog(
    "End script '$ScriptName' | Semantic=UCC | duration=${duration}s | targets=$($Results.Count) not_converged=$notConverged",
    "NOTICE",
    $Context
)

# ------------------------------------------------------------
# UCC exit semantics
# ------------------------------------------------------------
# exit code indicates execution correctness, not convergence
exit 0
