param(
    [switch]$Debug,
    [switch]$SkipRegistry,
    [switch]$SkipCom,
    [string[]]$Modes
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

. "$here/_TestCommon.ps1"

function Invoke-RunMode {
    param(
        [Parameter(Mandatory)] [string] $RunMode,
        [Parameter(Mandatory)] [System.IO.FileInfo[]] $Tests,
        [Parameter(Mandatory)] [string] $ModeLabel
    )

    Remove-TestTemp -BasePath $here
    Remove-TestLogs -BasePath $here

    $passed = @()
    $failed = @()
    foreach ($test in $Tests) {
        Write-Host ("`n>>> Running {0} | {1}" -f $test.Name, $ModeLabel)
        $testArgs = @{}
        if ($Debug) { $testArgs.Debug = $true }
        $testArgs.Mode = $RunMode
        if ($SkipCom -and $test.Name -eq "TestFileNewUrlShortcut.ps1") { $testArgs.SkipCom = $true }

        & $test.FullName @testArgs
        if (-not $?) {
            Write-Host ("FAIL: {0}" -f $test.Name)
            $logPath = New-TestLogPath -ScriptName $test.Name
            Write-Host ("  Log: {0}" -f $logPath)
            $failed += $test.Name
        } else {
            Write-Host ("PASS: {0}" -f $test.Name)
            $passed += $test.Name
        }
    }

    Write-Host "`n=== Test Summary ==="
    Write-Host ("Passed: {0}" -f $passed.Count)
    foreach ($t in $passed) { Write-Host ("  - {0}" -f $t) }
    Write-Host ("Failed: {0}" -f $failed.Count)
    foreach ($t in $failed) { Write-Host ("  - {0}" -f $t) }

    return $(if ($failed.Count -gt 0) { 1 } else { 0 })
}

if (-not $Modes -or $Modes.Count -eq 0) {
    $Modes = @("InvalidDefinition","InvalidState","HappyClean","HappyIdempotent")
}

$hasFailure = $false
$global:TestSectionSuppressed = $true
$tests = Get-ChildItem -Path $here -Filter "Test*.ps1" -File -ErrorAction SilentlyContinue
if ($SkipRegistry) {
    $tests = $tests | Where-Object { $_.Name -ne "TestRegistrySetKeyValue.ps1" }
}
$logDir = Join-Path $here "logs"
$writeMarkers = $Modes.Count -gt 1

for ($i = 0; $i -lt $Modes.Count; $i++) {
    $runMode = $Modes[$i]
    $runIndex = $i + 1
    $modeLabel = switch ($runMode) {
        "InvalidDefinition" { "Invalid definition" }
        "InvalidState" { "Invalid state" }
        "HappyClean" { "Happy path (clean)" }
        "HappyIdempotent" { "Happy path (idempotent)" }
        default { $runMode }
    }
    if ($writeMarkers) {
        Write-Host ("{0}=== Test Run {1} ({2}) ===" -f $(if ($runIndex -gt 1) { "`n" } else { "" }), $runIndex, $runMode)
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }
        foreach ($test in $tests) {
            $path = New-TestLogPath -ScriptName $test.Name
            Add-Content -Path $path -Value ("=== RUN {0} START ===" -f $runIndex)
        }
    }

    $exitCode = Invoke-RunMode -RunMode $runMode -Tests $tests -ModeLabel $modeLabel

    if ($writeMarkers) {
        foreach ($test in $tests) {
            $path = New-TestLogPath -ScriptName $test.Name
            Add-Content -Path $path -Value ("=== RUN {0} END ===" -f $runIndex)
        }
        Write-Host ("Run {0} exit code: {1}" -f $runIndex, $exitCode)
    }

    if ($exitCode -ne 0) {
        $hasFailure = $true
    }
}

if ($hasFailure) {
    exit 1
}
$global:TestSectionSuppressed = $false
