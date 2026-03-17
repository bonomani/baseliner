param([switch]$Debug, [switch]$SkipCom, [string]$Mode)
# SkipCom is unused in this test; kept for future expansion.

. "$PSScriptRoot/_TestCommon.ps1"
Import-Module "$PSScriptRoot/../app/lib/GeneralUtil.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/FileUtils.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/FileNewUrlShortcut.psm1" -ErrorAction Stop

$actionMap = @{
    NewUrlShortcut = { param($EntryContext, $Item, $Logger, $Context) Invoke-NewUrlShortcut -EntryContext $EntryContext -Item $Item -Logger $Logger -Context $Context }
}

$setup = New-TestSetup -EnableDebug:$Debug -Mode $Mode -ActionMap $actionMap
$logger = $setup.Logger
$ctx = $setup.Context
$base = $setup.Base

Reset-TestRegistries
$seedMap = @{
    "SeedEnsureIconMissing" = {
        $missingIcon = Join-Path $base "missing.ico"
        if (Test-Path -LiteralPath $missingIcon) {
            Remove-Item -LiteralPath $missingIcon -Force
        }
    }
    "SeedEnsureShortcutPresent" = {
        $path = Join-Path $base "Example.url"
        if (-not (Test-Path -LiteralPath $path)) {
            $lines = @(
                "[InternetShortcut]",
                "URL=https://example.com"
            )
            New-TestFile -Path $path -Content $lines
        }
    }
    "SeedEnsureShortcutAbsent" = {
        $path = Join-Path $base "Example.url"
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

$ctxSkipCom = $ctx.Clone()
$ctxSkipCom.SkipCom = $true

$contextMap = @{
    Default = $ctx
    SkipCom = $ctxSkipCom
}

Register-TestSeedMap -Map $seedMap
Register-TestContextMap -Map $contextMap
Register-TestTokenMap -Map @{ base = $base }
Register-TestCleanup {
    if ($base -and (Test-Path -LiteralPath $base)) {
        Remove-Item -LiteralPath $base -Recurse -Force
    }
}

$caseTable = @(
    @{ Phase = "InvalidDefinition"; Name = "missing_all"; Action = "NewUrlShortcut"; EntryContext = @{}; Item = @{} }
    @{ Phase = "InvalidDefinition"; Name = "missing_url"; Action = "NewUrlShortcut"; EntryContext = @{}; Item = @{ path = "{base}\\NoUrl.url" }; Context = "SkipCom" }
    @{ Phase = "InvalidState"; Name = "missing_icon"; Action = "NewUrlShortcut"; EntryContext = @{}; Item = @{ path = "{base}\\BadIcon.url"; url = "https://example.com"; iconPath = "{base}\\missing.ico" }; Context = "SkipCom"; Seed = "SeedEnsureIconMissing" }
    @{ Phase = "HappyClean"; Name = "create_url_shortcut"; Action = "NewUrlShortcut"; EntryContext = @{}; Item = @{ path = "{base}\\Example.url"; url = "https://example.com" }; Context = "SkipCom"; Seed = "SeedEnsureShortcutAbsent" }
    @{ Phase = "HappyIdempotent"; Name = "create_url_shortcut"; Action = "NewUrlShortcut"; EntryContext = @{}; Item = @{ path = "{base}\\Example.url"; url = "https://example.com" }; Context = "SkipCom"; Seed = "SeedEnsureShortcutPresent" }
)

$cases = New-TestCaseActionSeedTable -Cases $caseTable -Logger $logger -Context $ctx -ActionMap $setup.ActionMap

Invoke-TestMatrixFromTable -Mode $setup.Mode -Cases $cases

Complete-Test
