# AdminSetupFirefoxDefaultConfig.ps1
# Compatible PowerShell 5.1

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
$ScriptName = $init.ScriptName

$startTime = [datetime]::Now

$ConfigPath = $init.ConfigPath

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

# ------------------------------------------------------------
# Script start
# ------------------------------------------------------------
$Logger.WrapLog("Invoke script $ScriptName.", "INFO", $Context)

# ------------------------------------------------------------
# Load configuration
# ------------------------------------------------------------
try {
    $Config = Get-ScriptConfig `
        -ScriptName     $ScriptName `
        -ConfigPath     $ConfigPath `
        -RequiredFields @("FirefoxProfileDir","Extensions","UserJSContent") `
        -Logger         $Logger `
        -Context        $Context

    $Stats.Observed++

    $Logger.WrapLog(
        "Config loaded: FirefoxProfileDir='$($Config.FirefoxProfileDir)'",
        "DEBUG",
        $Context
    )
}
catch {
    $Stats.Observed++
    $Stats.Failed++
    $HasFatalError = $true

    $Logger.WrapLog("Configuration loading failed", "ERROR", $Context)
}

# ------------------------------------------------------------
# Resolve paths
# ------------------------------------------------------------
if (-not $HasFatalError) {

    $FirefoxProfileDir = Expand-Path $Config.FirefoxProfileDir
    $ExtensionDir      = Join-Path $FirefoxProfileDir "extensions"
    $UserJSPath        = Join-Path $FirefoxProfileDir "user.js"

    $Stats.Observed++

$Logger.WrapLog("Resolved FirefoxProfileDir = '$FirefoxProfileDir'", "DEBUG", $Context)
$Logger.WrapLog("Resolved ExtensionDir      = '$ExtensionDir'",      "DEBUG", $Context)
$Logger.WrapLog("Resolved UserJSPath        = '$UserJSPath'",         "DEBUG", $Context)
}

# ------------------------------------------------------------
# Ensure profile directory exists & writable
# ------------------------------------------------------------
if (-not $HasFatalError) {

    if (-not (Test-Path $FirefoxProfileDir)) {
        $Logger.WrapLog(
            "Profile directory does not exist and will be created",
            "DEBUG",
            $Context
        )

        $Stats.Applied++
        if (-not $WhatIf) {
            New-Item -ItemType Directory -Path $FirefoxProfileDir -Force | Out-Null
        }
        $Stats.Changed++
    }
    else {
        $Logger.WrapLog(
            "Profile directory already exists (noop)",
            "DEBUG",
            $Context
        )
    }

    $testFile = Join-Path $FirefoxProfileDir "_write_test.tmp"

    try {
        if (-not $WhatIf) {
            Set-Content -Path $testFile -Value "test" -Force
            Remove-Item -Path $testFile -Force
        }
        $Stats.Observed++

        $Logger.WrapLog(
            "Profile directory is writable",
            "DEBUG",
            $Context
        )
    }
    catch {
        $Stats.Failed++
        $HasFatalError = $true

        $Logger.WrapLog(
            "Profile directory not writable",
            "ERROR",
            $Context
        )
    }
}

# ------------------------------------------------------------
# TARGET: user.js
# ------------------------------------------------------------
if (-not $HasFatalError) {

    $UserJSGroups = $Config.UserJSContent
    $desiredUserJS = @()

    foreach ($GroupName in ($UserJSGroups.PSObject.Properties.Name | Sort-Object)) {
        $Group = $UserJSGroups.$GroupName
        $desiredUserJS += "// $($Group.Description)"

        foreach ($Pref in $Group.UserPref) {
            if ($Pref.Value -is [string]) {
                $v = "'$($Pref.Value)'"
            } elseif ($Pref.Value -is [bool]) {
                $v = $Pref.Value.ToString().ToLower()
            } else {
                $v = $Pref.Value
            }
            $desiredUserJS += "user_pref('$($Pref.Name)', $v);"
        }
        $desiredUserJS += ""
    }

    $desiredUserJSContent = ($desiredUserJS -join "`n").Trim()
    $currentUserJSContent = if (Test-Path $UserJSPath) {
        (Get-Content $UserJSPath -Raw).Trim()
    }

    $Stats.Observed++

    $Logger.WrapLog(
        "user.js exists: $(Test-Path $UserJSPath)",
        "DEBUG",
        $Context
    )
    $Logger.WrapLog(
        "user.js desired length = $($desiredUserJSContent.Length)",
        "DEBUG",
        $Context
    )
    $Logger.WrapLog(
        "user.js current length = $($currentUserJSContent.Length)",
        "DEBUG",
        $Context
    )

    if ($desiredUserJSContent -ne $currentUserJSContent) {

        $Logger.WrapLog(
            "user.js content differs -> update required",
            "DEBUG",
            $Context
        )

        $Stats.Applied++
        if (-not $WhatIf) {
            Set-Content -Path $UserJSPath -Value $desiredUserJSContent -Force
        }
        $Stats.Changed++
    }
    else {
        $Logger.WrapLog(
            "user.js already compliant (noop)",
            "DEBUG",
            $Context
        )
    }
}

# ------------------------------------------------------------
# TARGET: extensions
# ------------------------------------------------------------
if (-not $HasFatalError) {

    if (-not (Test-Path $ExtensionDir)) {

        $Logger.WrapLog(
            "Extensions directory does not exist and will be created",
            "DEBUG",
            $Context
        )

        $Stats.Applied++
        if (-not $WhatIf) {
            New-Item -ItemType Directory -Path $ExtensionDir -Force | Out-Null
        }
        $Stats.Changed++
    }
    else {
        $Logger.WrapLog(
            "Extensions directory already exists (noop)",
            "DEBUG",
            $Context
        )
    }

    $desiredExtensions = $Config.Extensions.PSObject.Properties.Name |
        ForEach-Object { "$_.xpi" }

    $currentExtensions = if (Test-Path $ExtensionDir) {
        Get-ChildItem $ExtensionDir -Filter "*.xpi" -File |
            Select-Object -ExpandProperty Name
    } else {
        @()
    }

    $Stats.Observed++

    $Logger.WrapLog(
        "Desired extensions: $($desiredExtensions -join ', ')",
        "DEBUG",
        $Context
    )
    $Logger.WrapLog(
        "Current extensions: $($currentExtensions -join ', ')",
        "DEBUG",
        $Context
    )

    foreach ($file in $currentExtensions) {
        if ($file -notin $desiredExtensions) {

            $Logger.WrapLog(
                "Removing obsolete extension $file",
                "DEBUG",
                $Context
            )

            $Stats.Applied++
            if (-not $WhatIf) {
                Remove-Item (Join-Path $ExtensionDir $file) -Force
            }
            $Stats.Changed++
        }
    }

    foreach ($ExtensionId in $Config.Extensions.PSObject.Properties.Name) {

        $XpiPath = Join-Path $ExtensionDir "$ExtensionId.xpi"

        if (-not (Test-Path $XpiPath)) {

            $Logger.WrapLog(
                "Extension $ExtensionId missing -> download required",
                "DEBUG",
                $Context
            )

            $Stats.Applied++
            if (-not $WhatIf) {
                try {
                    Invoke-WebRequest `
                        -Uri $Config.Extensions.$ExtensionId `
                        -OutFile $XpiPath `
                        -TimeoutSec 30 `
                        -UseBasicParsing `
                        -ErrorAction Stop
                }
                catch {
                    $Stats.Failed++
                    $HasFatalError = $true

                    $Logger.WrapLog(
                        "Failed to download extension $ExtensionId",
                        "ERROR",
                        $Context
                    )
                    break
                }
            }
            $Stats.Changed++
        }
        else {
            $Logger.WrapLog(
                "Extension $ExtensionId already present (noop)",
                "DEBUG",
                $Context
            )
        }
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
$scope = "files"

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$observed applied=$applied changed=$changed failed=$failed skipped=$skipped | scope=$scope",
    "NOTICE",
    $Context
)

if ($Stats.Failed -eq 0) {
    exit 0
}

exit 1
