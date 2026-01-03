param([switch]$Debug, [string]$Mode)

. "$PSScriptRoot/_TestCommon.ps1"
Import-Module "$PSScriptRoot/../app/lib/GeneralUtil.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/RegistrySetKeyValue.psm1" -ErrorAction Stop

$actionMap = @{
    SetKeyValue = { param($EntryContext, $Item, $Logger, $Context) Invoke-SetKeyValue -EntryContext $EntryContext -Item $Item -Logger $Logger -Context $Context }
}

$setup = New-TestSetup -EnableDebug:$Debug -Mode $Mode -ActionMap $actionMap
$logger = $setup.Logger
$ctx = $setup.Context

$seedMap = @{
    "SeedEnsureValueAbsent" = {
        $regPath = "HKCU:\\Software\\BaselinerTest"
        $valueName = "TestValue"
        if (Test-Path -Path $regPath) {
            $props = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
            if ($props -and ($props.PSObject.Properties.Name -contains $valueName)) {
                Remove-ItemProperty -Path $regPath -Name $valueName -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }
    "SeedEnsureValuePresent" = {
        $regPath = "HKCU:\\Software\\BaselinerTest"
        $valueName = "TestValue"
        if (-not (Test-Path -Path $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }
        New-ItemProperty -Path $regPath -Name $valueName -Value "1" -PropertyType String -Force | Out-Null
    }
}

Register-TestSeedMap -Map $seedMap

Register-TestCleanup {
    if (-not $script:TestFailed) {
        $regPath = "HKCU:\\Software\\BaselinerTest"
        if (Test-Path -Path $regPath) {
            Remove-Item -Path $regPath -Recurse -Force | Out-Null
        }
    }
}

$caseTable = @(
    @{ Phase = "InvalidDefinition"; Name = "missing_all"; Action = "SetKeyValue"; EntryContext = @{}; Item = @{} }
    @{ Phase = "InvalidDefinition"; Name = "key_mismatch"; Action = "SetKeyValue"; EntryContext = @{ key = "HKEY_CURRENT_USER\\Software\\BaselinerTest" }; Item = @{ key = "HKEY_CURRENT_USER\\Software\\Other"; name = "Test"; value = "1"; type = "string" } }
    @{ Phase = "InvalidDefinition"; Name = "bad_type"; Action = "SetKeyValue"; EntryContext = @{ key = "HKEY_CURRENT_USER\\Software\\BaselinerTest" }; Item = @{ name = "Test"; value = "1"; type = "badtype" } }
    @{ Phase = "InvalidDefinition"; Name = "bad_root"; Action = "SetKeyValue"; EntryContext = @{ key = "HKEY_INVALID\\Software\\BaselinerTest" }; Item = @{ name = "Test"; value = "1"; type = "string" } }
    @{ Phase = "HappyClean"; Name = "set_value"; Action = "SetKeyValue"; EntryContext = @{ key = "HKEY_CURRENT_USER\\Software\\BaselinerTest" }; Item = @{ name = "TestValue"; value = "1"; type = "string" }; Seed = "SeedEnsureValueAbsent" }
    @{ Phase = "HappyIdempotent"; Name = "set_value"; Action = "SetKeyValue"; EntryContext = @{ key = "HKEY_CURRENT_USER\\Software\\BaselinerTest" }; Item = @{ name = "TestValue"; value = "1"; type = "string" }; Seed = "SeedEnsureValuePresent" }
)

$cases = New-TestCaseActionSeedTable -Cases $caseTable -Logger $logger -Context $ctx -ActionMap $setup.ActionMap

Invoke-TestMatrixFromTable -Mode $setup.Mode -Cases $cases

Complete-Test
