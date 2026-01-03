param (
    [switch]$Clean,
    [switch]$Zip,
    [string]$Version,
    [switch]$TimestampVersion,
    [switch]$UsePayloadFolder
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoRoot {
    $root = Join-Path $PSScriptRoot "..\.."
    return (Resolve-Path $root).Path
}

function New-DirectoryIfMissing {
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
$buildRoot = Join-Path $repoRoot "build"
$payloadRoot = if ($UsePayloadFolder) { Join-Path $buildRoot "Baseliner" } else { $buildRoot }
$updateRoot = Join-Path $payloadRoot "update"

if ($TimestampVersion -and -not $Version) {
    $Version = Get-Date -Format "yyyyMMdd_HHmmss"
}

New-DirectoryIfMissing -Path $buildRoot
if ($UsePayloadFolder) {
    New-DirectoryIfMissing -Path $payloadRoot
}
if ($Clean) {
    Clear-Directory -Path $buildRoot
    if ($UsePayloadFolder) {
        New-DirectoryIfMissing -Path $payloadRoot
    }
}
New-DirectoryIfMissing -Path $updateRoot

$copyTargets = @(
    @{ Source = "setup.ps1"; Destination = "setup.ps1"; Root = $payloadRoot },
    @{ Source = "app"; Destination = "app"; Root = $updateRoot },
    @{ Source = "test"; Destination = "test"; Root = $updateRoot },
    @{ Source = "profiles_default"; Destination = "profiles_default"; Root = $updateRoot },
    @{ Source = "setup.core.ps1"; Destination = "setup.core.ps1"; Root = $updateRoot },
    @{ Source = "README.md"; Destination = "README.md"; Root = $updateRoot },
    @{ Source = ".gitignore"; Destination = ".gitignore"; Root = $updateRoot },
    @{ Source = ".markdownlint.json"; Destination = ".markdownlint.json"; Root = $updateRoot }
)

foreach ($item in $copyTargets) {
    $src = Join-Path $repoRoot $item.Source
    $dst = Join-Path $item.Root $item.Destination

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
    $tagVersion = if ($Version -match '^v') { $Version } else { "v$Version" }
    Set-Content -Path $versionFile -Value $tagVersion
    Write-Output "Wrote version: $versionFile"
}

if ($Zip) {
    $zipName = if ($Version) { "package_$Version.zip" } else { "package.zip" }
    $zipPath = Join-Path $buildRoot $zipName
    if (Test-Path $zipPath) {
        Remove-Item -Path $zipPath -Force
    }
    Compress-Archive -Path (Join-Path $buildRoot "*") -DestinationPath $zipPath -Force
    Write-Output "Created ZIP: $zipPath"
}
