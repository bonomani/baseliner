param([switch]$Debug, [string]$Mode)

. "$PSScriptRoot/_TestCommon.ps1"
Import-Module "$PSScriptRoot/../app/lib/GeneralUtil.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/FirewallSetRule.psm1" -ErrorAction Stop

if (-not (Get-Command Invoke-TestAction -ErrorAction SilentlyContinue)) {
    . "$PSScriptRoot/_TestCommon.ps1"
}

$actionMap = @{
    SetFirewallRule = { param($EntryContext, $Item, $Logger, $Context) Invoke-SetFirewallRule -EntryContext $EntryContext -Item $Item -Logger $Logger -Context $Context }
}

$setup = New-TestSetup -EnableDebug:$Debug -Mode $Mode -ActionMap $actionMap
$logger = $setup.Logger
$ctx = $setup.Context

$isAdmin = Test-IsAdministrator
$testRuleName = "BaselinerTestFirewallRule-$PID"
$profiles = @("Private", "Domain")

$seedMap = @{
    "SeedEnsureRuleAbsent" = {
        Remove-NetFirewallRule -DisplayName $testRuleName -ErrorAction SilentlyContinue | Out-Null
    }
    "SeedEnsureRulePresent" = {
        Remove-NetFirewallRule -DisplayName $testRuleName -ErrorAction SilentlyContinue | Out-Null
        New-NetFirewallRule `
            -DisplayName $testRuleName `
            -Direction "Inbound" `
            -Action "Allow" `
            -Protocol "TCP" `
            -LocalPort 5985 `
            -Profile ($profiles -join ",") `
            -Enabled "True" `
            -EdgeTraversalPolicy "Block" | Out-Null
    }
}

if ($isAdmin) {
    Register-TestSeedMap -Map $seedMap
} else {
    $logger.WrapLog("Not elevated: only invalid definition cases will run.", "WARN", $ctx)
}

Register-TestCleanup {
    if (-not $script:TestFailed -and $isAdmin) {
        Remove-NetFirewallRule -DisplayName $testRuleName -ErrorAction SilentlyContinue | Out-Null
    }
}

$caseTable = @(
    @{ Phase = "InvalidDefinition"; Name = "missing_all"; Action = "SetFirewallRule"; EntryContext = @{}; Item = @{} }
    @{ Phase = "InvalidDefinition"; Name = "missing_name"; Action = "SetFirewallRule"; EntryContext = @{ profiles = $profiles }; Item = @{ protocol = "TCP"; port = 5985 } }
    @{ Phase = "InvalidDefinition"; Name = "missing_profiles"; Action = "SetFirewallRule"; EntryContext = @{}; Item = @{ name = $testRuleName; protocol = "TCP"; port = 5985 } }
)

if ($isAdmin) {
    $caseTable += @(
        @{
            Phase = "HappyClean"
            Name = "set_rule"
            Action = "SetFirewallRule"
            EntryContext = @{ direction = "Inbound"; action = "Allow"; profiles = $profiles }
            Item = @{ name = $testRuleName; protocol = "TCP"; port = 5985 }
            Seed = "SeedEnsureRuleAbsent"
        },
        @{
            Phase = "HappyIdempotent"
            Name = "set_rule"
            Action = "SetFirewallRule"
            EntryContext = @{ direction = "Inbound"; action = "Allow"; profiles = $profiles }
            Item = @{ name = $testRuleName; protocol = "TCP"; port = 5985 }
            Seed = "SeedEnsureRulePresent"
        }
    )
}

$cases = New-TestCaseActionSeedTable -Cases $caseTable -Logger $logger -Context $ctx -ActionMap $setup.ActionMap

Invoke-TestMatrixFromTable -Mode $setup.Mode -Cases $cases

Complete-Test
