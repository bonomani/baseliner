param([switch]$Debug, [string]$Mode)

. "$PSScriptRoot/_TestCommon.ps1"

function Assert-True {
    param([string]$Label, [bool]$Value)
    if (-not $Value) {
        $script:TestFailed = $true
        Write-Host ("ASSERTION FAILED [{0}]: expected true but got false" -f $Label)
    }
}

function Invoke-Validator {
    param([string]$YamlPath)

    $scriptPath = Join-Path $PSScriptRoot "..\app\tools\Validate-YamlSections.ps1"
    $hostCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } elseif (Get-Command powershell -ErrorAction SilentlyContinue) { "powershell" } else { $null }
    if (-not $hostCmd) {
        throw "Neither pwsh nor powershell is available."
    }
    $output = & $hostCmd -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Path $YamlPath 2>&1
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = $output
    }
}

if ($Mode -and $Mode -ne 'HappyClean') {
    Complete-Test
    return
}

Write-TestSection "Validate-YamlSections"

$tempDir = Join-Path $PSScriptRoot "tmp-validate-yaml"
if (-not (Test-Path -LiteralPath $tempDir)) {
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
}

try {
    $okYaml = Join-Path $tempDir "ok.yaml"
    Set-Content -Path $okYaml -Value @"
AdminSetup:
  enabled: true
UserLogon:
  enabled: true
"@

    $badYaml = Join-Path $tempDir "bad.yaml"
    Set-Content -Path $badYaml -Value @"
AdminSetup:
  enabled: true
MissingScript:
  enabled: true
"@

    $ok = Invoke-Validator -YamlPath $okYaml
    Assert-True "ok.exitcode" ($ok.ExitCode -eq 0)
    Assert-True "ok.output" (($ok.Output -join "`n") -match "All YAML sections match existing scripts")

    $bad = Invoke-Validator -YamlPath $badYaml
    Assert-True "bad.exitcode" ($bad.ExitCode -ne 0)
    Assert-True "bad.output" (($bad.Output -join "`n") -match "MISSING: MissingScript")
}
finally {
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
}

Complete-Test
