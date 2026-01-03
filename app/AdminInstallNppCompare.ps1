# AdminInstallNppCompare.ps1
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


$startTime = [datetime]::Now

# ------------------------------------------------------------
# Administrator requirement
# ------------------------------------------------------------
if (-not (Test-IsAdministrator)) {
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
$Logger.WrapLog(
    "Start script '$ScriptName'.",
    "INFO",
    $Context
)

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
$requiredFields = @("compareUrl")

try {
    $config = Get-ScriptConfig `
        -ScriptName     $ScriptName `
        -ConfigPath     $ConfigPath `
        -RequiredFields $requiredFields `
        -Logger         $Logger `
        -Context        $Context
} catch {
    $Logger.WrapLog(
        "Script $ScriptName failed: configuration loading error",
        "ERROR",
        $Context
    )
    exit 1
}

$compareUrl = $config.compareUrl

# ------------------------------------------------------------
# Locate Notepad++ (precondition)
# ------------------------------------------------------------
$possiblePaths = @(
    "${env:ProgramFiles(x86)}\Notepad++",
    "${env:ProgramFiles}\Notepad++"
)

$installPath = $possiblePaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $installPath) {
    $Logger.WrapLog(
        "Notepad++ not found in Program Files",
        "ERROR",
        $Context
    )
    exit 1
}

# ------------------------------------------------------------
# ComparePlugin (TARGET)
# ------------------------------------------------------------
$pluginDir = Join-Path $installPath "plugins\ComparePlugin"
$pluginDll = Join-Path $pluginDir "ComparePlugin.dll"

$Logger.WrapLog(
    "Install Notepad++ ComparePlugin.",
    "INFO",
    $Context
)

if (Test-Path $pluginDll) {
    $Logger.WrapLog(
        "ComparePlugin already installed | Reason=match",
        "NOTICE",
        $Context
    )

    $duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)
    $Logger.WrapLog(
        "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=1 applied=0 changed=0 failed=0 skipped=0 | scope=packages",
        "NOTICE",
        $Context
    )
    exit 0
}

# ------------------------------------------------------------
# Installation
# ------------------------------------------------------------
if (-not (Test-Path $pluginDir)) {
    New-Item -Path $pluginDir -ItemType Directory | Out-Null
    $Logger.WrapLog(
        "Plugin directory created",
        "DEBUG",
        $Context
    )
}

$tempZip = Join-Path $env:TEMP "ComparePlugin.zip"

try {
    $Logger.WrapLog(
        "Downloading ComparePlugin",
        "DEBUG",
        $Context
    )
    (New-Object System.Net.WebClient).DownloadFile($compareUrl, $tempZip)
} catch {
    $Logger.WrapLog(
        "ComparePlugin download failed",
        "ERROR",
        $Context
    )
    exit 1
}

try {
    $Logger.WrapLog(
        "Extracting ComparePlugin archive",
        "DEBUG",
        $Context
    )
    Expand-Archive -LiteralPath $tempZip -DestinationPath $pluginDir -Force
} catch {
    Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    $Logger.WrapLog(
        "ComparePlugin extraction failed",
        "ERROR",
        $Context
    )
    exit 1
}

Remove-Item $tempZip -Force -ErrorAction SilentlyContinue

$Logger.WrapLog(
    "ComparePlugin installed | Reason=missing",
    "NOTICE",
    $Context
)

# ------------------------------------------------------------
# Script final observable state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=1 applied=1 changed=1 failed=0 skipped=0 | scope=packages",
    "NOTICE",
    $Context
)

exit 0
