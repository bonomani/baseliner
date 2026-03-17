param([switch]$Debug, [string]$Mode)

. "$PSScriptRoot/_TestCommon.ps1"
Import-Module "$PSScriptRoot/../app/lib/GeneralUtil.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/FileUtils.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/FileSplit.psm1" -ErrorAction Stop

$actionMap = @{
    SplitFile = { param($EntryContext, $Item, $Logger, $Context) Invoke-SplitFile -EntryContext $EntryContext -Item $Item -Logger $Logger -Context $Context }
}

$setup = New-TestSetup -EnableDebug:$Debug -Mode $Mode -ActionMap $actionMap
$logger = $setup.Logger
$ctx = $setup.Context
$base = $setup.Base

Reset-TestRegistries
$seedMap = @{
    "SeedEnsureSourceMissing" = {
        $missingSrc = Join-Path $base "missing.bin"
        if (Test-Path -LiteralPath $missingSrc) {
            Remove-Item -LiteralPath $missingSrc -Force
        }
    }
    "SeedEnsureSourcePresent" = {
        $src = Join-Path $base "split.bin"
        if (-not (Test-Path -LiteralPath $src)) {
            [IO.File]::WriteAllBytes($src, (0..255))
        }
    }
    "SeedEnsureChunksAndJoinedPresent" = {
        $src = Join-Path $base "split.bin"
        $chunks = Join-Path $base "chunks"
        $joined = Join-Path $base "joined.bin"
        if (-not (Test-Path -LiteralPath $src)) {
            [IO.File]::WriteAllBytes($src, (0..255))
        }
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
}

Register-TestSeedMap -Map $seedMap
Register-TestTokenMap -Map @{ base = $base }
Register-TestCleanup {
    if ($base -and (Test-Path -LiteralPath $base)) {
        Remove-Item -LiteralPath $base -Recurse -Force
    }
}

$caseTable = @(
    @{ Phase = "InvalidDefinition"; Name = "split_missing_target"; Action = "SplitFile"; EntryContext = @{}; Item = @{} }
    @{ Phase = "InvalidDefinition"; Name = "split_missing_chunk_size"; Action = "SplitFile"; EntryContext = @{}; Item = @{ srcPath = "{base}\\split.bin"; folder = "{base}\\chunks" } }
    @{ Phase = "InvalidState"; Name = "split_source_missing"; Action = "SplitFile"; EntryContext = @{}; Item = @{ srcPath = "{base}\\missing.bin"; folder = "{base}\\chunks"; chunkSize = 64 }; Seed = "SeedEnsureSourceMissing" }
    @{ Phase = "HappyClean"; Name = "split_file"; Action = "SplitFile"; EntryContext = @{}; Item = @{ srcFolder = "{base}"; srcName = "split.bin"; folder = "{base}\\chunks"; chunkSize = 64 }; Seed = "SeedEnsureSourcePresent" }
    @{ Phase = "HappyIdempotent"; Name = "split_file"; Action = "SplitFile"; EntryContext = @{}; Item = @{ srcFolder = "{base}"; srcName = "split.bin"; folder = "{base}\\chunks"; chunkSize = 64 }; Seed = "SeedEnsureChunksAndJoinedPresent" }
)

$cases = New-TestCaseActionSeedTable -Cases $caseTable -Logger $logger -Context $ctx -ActionMap $setup.ActionMap

Invoke-TestMatrixFromTable -Mode $setup.Mode -Cases $cases

Complete-Test
