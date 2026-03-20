param (
    [Parameter(Mandatory = $true)]
    [string]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-RepoRoot {
    $root = Join-Path $PSScriptRoot "..\.."
    return (Resolve-Path $root).Path
}

function Get-YamlSections {
    param (
        [Parameter(Mandatory = $true)]
        [string]$YamlPath
    )

    $lines = Get-Content -LiteralPath $YamlPath
    $sections = New-Object System.Collections.Generic.List[string]

    foreach ($line in $lines) {
        if ($line -match '^\s*#') { continue }
        if ($line -match '^[A-Za-z0-9_.-]+:\s*(#.*)?$') {
            $sections.Add($Matches[0].Split(':')[0].Trim())
        }
    }

    return $sections
}

$repoRoot = Resolve-RepoRoot
$yamlPath = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $repoRoot $Path }

if (-not (Test-Path -LiteralPath $yamlPath)) {
    throw "YAML file not found: $yamlPath"
}

$scripts = Get-ChildItem -Path $repoRoot -Recurse -File -Filter '*.ps1' | ForEach-Object {
    [IO.Path]::GetFileNameWithoutExtension($_.Name).ToLowerInvariant()
} | Sort-Object -Unique

$sections = Get-YamlSections -YamlPath $yamlPath
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
    Write-Error ("One or more YAML sections do not match an existing script: {0}" -f ($missing -join ', '))
    exit 1
}

Write-Output "All YAML sections match existing scripts."
exit 0
