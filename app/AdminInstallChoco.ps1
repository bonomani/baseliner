# AdminInstallChoco.ps1
param (
    [string]$ConfigPath,

    [ValidateSet("DEBUG","INFO","NOTICE","WARN","ERROR")]
    [string]$LogLevel = "INFO",

    [int]$RetryCount = 1,
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
# Core modules
# ------------------------------------------------------------
$lib = Join-Path $PSScriptRoot 'lib'

Import-Module "$lib\GeneralUtil.psm1" -ErrorAction Stop -Force

# ------------------------------------------------------------
# Bootstrap
# ------------------------------------------------------------
$init = Initialize-Script `
    -ScriptPath   $PSCommandPath `
    -ConfigPath   $ConfigPath `
    -LogLevel     $LogLevel `
    -Verbose:$Verbose `
    -Debug:$Debug `
    -RetryCount   $RetryCount `
    -DelaySeconds $DelaySeconds `
    -ErrorAction  $ErrorAction `
    -WhatIf:$WhatIf `
    -Confirm:$Confirm `
    -Force:$Force

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
$RequiredFields = @("installUrl", "packages")

try {
    $Config = Get-ScriptConfig `
        -ScriptName     $ScriptName `
        -ConfigPath     $ConfigPath `
        -RequiredFields $RequiredFields `
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

$InstallUrl = $Config.installUrl
$Packages   = $Config.packages

$ProxyPresent = $Config.PSObject.Properties.Name -contains 'proxy'
$Proxy        = $Config.proxy

# ------------------------------------------------------------
# Chocolatey (TARGET)
# ------------------------------------------------------------
$Logger.WrapLog("Install package manager 'Chocolatey'.", "INFO", $Context)

$chocoInstalled = $false
$chocoObserved  = 1
$chocoApplied   = 0
$chocoChanged   = 0

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    try {
        if (-not $WhatIf) {
            Set-ExecutionPolicy Bypass -Scope Process -Force
            [System.Net.ServicePointManager]::SecurityProtocol =
                [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
            iex ((New-Object System.Net.WebClient).DownloadString($InstallUrl))
            $env:Path = "$env:ChocolateyInstall\bin;$env:Path"
        }
        $chocoInstalled = $true
        $chocoApplied   = 1
        $chocoChanged   = 1
        $Logger.WrapLog("Package manager 'Chocolatey' installed | Reason=missing", "NOTICE", $Context)
    } catch {
        $Logger.WrapLog("Chocolatey installation failed", "ERROR", $Context)
        exit 1
    }
} else {
    $Logger.WrapLog("Package manager 'Chocolatey' already present | Reason=match", "NOTICE", $Context)
}

# ------------------------------------------------------------
# Proxy (implementation detail)
# ------------------------------------------------------------
if ($ProxyPresent) {
    if ([string]::IsNullOrWhiteSpace($Proxy)) {
        $Logger.WrapLog("Removing Chocolatey proxy configuration", "DEBUG", $Context)
        if (-not $WhatIf) {
            & choco config unset --name proxy --yes --no-progress 2>&1 | Out-Null
        }
    } else {
        $Logger.WrapLog("Configuring Chocolatey proxy", "DEBUG", $Context)
        if (-not $WhatIf) {
            & choco config set --name proxy --value $Proxy 2>&1 | Out-Null
        }
    }
}

# ------------------------------------------------------------
# Packages (TARGET = package)
# ------------------------------------------------------------
$processed = 0
$installed = 0
$unchanged = 0
$failed    = 0

foreach ($Pkg in $Packages) {

    $processed++

    $Logger.WrapLog("Install package '$Pkg'.", "INFO", $Context)

    $IsInstalled = & choco list --local-only --exact $Pkg 2>$null

    if (-not $IsInstalled) {
        try {
            if (-not $WhatIf) {
                & choco install -y $Pkg | Out-Null
            }
            $installed++
            $Logger.WrapLog("Package '$Pkg' installed | Reason=missing", "NOTICE", $Context)
        } catch {
            $failed++
            $Logger.WrapLog("Package '$Pkg' failed to install", "WARN", $Context)
        }
    } else {
        $unchanged++
        $Logger.WrapLog("Package '$Pkg' already installed | Reason=match", "NOTICE", $Context)
    }
}

# ------------------------------------------------------------
# Script final observable state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)
$observed = $processed + $chocoObserved
$applied  = $installed + $failed + $chocoApplied
$changed  = $installed + $chocoChanged
$skipped  = 0
$scope = "packages"

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$observed applied=$applied changed=$changed failed=$failed skipped=$skipped | scope=$scope",
    "NOTICE",
    $Context
)

if ($failed -gt 0) {
    exit 1
}

exit 0
