# AdminSetLanguage.ps1
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
$ConfigPath = $init.ConfigPath
$ScriptName = $init.ScriptName

$startTime = [datetime]::Now

$Logger.WrapLog("Start script '$ScriptName'.", "INFO", $Context)

# ------------------------------------------------------------
# Contract counters
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
        $Config = Get-ScriptConfig `
            -ScriptName     $ScriptName `
            -ConfigPath     $ConfigPath `
            -RequiredFields @('Language') `
            -Logger         $Logger `
            -Context        $Context

        $Stats.Observed++
        $Logger.WrapLog("Configuration loaded: Language='$($Config.Language)'", "DEBUG", $Context)
    }
    catch {
        $Stats.Observed++
        $Stats.Failed++
        $HasFatalError = $true
        $Logger.WrapLog("Configuration loading failed: $_", "ERROR", $Context)
    }
}

# ------------------------------------------------------------
# Resolve settings
# ------------------------------------------------------------
if (-not $HasFatalError) {
    $Language     = $Config.Language
    $CopyToSystem = if ($null -ne $Config.CopyToSystem) { [bool]$Config.CopyToSystem } else { $true }

    $Logger.WrapLog("Target language: '$Language' | CopyToSystem: $CopyToSystem", "DEBUG", $Context)
}

# ------------------------------------------------------------
# Install language if missing
# ------------------------------------------------------------
if (-not $HasFatalError) {
    $Stats.Observed++

    $installed = Get-WinUserLanguageList | Where-Object { $_.LanguageTag -eq $Language }

    if (-not $installed) {
        $Logger.WrapLog("Language '$Language' not installed, installing", "INFO", $Context)
        try {
            if (-not $WhatIf) {
                Install-Language -Language $Language -ErrorAction Stop
                $Stats.Applied++
                $Stats.Changed++
                $Logger.WrapLog("Language '$Language' installed successfully", "INFO", $Context)
            } else {
                $Logger.WrapLog("WhatIf: would install language '$Language'", "INFO", $Context)
            }
        }
        catch {
            $Stats.Failed++
            $HasFatalError = $true
            $Logger.WrapLog("Failed to install language '$Language': $_", "ERROR", $Context)
        }
    } else {
        $Stats.Skipped++
        $Logger.WrapLog("Language '$Language' already installed", "DEBUG", $Context)
    }
}

# ------------------------------------------------------------
# Set UI language override
# ------------------------------------------------------------
if (-not $HasFatalError) {
    $Stats.Observed++
    $current = (Get-WinUILanguageOverride).LanguageTag

    if ($current -ne $Language) {
        $Logger.WrapLog("Setting UI language override: '$Language' (was '$current')", "INFO", $Context)
        if (-not $WhatIf) {
            Set-WinUILanguageOverride -Language $Language
            $Stats.Applied++
            $Stats.Changed++
        } else {
            $Logger.WrapLog("WhatIf: would set UI language override to '$Language'", "INFO", $Context)
        }
    } else {
        $Stats.Skipped++
        $Logger.WrapLog("UI language override already '$Language'", "DEBUG", $Context)
    }
}

# ------------------------------------------------------------
# Set culture (regional format)
# ------------------------------------------------------------
if (-not $HasFatalError) {
    $Stats.Observed++
    $current = (Get-Culture).Name

    if ($current -ne $Language) {
        $Logger.WrapLog("Setting culture: '$Language' (was '$current')", "INFO", $Context)
        if (-not $WhatIf) {
            Set-Culture -CultureInfo $Language
            $Stats.Applied++
            $Stats.Changed++
        } else {
            $Logger.WrapLog("WhatIf: would set culture to '$Language'", "INFO", $Context)
        }
    } else {
        $Stats.Skipped++
        $Logger.WrapLog("Culture already '$Language'", "DEBUG", $Context)
    }
}

# ------------------------------------------------------------
# Set system locale (non-Unicode programs)
# ------------------------------------------------------------
if (-not $HasFatalError) {
    $Stats.Observed++
    $current = (Get-WinSystemLocale).Name

    if ($current -ne $Language) {
        $Logger.WrapLog("Setting system locale: '$Language' (was '$current')", "INFO", $Context)
        if (-not $WhatIf) {
            Set-WinSystemLocale -SystemLocale $Language
            $Stats.Applied++
            $Stats.Changed++
        } else {
            $Logger.WrapLog("WhatIf: would set system locale to '$Language'", "INFO", $Context)
        }
    } else {
        $Stats.Skipped++
        $Logger.WrapLog("System locale already '$Language'", "DEBUG", $Context)
    }
}

# ------------------------------------------------------------
# Set user language list (keyboard layout)
# ------------------------------------------------------------
if (-not $HasFatalError) {
    $Stats.Observed++
    $primary = (Get-WinUserLanguageList | Select-Object -First 1).LanguageTag

    if ($primary -ne $Language) {
        $Logger.WrapLog("Setting user language list: '$Language' (primary was '$primary')", "INFO", $Context)
        if (-not $WhatIf) {
            Set-WinUserLanguageList -LanguageList $Language -Force
            $Stats.Applied++
            $Stats.Changed++
        } else {
            $Logger.WrapLog("WhatIf: would set user language list to '$Language'", "INFO", $Context)
        }
    } else {
        $Stats.Skipped++
        $Logger.WrapLog("User language list primary already '$Language'", "DEBUG", $Context)
    }
}

# ------------------------------------------------------------
# Copy to welcome screen and new users
# ------------------------------------------------------------
if (-not $HasFatalError -and $CopyToSystem) {
    $Stats.Observed++
    $Logger.WrapLog("Copying international settings to system (WelcomeScreen + NewUser)", "INFO", $Context)
    if (-not $WhatIf) {
        try {
            Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
            $Stats.Applied++
            $Stats.Changed++
        }
        catch {
            $Stats.Failed++
            $Logger.WrapLog("Failed to copy international settings to system: $_", "ERROR", $Context)
        }
    } else {
        $Logger.WrapLog("WhatIf: would copy international settings to WelcomeScreen and NewUser", "INFO", $Context)
    }
}

# ------------------------------------------------------------
# Restart notice
# ------------------------------------------------------------
if (-not $HasFatalError -and $Stats.Changed -gt 0) {
    $Logger.WrapLog("A system restart is required for all language changes to take effect", "WARN", $Context)
}

# ------------------------------------------------------------
# Final observable state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$($Stats.Observed) applied=$($Stats.Applied) changed=$($Stats.Changed) failed=$($Stats.Failed) skipped=$($Stats.Skipped) | scope=locale",
    "NOTICE",
    $Context
)

if ($Stats.Failed -eq 0) { exit 0 }
exit 1
