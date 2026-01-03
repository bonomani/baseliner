param([switch]$Debug, [string]$Mode)

. "$PSScriptRoot/_TestCommon.ps1"
Import-Module "$PSScriptRoot/../app/lib/GeneralUtil.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/FileUtils.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/FileCopy.psm1" -ErrorAction Stop

$actionMap = @{
    CopyFile = { param($EntryContext, $Item, $Logger, $Context) Invoke-CopyFile -EntryContext $EntryContext -Item $Item -Logger $Logger -Context $Context }
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
    "SeedEnsureSourceAndDestPresent" = {
        $src = Join-Path $base "source.txt"
        $dst = Join-Path $base "dest.txt"
        New-TestFile -Path $src -Content "hello"
        Copy-Item -LiteralPath $src -Destination $dst -Force
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
    @{ Phase = "InvalidDefinition"; Name = "missing_all"; Action = "CopyFile"; EntryContext = @{}; Item = @{} }
    @{ Phase = "InvalidDefinition"; Name = "missing_source"; Action = "CopyFile"; EntryContext = @{ path = "{base}\\dest.txt" }; Item = @{} }
    @{ Phase = "InvalidDefinition"; Name = "missing_target"; Action = "CopyFile"; EntryContext = @{ folder = "{base}" }; Item = @{ srcPath = "{base}\\source.txt" } }
    @{ Phase = "InvalidState"; Name = "source_missing"; Action = "CopyFile"; EntryContext = @{}; Item = @{ srcPath = "{base}\\missing.txt"; path = "{base}\\dest.txt" }; Seed = "SeedEnsureSourceMissing" }
    @{ Phase = "HappyClean"; Name = "copy_file"; Action = "CopyFile"; EntryContext = @{}; Item = @{ srcPath = "{base}\\source.txt"; path = "{base}\\dest.txt" }; Seed = "SeedEnsureSourcePresent" }
    @{ Phase = "HappyIdempotent"; Name = "copy_file"; Action = "CopyFile"; EntryContext = @{}; Item = @{ srcPath = "{base}\\source.txt"; path = "{base}\\dest.txt" }; Seed = "SeedEnsureSourceAndDestPresent" }
)

$cases = New-TestCaseActionSeedTable -Cases $caseTable -Logger $logger -Context $ctx -ActionMap $setup.ActionMap

Invoke-TestMatrixFromTable -Mode $setup.Mode -Cases $cases

Complete-Test
