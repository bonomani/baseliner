param (
    [switch]$Clean,
    [switch]$Zip,
    [string]$Version,
    [switch]$TimestampVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoRoot {
    $root = Join-Path $PSScriptRoot "..\.."
    return (Resolve-Path $root).Path
}

function Ensure-Directory {
    param ([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Clear-Directory {
    param ([string]$Path)
    if (-not (Test-Path $Path)) { return }
    Get-ChildItem -Path $Path -Force | ForEach-Object {
        Remove-Item -Path $_.FullName -Recurse -Force
    }
}

$repoRoot = Resolve-RepoRoot
$updateRoot = Join-Path $repoRoot "update"

if ($TimestampVersion -and -not $Version) {
    $Version = Get-Date -Format "yyyyMMdd_HHmmss"
}

Ensure-Directory -Path $updateRoot
if ($Clean) {
    Clear-Directory -Path $updateRoot
}

$copyTargets = @(
    @{ Source = "app"; Destination = "app" },
    @{ Source = "test"; Destination = "test" },
    @{ Source = "profiles_default"; Destination = "profiles_default" },
    @{ Source = "setup.core.ps1"; Destination = "setup.core.ps1" },
    @{ Source = "setup.ps1"; Destination = "setup.ps1" }
)

foreach ($item in $copyTargets) {
    $src = Join-Path $repoRoot $item.Source
    $dst = Join-Path $updateRoot $item.Destination

    if (-not (Test-Path $src)) {
        Write-Warning "Source missing, skipping: $src"
        continue
    }

    if (Test-Path $dst) {
        Remove-Item -Path $dst -Recurse -Force
    }

    Copy-Item -Path $src -Destination $dst -Recurse -Force
    Write-Output "Copied: $src -> $dst"
}

if ($Version) {
    $versionFile = Join-Path $updateRoot "VERSION.txt"
    Set-Content -Path $versionFile -Value $Version
    Write-Output "Wrote version: $versionFile"
}

if ($Zip) {
    $zipName = if ($Version) { "package_$Version.zip" } else { "package.zip" }
    $zipPath = Join-Path $updateRoot $zipName
    if (Test-Path $zipPath) {
        Remove-Item -Path $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $updateRoot "*") -DestinationPath $zipPath -Force
    Write-Output "Created ZIP: $zipPath"
}
