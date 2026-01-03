param([switch]$Debug, [string]$Mode)

. "$PSScriptRoot/_TestCommon.ps1"
Import-Module "$PSScriptRoot/../app/lib/GeneralUtil.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/FileUtils.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/FileRemove.psm1" -ErrorAction Stop

$actionMap = @{
    RemoveFile = { param($EntryContext, $Item, $Logger, $Context) Invoke-RemoveFile -EntryContext $EntryContext -Item $Item -Logger $Logger -Context $Context }
}

$setup = New-TestSetup -EnableDebug:$Debug -Mode $Mode -ActionMap $actionMap
$logger = $setup.Logger
$ctx = $setup.Context
$base = $setup.Base

Reset-TestRegistries
$seedMap = @{
    "SeedEnsureFilePresent" = {
        New-TestFile -Path (Join-Path $base "toremove.txt") -Content "x"
    }
    "SeedEnsureFileAbsent" = {
        $path = Join-Path $base "toremove.txt"
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
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
    @{ Phase = "InvalidDefinition"; Name = "missing_target"; Action = "RemoveFile"; EntryContext = @{}; Item = @{} }
    @{ Phase = "HappyClean"; Name = "remove_file"; Action = "RemoveFile"; EntryContext = @{}; Item = @{ path = "{base}\\toremove.txt" }; Seed = "SeedEnsureFilePresent" }
    @{ Phase = "HappyIdempotent"; Name = "remove_file"; Action = "RemoveFile"; EntryContext = @{}; Item = @{ path = "{base}\\toremove.txt" }; Seed = "SeedEnsureFileAbsent" }
)

$cases = New-TestCaseActionSeedTable -Cases $caseTable -Logger $logger -Context $ctx -ActionMap $setup.ActionMap

Invoke-TestMatrixFromTable -Mode $setup.Mode -Cases $cases

Complete-Test
