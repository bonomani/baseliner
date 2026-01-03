# AdminSetupActiveSetup.ps1
# PowerShell 5.1

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
# Contract counters (single TARGET)
# ------------------------------------------------------------
$Stats = @{
    Observed = 0
    Applied   = 0
    Changed   = 0
    Failed    = 0
    Skipped   = 0
}

$Terminate = $false

# ------------------------------------------------------------
# Administrator requirement
# ------------------------------------------------------------
if (-not (Test-IsAdministrator)) {
    $Stats.Failed = 1
    $Terminate = $true

    $Logger.WrapLog(
        "Script $ScriptName cannot start: administrator privileges required",
        "ERROR",
        $Context
    )
}

# ------------------------------------------------------------
# Script TARGET taken in charge
# ------------------------------------------------------------
if (-not $Terminate) {
    $Logger.WrapLog(
        "Start script '$ScriptName'.",
        "INFO",
        $Context
    )
}

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
if (-not $Terminate) {
    try {
        $config = Get-ScriptConfig `
            -ScriptName     $ScriptName `
            -ConfigPath     $ConfigPath `
            -RequiredFields @("MonitoredFiles") `
            -Logger         $Logger `
            -Context        $Context
    }
    catch {
        $Stats.Failed = 1
        $Terminate = $true

        $Logger.WrapLog(
            "Script $ScriptName failed: configuration loading error",
            "ERROR",
            $Context
        )
    }
}

# ------------------------------------------------------------
# Resolve monitored files (implementation detail)
# ------------------------------------------------------------
$filePaths = @()

if (-not $Terminate) {
    foreach ($rawPath in $config.MonitoredFiles) {

        $Logger.WrapLog(
            "Resolving monitored path template: $rawPath",
            "DEBUG",
            $Context
        )

        $templated = Expand-TemplateValue $rawPath
        $resolved  = Expand-Path -Path $templated

        if (-not $resolved) {
            $Logger.WrapLog(
                "Template resolved to empty path: $rawPath",
                "WARN",
                $Context
            )
            continue
        }

        foreach ($p in $resolved) {
            if (Test-Path $p) {
                $Logger.WrapLog(
                    "Monitored file resolved and exists: '$p'",
                    "DEBUG",
                    $Context
                )
                $filePaths += $p
            }
            else {
                $Logger.WrapLog(
                    "Monitored file resolved but does NOT exist: '$p'",
                    "DEBUG",
                    $Context
                )
                $filePaths += $p
            }
        }
    }
}

# ------------------------------------------------------------
# SKIP: no monitored files resolved at all
# ------------------------------------------------------------
if (-not $Terminate -and $filePaths.Count -eq 0) {
    $Stats.Skipped = 1
    $Terminate = $true

    $Logger.WrapLog(
        "Active Setup component skipped (no monitored files resolved) | Reason=not_applicable",
        "NOTICE",
        $Context
    )
}

# ------------------------------------------------------------
# Active Setup component (TARGET)
# ------------------------------------------------------------
if (-not $Terminate) {

    $Stats.Observed = 1

    $componentId  = "AdminUserSetupFromActiveSetup"
    $registryPath = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$componentId"
    $scriptPath   = Join-Path $PSScriptRoot "$componentId.ps1"

$Logger.WrapLog("Active Setup component ID: $componentId", "DEBUG", $Context)
$Logger.WrapLog("Active Setup registry path: '$registryPath'", "DEBUG", $Context)
$Logger.WrapLog("Active Setup stub script path: '$scriptPath'", "DEBUG", $Context)

    if (-not (Test-Path $scriptPath)) {
        $Stats.Failed = 1
        $Terminate = $true

        $Logger.WrapLog(
            "Active Setup component failed: stub script not found ($scriptPath)",
            "ERROR",
            $Context
        )
    }

    if (-not $Terminate -and -not (Test-Path $registryPath)) {
        try {
            New-Item -Path $registryPath -Force | Out-Null
        }
        catch {
            $Stats.Failed = 1
            $Terminate = $true

            $Logger.WrapLog(
                "Active Setup component failed: unable to create registry key",
                "ERROR",
                $Context
            )
        }
    }
}

# ------------------------------------------------------------
# Modification detection (idempotent)
# ------------------------------------------------------------
$maxLastModified = [DateTime]::MinValue
$lastRecorded    = $null

if (-not $Terminate) {

    foreach ($file in $filePaths) {
        if (Test-Path $file) {
            $modified = (Get-Item $file).LastWriteTime
            if ($modified -gt $maxLastModified) {
                $maxLastModified = $modified
            }
        }
    }

    $lastRecordedRaw = (Get-ItemProperty `
        -Path $registryPath `
        -Name "LastModified" `
        -ErrorAction SilentlyContinue).LastModified

    if ($lastRecordedRaw) {
        $lastRecorded = [datetime]::Parse(
            $lastRecordedRaw,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }
}

# ------------------------------------------------------------
# Apply Active Setup update if needed
# ------------------------------------------------------------
if (-not $Terminate -and (-not $lastRecorded -or $maxLastModified -gt $lastRecorded)) {

    $Stats.Applied = 1
    $Stats.Changed = 1

    $currentVersionRaw = (Get-ItemProperty `
        -Path $registryPath `
        -Name "Version" `
        -ErrorAction SilentlyContinue).Version

    $currentVersion = if ($currentVersionRaw) {
        [version]$currentVersionRaw
    } else {
        [version]"1.0.0"
    }

    $newVersion = [version]::new(
        $currentVersion.Major,
        $currentVersion.Minor,
        $currentVersion.Build + 1
    )

    $properties = @{
        StubPath      = "PowerShell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
        Version       = $newVersion.ToString()
        Locale        = "*"
        IsInstalled   = 1
        DontAsk       = 2
        RequiresAdmin = 1
        LastModified  = $maxLastModified.ToString("o")
    }

    foreach ($key in $properties.Keys) {
        New-ItemProperty `
            -Path $registryPath `
            -Name $key `
            -Value $properties[$key] `
            -Force | Out-Null
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
$scopeParts = @()
if ($filePaths.Count -gt 0) { $scopeParts += "files" }
if (($Stats.Observed + $Stats.Applied + $Stats.Changed + $Stats.Failed + $Stats.Skipped) -gt 0) {
    $scopeParts += "registry"
}
if ($scopeParts.Count -eq 0) { $scopeParts = @("unspecified") }
$scope = $scopeParts -join ","

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$observed applied=$applied changed=$changed failed=$failed skipped=$skipped | scope=$scope",
    "NOTICE",
    $Context
)

if ($Stats.Failed -eq 0) { exit 0 }
exit 1
