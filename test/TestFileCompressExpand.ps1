param([switch]$Debug, [string]$Mode)

. "$PSScriptRoot/_TestCommon.ps1"
Import-Module "$PSScriptRoot/../app/lib/GeneralUtil.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/FileUtils.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/FileCompress.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/FileExpandArchive.psm1" -ErrorAction Stop

$actionMap = @{
    CompressFile = { param($EntryContext, $Item, $Logger, $Context) Invoke-CompressFile -EntryContext $EntryContext -Item $Item -Logger $Logger -Context $Context }
    ExpandArchive = { param($EntryContext, $Item, $Logger, $Context) Invoke-ExpandArchive -EntryContext $EntryContext -Item $Item -Logger $Logger -Context $Context }
}

$setup = New-TestSetup -EnableDebug:$Debug -Mode $Mode -ActionMap $actionMap
$logger = $setup.Logger
$ctx = $setup.Context
$base = $setup.Base

Reset-TestRegistries
$seedMap = @{
    "SeedEnsureSourceMissing" = {
        $missingSrc = Join-Path $base "missing.txt"
        if (Test-Path -LiteralPath $missingSrc) {
            Remove-Item -LiteralPath $missingSrc -Force
        }
    }
    "SeedEnsureSourcePresent" = {
        New-TestFile -Path (Join-Path $base "source.txt") -Content "hello"
    }
    "SeedEnsureZipPresent" = {
        $src = Join-Path $base "source.txt"
        $zip = Join-Path $base "out.zip"
        New-TestFile -Path $src -Content "hello"
        if (-not (Test-Path -LiteralPath $zip)) {
            Compress-Archive -Path $src -DestinationPath $zip -Force
        }
    }
    "SeedEnsureZipAndExpandedPresent" = {
        $zip = Join-Path $base "out.zip"
        $dest = Join-Path $base "expanded"
        if (-not (Test-Path -LiteralPath $zip)) {
            New-TestFile -Path (Join-Path $base "source.txt") -Content "hello"
            Compress-Archive -Path (Join-Path $base "source.txt") -DestinationPath $zip -Force
        }
        if (-not (Test-Path -LiteralPath $dest)) {
            New-TestDir -Path $dest
            New-TestFile -Path (Join-Path $dest "seed.txt") -Content "hello"
        }
    }
    "SeedEnsureZipPresentAndExpandedAbsent" = {
        $src = Join-Path $base "source.txt"
        $zip = Join-Path $base "out.zip"
        $dest = Join-Path $base "expanded"
        New-TestFile -Path $src -Content "hello"
        Compress-Archive -Path $src -DestinationPath $zip -Force
        if (Test-Path -LiteralPath $dest) {
            Remove-Item -LiteralPath $dest -Recurse -Force
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
    @{ Phase = "InvalidDefinition"; Name = "compress_missing_target"; Action = "CompressFile"; EntryContext = @{}; Item = @{} }
    @{ Phase = "InvalidDefinition"; Name = "expand_missing_target"; Action = "ExpandArchive"; EntryContext = @{}; Item = @{} }
    @{ Phase = "InvalidDefinition"; Name = "compress_missing_target_name"; Action = "CompressFile"; EntryContext = @{ srcPath = "{base}\\source.txt" }; Item = @{} }
    @{ Phase = "InvalidState"; Name = "compress_source_missing"; Action = "CompressFile"; EntryContext = @{}; Item = @{ srcPath = "{base}\\missing.txt"; path = "{base}\\missing.zip" }; Seed = "SeedEnsureSourceMissing" }
    @{ Phase = "InvalidState"; Name = "expand_source_missing"; Action = "ExpandArchive"; EntryContext = @{}; Item = @{ srcPath = "{base}\\missing.zip"; folder = "{base}\\out" } }
    @{ Phase = "HappyClean"; Name = "compress_file"; Action = "CompressFile"; EntryContext = @{}; Item = @{ srcPath = "{base}\\source.txt"; path = "{base}\\out.zip" }; Seed = "SeedEnsureSourcePresent" }
    @{ Phase = "HappyClean"; Name = "expand_archive"; Action = "ExpandArchive"; EntryContext = @{}; Item = @{ srcPath = "{base}\\out.zip"; folder = "{base}\\expanded" }; Seed = "SeedEnsureZipPresentAndExpandedAbsent" }
    @{ Phase = "HappyIdempotent"; Name = "compress_file"; Action = "CompressFile"; EntryContext = @{}; Item = @{ srcPath = "{base}\\source.txt"; path = "{base}\\out.zip" }; Seed = "SeedEnsureZipPresent" }
    @{ Phase = "HappyIdempotent"; Name = "expand_archive"; Action = "ExpandArchive"; EntryContext = @{}; Item = @{ srcPath = "{base}\\out.zip"; folder = "{base}\\expanded" }; Seed = "SeedEnsureZipAndExpandedPresent" }
)

$cases = New-TestCaseActionSeedTable -Cases $caseTable -Logger $logger -Context $ctx -ActionMap $setup.ActionMap

Invoke-TestMatrixFromTable -Mode $setup.Mode -Cases $cases

Complete-Test
