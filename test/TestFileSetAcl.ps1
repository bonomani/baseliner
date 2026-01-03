param([switch]$Debug, [string]$Mode)

. "$PSScriptRoot/_TestCommon.ps1"
Import-Module "$PSScriptRoot/../app/lib/GeneralUtil.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/FileUtils.psm1" -ErrorAction Stop
Import-Module "$PSScriptRoot/../app/lib/FileSetAcl.psm1" -ErrorAction Stop

$actionMap = @{
    SetAcl = { param($EntryContext, $Item, $Logger, $Context) Invoke-SetAcl -EntryContext $EntryContext -Item $Item -Logger $Logger -Context $Context }
}

$setup = New-TestSetup -EnableDebug:$Debug -Mode $Mode -ActionMap $actionMap
$logger = $setup.Logger
$ctx = $setup.Context
$base = $setup.Base

Reset-TestRegistries
$seedMap = @{
    "SeedEnsureTargetMissing" = {
        $missingPath = Join-Path $base "missing-acl.txt"
        if (Test-Path -LiteralPath $missingPath) {
            Remove-Item -LiteralPath $missingPath -Force
        }
    }
    "SeedEnsureFilePresent" = {
        $path = Join-Path $base "acl.txt"
        if (-not (Test-Path -LiteralPath $path)) {
            New-TestFile -Path $path -Content "x"
        }
    }
    "SeedEnsureFileAndAclPresent" = {
        $path = Join-Path $base "acl.txt"
        $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($user,"Read","Allow")
        New-TestFile -Path $path -Content "x"
        Set-TestAcl -Path $path -Rule $rule
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
    @{ Phase = "InvalidDefinition"; Name = "missing_rules"; Action = "SetAcl"; EntryContext = @{}; Item = @{} }
    @{ Phase = "InvalidDefinition"; Name = "missing_target"; Action = "SetAcl"; EntryContext = @{ folder = "{base}"; accessRules = @((New-Object System.Security.AccessControl.FileSystemAccessRule(([System.Security.Principal.WindowsIdentity]::GetCurrent().Name),"Read","Allow"))) }; Item = @{} }
    @{ Phase = "InvalidState"; Name = "target_missing"; Action = "SetAcl"; EntryContext = @{ path = "{base}\\missing-acl.txt"; accessRules = @((New-Object System.Security.AccessControl.FileSystemAccessRule(([System.Security.Principal.WindowsIdentity]::GetCurrent().Name),"Read","Allow"))) }; Item = @{}; Seed = "SeedEnsureTargetMissing" }
    @{ Phase = "HappyClean"; Name = "set_acl"; Action = "SetAcl"; EntryContext = @{ path = "{base}\\acl.txt"; accessRules = @((New-Object System.Security.AccessControl.FileSystemAccessRule(([System.Security.Principal.WindowsIdentity]::GetCurrent().Name),"Read","Allow"))) }; Item = @{}; Seed = "SeedEnsureFilePresent" }
    @{ Phase = "HappyIdempotent"; Name = "set_acl"; Action = "SetAcl"; EntryContext = @{ path = "{base}\\acl.txt"; accessRules = @((New-Object System.Security.AccessControl.FileSystemAccessRule(([System.Security.Principal.WindowsIdentity]::GetCurrent().Name),"Read","Allow"))) }; Item = @{}; Seed = "SeedEnsureFileAndAclPresent" }
)

$cases = New-TestCaseActionSeedTable -Cases $caseTable -Logger $logger -Context $ctx -ActionMap $setup.ActionMap

Invoke-TestMatrixFromTable -Mode $setup.Mode -Cases $cases

Complete-Test
