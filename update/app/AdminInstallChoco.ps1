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

Import-Module "$lib\GeneralUtil.psm1"   -ErrorAction Stop -Force
Import-Module "$lib\LoadScriptConfig.psm1" -ErrorAction Stop -Force
Import-Module "$lib\PhaseAlias.psm1"    -ErrorAction Stop -Force

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
$Logger.WrapLog("Start script '$ScriptName'.", "INFO", $Context)

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
$RequiredFields = @("packageBatchOperations")

try {
    $Config = Get-ScriptConfig `
        -ScriptName     $ScriptName `
        -ConfigPath     $ConfigPath `
        -RequiredFields $RequiredFields `
        -Logger         $Logger `
        -Context        $Context
} catch {
    $Logger.WrapLog(
        ("Script {0} failed: configuration loading error | Detail={1}" -f $ScriptName, $_.Exception.Message),
        "ERROR",
        $Context
    )
    exit 1
}

$BatchOps = $Config.packageBatchOperations

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------
function Get-ChocoInstalledVersion {
    param ([string]$Name)
    $line = & choco list --local-only --exact $Name --limit-output 2>$null
    if ($line -match ("^" + [regex]::Escape($Name) + "\|(.+)$")) { return $Matches[1] }
    return $null
}

function Get-ChocoPinned {
    param ([string]$Name)
    $lines = & choco pin list --limit-output 2>$null
    return [bool]($lines -match ("^" + [regex]::Escape($Name) + "\|"))
}

function Invoke-UninstallChocoPackage {
    param (
        [string]   $PkgName,
        [object]   $Logger,
        [hashtable]$Context
    )

    $Logger.WrapLog("Uninstall package '$PkgName'.", "INFO", $Context)

    $currentVersion = Get-ChocoInstalledVersion -Name $PkgName
    $targetId = if ($currentVersion) { "'$PkgName' ($currentVersion)" } else { "'$PkgName'" }

    $result = Invoke-CheckDoReportPhase `
        -Action          "Uninstall package '$PkgName'" `
        -PreVerifyBlock  { return @{ Success = ($null -eq $currentVersion); Hint = if ($null -eq $currentVersion) { "absent.package" } else { "present.package" } } } `
        -DoBlock         {
            & choco uninstall -y $PkgName | Out-Null
            return @{ Success = $true }
        } `
        -VerifyBlock     {
            $v = Get-ChocoInstalledVersion -Name $PkgName
            return @{ Success = ($null -eq $v); Hint = if ($null -eq $v) { "absent.package" } else { "present.package" } }
        } `
        -Logger          $Logger `
        -PreVerifyContext $Context `
        -DoContext        $Context `
        -VerifyContext    $Context

    $Logger.WriteTargetNotice("Package", $targetId, $result, $Context, "uninstall")
    return $result
}

function Invoke-InstallChocoPackage {
    param (
        [string]   $PkgName,
        [object]   $Logger,
        [hashtable]$Context
    )

    $Logger.WrapLog("Install package '$PkgName'.", "INFO", $Context)

    $currentVersion = Get-ChocoInstalledVersion -Name $PkgName
    $targetId = if ($currentVersion) { "'$PkgName' ($currentVersion)" } else { "'$PkgName'" }

    $result = Invoke-CheckDoReportPhase `
        -Action          "Install package '$PkgName'" `
        -PreVerifyBlock  { return @{ Success = ($null -ne $currentVersion); Hint = if ($currentVersion) { "present.package" } else { "absent.package" } } } `
        -DoBlock         {
            & choco install -y $PkgName | Out-Null
            return @{ Success = $true }
        } `
        -VerifyBlock     {
            $v = Get-ChocoInstalledVersion -Name $PkgName
            return @{ Success = ($null -ne $v); Hint = if ($v) { "present.package" } else { "absent.package" } }
        } `
        -Logger          $Logger `
        -PreVerifyContext $Context `
        -DoContext        $Context `
        -VerifyContext    $Context

    $Logger.WriteTargetNotice("Package", $targetId, $result, $Context, "install")
    return $result
}

function Invoke-PinChocoPackage {
    param (
        [string]   $PkgName,
        [bool]     $DesiredPin,
        [object]   $Logger,
        [hashtable]$Context
    )

    $action = if ($DesiredPin) { "pin" } else { "unpin" }
    $Logger.WrapLog("$([char]::ToUpper($action[0]) + $action.Substring(1)) package '$PkgName'.", "INFO", $Context)

    $currentPin = Get-ChocoPinned -Name $PkgName

    $result = Invoke-CheckDoReportPhase `
        -Action          "$action package '$PkgName'" `
        -PreVerifyBlock  { return @{ Success = ($currentPin -eq $DesiredPin); Hint = if ($currentPin -eq $DesiredPin) { "pin.match" } else { "pin.mismatch" } } } `
        -DoBlock         {
            if ($DesiredPin) { & choco pin add    -n $PkgName | Out-Null }
            else             { & choco pin remove -n $PkgName | Out-Null }
            return @{ Success = $true }
        } `
        -VerifyBlock     {
            $isPinned = Get-ChocoPinned -Name $PkgName
            return @{ Success = ($isPinned -eq $DesiredPin); Hint = if ($isPinned -eq $DesiredPin) { "pin.match" } else { "pin.mismatch" } }
        } `
        -Logger          $Logger `
        -PreVerifyContext $Context `
        -DoContext        $Context `
        -VerifyContext    $Context

    $Logger.WriteTargetNotice("Package pin", "'$PkgName'", $result, $Context, $action)
    return $result
}

# ------------------------------------------------------------
# Batch operations
# ------------------------------------------------------------
$stats = @{ Observed = 0; Applied = 0; Changed = 0; Failed = 0; Skipped = 0 }

foreach ($BatchOp in $BatchOps) {

    if ($BatchOp.operation -notin @("install-package", "uninstall-package")) {
        $Logger.WrapLog("Unknown operation '$($BatchOp.operation)' | Reason=invalid_definition", "WARN", $Context)
        $stats.Skipped++
        continue
    }

    $Items = $BatchOp.items

    # ----------------------------------------------------------
    # Chocolatey (TARGET) — only for install-package
    # ----------------------------------------------------------
    if ($BatchOp.operation -eq "install-package") {
        $batchContext = $BatchOp.context
        $InstallUrl   = if ($batchContext) { $batchContext.installUrl } else { $null }
        $Proxy        = if ($batchContext) { $batchContext.proxy }      else { $null }
        $ProxyPresent = $batchContext -and ($batchContext.PSObject.Properties.Name -contains 'proxy')

        $Logger.WrapLog("Install package manager 'Chocolatey'.", "INFO", $Context)

        $chocoResult = Invoke-CheckDoReportPhase `
            -Action          "Install Chocolatey" `
            -PreVerifyBlock  { return @{ Success = [bool](Get-Command choco -ErrorAction SilentlyContinue); Hint = "present.choco" } } `
            -DoBlock         {
                Set-ExecutionPolicy Bypass -Scope Process -Force
                [System.Net.ServicePointManager]::SecurityProtocol =
                    [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
                Invoke-Expression ((New-Object System.Net.WebClient).DownloadString($InstallUrl))
                $env:Path = "$env:ChocolateyInstall\bin;$env:Path"
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                            [System.Environment]::GetEnvironmentVariable("Path","User")
                return @{ Success = $true }
            } `
            -VerifyBlock     { return @{ Success = [bool](Get-Command choco -ErrorAction SilentlyContinue) } } `
            -Logger          $Logger `
            -PreVerifyContext $Context `
            -DoContext        $Context `
            -VerifyContext    $Context

        $Logger.WriteTargetNotice("Package manager", "'Chocolatey'", $chocoResult, $Context, "install")
        foreach ($k in @('Observed','Applied','Changed','Failed','Skipped')) { $stats[$k] += $chocoResult[$k] }

        if ($chocoResult.Failed -eq 1) {
            $Logger.WrapLog("Cannot continue: Chocolatey installation failed", "ERROR", $Context)
            exit 1
        }

        if ($ProxyPresent) {
            if ([string]::IsNullOrWhiteSpace($Proxy)) {
                $Logger.WrapLog("Removing Chocolatey proxy configuration", "DEBUG", $Context)
                if (-not $Context.WhatIf) { & choco config unset --name proxy --yes --no-progress 2>&1 | Out-Null }
            } else {
                $Logger.WrapLog("Configuring Chocolatey proxy", "DEBUG", $Context)
                if (-not $Context.WhatIf) { & choco config set --name proxy --value $Proxy 2>&1 | Out-Null }
            }
        }
    }

    # ----------------------------------------------------------
    # Packages (TARGET = package + optional pin)
    # ----------------------------------------------------------
    foreach ($Item in $Items) {

        $PkgName = [string]$Item.name

        if ($BatchOp.operation -eq "uninstall-package") {
            $r = Invoke-UninstallChocoPackage -PkgName $PkgName -Logger $Logger -Context $Context
            foreach ($k in @('Observed','Applied','Changed','Failed','Skipped')) { $stats[$k] += $r[$k] }
            continue
        }

        $PkgPin = if ($Item.PSObject.Properties.Name -contains 'pin') { [bool]$Item.pin } else { $null }

        $r = Invoke-InstallChocoPackage -PkgName $PkgName -Logger $Logger -Context $Context
        foreach ($k in @('Observed','Applied','Changed','Failed','Skipped')) { $stats[$k] += $r[$k] }

        if ($null -ne $PkgPin) {
            $rPin = Invoke-PinChocoPackage -PkgName $PkgName -DesiredPin $PkgPin -Logger $Logger -Context $Context
            foreach ($k in @('Observed','Applied','Changed','Failed','Skipped')) { $stats[$k] += $rPin[$k] }
        }
    }
}

# ------------------------------------------------------------
# Script final observable state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | " +
    "observed=$($stats.Observed) applied=$($stats.Applied) changed=$($stats.Changed) " +
    "failed=$($stats.Failed) skipped=$($stats.Skipped) | scope=packages",
    "NOTICE",
    $Context
)

if ($stats.Failed -gt 0) { exit 1 }

exit 0
