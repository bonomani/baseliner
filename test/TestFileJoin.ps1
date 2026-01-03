param([switch]$Debug, [string]$Mode)

. "$PSScriptRoot/_TestCommon.ps1"
Import-Module "$PSScriptRoot/../app/lib/GeneralUtil.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/FileUtils.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/FileJoin.psm1" -ErrorAction Stop

$actionMap = @{
    JoinFile = { param($EntryContext, $Item, $Logger, $Context) Invoke-JoinFile -EntryContext $EntryContext -Item $Item -Logger $Logger -Context $Context }
}

$setup = New-TestSetup -EnableDebug:$Debug -Mode $Mode -ActionMap $actionMap
$logger = $setup.Logger
$ctx = $setup.Context
$base = $setup.Base

Reset-TestRegistries
$seedMap = @{
    "SeedEnsureMissingPart" = {
        $joinDir = Join-Path $base "join-missing"
        New-TestDir -Path $joinDir
        New-TestFile -Path (Join-Path $joinDir "part1.bin") -Content "x"
    }
    "SeedEnsureChunksAndJoinedPresent" = {
        $chunks = Join-Path $base "chunks"
        $joined = Join-Path $base "joined.bin"
        if (-not (Test-Path -LiteralPath $chunks)) {
            New-TestDir -Path $chunks
            0..3 | ForEach-Object {
                New-TestFile -Path (Join-Path $chunks ("part{0}.bin" -f $_)) -Content "x"
            }
        }
        if (-not (Test-Path -LiteralPath $joined)) {
            New-TestFile -Path $joined -Content "x"
        }
    }
    "SeedEnsurePartsPresent" = {
        $chunks = Join-Path $base "chunks"
        if (-not (Test-Path -LiteralPath $chunks)) {
            New-TestDir -Path $chunks
            0..3 | ForEach-Object {
                New-TestFile -Path (Join-Path $chunks ("part{0}.bin" -f $_)) -Content "x"
            }
        }
        $joined = Join-Path $base "joined.bin"
        if (-not (Test-Path -LiteralPath $joined)) {
            New-TestFile -Path $joined -Content "x"
        }
    }
    "SeedEnsurePartsPresentClean" = {
        $chunks = Join-Path $base "chunks"
        if (-not (Test-Path -LiteralPath $chunks)) {
            New-TestDir -Path $chunks
        }
        0..3 | ForEach-Object {
            New-TestFile -Path (Join-Path $chunks ("part{0}.bin" -f $_)) -Content "x"
        }
    }
}

Register-TestSeedMap -Map $seedMap
Register-TestTokenMap -Map @{ base = $base }
Register-TestCleanup {
    if ($base -and (Test-Path -LiteralPath $base)) {
        Remove-Item -LiteralPath $base -Recurse -Force
    }
}

$caseTable = @(
    @{ Phase = "InvalidDefinition"; Name = "join_missing_target"; Action = "JoinFile"; EntryContext = @{}; Item = @{} }
    @{ Phase = "InvalidDefinition"; Name = "join_missing_parts"; Action = "JoinFile"; EntryContext = @{ srcFolder = "{base}\\chunks" }; Item = @{ path = "{base}\\joined.bin" } }
    @{ Phase = "InvalidState"; Name = "join_missing_part"; Action = "JoinFile"; EntryContext = @{ srcFolder = "{base}\\join-missing" }; Item = @{ path = "{base}\\joined-missing.bin"; parts = @("part1.bin","part2.bin") }; Seed = "SeedEnsureMissingPart" }
    @{ Phase = "HappyClean"; Name = "join_file"; Action = "JoinFile"; EntryContext = @{ srcFolder = "{base}\\chunks" }; Item = @{ path = "{base}\\joined.bin"; parts = @("part0.bin","part1.bin","part2.bin","part3.bin") }; Seed = "SeedEnsurePartsPresentClean" }
    @{ Phase = "HappyIdempotent"; Name = "join_file"; Action = "JoinFile"; EntryContext = @{ srcFolder = "{base}\\chunks" }; Item = @{ path = "{base}\\joined.bin"; parts = @("part0.bin","part1.bin","part2.bin","part3.bin") }; Seed = "SeedEnsurePartsPresent" }
)

$cases = New-TestCaseActionSeedTable -Cases $caseTable -Logger $logger -Context $ctx -ActionMap $setup.ActionMap

Invoke-TestMatrixFromTable -Mode $setup.Mode -Cases $cases

Complete-Test
