param (
    [string]$Path = "profiles_default/Windows_default/config.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoRoot {
    $root = Join-Path $PSScriptRoot "..\.."
    return (Resolve-Path $root).Path
}

function Get-SectionsFromJson {
    param (
        [Parameter(Mandatory = $true)]
        [string]$JsonPath
    )

    $json = Get-Content -LiteralPath $JsonPath -Raw | ConvertFrom-Json
    return @($json.PSObject.Properties.Name)
}

$repoRoot = Resolve-RepoRoot
$jsonPath = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $repoRoot $Path }

if (-not (Test-Path -LiteralPath $jsonPath)) {
    throw "JSON file not found: $jsonPath"
}

$scriptsRoot = Join-Path $repoRoot "app"
$scripts = if (Test-Path -LiteralPath $scriptsRoot) {
    Get-ChildItem -Path $scriptsRoot -Recurse -File -Filter '*.ps1' | ForEach-Object {
        [IO.Path]::GetFileNameWithoutExtension($_.Name).ToLowerInvariant()
    } | Sort-Object -Unique
} else {
    @()
}

$sections = Get-SectionsFromJson -JsonPath $jsonPath
$missing = New-Object System.Collections.Generic.List[string]

foreach ($section in $sections) {
    $normalized = $section.ToLowerInvariant()
    $sectionExists = $scripts -contains $normalized
    if (-not $sectionExists) {
        $missing.Add($section)
        Write-Output "MISSING: $section"
    } else {
        Write-Output "OK: $section"
    }
}

if ($missing.Count -gt 0) {
    Write-Error ("One or more JSON sections do not match an existing script: {0}" -f ($missing -join ', '))
    exit 1
}

Write-Output "All JSON sections match existing scripts."
exit 0
