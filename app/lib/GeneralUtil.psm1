Import-Module "$PSScriptRoot\Logger.psm1" -ErrorAction Stop

function Get-CurrentTimestamp {
    return (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

function Convert-SizeToBytes {
    param([string]$Size)
    if ($Size -match '^(\d+)([KMG]B?)$') {
        $num = [int]$matches[1]
        switch ($matches[2].ToUpper()) {
            'KB' { return $num * 1KB }
            'K'  { return $num * 1KB }
            'MB' { return $num * 1MB }
            'M'  { return $num * 1MB }
            'GB' { return $num * 1GB }
            'G'  { return $num * 1GB }
        }
    }
    throw "Invalid size format: $Size"
}

function Format-Bytes {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB)   { "{0:N2} GB" -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { "{0:N2} MB" -f ($Bytes / 1MB) }
    elseif ($Bytes -ge 1KB) { "{0:N2} KB" -f ($Bytes / 1KB) }
    else                   { "$Bytes bytes" }
}

function New-Guid {
    return [guid]::NewGuid().ToString()
}

function Invoke-SafeAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0)]
        [scriptblock]$Action,
        [Parameter(Mandatory, Position=1)]
        [string]     $ActionName,
        [scriptblock]$Confirmation,
        [string]     $ConfirmationName = 'Confirmation',
        [object]     $Logger,
        [ValidateSet('Ignore','Warn','Error')][string]$OnFailure = 'Warn',
        [switch]     $DryRun,
        [int]        $MaxRetries    = 1,
        [int]        $DelaySeconds  = 1,
        [hashtable]  $Context       = @{}
    )

    $minLevel = if ($Context.Debug) { "DEBUG" } elseif ($Context.Verbose) { "INFO" } else { "NOTICE" }
    if ($Logger -and -not $Logger.MinLevel) {
        $Logger = New-Logger -LogFilePath $Logger.Path -Console:$Logger.Console -MinLevel $minLevel
    }

    $flags = "DryRun=$DryRun;Retries=$MaxRetries;Delay=${DelaySeconds}s;OnFailure=$OnFailure"
    if ($Context.Debug -and $Logger) {
        $Logger.WrapLog("Context: $flags", 'DEBUG', $Context)
    }

    if ($DryRun) {
        if ($Logger) { $Logger.WrapLog("$ActionName skipped (DryRun)", 'INFO', $Context) }
        return $true
    }

    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            if ($Context.Verbose -and $Logger) {
                $Logger.WrapLog("Attempt $i for: $ActionName", 'DEBUG', $Context)
            }

            $result = & $Action 

            if ($Confirmation) {
                try {
                    $ok = & $Confirmation
                    if (-not $ok) { throw }
                    if ($Context.Debug -and $Logger) {
                        $Logger.WrapLog("$ConfirmationName succeeded", 'DEBUG', $Context)
                    }
                } catch {
                    throw "Confirmation failed: $ConfirmationName - $($_.Exception.Message)"
                }
            }

            if ($Logger) { $Logger.WrapLog("$ActionName succeeded", 'INFO', $Context) }
            return $result
        }
        catch {
            if ($Logger) { $Logger.WrapLog("Attempt $i failed: $($_.Exception.Message)", 'WARN', $Context) }
            if ($i -lt $MaxRetries) {
                Start-Sleep -Seconds $DelaySeconds
                continue
            }
            switch ($OnFailure) {
                'Ignore' { return $false }
                'Warn' {
                    if ($Logger) { $Logger.WrapLog("$ActionName failed after $MaxRetries attempt(s)", 'ERROR', $Context) }
                    return $false
                }
                'Error' {
                    if ($Logger) { $Logger.WrapLog("$ActionName failed after $MaxRetries attempt(s)", 'ERROR', $Context) }
                    throw
                }
            }
        }
    }
}

function Close-ComObject {
    param(
        [Parameter(Mandatory)]
        [System.__ComObject] $Object
    )
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($Object)
}

function Get-DefaultFlags {
    param ()
    return @{
        WhatIf       = $false
        Confirm      = $false
        Force        = $false
        RetryCount   = 1
        DelaySeconds = 0
        ErrorAction  = 'Continue'
        Verbose      = $false
        Debug        = $false
    }
}

function Invoke-MergeFlags {
    param (
        [hashtable]$Context = @{},
        [switch] $WhatIf,
        [switch] $Confirm,
        [switch] $Force,
        [int]    $RetryCount   = 1,
        [int]    $DelaySeconds = 0,
        [ValidateSet('Continue','Stop','SilentlyContinue','Inquire')] [string]$ErrorAction  = 'Continue',
        [switch] $Verbose,
        [switch] $Debug
    )

    $merged = @{
        WhatIf       = if ($WhatIf) { $WhatIf } else { $Context.WhatIf }
        Confirm      = if ($Confirm) { $Confirm } else { $Context.Confirm }
        Force        = if ($Force) { $Force } else { $Context.Force }
        RetryCount   = if ($RetryCount) { $RetryCount } else { $Context.RetryCount }
        DelaySeconds = if ($DelaySeconds) { $DelaySeconds } else { $Context.DelaySeconds }
        ErrorAction  = if ($ErrorAction) { $ErrorAction } else { $Context.ErrorAction }
        Verbose      = if ($Verbose) { $Verbose } else { $Context.Verbose }
        Debug        = if ($Debug) { $Debug } else { $Context.Debug }
    }

    return $merged
}

# Checks whether the current session is elevated.
function Test-IsAdministrator {
    [CmdletBinding()]
    param ()

    try {
        $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-TopScriptRoot {
    $topScript = (Get-PSCallStack | Where-Object ScriptName | Select-Object -Last 1).ScriptName
    return Split-Path -Parent $topScript
}

function Resolve-Item {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]   $Context,
        [Parameter(Mandatory)] [object]   $Item,
        [string[]]                         $ItemContextPairs,
        [string]                           $ErrorCode = "missing_path"
    )

    if (-not ($Context -is [hashtable])) {
        $ctxTable = @{}
        if ($Context) {
            foreach ($prop in $Context.PSObject.Properties) {
                $ctxTable[$prop.Name] = $prop.Value
            }
        }
        $Context = $ctxTable
    }

    if (-not ($Item -is [hashtable])) {
        $itemTable = @{}
        if ($Item) {
            foreach ($prop in $Item.PSObject.Properties) {
                $itemTable[$prop.Name] = $prop.Value
            }
        }
        $Item = $itemTable
    }

    if (-not $ItemContextPairs) {
        return @{ Error = $ErrorCode }
    }

    $resolved = @{}

    foreach ($key in $ItemContextPairs) {
        if ($Item[$key]) {
            $resolved[$key] = $Item[$key]
            continue
        }
        if ($Context[$key]) {
            $resolved[$key] = $Context[$key]
        }
    }

    if ($resolved.Count -eq 0) {
        return @{ Error = $ErrorCode }
    }

    return $resolved
}

function Expand-TemplateValue {
    param (
        [string]$Template,
        [int]   $MaxDepth = 5
    )

    if (-not $Template) { return $Template }

    $pattern = '{{([^{}]+?)}}'
    $depth   = 0

    while ($Template -match $pattern -and $depth -lt $MaxDepth) {
        $Template = [Regex]::Replace($Template, $pattern, {
            param($match)
            $token = $match.Groups[1].Value.Trim()

            switch -Regex ($token) {
                '^env:(.+)$'   { return $env[$matches[1]] }
                '^ps:(.+)$'    { return Get-Variable -Name $matches[1] -ValueOnly -ErrorAction SilentlyContinue }
                '^path:(.+)$'  { try { Expand-Path $matches[1] } catch { $matches[1] } }
                '^scriptroot$' { try { Get-TopScriptRoot } catch { $token } }
                default        { return $match.Value }
            }
        })
        $depth++
    }

    return $Template
}

function Expand-Path {
    param ([string]$Path)

    $p = $Path -replace '/', '\'
    $p = [Environment]::ExpandEnvironmentVariables($p)

    if ($p -eq '~' -or $p -like '~\*') {
        $p = $p -replace '^~', $HOME
    }

    if (Test-Path $p) {
        return (Resolve-Path $p).ProviderPath
    } else {
        return $p
    }
}

function New-InvalidDefinitionResult {
    return @{
        Observed = 0
        Applied  = 0
        Changed  = 0
        Failed   = 0
        Skipped  = 1
        Reason   = "invalid_definition"
    }
}

function Write-InvalidDefinitionNotice {
    param(
        [Parameter(Mandatory)] [object]   $Logger,
        [Parameter(Mandatory)] [string]   $TargetType,
        [Parameter(Mandatory)] [string]   $TargetId,
        [hashtable]                       $Context = @{},
        [hashtable]                       $Result = $null,
        [string]                          $State = "skipped"
    )

    if (-not $Result) {
        $Result = New-InvalidDefinitionResult
    }

    $Logger.WriteTargetNotice($TargetType, $TargetId, $Result, $Context, $State)
    return $Result
}

function New-ExecutionContext {
    param (
        [int]   $RetryCount,
        [int]   $DelaySeconds,
        [string]$ErrorAction,

        [switch] $WhatIf,
        [switch] $Confirm,
        [switch] $Force,
        [switch] $Verbose,
        [switch] $Debug
    )

    $params = @{
        Context      = Get-DefaultFlags
        RetryCount   = $RetryCount
        DelaySeconds = $DelaySeconds
    }

    if ($ErrorAction) { $params.ErrorAction = $ErrorAction }
    if ($WhatIf)      { $params.WhatIf  = $true }
    if ($Confirm)     { $params.Confirm = $true }
    if ($Force)       { $params.Force   = $true }
    if ($Verbose)     { $params.Verbose = $true }
    if ($Debug)       { $params.Debug   = $true }

    return Invoke-MergeFlags @params
}


function Get-CommandArguments {
    param([string]$Command)
    if ($Command -match "^'([^']+)'(?:\s+(.*))?$") {
        return @{ Path = $Matches[1]; Args = $Matches[2] }
    }
    $parts = $Command -split '\s+', 2
    return @{ Path = $parts[0]; Args = if ($parts.Count -gt 1) { $parts[1] } else { '' } }
}

function Invoke-Script {
    param(
        [string]   $AppCommand,
        [int]      $TimeoutSeconds = 120,
        [hashtable]$Context,
        [object]   $Logger
    )


    $parsed  = Get-CommandArguments -Command $AppCommand

    # First expand any {{template}} tokens, then resolve to a filesystem path
    $expandedTemplate = Expand-TemplateValue -Template $parsed.Path
    $AppPath = Expand-Path -Path $expandedTemplate

    if (-not [System.IO.Path]::IsPathRooted($AppPath)) {
        $AppPath = Join-Path $PSScriptRoot $AppPath
    }

    if (-not (Test-Path $AppPath -PathType Leaf)) {
        $msg = "Script not found: '$AppPath' (from: '$AppCommand')"
        $Logger.WrapLog($msg, 'ERROR', $Context)
        return @{ Success = $false; Message = $msg }
    }

    $flags      = @()
    if ($Context.Verbose) { $flags += "-Verbose" }
    if ($Context.Debug)   { $flags += "-Debug" }

    $argString  = "$($parsed.Args) $($flags -join ' ')".Trim()
    $commandLine = "& `"$AppPath`" $argString"

    $Logger.WrapLog("Invoking child script: $commandLine", 'DEBUG', $Context)

    try {
        Invoke-Expression $commandLine
        # If the launched script sets a non-zero exit code, $LASTEXITCODE will capture it:
        if ($LASTEXITCODE -ne 0) {
            $msg = "Command returned exit code ${LASTEXITCODE}: '$AppPath'"
            $Logger.WrapLog($msg, 'ERROR', $Context)
            return $false
        }
        return $true
    }
    catch {
        $msg = "Exception: $_ while executing '$AppPath'"
        $Logger.WrapLog($msg, 'ERROR', $Context)
        return $false
    }
}

function Initialize-Script {
    param (
        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [string]$ConfigPath,

        [ValidateSet("DEBUG","INFO","NOTICE","WARN","ERROR")]
        [string]$LogLevel = "INFO",

        [int]$RetryCount   = 1,
        [int]$DelaySeconds = 0,

        [switch]$WhatIf,
        [switch]$Confirm,
        [switch]$Force
    )

    # ------------------------------------------------------------
    # Resolve common parameters
    # ------------------------------------------------------------
    $IsVerbose = ($VerbosePreference -ne 'SilentlyContinue')
    $IsDebug   = ($DebugPreference   -ne 'SilentlyContinue')

    # ------------------------------------------------------------
    # Paths
    # ------------------------------------------------------------
    $ScriptRoot = Split-Path -Parent $ScriptPath
    $DataRoot   = Resolve-Path (Join-Path $ScriptRoot '..\data')

    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $DataRoot 'config.json'
    }

    $ScriptName   = [IO.Path]::GetFileNameWithoutExtension($ScriptPath)
    $LogDirectory = Join-Path $DataRoot 'logs'
    $LogFilePath  = Join-Path $LogDirectory "$ScriptName.log"

    if (-not (Test-Path $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }

    # ------------------------------------------------------------
    # Execution context
    # ------------------------------------------------------------
    $Context = New-ExecutionContext `
        -RetryCount   $RetryCount `
        -DelaySeconds $DelaySeconds `
        -WhatIf:$WhatIf `
        -Confirm:$Confirm `
        -Force:$Force `
        -Verbose:$IsVerbose `
        -Debug:$IsDebug

    # ------------------------------------------------------------
    # Logging
    # ------------------------------------------------------------
    $EffectiveLogLevel = if ($IsDebug) {
        'DEBUG'
    } elseif ($IsVerbose -and $LogLevel -eq 'NOTICE') {
        'INFO'
    } else {
        $LogLevel
    }

    $Logger = New-Logger `
        -LogFilePath $LogFilePath `
        -Console:($IsVerbose -or $IsDebug) `
        -MinLevel $EffectiveLogLevel

    return @{
        ScriptRoot = $ScriptRoot
        DataRoot   = $DataRoot
        ConfigPath = $ConfigPath
        ScriptName = $ScriptName
        Logger     = $Logger
        Context    = $Context
    }
}

Export-ModuleMember -Function `
    Get-CurrentTimestamp,
    Convert-SizeToBytes,
    Format-Bytes,
    New-Guid,
    Invoke-SafeAction,
    Close-ComObject,
    Get-DefaultFlags,
    Invoke-MergeFlags,
    Test-IsAdministrator, 
    Expand-Path, 
    Expand-TemplateValue,
    New-InvalidDefinitionResult,
    Write-InvalidDefinitionNotice,
    New-ExecutionContext,
    Get-CommandArguments,
    Invoke-Script,
    Get-TopScriptRoot,
    Resolve-Item,
    Initialize-Script
