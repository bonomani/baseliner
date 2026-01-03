# AdminApplyFirewallRules
param (
    [string]$ConfigPath,

    [ValidateSet("DEBUG","INFO","NOTICE","WARN","ERROR")]
    [string]$LogLevel = "NOTICE",

    [int]$RetryCount   = 1,
    [int]$DelaySeconds = 0,

    [ValidateSet('Continue','Stop','SilentlyContinue','Inquire')]
    [string]$ErrorAction = 'Continue',

    [string]$ConfigSection,
    [string]$StartMessage,
    [string[]]$RequiredFields,

    [switch]$WhatIf,
    [switch]$Confirm,
    [switch]$Force,
    [switch]$Verbose,
    [switch]$Debug
)

# ------------------------------------------------------------
# Core modules
# ------------------------------------------------------------
$lib = Join-Path $PSScriptRoot 'lib'

Import-Module "$lib\GeneralUtil.psm1"       -ErrorAction Stop -Force
Import-Module "$lib\LoadScriptConfig.psm1"  -ErrorAction Stop -Force
Import-Module "$lib\FirewallRuleUtils.psm1"        -ErrorAction Stop -Force
Import-Module "$lib\FirewallRuleOperationUtils.psm1" -ErrorAction Stop -Force

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

$ConfigSection = if ($ConfigSection) { $ConfigSection } else { $ScriptName }
$ScriptName = $ConfigSection

$startTime = [datetime]::Now

# ------------------------------------------------------------
# Administrator requirement
# ------------------------------------------------------------
$requiresAdmin = $ConfigSection -match '^Admin'
if ($requiresAdmin -and -not (Test-IsAdministrator)) {
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
# Configuration
# ------------------------------------------------------------
$RequiredFields = if ($RequiredFields) { $RequiredFields } else { @("firewallBatchOperations") }

try {
    $Config = Get-ScriptConfig `
        -ScriptName     $ConfigSection `
        -ConfigPath     $ConfigPath `
        -RequiredFields $RequiredFields `
        -Logger         $Logger `
        -Context        $Context
} catch {
    $Logger.WrapLog(
        "Configuration loading failed",
        "ERROR",
        $Context
    )
    exit 1
}

# ------------------------------------------------------------
# Optional start message
# ------------------------------------------------------------
if ($StartMessage -or $Config.StartMessage) {
    $Logger.WrapLog(
        $(if ($StartMessage) { $StartMessage } else { $Config.StartMessage }),
        "INFO",
        $Context
    )
}

# ------------------------------------------------------------
# Normalized counters (contract)
# ------------------------------------------------------------
$Stats = @{
    Failed    = 0
    Changed   = 0
    Skipped   = 0
    Applied   = 0
    Observed = 0
}

# ------------------------------------------------------------
# Apply firewall rules
# ------------------------------------------------------------
foreach ($entry in $Config.firewallBatchOperations) {
    $operation = $entry.operation
    if (-not $operation) {
        $Logger.WrapLog(
            "Firewall batch skipped: missing operation | Reason=invalid_definition | observed=0 applied=0 changed=0 failed=0 skipped=1",
            "NOTICE",
            $Context
        )
        $Stats.Skipped++
        continue
    }

    $r = Invoke-FirewallBatchOperation `
        -Operation $operation `
        -Entry $entry `
        -Logger $Logger `
        -Context $Context

    foreach ($k in @('Observed','Applied','Changed','Failed','Skipped')) {
        $Stats[$k] += $r[$k]
    }
}

# ------------------------------------------------------------
# Final observable state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)
$observed = $Stats.Observed
$applied = $Stats.Applied
$changed = $Stats.Changed
$failed = $Stats.Failed
$skipped = $Stats.Skipped
$scope = "firewall_rules"

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$observed applied=$applied changed=$changed failed=$failed skipped=$skipped | scope=$scope",
    "NOTICE",
    $Context
)

if ($Stats.Failed -gt 0) { exit 1 }
exit 0
