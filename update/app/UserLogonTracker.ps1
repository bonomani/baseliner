# UserLogonTracker.ps1
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
    [switch]$Debug,

    [switch]$ResetCurrentUserCount
)

# ------------------------------------------------------------
# Core imports (NO Logger import)
# ------------------------------------------------------------
$lib = Join-Path $PSScriptRoot 'lib'

Import-Module (Join-Path $lib 'GeneralUtil.psm1')            -ErrorAction Stop -Force
Import-Module (Join-Path $lib 'FileUtils.psm1')              -ErrorAction Stop -Force
Import-Module (Join-Path $lib 'LoadScriptConfig.psm1')       -ErrorAction Stop -Force
Import-Module (Join-Path $lib 'FileOperationUtils.psm1')     -ErrorAction Stop -Force
Import-Module (Join-Path $lib 'RegistryOperationUtils.psm1') -ErrorAction Stop -Force

# ------------------------------------------------------------
# Bootstrap (only if Logger/Context not provided)
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

    if (-not $Logger)  { $Logger  = $init.Logger }
    if (-not $Context) { $Context = $init.Context }

    $DataRoot   = $init.DataRoot
    $ConfigPath = $init.ConfigPath
    $ScriptName = $init.ScriptName

$startTime = [datetime]::Now

}

# ------------------------------------------------------------
# Script start (TARGET taken in charge)
# ------------------------------------------------------------
$Logger.WrapLog(
    "Start script '$ScriptName'.",
    "INFO",
    $Context
)

# ------------------------------------------------------------
# Config
# ------------------------------------------------------------
$RequiredFields = @("CsvPath")

try {
    $Config = Get-ScriptConfig `
        -ScriptName     $ScriptName `
        -ConfigPath     $ConfigPath `
        -RequiredFields $RequiredFields `
        -Logger         $Logger
} catch {
    $Logger.WrapLog(
        "Failed to load configuration file",
        "ERROR",
        $Context
    )
    exit 1
}

# ------------------------------------------------------------
# Debug start context
# ------------------------------------------------------------
$Logger.WrapLog(
    "Start ${ScriptName} targets=1 scope=users",
    "DEBUG",
    $Context
)

# ------------------------------------------------------------
# CSV handling
# ------------------------------------------------------------
$LogonCsvPath = if ([IO.Path]::IsPathRooted($Config.CsvPath)) {
    $Config.CsvPath
} else {
    Join-Path $DataRoot $Config.CsvPath
}

New-DirectoryIfMissing -Path (Split-Path $LogonCsvPath) | Out-Null

if (-not (Test-Path $LogonCsvPath)) {
    "Username,LogonCount" | Out-File -FilePath $LogonCsvPath
}

$logonReset       = 0
$logonAdded       = 0
$logonIncremented = 0

function Reset-LogonCount {
    param ([string]$Username)

    $Data = @(Import-Csv $LogonCsvPath)
    $User = $Data | Where-Object { $_.Username -eq $Username }

    if ($User) {
        $User.LogonCount = 0
        $script:logonReset++
    }

    $Data | Export-Csv $LogonCsvPath -NoTypeInformation
}

function Log-UserLogon {
    param ([string]$Username)

    if ($Config.AllowedUsers) {
        $Allowed = $Config.AllowedUsers | Where-Object { $Username -like $_ }
        if (-not $Allowed) {
            $Logger.WrapLog(
                "User '$Username' not in allowed list",
                "DEBUG",
                $Context
            )
        }
    }

    $Data = @(Import-Csv $LogonCsvPath)
    $User = $Data | Where-Object { $_.Username -eq $Username }

    if ($User) {
        $User.LogonCount = [int]$User.LogonCount + 1
        $script:logonIncremented++
    } else {
        $Data += [PSCustomObject]@{
            Username   = $Username
            LogonCount = 1
        }
        $script:logonAdded++
    }

    $Data | Export-Csv $LogonCsvPath -NoTypeInformation
}

# ------------------------------------------------------------
# Execution (TARGET = user)
# ------------------------------------------------------------
$CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

$Logger.WrapLog(
    "Update logon count for user '$CurrentUser'.",
    "INFO",
    $Context
)

if ($ResetCurrentUserCount) {
    Reset-LogonCount -Username $CurrentUser
} else {
    Log-UserLogon -Username $CurrentUser
}

$FinalData  = @(Import-Csv $LogonCsvPath)
$UserFinal  = $FinalData | Where-Object { $_.Username -eq $CurrentUser }
$FinalCount = if ($UserFinal) { $UserFinal.LogonCount } else { 0 }

    if ($logonReset -gt 0) {
        $Logger.WrapLog(
            "User $CurrentUser logon count reset | Reason=policy",
            "NOTICE",
            $Context
        )
}
    elseif ($logonAdded -gt 0) {
        $Logger.WrapLog(
            "User $CurrentUser added with logon count $FinalCount | Reason=policy",
            "NOTICE",
            $Context
        )
}
    else {
        $Logger.WrapLog(
            "User $CurrentUser logon count incremented to $FinalCount | Reason=policy",
            "NOTICE",
            $Context
        )
}

$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)
$observed = 1
$applied  = 1
$changed  = 1
$failed   = 0
$skipped  = 0
$scope = "users"

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$observed applied=$applied changed=$changed failed=$failed skipped=$skipped | scope=$scope",
    "NOTICE",
    $Context
)

exit 0
