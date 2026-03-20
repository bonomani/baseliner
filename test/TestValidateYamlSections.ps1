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
    param([string]$JsonPath)

    $scriptPath = Join-Path $PSScriptRoot "..\app\tools\Validate-Scripts.ps1"
    $hostCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } elseif (Get-Command powershell -ErrorAction SilentlyContinue) { "powershell" } else { $null }
    if (-not $hostCmd) {
        throw "Neither pwsh nor powershell is available."
    }
    $output = & $hostCmd -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Path $JsonPath 2>&1
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = $output
    }
}

if ($Mode -and $Mode -ne 'HappyClean') {
    Complete-Test
    return
}

Write-TestSection "Validate-Scripts"

$configPath = Join-Path $PSScriptRoot "..\profiles_default\Windows_default\config.json"

$result = Invoke-Validator -JsonPath $configPath
Assert-True "config.exitcode" ($result.ExitCode -eq 0)
Assert-True "config.output" (($result.Output -join "`n") -match "All JSON sections match existing scripts")

Complete-Test
