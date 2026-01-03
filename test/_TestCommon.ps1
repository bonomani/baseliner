param()

$script:TestFailed = $false
$script:TestCleanups = @()
$script:TestSeedRegistry = @{}
$script:TestContextRegistry = @{}
$script:TestTokenRegistry = @{}

function New-TestLogger {
    param(
        [string]$LogPath,
        [switch]$Debug
    )

    Import-Module "$PSScriptRoot/../app/lib/Logger.psm1" -ErrorAction Stop
    $logDir = Split-Path -Parent $LogPath
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }

    $minLevel = 'NOTICE'
    if ($Debug) { $minLevel = 'DEBUG' }

    return New-Logger -LogFilePath $LogPath -Console:$true -MinLevel $minLevel
}

function New-TestLogPath {
    param([Parameter(Mandatory)] [string]$ScriptName)
    $baseName = [IO.Path]::GetFileNameWithoutExtension($ScriptName)
    if ($baseName.StartsWith("Test")) {
        $baseName = $baseName.Substring(4)
    }
    $logFile = "test-{0}.log" -f $baseName.ToLower()
    return (Join-Path (Join-Path $PSScriptRoot "logs") $logFile)
}

function New-TestContext {
    param([switch]$Debug)

    return @{
        Verbose = $true
        Debug = [bool]$Debug
        WhatIf = $false
        Confirm = $false
        Force = $true
    }
}

function New-TestDirWithInitialState {
    param([string]$BasePath)

    if (Test-Path -LiteralPath $BasePath) {
        Remove-Item -LiteralPath $BasePath -Recurse -Force
    }
    New-Item -Path $BasePath -ItemType Directory -Force | Out-Null
    return $BasePath
}

function Assert-Result {
    param(
        [Parameter(Mandatory)] [hashtable] $Result,
        [Parameter(Mandatory)] [hashtable] $Expected,
        [string] $ReasonPattern
    )

    foreach ($key in @('Observed','Applied','Changed','Failed','Skipped')) {
        if ($Expected.ContainsKey($key)) {
            if ($Expected[$key] -ne $Result[$key]) {
                $script:TestFailed = $true
                Write-Host ("ASSERTION FAILED: Result {0} mismatch (expected='{1}' actual='{2}')" -f $key, $Expected[$key], $Result[$key])
            }
        }
    }

    if ($ReasonPattern) {
        $reasonText = if ($Result.ContainsKey('Reason')) { [string]$Result.Reason } else { "" }
        $reasonText = ($reasonText -replace "\s+", " ").Trim()
        $reasonPrimary = ($reasonText -split '\|')[0].Trim()
        $pattern = $ReasonPattern -replace '\\\\\.', '\\.'
        if (-not [regex]::IsMatch($reasonPrimary, $pattern)) {
            $script:TestFailed = $true
            Write-Host ("ASSERTION FAILED: Result Reason mismatch (pattern='{0}' actual='{1}')" -f $pattern, $reasonPrimary)
        }
    }
}

function Resolve-TestModeName {
    param([Parameter(Mandatory)] $Mode)

    if ($Mode -is [string]) {
        switch ($Mode) {
            "InvalidDefinition" { return "InvalidDefinition" }
            "InvalidState" { return "InvalidState" }
            "HappyClean" { return "HappyClean" }
            "HappyIdempotent" { return "HappyIdempotent" }
            default { throw "Unknown test mode '$Mode'. Expected InvalidDefinition, InvalidState, HappyClean, or HappyIdempotent." }
        }
    }

    throw "Invalid test mode. Expected a mode name string."
}

function Assert-ResultForMode {
    param(
        [Parameter(Mandatory)] [hashtable] $Result,
        [Parameter(Mandatory)] [string] $Mode
    )

    switch ($Mode) {
        "InvalidDefinition" {
            Assert-Result -Result $Result -Expected @{ Observed = 0; Applied = 0; Changed = 0; Failed = 0; Skipped = 1 } -ReasonPattern "invalid_definition"
        }
        "InvalidState" {
            Assert-Result -Result $Result -Expected @{ Observed = 1; Applied = 0; Changed = 0; Failed = 0; Skipped = 1 } -ReasonPattern "^check\.fail"
        }
        "HappyIdempotent" {
            Assert-Result -Result $Result -Expected @{ Observed = 1; Applied = 0; Changed = 0; Failed = 0; Skipped = 0 } -ReasonPattern "^preverify\.ok"
        }
        "HappyClean" {
            Assert-Result -Result $Result -Expected @{ Observed = 1; Applied = 1; Changed = 1; Failed = 0; Skipped = 0 } -ReasonPattern "^verify\.ok"
        }
        default {
            throw "Unknown test mode '$Mode'."
        }
    }
}

function Complete-Test {
    Invoke-TestCleanup
    if ($script:TestFailed) {
        exit 1
    }
}

function Write-TestSection {
    param([string]$Title)
    if ($global:TestSectionSuppressed) {
        return
    }
    if ($script:LastTestSection -eq $Title) {
        return
    }
    $script:LastTestSection = $Title
    Write-Host ""
    Write-Host "=== $Title ==="
}

function New-TestSetup {
    param(
        [string] $LogName,
        [string] $TempDir,
        [switch] $EnableDebug,
        $Mode,
        [hashtable] $ActionMap
    )

    if (-not $LogName -or -not $TempDir) {
        $caller = (Get-PSCallStack | Select-Object -Skip 1 | Where-Object { $_.ScriptName } | Select-Object -First 1).ScriptName
        $baseName = if ($caller) { [IO.Path]::GetFileNameWithoutExtension($caller) } else { "Test" }
        if ($baseName.StartsWith("Test")) {
            $baseName = $baseName.Substring(4)
        }
        $baseName = $baseName.ToLower()
        if (-not $LogName) {
            $LogName = "test-$baseName.log"
        }
        if (-not $TempDir) {
            $TempDir = "tmp-$baseName"
        }
    }

    $setup = @{
        Logger = New-TestLogger -LogPath (Join-Path (Join-Path $PSScriptRoot "logs") $LogName) -Debug:$EnableDebug
        Context = New-TestContext -Debug:$EnableDebug
        Base = $null
        Mode = $null
        ActionMap = $null
    }

    $modeData = $null
    $modeData = if ($Mode) { $Mode } else { "HappyClean" }

    $setup.Mode = Resolve-TestModeName -Mode $modeData
    if ($TempDir) {
        $setup.Base = New-TestDirWithInitialState -BasePath (Join-Path $PSScriptRoot $TempDir)
    }

    $actionData = $null
    if ($ActionMap) {
        $actionData = $ActionMap
    } elseif ($global:TestActionMap) {
        $actionData = $global:TestActionMap
    }
    $setup.ActionMap = $actionData

    return $setup
}

function Register-TestCleanup {
    param([Parameter(Mandatory)] [ScriptBlock] $Action)
    $script:TestCleanups += $Action
}

function Invoke-TestCleanup {
    foreach ($action in $script:TestCleanups) {
        & $action
    }
    $script:TestCleanups = @()
}

function Remove-TestTemp {
    param([Parameter(Mandatory)] [string] $BasePath)
    Get-ChildItem -Path $BasePath -Filter "tmp-*" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
    $tmpPath = Join-Path $BasePath "tmp"
    if (Test-Path -LiteralPath $tmpPath) {
        Remove-Item -LiteralPath $tmpPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-TestLogs {
    param([Parameter(Mandatory)] [string] $BasePath)
    $logDir = Join-Path $BasePath "logs"
    if (Test-Path -LiteralPath $logDir) {
        Get-ChildItem -Path $logDir -File -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-TestDir {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function New-TestFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [object] $Content = "x"
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        Set-Content -Path $Path -Value $Content -Encoding ASCII
    }
}

function Set-TestAcl {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Rule
    )
    $acl = Get-Acl -Path $Path
    $acl.SetAccessRule($Rule)
    Set-Acl -Path $Path -AclObject $acl
}


function Invoke-Cases {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Cases,
        [Parameter(Mandatory)] [string] $Mode
    )

    if (-not $Cases -or $Cases.Count -eq 0) {
        return
    }

    foreach ($case in $Cases) {
        $caseName = $null
        $caseBlock = $null
        if ($case -is [hashtable] -and $case.ContainsKey('Run')) {
            $caseName = $case.Name
            $caseBlock = $case.Run
        } elseif ($case -is [psobject] -and $case.PSObject.Properties['Run']) {
            $caseName = $case.Name
            $caseBlock = $case.Run
        } elseif ($case -is [ScriptBlock]) {
            $caseBlock = $case
        } else {
            $caseBlock = $null
        }

        if ($caseName) {
            Write-Host ("--- Case: {0} ---" -f $caseName)
        }
        if (-not $caseBlock) {
            $script:TestFailed = $true
            Write-Host "ASSERTION FAILED: Test case missing Run block."
            continue
        }
        $result = & $caseBlock
        Assert-ResultForMode -Result $result -Mode $Mode
    }
}

function Invoke-TestAction {
    param(
        [Parameter(Mandatory)] [string] $Action,
        [Parameter(Mandatory)] [object] $EntryContext,
        [Parameter(Mandatory)] [object] $Item,
        [Parameter(Mandatory)] [object] $Logger,
        [hashtable] $Context = @{},
        [hashtable] $ActionMap
    )

    $map = $ActionMap
    if (-not $map -and $global:TestActionMap) {
        $map = $global:TestActionMap
    }
    if (-not $map -or -not $map.ContainsKey($Action)) {
        $script:TestFailed = $true
        Write-Host ("ASSERTION FAILED: No action mapping found for '{0}'." -f $Action)
        return @{ Observed = 0; Applied = 0; Changed = 0; Failed = 1; Skipped = 0; Reason = "action.missing" }
    }

    $fn = $map[$Action]
    return & $fn -EntryContext $EntryContext -Item $Item -Logger $Logger -Context $Context
}

function New-TestCase {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [ScriptBlock] $Run,
        [Parameter(Mandatory)] [string] $Phase
    )

    $case = [pscustomobject]@{
        Name = $Name
        Run = $Run
        Phase = $Phase
    }
    return $case
}

function New-TestCaseAction {
    param(
        [Parameter(Mandatory)] [string] $Phase,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Action,
        [Parameter(Mandatory)] [object] $EntryContext,
        [Parameter(Mandatory)] [object] $Item,
        [Parameter(Mandatory)] [object] $Logger,
        [Parameter(Mandatory)] [hashtable] $Context,
        [ScriptBlock] $Seed,
        [hashtable] $ActionMap
    )

    $actionInvoker = ${function:Invoke-TestAction}
    $run = {
        if ($Seed) {
            & $Seed
        }
        $resolvedItem = $Item
        if ($Item -is [ScriptBlock]) {
            $resolvedItem = & $Item
        }
        if (-not $actionInvoker) {
            $script:TestFailed = $true
            Write-Host "ASSERTION FAILED: Invoke-TestAction is not available in scope."
            return @{ Observed = 0; Applied = 0; Changed = 0; Failed = 1; Skipped = 0; Reason = "action.missing" }
        }
        & $actionInvoker -Action $Action -EntryContext $EntryContext -Item $resolvedItem -Logger $Logger -Context $Context -ActionMap $ActionMap
    }.GetNewClosure()

    return New-TestCase -Phase $Phase -Name $Name -Run $run
}

function Reset-TestRegistries {
    $script:TestSeedRegistry = @{}
    $script:TestContextRegistry = @{}
    $script:TestTokenRegistry = @{}
}

function Register-TestSeedMap {
    param([Parameter(Mandatory)] [hashtable] $Map)
    Register-TestMap -Registry $script:TestSeedRegistry -Map $Map
}

function Register-TestMap {
    param(
        [Parameter(Mandatory)] [hashtable] $Registry,
        [Parameter(Mandatory)] [hashtable] $Map
    )
    foreach ($key in $Map.Keys) {
        if ($Registry.ContainsKey($key)) {
            throw "Test entry '$key' is already registered."
        }
        $Registry[$key] = $Map[$key]
    }
}


function Register-TestContextMap {
    param([Parameter(Mandatory)] [hashtable] $Map)
    Register-TestMap -Registry $script:TestContextRegistry -Map $Map
}

function Register-TestTokenMap {
    param([Parameter(Mandatory)] [hashtable] $Map)
    Register-TestMap -Registry $script:TestTokenRegistry -Map $Map
}

function Resolve-TestTokens {
    param(
        [Parameter(Mandatory)] $Value
    )
    if ($null -eq $Value) { return $Value }
    if ($Value -is [string]) {
        $text = $Value
        foreach ($key in $script:TestTokenRegistry.Keys) {
            $token = '{' + $key + '}'
            $text = $text -replace [regex]::Escape($token), [string]$script:TestTokenRegistry[$key]
        }
        return $text
    }
    if ($Value -is [hashtable]) {
        $resolved = @{}
        foreach ($k in $Value.Keys) {
            $resolved[$k] = Resolve-TestTokens -Value $Value[$k]
        }
        return $resolved
    }
    if ($Value -is [array]) {
        return @($Value | ForEach-Object { Resolve-TestTokens -Value $_ })
    }
    return $Value
}

function New-TestCaseActionSeedTable {
    param(
        [Parameter(Mandatory)] [object[]] $Cases,
        [Parameter(Mandatory)] [object] $Logger,
        [Parameter(Mandatory)] [hashtable] $Context,
        [Parameter(Mandatory)] [hashtable] $ActionMap
    )

    $result = @()
    foreach ($case in $Cases) {
        if (-not $case) { continue }
        $seed = $case.Seed
        if ($seed -is [string]) {
            if (-not $script:TestSeedRegistry.ContainsKey($seed)) {
                throw "Unknown test seed '$seed'."
            }
            $seed = $script:TestSeedRegistry[$seed]
        }
        if (-not $seed) {
            $seed = { $null = $true }
        }
        $item = $case.Item
        $caseLogger = $case.Logger
        if (-not $caseLogger) {
            $caseLogger = $Logger
        }
        $caseContext = $case.Context
        if ($caseContext -is [string]) {
            if (-not $script:TestContextRegistry.ContainsKey($caseContext)) {
                throw "Unknown test context '$caseContext'."
            }
            $caseContext = $script:TestContextRegistry[$caseContext]
        }
        if (-not $caseContext) {
            $caseContext = $Context
        }
        $entryContext = Resolve-TestTokens -Value $case.EntryContext
        $resolvedItem = Resolve-TestTokens -Value $item
        $result += New-TestCaseAction -Phase $case.Phase -Name $case.Name -Action $case.Action -EntryContext $entryContext -Item $resolvedItem -Logger $caseLogger -Context $caseContext -Seed $seed -ActionMap $ActionMap
    }
    return $result
}

function Invoke-TestMatrix {
    param(
        [Parameter(Mandatory)] [string] $Mode,
        [string] $InvalidDefinitionLabel = "Invalid definition",
        [AllowEmptyCollection()] [object[]] $InvalidDefinitionCases,
        [string] $InvalidStateLabel = "Invalid state",
        [AllowEmptyCollection()] [object[]] $InvalidStateCases,
        [string] $HappyCleanLabel = "Happy path (clean)",
        [AllowEmptyCollection()] [object[]] $HappyCleanCases,
        [string] $HappyIdempotentLabel = "Happy path (idempotent)",
        [AllowEmptyCollection()] [object[]] $HappyIdempotentCases
    )

    $hasInvalidDefinition = $PSBoundParameters.ContainsKey('InvalidDefinitionCases')
    $hasInvalidState = $PSBoundParameters.ContainsKey('InvalidStateCases')
    $hasHappyClean = $PSBoundParameters.ContainsKey('HappyCleanCases')
    $hasHappyIdempotent = $PSBoundParameters.ContainsKey('HappyIdempotentCases')

    switch ($Mode) {
        "InvalidDefinition" {
            if ($hasInvalidDefinition) {
                Write-TestSection $InvalidDefinitionLabel
                Invoke-Cases -Cases $InvalidDefinitionCases -Mode $Mode
            }
        }
        "InvalidState" {
            if ($hasInvalidState) {
                Write-TestSection $InvalidStateLabel
                Invoke-Cases -Cases $InvalidStateCases -Mode $Mode
            }
        }
        "HappyIdempotent" {
            if ($hasHappyIdempotent) {
                Write-TestSection $HappyIdempotentLabel
                Invoke-Cases -Cases $HappyIdempotentCases -Mode $Mode
            }
        }
        "HappyClean" {
            if ($hasHappyClean) {
                Write-TestSection $HappyCleanLabel
                Invoke-Cases -Cases $HappyCleanCases -Mode $Mode
            }
        }
        default {
            throw "Unknown test mode '$Mode'."
        }
    }
}

function Invoke-TestMatrixFromTable {
    param(
        [Parameter(Mandatory)] [string] $Mode,
        [Parameter(Mandatory)] [object[]] $Cases,
        [string] $InvalidDefinitionLabel = "Invalid definition",
        [string] $InvalidStateLabel = "Invalid state",
        [string] $HappyCleanLabel = "Happy path (clean)",
        [string] $HappyIdempotentLabel = "Happy path (idempotent)"
    )

    $invalidDefinitionCases = @()
    $invalidStateCases = @()
    $happyCleanCases = @()
    $happyIdempotentCases = @()

    foreach ($case in $Cases) {
        $phase = $case.Phase
        if (-not $phase) { continue }
        switch ($phase) {
            "InvalidDefinition" { $invalidDefinitionCases += $case }
            "InvalidState" { $invalidStateCases += $case }
            "HappyClean" { $happyCleanCases += $case }
            "HappyIdempotent" { $happyIdempotentCases += $case }
        }
    }

    Invoke-TestMatrix -Mode $Mode `
        -InvalidDefinitionLabel $InvalidDefinitionLabel `
        -InvalidDefinitionCases $invalidDefinitionCases `
        -InvalidStateLabel $InvalidStateLabel `
        -InvalidStateCases $invalidStateCases `
        -HappyCleanLabel $HappyCleanLabel `
        -HappyIdempotentLabel $HappyIdempotentLabel `
        -HappyCleanCases $happyCleanCases `
        -HappyIdempotentCases $happyIdempotentCases
}
