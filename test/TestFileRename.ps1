param([switch]$Debug, [string]$Mode)

. "$PSScriptRoot/_TestCommon.ps1"
Import-Module "$PSScriptRoot/../app/lib/GeneralUtil.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/FileUtils.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/FileRename.psm1" -ErrorAction Stop

$actionMap = @{
    RenameFile = { param($EntryContext, $Item, $Logger, $Context) Invoke-RenameFile -EntryContext $EntryContext -Item $Item -Logger $Logger -Context $Context }
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
    "SeedEnsureRenamePrecondition" = {
        $src = Join-Path $base "old.txt"
        $dst = Join-Path $base "new.txt"
        if (-not (Test-Path -LiteralPath $dst)) {
            New-TestFile -Path $src -Content "x"
        } else {
            if (Test-Path -LiteralPath $src) {
                Remove-Item -LiteralPath $src -Force
            }
        }
    }
    "SeedEnsureDestPresent" = {
        $src = Join-Path $base "old.txt"
        $dst = Join-Path $base "new.txt"
        New-TestFile -Path $dst -Content "x"
        if (Test-Path -LiteralPath $src) {
            Remove-Item -LiteralPath $src -Force
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
    @{ Phase = "InvalidDefinition"; Name = "missing_all"; Action = "RenameFile"; EntryContext = @{}; Item = @{} }
    @{ Phase = "InvalidDefinition"; Name = "missing_source"; Action = "RenameFile"; EntryContext = @{ srcFolder = "{base}" }; Item = @{ path = "{base}\\dest.txt" } }
    @{ Phase = "InvalidState"; Name = "source_missing"; Action = "RenameFile"; EntryContext = @{}; Item = @{ srcPath = "{base}\\missing.txt"; path = "{base}\\dest.txt" }; Seed = "SeedEnsureSourceMissing" }
    @{ Phase = "HappyClean"; Name = "rename_file"; Action = "RenameFile"; EntryContext = @{}; Item = @{ srcPath = "{base}\\old.txt"; path = "{base}\\new.txt" }; Seed = "SeedEnsureRenamePrecondition" }
    @{ Phase = "HappyIdempotent"; Name = "rename_file"; Action = "RenameFile"; EntryContext = @{}; Item = @{ srcPath = "{base}\\old.txt"; path = "{base}\\new.txt" }; Seed = "SeedEnsureDestPresent" }
)

$cases = New-TestCaseActionSeedTable -Cases $caseTable -Logger $logger -Context $ctx -ActionMap $setup.ActionMap

Invoke-TestMatrixFromTable -Mode $setup.Mode -Cases $cases

Complete-Test
