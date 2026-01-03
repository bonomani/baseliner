$Root = Split-Path -Parent $PSCommandPath
$Core = Join-Path $Root 'setup.core.ps1'
$UpdateCore = Join-Path $Root 'update\setup.core.ps1'

if (-not (Test-Path $Core)) {
    if (Test-Path $UpdateCore) {
        $Core = $UpdateCore
    } else {
        Write-Error "setup.core.ps1 introuvable"
        exit 1
    }
}

& $Core
