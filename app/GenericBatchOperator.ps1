# GenericBatchOperator.ps1
# Compatible PowerShell 5.1
# Reusable batch orchestrator for file/registry operations

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
# Core imports
# ------------------------------------------------------------
$lib = Join-Path $PSScriptRoot 'lib'

Import-Module "$lib\GeneralUtil.psm1"            -ErrorAction Stop -Force
Import-Module "$lib\LoadScriptConfig.psm1"       -ErrorAction Stop -Force
Import-Module "$lib\FileOperationUtils.psm1"     -ErrorAction Stop -Force
Import-Module "$lib\RegistryOperationUtils.psm1" -ErrorAction Stop -Force

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
$RequiredFields = if ($RequiredFields) { $RequiredFields } else { @() }

try {
    $Config = Get-ScriptConfig `
        -ScriptName     $ConfigSection `
        -ConfigPath     $ConfigPath `
        -RequiredFields $RequiredFields `
        -Logger         $Logger `
        -Context        $Context
}
catch {
    $Logger.WrapLog(
        "Configuration loading failed",
        "ERROR",
        $Context
    )
    exit 1
}

# ------------------------------------------------------------
# Optional admin requirement
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
# Counters (normalized contract – per domain)
# ------------------------------------------------------------
$FileStats = @{
    Observed = 0
    Applied   = 0
    Changed   = 0
    Failed    = 0
    Skipped   = 0
}

$RegistryStats = @{
    Observed = 0
    Applied   = 0
    Changed   = 0
    Failed    = 0
    Skipped   = 0
}

# ------------------------------------------------------------
# File batch operations
# ------------------------------------------------------------
if ($Config.fileBatchOperations) {
    foreach ($Op in $Config.fileBatchOperations) {

        $Result = Invoke-FileBatchOperation `
            -Operation $Op.operation `
            -Entry     $Op `
            -Logger    $Logger `
            -Context   $Context

        foreach ($k in @('Observed','Applied','Changed','Failed','Skipped')) {
            if ($Result.ContainsKey($k)) {
                $FileStats[$k] += $Result[$k]
            }
        }
    }
}

# ------------------------------------------------------------
# Registry batch operations
# ------------------------------------------------------------
if ($Config.registryBatchOperations) {
    foreach ($Op in $Config.registryBatchOperations) {

        $Result = Invoke-RegistryBatchOperation `
            -Operation $Op.operation `
            -Entry     $Op `
            -Logger    $Logger `
            -Context   $Context

        foreach ($k in @('Observed','Applied','Changed','Failed','Skipped')) {
            if ($Result.ContainsKey($k)) {
                $RegistryStats[$k] += $Result[$k]
            }
        }
    }
}

# ------------------------------------------------------------
# Final observable state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)
$observed = $FileStats.Observed + $RegistryStats.Observed
$applied = $FileStats.Applied + $RegistryStats.Applied
$changed = $FileStats.Changed + $RegistryStats.Changed
$failed = $FileStats.Failed + $RegistryStats.Failed
$skipped = $FileStats.Skipped + $RegistryStats.Skipped
$fileSum = ($FileStats.Values | Measure-Object -Sum).Sum
$regSum = ($RegistryStats.Values | Measure-Object -Sum).Sum
$scopeParts = @()
if ($fileSum -gt 0) { $scopeParts += "files" }
if ($regSum -gt 0) { $scopeParts += "registry" }
if ($scopeParts.Count -eq 0) { $scopeParts = @("unspecified") }
$scope = $scopeParts -join ","

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$observed applied=$applied changed=$changed failed=$failed skipped=$skipped | scope=$scope",
    "NOTICE",
    $Context
)

if ($FileStats.Failed -eq 0 -and $RegistryStats.Failed -eq 0) {
    exit 0
}

exit 1
