$Root = Split-Path -Parent $PSCommandPath
$Core = Join-Path $Root 'setup.core.ps1'
if (-not (Test-Path $Core)) {
    Write-Error "setup.core.ps1 introuvable"
    exit 1
}

& $Core @args
