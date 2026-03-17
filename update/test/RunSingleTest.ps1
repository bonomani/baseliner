param(
    [Parameter(Mandatory)] [string] $TestName,
    [string[]] $Modes,
    [switch] $EnableDebug,
    [switch] $SkipCom
)

[CmdletBinding()]

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$here/_TestCommon.ps1"

if (-not $Modes -or $Modes.Count -eq 0) {
    $Modes = @("InvalidDefinition","InvalidState","HappyClean","HappyIdempotent")
}

$testPath = Join-Path $here $TestName
if (-not (Test-Path -LiteralPath $testPath)) {
    throw "Test file not found: $testPath"
}

$hasFailure = $false
foreach ($runMode in $Modes) {
    Write-Host ("`n>>> Running {0} | {1}" -f $TestName, $runMode)
    $testArgs = @{}
    if ($EnableDebug -or $PSBoundParameters.ContainsKey('Debug')) { $testArgs.Debug = $true }
    $testArgs.Mode = $runMode
    if ($SkipCom -and $TestName -eq "TestFileNewUrlShortcut.ps1") { $testArgs.SkipCom = $true }

    & $testPath @testArgs
    if (-not $?) {
        Write-Host ("FAIL: {0} | {1}" -f $TestName, $runMode)
        $logPath = New-TestLogPath -ScriptName $TestName
        Write-Host ("  Log: {0}" -f $logPath)
        $hasFailure = $true
    } else {
        Write-Host ("PASS: {0} | {1}" -f $TestName, $runMode)
    }
}

if ($hasFailure) {
    exit 1
}
