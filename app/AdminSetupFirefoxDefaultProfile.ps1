# AdminSetupFirefoxDefaultProfile.ps1
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
Import-Module "$lib\FileUtils.psm1"        -ErrorAction Stop -Force
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
$Logger.WrapLog("Bootstrap completed", "DEBUG", $Context)
$Logger.WrapLog("ConfigPath='$ConfigPath'", "DEBUG", $Context)

# ------------------------------------------------------------
# Contract counters
# ------------------------------------------------------------
$Stats = @{
    Observed = 0
    Applied   = 0
    Changed   = 0
    Failed    = 0
    Skipped   = 0
}

$HasFatalError = $false
$SkipRemaining = $false

# ------------------------------------------------------------
# Administrator requirement
# ------------------------------------------------------------
if (-not (Test-IsAdministrator)) {
    $Stats.Failed++
    $HasFatalError = $true
    $Logger.WrapLog("Administrator privileges required", "ERROR", $Context)
}

# ------------------------------------------------------------
# Load configuration
# ------------------------------------------------------------
if (-not $HasFatalError) {
    try {
        $Logger.WrapLog("Loading configuration", "DEBUG", $Context)

        $Config = Get-ScriptConfig `
            -ScriptName     $ScriptName `
            -ConfigPath     $ConfigPath `
            -RequiredFields @('FirefoxDir','AppDataFirefoxDir') `
            -Logger         $Logger `
            -Context        $Context

        $Stats.Observed++
        $Logger.WrapLog("Configuration loaded successfully", "DEBUG", $Context)
    }
    catch {
        $Stats.Observed++
        $Stats.Failed++
        $HasFatalError = $true
        $Logger.WrapLog("Configuration loading failed", "ERROR", $Context)
        $Logger.WrapLog("Configuration error detail: $_", "DEBUG", $Context)
    }
}

# ------------------------------------------------------------
# Resolve paths
# ------------------------------------------------------------
if (-not $HasFatalError) {
    $FirefoxExePath    = Join-Path $Config.FirefoxDir 'firefox.exe'
    $AppDataFirefoxDir = Expand-Path -Path $Config.AppDataFirefoxDir
    $FirefoxProfileDir = Join-Path $Config.FirefoxDir 'defaults\profile'
    $ProfileIniPath    = Join-Path $AppDataFirefoxDir 'profiles.ini'

    $Stats.Observed++

    $Logger.WrapLog("FirefoxExePath='$FirefoxExePath'", "DEBUG", $Context)
    $Logger.WrapLog("ProfileIniPath='$ProfileIniPath'", "DEBUG", $Context)
}

# ------------------------------------------------------------
# Idempotency guard
# ------------------------------------------------------------
if (-not $HasFatalError -and (Test-Path $ProfileIniPath)) {
    $Logger.WrapLog(
        "Idempotency guard triggered: profiles.ini exists | Reason=match",
        "NOTICE",
        $Context
    )

    $Stats.Skipped = 1
    $SkipRemaining = $true
}


# ------------------------------------------------------------
# Ensure Firefox closed
# ------------------------------------------------------------
function Ensure-FirefoxClosed {
    for ($i = 0; $i -lt 5; $i++) {
        if (-not (Get-Process firefox -ErrorAction SilentlyContinue)) {
            return $true
        }

        $Logger.WrapLog(
            "Firefox still running, attempt $($i + 1)/5",
            "DEBUG",
            $Context
        )

        try {
            Stop-Process -Name firefox -Force -ErrorAction Stop
            Start-Sleep -Seconds 3
        } catch {
            return $false
        }
    }
    return $false
}

if (-not $HasFatalError -and -not $SkipRemaining) {
    $Stats.Observed++
    if (-not (Ensure-FirefoxClosed)) {
        $Stats.Failed++
        $HasFatalError = $true
        $Logger.WrapLog("Unable to stop Firefox", "ERROR", $Context)
    }
}

# ------------------------------------------------------------
# Start Firefox headless
# ------------------------------------------------------------
if (-not $HasFatalError -and -not $SkipRemaining) {
    try {
        $Stats.Applied++
        $Logger.WrapLog("Starting Firefox headless", "DEBUG", $Context)
        Start-Process -FilePath $FirefoxExePath -ArgumentList '-headless' | Out-Null
    }
    catch {
        $Stats.Failed++
        $HasFatalError = $true
        $Logger.WrapLog("Failed to start Firefox", "ERROR", $Context)
    }
}

# ------------------------------------------------------------
# Wait for profiles.ini
# ------------------------------------------------------------
if (-not $HasFatalError -and -not $SkipRemaining) {
    $Stats.Observed++
    $Logger.WrapLog("Waiting for profiles.ini creation (max 20s)", "DEBUG", $Context)

    for ($i = 0; $i -lt 20; $i++) {
        if (Test-Path $ProfileIniPath) { break }
        Start-Sleep -Seconds 1
    }

    if (-not (Test-Path $ProfileIniPath)) {
        $Stats.Failed++
        $HasFatalError = $true
        $Logger.WrapLog("profiles.ini not created", "ERROR", $Context)
    }
}

if (-not $HasFatalError -and -not $SkipRemaining) {
    Ensure-FirefoxClosed | Out-Null
}

# ------------------------------------------------------------
# Detect default profile
# ------------------------------------------------------------
function Get-DefaultProfilePath {
    param ($IniPath)

    $locked = $false
    foreach ($line in Get-Content $IniPath) {
        if ($line -match '^\[') { $locked = $false }
        elseif ($line -eq 'Locked=1') { $locked = $true }
        elseif ($locked -and $line -like 'Default=*') {
            return $line.Split('=')[1]
        }
    }
    return $null
}

if (-not $HasFatalError -and -not $SkipRemaining) {
    $Stats.Observed++
    $RelProfile = Get-DefaultProfilePath -IniPath $ProfileIniPath

    if (-not $RelProfile) {
        $Stats.Failed++
        $HasFatalError = $true
        $Logger.WrapLog("Default profile not found", "ERROR", $Context)
    }
    else {
        $NewProfilePath = Join-Path $AppDataFirefoxDir $RelProfile
        $Logger.WrapLog("Default profile resolved to $NewProfilePath", "DEBUG", $Context)
    }
}

# ------------------------------------------------------------
# Deploy user.js
# ------------------------------------------------------------
if (-not $HasFatalError -and -not $SkipRemaining) {
    $SourceUserJS = Join-Path $FirefoxProfileDir 'user.js'
    $TargetUserJS = Join-Path $NewProfilePath 'user.js'

    $Stats.Observed++

    if (Test-Path $SourceUserJS) {
        $Stats.Applied++
        Copy-Item $SourceUserJS $TargetUserJS -Force
        $Stats.Changed++
    }
    else {
        $Stats.Skipped++
    }
}

# ------------------------------------------------------------
# Deploy extensions
# ------------------------------------------------------------
if (-not $HasFatalError -and -not $SkipRemaining) {
    $SourceExt = Join-Path $FirefoxProfileDir 'extensions'
    $TargetExt = Join-Path $NewProfilePath 'extensions'

    $Stats.Observed++

    if (Test-Path $SourceExt) {
        $Stats.Applied++
        New-DirectoryIfMissing -Path $TargetExt
        Get-ChildItem $SourceExt -Filter *.xpi | ForEach-Object {
            Copy-Item $_.FullName $TargetExt -Force
        }
        $Stats.Changed++
    }
    else {
        $Stats.Skipped++
    }
}

# ------------------------------------------------------------
# Final observable state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)
$scope = "files"

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$($Stats.Observed) applied=$($Stats.Applied) changed=$($Stats.Changed) failed=$($Stats.Failed) skipped=$($Stats.Skipped) | scope=$scope",
    "NOTICE",
    $Context
)

if ($Stats.Failed -eq 0) { exit 0 }
exit 1
