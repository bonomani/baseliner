param (
    [string]$Replace
)

$Root = Get-Location | Select-Object -ExpandProperty Path
$Self = $MyInvocation.MyCommand.Definition
$New  = Join-Path $Root "update\setup.core.ps1"
$SetupFile = Join-Path $Root "data\db\setup.json"
$RepoWebBase = "https://github.com/bonomani/baseliner"
$LatestTagUrl = "$RepoWebBase/releases/latest/download/latest.txt"
$UpdateZipPath = Join-Path $Root "update\package.zip"
$DefaultCustomProfileZipUrl = "https://example.com/custom_profiles.zip"

# --- Self update ---
if ($Replace) {
    Copy-Item -Path $Self -Destination $Replace -Force
    Remove-Item -Path $Self -Force
    Write-Output "setup.core.ps1 updated"
    exit
}

if ((Test-Path $New) -and ($New -ne $Self)) {
    $currentHash = (Get-FileHash -Algorithm SHA256 -Path $Self).Hash.ToLower()
    $newHash = (Get-FileHash -Algorithm SHA256 -Path $New).Hash.ToLower()
    if ($currentHash -ne $newHash) {
        Write-Output "New version of setup.core.ps1 detected"
        Start-Process powershell -ArgumentList @(
            "-ExecutionPolicy", "Bypass",
            "-File", $New,
            "-Replace", $Self
        ) -Wait
        exit
    } else {
        Write-Output "setup.core.ps1 already up to date"
    }
}

# --- Update check (release + commit) ---
function Get-SetupState {
    if (-not (Test-Path $SetupFile)) {
        return @{}
    }
    try {
        return Get-JsonFile -Path $SetupFile
    } catch {
        return @{}
    }
}

function Get-Manifest {
    param ([string]$ManifestPath)
    if (-not (Test-Path $ManifestPath)) { return $null }
    try {
        return Get-JsonFile -Path $ManifestPath
    } catch {
        throw
    }
}

function Get-JsonFile {
    param ([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try {
        return Get-Content $Path -Raw | ConvertFrom-Json
    } catch {
        Write-Error "Invalid JSON in file: $Path"
        throw
    }
}

function Get-BackupPath {
    param ([switch]$Create)
    if (-not $script:BackupPath) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $script:BackupPath = Join-Path (Join-Path $Root "backup") $timestamp
    }
    if ($Create -and -not (Test-Path $script:BackupPath)) {
        New-Item -ItemType Directory -Force -Path $script:BackupPath | Out-Null
    }
    return $script:BackupPath
}

function Save-SetupState {
    param ($State)
    $setupDir = Split-Path -Parent $SetupFile
    if (-not (Test-Path $setupDir)) {
        New-Item -ItemType Directory -Force -Path $setupDir | Out-Null
    }
    $newJson = $State | ConvertTo-Json -Depth 10 -Compress
    if (Test-Path $SetupFile) {
        try {
            $oldJson = (Get-JsonFile -Path $SetupFile) | ConvertTo-Json -Depth 10 -Compress
            if ($oldJson -eq $newJson) {
                return
            }
        } catch {
            # If existing JSON is invalid, back it up and proceed.
        }
        $backupRoot = Get-BackupPath -Create
        $backupDb = Join-Path (Join-Path $backupRoot "data") "db"
        if (-not (Test-Path $backupDb)) {
            New-Item -ItemType Directory -Force -Path $backupDb | Out-Null
        }
        Copy-Item -Path $SetupFile -Destination (Join-Path $backupDb "setup.json") -Force
    }
    $tmp = Join-Path $setupDir ("setup_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".tmp")
    try {
        $newJson | Set-Content -Path $tmp
        Move-Item -Path $tmp -Destination $SetupFile -Force -ErrorAction Stop
    } catch {
        if (Test-Path $tmp) {
            Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Write-PrettyJsonFile {
    param (
        $Object,
        [string]$Path,
        [int]$Depth = 20
    )
    $json = $Object | ConvertTo-Json -Depth $Depth -Compress
    $pretty = Format-JsonString -Json $json -Indent 2
    Set-Content -Path $Path -Value $pretty
}

function ConvertTo-OrderedJsonObject {
    param ($Object)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Management.Automation.PSObject] -and $Object.BaseObject -is [string]) {
        return $Object.BaseObject
    }
    if ($Object -is [string] -or $Object -is [char]) {
        return $Object
    }
    if ($Object -is [System.Collections.IDictionary]) {
        $sorted = [ordered]@{}
        foreach ($key in ($Object.Keys | Sort-Object)) {
            $sorted[$key] = ConvertTo-OrderedJsonObject -Object $Object[$key]
        }
        return $sorted
    }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $sorted = [ordered]@{}
        foreach ($p in ($Object.PSObject.Properties.Name | Sort-Object)) {
            $sorted[$p] = ConvertTo-OrderedJsonObject -Object $Object.$p
        }
        return $sorted
    }
    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        $list = @()
        foreach ($item in $Object) {
            $list += ,(ConvertTo-OrderedJsonObject -Object $item)
        }
        return $list
    }
    $props = $Object.PSObject.Properties
    if ($props -and $props.Count -gt 0) {
        $sorted = [ordered]@{}
        foreach ($p in ($props.Name | Sort-Object)) {
            $sorted[$p] = ConvertTo-OrderedJsonObject -Object $Object.$p
        }
        return $sorted
    }
    return $Object
}

function ConvertTo-NormalizedJsonFile {
    param ([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $obj = Get-JsonFile -Path $Path
    return ConvertTo-OrderedJsonObject -Object $obj
}


function Show-ConfigDiff {
    param (
        [string]$OldPath,
        [string]$NewPath
    )
    if (-not (Test-Path $OldPath)) {
        Write-Output "No existing config to diff: $OldPath"
        return
    }
    if (-not (Test-Path $NewPath)) {
        Write-Output "No generated config to diff: $NewPath"
        return
    }
    $oldObj = ConvertTo-NormalizedJsonFile -Path $OldPath
    $newObj = ConvertTo-NormalizedJsonFile -Path $NewPath
    if ($null -eq $oldObj -or $null -eq $newObj) {
        Write-Output "Unable to normalize config for diff."
        return
    }
    $oldKeys = @($oldObj.Keys)
    $newKeys = @($newObj.Keys)
    $allKeys = @($oldKeys + $newKeys | Sort-Object -Unique)
    $changedKeys = @()
    foreach ($key in $allKeys) {
        if (-not $oldObj.Contains($key) -or -not $newObj.Contains($key)) {
            $changedKeys += $key
            continue
        }
        $oldKeyJson = ($oldObj[$key] | ConvertTo-Json -Depth 50 -Compress)
        $newKeyJson = ($newObj[$key] | ConvertTo-Json -Depth 50 -Compress)
        if ($oldKeyJson -ne $newKeyJson) {
            $changedKeys += $key
        }
    }
    if ($changedKeys.Count -gt 0) {
        Write-Output "Changed top-level keys:"
        $changedKeys | ForEach-Object { Write-Output "- $_" }
    }

    $oldJson = Format-JsonString -Json ($oldObj | ConvertTo-Json -Depth 50 -Compress) -Indent 2
    $newJson = Format-JsonString -Json ($newObj | ConvertTo-Json -Depth 50 -Compress) -Indent 2
    $oldLines = $oldJson -split "`r?`n"
    $newLines = $newJson -split "`r?`n"
    $diff = Compare-Object -ReferenceObject $oldLines -DifferenceObject $newLines
    if (-not $diff -or $diff.Count -eq 0) {
        Write-Output "No config changes detected."
        return $false
    }
    Write-Output "Config diff (<= current, => new):"
    $diff | ForEach-Object { Write-Output ("{0} {1}" -f $_.SideIndicator, $_.InputObject) }
    return $true
}

function Format-JsonString {
    param (
        [string]$Json,
        [int]$Indent = 2
    )
    $sb = New-Object System.Text.StringBuilder
    $level = 0
    $inString = $false
    $escape = $false

    foreach ($ch in $Json.ToCharArray()) {
        if ($escape) {
            [void]$sb.Append($ch)
            $escape = $false
            continue
        }
        if ($ch -eq '\') {
            [void]$sb.Append($ch)
            $escape = $true
            continue
        }
        if ($ch -eq '"') {
            $inString = -not $inString
            [void]$sb.Append($ch)
            continue
        }
        if ($inString) {
            [void]$sb.Append($ch)
            continue
        }

        switch ($ch) {
            '{' {
                [void]$sb.Append($ch)
                $level++
                [void]$sb.Append("`n" + (" " * ($level * $Indent)))
            }
            '[' {
                [void]$sb.Append($ch)
                $level++
                [void]$sb.Append("`n" + (" " * ($level * $Indent)))
            }
            '}' {
                $level--
                [void]$sb.Append("`n" + (" " * ($level * $Indent)) + $ch)
            }
            ']' {
                $level--
                [void]$sb.Append("`n" + (" " * ($level * $Indent)) + $ch)
            }
            ',' {
                [void]$sb.Append($ch)
                [void]$sb.Append("`n" + (" " * ($level * $Indent)))
            }
            ':' {
                [void]$sb.Append(": ")
            }
            default {
                if (-not [char]::IsWhiteSpace($ch)) {
                    [void]$sb.Append($ch)
                }
            }
        }
    }
    return $sb.ToString()
}
function Set-SetupStateValue {
    param (
        $State,
        [string]$Name,
        $Value
    )
    if ($State -is [hashtable]) {
        $State[$Name] = $Value
        return
    }
    if ($State.PSObject.Properties[$Name]) {
        $State.$Name = $Value
        return
    }
    $State | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function Copy-UpdatePayloadFromZip {
    param (
        [string]$ZipPath,
        [string]$DestinationPath
    )
    if (-not (Test-Path $ZipPath)) { return $false }

    $tempRoot = Join-Path $Root ("update_extract_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    try {
        Expand-Archive -Path $ZipPath -DestinationPath $tempRoot -Force
        $updateSource = Get-ChildItem -Path $tempRoot -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq "update" } |
            Select-Object -First 1
        if (-not $updateSource) {
            throw "Update folder not found in package"
        }
        if (-not (Test-Path $DestinationPath)) {
            New-Item -ItemType Directory -Force -Path $DestinationPath | Out-Null
        }
        Get-ChildItem -Path $DestinationPath -Force -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-Item -Path $_.FullName -Recurse -Force
        }
        Copy-Item -Path (Join-Path $updateSource.FullName "*") -Destination $DestinationPath -Recurse -Force -ErrorAction Stop
        return $true
    } finally {
        if (Test-Path $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Copy-RootFilesFromUpdateIfChanged {
    param (
        [string]$UpdateRoot,
        [string]$DestinationRoot
    )
    $files = @("setup.core.ps1", "setup.ps1", "README.md", ".gitignore", ".markdownlint.json")
    foreach ($file in $files) {
        $src = Join-Path $UpdateRoot $file
        if (-not (Test-Path $src)) { continue }
        $dst = Join-Path $DestinationRoot $file
        if (Test-Path $dst) {
            $srcHash = (Get-FileHash -Algorithm SHA256 -Path $src).Hash.ToLower()
            $dstHash = (Get-FileHash -Algorithm SHA256 -Path $dst).Hash.ToLower()
            if ($srcHash -eq $dstHash) { continue }
        }
        Copy-Item -Path $src -Destination $dst -Force
    }
}

function Get-LatestTag {
    if (-not $LatestTagUrl) { return $null }
    try {
        $tmp = Join-Path $Root ("latest_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".tmp")
        Invoke-WebRequest -Uri $LatestTagUrl -OutFile $tmp -UseBasicParsing
        $content = Get-Content -Path $tmp -Raw
        if (Test-Path $tmp) { Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue }
        if ($null -eq $content) { return $null }
        $tag = ($content -replace '^\uFEFF', '').Trim()
        if (-not $tag) { return $null }
        return $tag
    } catch {
        throw
    }
}

function Invoke-UpdateZipDownload {
    param ([string]$Url)
    if (Test-Path $UpdateZipPath) {
        Remove-Item -Path $UpdateZipPath -Force
    }
    Invoke-WebRequest -Uri $Url -OutFile $UpdateZipPath -UseBasicParsing
}

function Invoke-UpdateShaDownload {
    param ([string]$Url)
    $shaPath = "$UpdateZipPath.sha256"
    if (Test-Path $shaPath) {
        Remove-Item -Path $shaPath -Force
    }
    Invoke-WebRequest -Uri $Url -OutFile $shaPath -UseBasicParsing
    return $shaPath
}

function Read-HashFromFile {
    param ([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $content = (Get-Content -Path $Path -Raw)
    $content = $content -replace '^\uFEFF', ''
    $content = $content.Trim()
    if (-not $content) { return $null }
    $firstToken = $content -split '\s+' | Select-Object -First 1
    return $firstToken.ToLower()
}

$setupState = Get-SetupState
$latestTag = $null
try {
    $latestTag = Get-LatestTag
} catch {
    Write-Output ("Update check failed (network). Continuing. Details: {0}" -f $_.Exception.Message)
}

if ($latestTag) {
    $releaseTag = $latestTag
    $isNewRelease = $releaseTag -and ($releaseTag -ne $setupState.CoreReleaseTag)
    $updateVersionPath = Join-Path $Root "update\VERSION.txt"
    $hasMatchingUpdateVersion = $false
    if (Test-Path $updateVersionPath) {
        $localVersion = (Get-Content -Path $updateVersionPath -Raw).Trim()
        if ($localVersion -and ($localVersion -eq $releaseTag)) {
            $hasMatchingUpdateVersion = $true
        }
    }

    if ($hasMatchingUpdateVersion) {
        Write-Output "Update already present (VERSION.txt matches latest tag)."
        Set-SetupStateValue -State $setupState -Name "CoreReleaseTag" -Value $releaseTag
        Set-SetupStateValue -State $setupState -Name "CoreCommitSha" -Value $null
        Save-SetupState -State $setupState
    } elseif ($isNewRelease) {
        Write-Output "Update available (release). Downloading..."
        $zipName = "package_$releaseTag.zip"
        $zipUrl = "$RepoWebBase/releases/download/$releaseTag/$zipName"
        $shaUrl = "$zipUrl.sha256"
        Write-Output "Update ZIP URL: $zipUrl"
        Write-Output "Update SHA URL: $shaUrl"
        Invoke-UpdateZipDownload -Url $zipUrl
        $shaPath = Invoke-UpdateShaDownload -Url $shaUrl
        $expectedHash = Read-HashFromFile -Path $shaPath
        if (-not $expectedHash) {
            Write-Error "SHA256 file is empty or invalid. Aborting update."
            exit 1
        }
        $actualHash = (Get-FileHash -Algorithm SHA256 -Path $UpdateZipPath).Hash.ToLower()
        if ($expectedHash -ne $actualHash) {
            Write-Error "Update ZIP hash mismatch. Aborting update."
            exit 1
        }
        if (Copy-UpdatePayloadFromZip -ZipPath $UpdateZipPath -DestinationPath (Join-Path $Root "update")) {
            Copy-RootFilesFromUpdateIfChanged -UpdateRoot (Join-Path $Root "update") -DestinationRoot $Root
            Set-SetupStateValue -State $setupState -Name "CoreReleaseTag" -Value $releaseTag
            Set-SetupStateValue -State $setupState -Name "CoreCommitSha" -Value $null
            Save-SetupState -State $setupState
            Write-Output "Core update applied. Please re-run setup."
            exit
        }
    }
}

# --- Paths ---
$AppPath        = Join-Path $Root "app"
$UpdateAppPath  = Join-Path $Root "update\app"
$TestPath       = Join-Path $Root "test"
$UpdateTestPath = Join-Path $Root "update\test"
$CustomProfilesPath = Join-Path $Root "profiles_custom"
$DefaultProfilesPath = Join-Path $Root "profiles_default"
$UpdateProfilesPath = Join-Path $Root "update\profiles_default"
$DataPath       = Join-Path $Root "data"
$DataResPath    = Join-Path $DataPath "resources"

function Resolve-ProfilesPath {
    if (Test-Path $CustomProfilesPath) {
        $customHasManifest = Get-ChildItem -Path $CustomProfilesPath -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName "manifest.json") } |
            Select-Object -First 1
        if ($customHasManifest) { return $CustomProfilesPath }
    }
    return $DefaultProfilesPath
}

function Get-ProfilesFromPath {
    param (
        [string]$ProfilesPath,
        [string]$Source
    )
    if (-not (Test-Path $ProfilesPath)) { return @() }
    return @(Get-ChildItem -Path $ProfilesPath -Directory -ErrorAction SilentlyContinue | Where-Object {
        Test-Path (Join-Path $_.FullName "manifest.json")
    } | ForEach-Object {
        [pscustomobject]@{
            Name     = $_.Name
            FullName = $_.FullName
            Source   = $Source
        }
    })
}

function Resolve-IncludePath {
    param (
        [string]$ProfilePath,
        [string]$IncludePath
    )
    $clean = $IncludePath.Trim()
    $normalized = $clean -replace '/', '\'
    if ([System.IO.Path]::IsPathRooted($normalized)) { return $normalized }
    if ($normalized -match '^[.]{1,2}[\\/]' ) { return Join-Path $ProfilePath $normalized }
    if ([regex]::IsMatch($normalized, '^(update|profiles_custom|profiles_default|data)[\\/]', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        return Join-Path $Root $normalized
    }
    return Join-Path $ProfilePath $normalized
}

function Move-Atomic {
    param (
        [string]$StagingPath,
        [string]$DestinationPath,
        [string]$BackupPath
    )
    try {
        if (Test-Path $DestinationPath) {
            if (Test-Path $BackupPath) {
                Remove-Item -Path $BackupPath -Recurse -Force -ErrorAction Stop
            }
            Move-Item -Path $DestinationPath -Destination $BackupPath -Force -ErrorAction Stop
        }
        Move-Item -Path $StagingPath -Destination $DestinationPath -Force -ErrorAction Stop
    } catch {
        if (Test-Path $StagingPath) {
            Remove-Item -Path $StagingPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $BackupPath -and -not (Test-Path $DestinationPath)) {
            Move-Item -Path $BackupPath -Destination $DestinationPath -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Sync-DefaultProfilesFromUpdateAtomic {
    if (-not (Test-Path $UpdateProfilesPath)) { return }
    $items = Get-ChildItem -Path $UpdateProfilesPath -Force -ErrorAction SilentlyContinue
    if (-not $items -or $items.Count -eq 0) { return }

    $staging = Join-Path $Root ("profiles_default_staging_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
    $backup = Join-Path (Get-BackupPath -Create) "profiles_default"
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    Copy-Item -Path (Join-Path $UpdateProfilesPath "*") -Destination $staging -Recurse -Force -ErrorAction Stop
    Move-Atomic -StagingPath $staging -DestinationPath $DefaultProfilesPath -BackupPath $backup
}

function Resolve-SelectedProfileSource {
    param ([string]$ProfileName)
    if (-not $ProfileName) { return $null }
    $customManifest = Join-Path (Join-Path $CustomProfilesPath $ProfileName) "manifest.json"
    if (Test-Path $customManifest) { return "profiles_custom" }
    $updateManifest = Join-Path (Join-Path $DefaultProfilesPath $ProfileName) "manifest.json"
    if (Test-Path $updateManifest) { return "profiles_default" }
    return $null
}

function Get-AvailableProfiles {
    $profiles = @()
    if (Test-Path $CustomProfilesPath) {
        $profiles += Get-ChildItem -Path $CustomProfilesPath -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $manifestPath = Join-Path $_.FullName "manifest.json"
                if (Test-Path $manifestPath) {
                    [pscustomobject]@{ Name = $_.Name; FullName = $_.FullName; Source = "profiles_custom" }
                }
            }
    }
    if (Test-Path $DefaultProfilesPath) {
        $profiles += Get-ChildItem -Path $DefaultProfilesPath -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $manifestPath = Join-Path $_.FullName "manifest.json"
                if (Test-Path $manifestPath) {
                    [pscustomobject]@{ Name = $_.Name; FullName = $_.FullName; Source = "profiles_default" }
                }
            }
    }
    return @($profiles)
}

function Invoke-CustomProfileDownload {
    param (
        [string]$ZipUrl,
        [string]$ExpectedSha256
    )
    if (-not (Test-Path $CustomProfilesPath)) {
        New-Item -ItemType Directory -Force -Path $CustomProfilesPath | Out-Null
    }
    $zipPath = Join-Path $CustomProfilesPath "custom_profiles.zip"
    if (Test-Path $zipPath) { Remove-Item -Path $zipPath -Force }
    Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -UseBasicParsing

    $actual = (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash.ToLower()
    if ($actual -ne $ExpectedSha256.ToLower()) {
        Write-Error "Custom profile ZIP hash mismatch"
        throw "Custom profile ZIP hash mismatch"
    }

    Get-ChildItem -Path $CustomProfilesPath -Force | ForEach-Object {
        if ($_.FullName -ne $zipPath) {
            Remove-Item -Path $_.FullName -Recurse -Force
        }
    }

    Expand-Archive -Path $zipPath -DestinationPath $CustomProfilesPath -Force
}

function Merge-ConfigFirstLevel {
    param (
        [hashtable]$Target,
        $Source
    )
    if ($null -eq $Source) { return }
    if ($Source -is [hashtable]) {
        foreach ($key in $Source.Keys) {
            $Target[$key] = $Source[$key]
        }
        return
    }
    foreach ($prop in $Source.PSObject.Properties) {
        $Target[$prop.Name] = $prop.Value
    }
}

function Get-ConfigFromManifest {
    param ([string]$ProfilePath)
    $manifestPath = Join-Path $ProfilePath "manifest.json"
    if (-not (Test-Path $manifestPath)) {
        return $null
    }
    $manifest = Get-Manifest -ManifestPath $manifestPath
    $config = @{}
    if ($manifest.configIncludes) {
        Write-Host "Config includes:"
        foreach ($include in $manifest.configIncludes) {
            $includePath = Resolve-IncludePath -ProfilePath $ProfilePath -IncludePath $include
            Write-Host "- $includePath"
            if (-not (Test-Path $includePath)) {
                Write-Error "Config include not found: $includePath"
                throw "Config include not found"
            }
            $fragment = Get-JsonFile -Path $includePath
            Merge-ConfigFirstLevel -Target $config -Source $fragment
        }
    }
    return $config
}


function Write-ConfigAtomic {
    param (
        [string]$ProfilePath,
        [string]$DestinationConfig
    )
    $config = Get-ConfigFromManifest -ProfilePath $ProfilePath
    if ($null -eq $config) { return $false }
    $tmp = Join-Path $DataPath ("config_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".tmp")
    Write-PrettyJsonFile -Object $config -Path $tmp -Depth 20
    try {
        if (Test-Path $DestinationConfig) {
            $backupConfig = Join-Path (Join-Path (Get-BackupPath -Create) "data") "config.json"
            $backupDir = Split-Path -Parent $backupConfig
            if (-not (Test-Path $backupDir)) {
                New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
            }
            Copy-Item -Path $DestinationConfig -Destination $backupConfig -Force
        }
        Move-Item -Path $tmp -Destination $DestinationConfig -Force -ErrorAction Stop
    } catch {
        if (Test-Path $tmp) {
            Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    return $true
}

function New-ResourcesToPath {
    param (
        [string]$ProfilePath,
        [string]$DestinationRoot
    )
    $manifestPath = Join-Path $ProfilePath "manifest.json"
    if (-not (Test-Path $manifestPath)) { return $false }
    $manifest = Get-Manifest -ManifestPath $manifestPath
    if (-not $manifest.resourceIncludes) { return $true }
    foreach ($res in $manifest.resourceIncludes) {
        $resPath = Resolve-IncludePath -ProfilePath $ProfilePath -IncludePath $res
        if (-not (Test-Path $resPath)) {
            Write-Error "Resource include not found: $resPath"
            throw
        }
        if (Test-Path $resPath -PathType Container) {
            Get-ChildItem -Path $resPath -Force | ForEach-Object {
                Copy-Item -Path $_.FullName -Destination $DestinationRoot -Recurse -Force -ErrorAction Stop
            }
        } else {
            Copy-Item -Path $resPath -Destination $DestinationRoot -Force -ErrorAction Stop
        }
    }
    return $true
}

function Sync-ResourcesAtomic {
    param (
        [string]$ProfilePath,
        [string]$DestinationRoot
    )
    $staging = Join-Path $Root ("resources_staging_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
    $backup = Join-Path (Join-Path (Get-BackupPath -Create) "data") "resources"
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        if (-not (New-ResourcesToPath -ProfilePath $ProfilePath -DestinationRoot $staging)) {
            return $false
        }
        Move-Atomic -StagingPath $staging -DestinationPath $DestinationRoot -BackupPath $backup
    } catch {
        throw
    }
    return $true
}

function Read-CustomProfileDownloadDecision {
    param (
        [string]$Phase,
        $SetupState
    )
    $prompt = if ($Phase -eq "INSTALL") {
        "Download custom profiles now?"
    } else {
        "Check for custom profile update?"
    }
    $confirm = Read-YesNoDecision -Prompt $prompt
    if (-not $confirm) { return }

    $defaultUrl = if ($SetupState.CustomProfileZipUrl) { $SetupState.CustomProfileZipUrl } else { $DefaultCustomProfileZipUrl }
    $zipUrl = Read-Host "Custom profile ZIP URL (blank = default)"
    if (-not $zipUrl) { $zipUrl = $defaultUrl }

    $expected = Read-Host "Expected SHA256 (required)"
    if (-not $expected) {
        Write-Error "SHA256 required"
        throw
    }

    if ($SetupState.CustomProfileZipSha256 -and ($expected.ToLower() -eq $SetupState.CustomProfileZipSha256.ToLower())) {
        Write-Output "Custom profile hash matches stored value; no update needed."
        return
    }

    Invoke-CustomProfileDownload -ZipUrl $zipUrl -ExpectedSha256 $expected
    $SetupState.CustomProfileZipUrl = $zipUrl
    $SetupState.CustomProfileZipSha256 = $expected
    $SetupState.LastProfileUpdateUtc = (Get-Date).ToString("o")
    Save-SetupState -State $SetupState
}

Write-Output "=== Setup ==="
Write-Output "Directory: $Root"
Write-Output ""

if (-not (Test-Path (Join-Path $Root "update"))) {
    Write-Error "update directory not found"
    throw
}

function Get-PayloadInfo {
    param (
        [string]$UpdatePath,
        [string]$NestedName
    )
    $root = $UpdatePath
    $nested = Join-Path $UpdatePath $NestedName
    if (Test-Path $nested) { $root = $nested }
    $items = @()
    if (Test-Path $root) {
        $items = Get-ChildItem -Path $root -Force -ErrorAction SilentlyContinue
    }
    return [pscustomobject]@{
        Root  = $root
        Items = $items
    }
}

function Sync-DefaultProfilesIfPresent {
    if (-not (Test-Path $UpdateProfilesPath)) { return }
    $updateProfileItems = Get-ChildItem -Path $UpdateProfilesPath -Force -ErrorAction SilentlyContinue
    if ($updateProfileItems -and $updateProfileItems.Count -gt 0) {
        try {
            Sync-DefaultProfilesFromUpdateAtomic
            Clear-PayloadFolder -Path $UpdateProfilesPath
        } catch {
            Write-Error "Default profile sync failed: $($_.Exception.Message)"
            throw
        }
    } else {
        Write-Output "Profiles sync skipped (no update profiles)"
    }
}

function Select-ProfileAndUpdateState {
    param (
        $SetupState,
        [array]$Profiles,
        [string]$CurrentName,
        [string]$CurrentSource
    )
    if (-not $Profiles -or $Profiles.Count -eq 0) {
        Write-Error "No profiles found"
        throw
    }
    $selected = Select-Profile -Profiles $Profiles -CurrentName $CurrentName -CurrentSource $CurrentSource
    Set-SetupStateValue -State $SetupState -Name "SelectedProfileName" -Value $selected.Name
    Set-SetupStateValue -State $SetupState -Name "SelectedProfileSource" -Value $selected.Source
    return $selected
}

# --- Resolve real payload root (avoid app/app or test/test) ---
$appPayloadInfo = Get-PayloadInfo -UpdatePath $UpdateAppPath -NestedName "app"
$testPayloadInfo = Get-PayloadInfo -UpdatePath $UpdateTestPath -NestedName "test"
$AppPayloadRoot = $appPayloadInfo.Root
$TestPayloadRoot = $testPayloadInfo.Root
$AppPayloadItems = $appPayloadInfo.Items
$TestPayloadItems = $testPayloadInfo.Items

$HasPayload = ($AppPayloadItems -and $AppPayloadItems.Count -gt 0) -or
              ($TestPayloadItems -and $TestPayloadItems.Count -gt 0)
if (-not $HasPayload) {
    Write-Output "No application or test payload found (expected after cleanup/install)."
}

# --- Safe deploy function (content only) ---
function Copy-PayloadContent {
    param (
        [string]$Source,
        [string]$Destination
    )

    Get-ChildItem -Path $Source -Force | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination $Destination -Force -Recurse -ErrorAction Stop
    }
}

function Copy-PayloadAtomic {
    param (
        [string]$Source,
        [string]$Destination,
        [string]$BackupPath
    )
    $staging = Join-Path $Root ("staging_" + [IO.Path]::GetFileName($Destination) + "_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    try {
        Copy-PayloadContent -Source $Source -Destination $staging
        if ($BackupPath) {
            $backupDir = Split-Path -Parent $BackupPath
            if ($backupDir -and -not (Test-Path $backupDir)) {
                New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
            }
        }
        Move-Atomic -StagingPath $staging -DestinationPath $Destination -BackupPath $BackupPath
    } catch {
        if (Test-Path $staging) {
            Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Clear-PayloadFolder {
    param ([string]$Path)
    if (-not (Test-Path $Path)) { return }
    $items = Get-ChildItem -Path $Path -Force -ErrorAction SilentlyContinue
    foreach ($item in $items) {
        try {
            Remove-Item -Path $item.FullName -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Error "Cleanup failed for: $($item.FullName) - $($_.Exception.Message)"
            throw
        }
    }
}

function Clear-UpdatePayload {
    $updatePath = Join-Path $Root "update"
    Clear-PayloadFolder -Path $updatePath
    $remaining = Get-ChildItem -Path $updatePath -Force -ErrorAction SilentlyContinue
    if ($remaining -and $remaining.Count -gt 0) {
        Write-Error "Update cleanup incomplete; remaining items detected."
        $remaining | ForEach-Object { Write-Error "- $($_.FullName)" }
        throw "Update cleanup failed"
    }
}

function Select-Profile {
    param (
        [array]$Profiles,
        [string]$CurrentName,
        [string]$CurrentSource
    )
    if (-not $Profiles -or $Profiles.Count -eq 0) {
        Write-Error "No profiles found"
        throw
    }
    Write-Host "Available profiles:"
    $i = 0
    foreach ($profileItem in $Profiles) {
        $isCurrentName = $CurrentName -and ($profileItem.Name -eq $CurrentName)
        $isCurrentSource = $CurrentSource -and ($profileItem.Source -eq $CurrentSource)
        $current = if ($isCurrentName -and $isCurrentSource) { " (current)" } else { "" }
        if ($profileItem.Source) {
            Write-Host "[$i] $($profileItem.Name) [$($profileItem.Source)]$current"
        } else {
            Write-Host "[$i] $($profileItem.Name)$current"
        }
        $i++
    }
    $idx = Read-Host "Select profile index"
    if ($idx -notmatch '^\d+$' -or [int]$idx -ge $i) {
        Write-Error "Invalid profile selection"
        throw
    }
    return @($Profiles)[[int]$idx]
}

function Read-YesNoDecision {
    param (
        [string]$Prompt,
        [string]$Default = "NO"
    )
    $defaultLabel = if ($Default -match '^(?i:y|yes)$') { "y" } else { "no" }
    $response = Read-Host ("{0} [default: {1}]" -f $Prompt, $defaultLabel)
    if (-not $response) { $response = $Default }
    return $response -match '^(?i:y|yes)$'
}

# ==================================================
# INSTALL
# ==================================================
# Note: INSTALL requires payload and creates the custom profile scaffold; UPDATE does not.
if (-not (Test-Path $AppPath)) {
    Write-Output "Action detected: INSTALL"
    if (-not $HasPayload) {
        Write-Error "No payload available for install"
        throw
    }
    $setupState = Get-SetupState
    Read-CustomProfileDownloadDecision -Phase "INSTALL" -SetupState $setupState
    Sync-DefaultProfilesIfPresent

    $ProfilesPath = Resolve-ProfilesPath
    Write-Output "Profiles root: $ProfilesPath"

    if (-not (Test-Path $ProfilesPath) -and (Test-Path $UpdateProfilesPath)) {
        $ProfilesPath = $UpdateProfilesPath
        Write-Output "Profiles root (update): $ProfilesPath"
    }

    if (-not (Test-Path $ProfilesPath)) {
        Write-Error "No profiles directory found: $ProfilesPath"
        throw
    }

    $availableProfiles = Get-AvailableProfiles
    $selectedProfile = Select-ProfileAndUpdateState -SetupState $setupState -Profiles $availableProfiles
    $ProfilePath = $selectedProfile.FullName
    Write-Output "Selected profile path: $ProfilePath"
    $ProfileManifest = Join-Path $ProfilePath "manifest.json"
    if (-not (Test-Path $ProfileManifest)) {
        Write-Error "manifest.json missing in selected profile"
        throw
    }

    $confirm = Read-YesNoDecision -Prompt "Confirm installation in this directory?"
    if (-not $confirm) {
        exit 0
    }

    # Create structure
    New-Item -ItemType Directory -Force -Path $DataPath | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $DataPath "db")   | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $DataPath "logs") | Out-Null

    # Create custom profile scaffold (empty by default)
    $DefaultProfile = Join-Path $CustomProfilesPath "default"
    $DefaultResources = Join-Path $DefaultProfile "resources"
    $ReadmePath = Join-Path $CustomProfilesPath "README.txt"

    New-Item -ItemType Directory -Force -Path $DefaultResources | Out-Null
    if (-not (Test-Path $ReadmePath)) {
        @'
profiles_custom is optional.
Create profiles_custom\<name>\manifest.json to override profiles_default.
If no manifest.json exists under profiles_custom, setup uses profiles_default.
'@ | Set-Content -Path $ReadmePath
    }

    # Apply profile (ONCE)
    $ConfigOut = Join-Path $DataPath "config.json"
    $usedManifest = Write-ConfigAtomic -ProfilePath $ProfilePath -DestinationConfig $ConfigOut
    if (-not $usedManifest) {
        Write-Error "manifest.json missing or invalid in selected profile"
        throw
    }
    try {
        $resApplied = Sync-ResourcesAtomic -ProfilePath $ProfilePath -DestinationRoot $DataResPath
        if (-not $resApplied) {
            Write-Error "manifest.json missing or invalid in selected profile"
            throw
        }
    } catch {
        Write-Error "Resource sync failed: $($_.Exception.Message)"
        throw
    }

    # Deploy app/test (atomic)
    try {
        if ($AppPayloadItems -and $AppPayloadItems.Count -gt 0) {
            Copy-PayloadAtomic -Source $AppPayloadRoot -Destination $AppPath -BackupPath (Join-Path (Get-BackupPath -Create) "app")
        }

        if ($TestPayloadItems -and $TestPayloadItems.Count -gt 0) {
            Copy-PayloadAtomic -Source $TestPayloadRoot -Destination $TestPath -BackupPath (Join-Path (Get-BackupPath -Create) "test")
        }
    } catch {
        Write-Error "Payload deploy failed: $($_.Exception.Message)"
        throw
    }

    Clear-PayloadFolder -Path (Join-Path $Root "update")

    Save-SetupState -State $setupState

    Write-Output "Installation completed"
    exit
}

# ==================================================
# UPDATE
# ==================================================
Write-Output "Action detected: UPDATE"

$setupState = Get-SetupState
$updateSucceeded = $false
$needsSave = $false

# Prefer update profiles if present; otherwise use existing profiles_default.
Sync-DefaultProfilesIfPresent
    if ($setupState.SelectedProfileName) {
        if ($setupState.SelectedProfileSource) {
            Write-Output "Selected profile: $($setupState.SelectedProfileName) [$($setupState.SelectedProfileSource)]"
        } else {
            Write-Output "Selected profile: $($setupState.SelectedProfileName)"
        }
    }
if ($setupState.SelectedProfileSource -eq "update") {
    Set-SetupStateValue -State $setupState -Name "SelectedProfileSource" -Value "profiles_default"
    $needsSave = $true
}
if ($setupState.SelectedProfileSource -eq "custom") {
    Set-SetupStateValue -State $setupState -Name "SelectedProfileSource" -Value "profiles_custom"
    $needsSave = $true
}
if ($setupState.SelectedProfileName -and -not $setupState.SelectedProfileSource) {
    $resolvedSource = Resolve-SelectedProfileSource -ProfileName $setupState.SelectedProfileName
    if ($resolvedSource) {
        Set-SetupStateValue -State $setupState -Name "SelectedProfileSource" -Value $resolvedSource
        $needsSave = $true
    }
}
if ($setupState.SelectedProfileName) {
    $changeProfile = Read-YesNoDecision -Prompt "Update profile?"
    if ($changeProfile) {
        $availableProfiles = Get-AvailableProfiles
        $selected = Select-ProfileAndUpdateState -SetupState $setupState -Profiles $availableProfiles -CurrentName $setupState.SelectedProfileName -CurrentSource $setupState.SelectedProfileSource
        $needsSave = $true
    }
}
if (-not $setupState.SelectedProfileName) {
    $availableProfiles = Get-AvailableProfiles
    $selected = Select-ProfileAndUpdateState -SetupState $setupState -Profiles $availableProfiles
    $needsSave = $true
}
Read-CustomProfileDownloadDecision -Phase "UPDATE" -SetupState $setupState
$ProfilesPath = if ($setupState.SelectedProfileSource -eq "profiles_custom") { $CustomProfilesPath } `
    elseif ($setupState.SelectedProfileSource -eq "profiles_default") { $DefaultProfilesPath } `
    else { Resolve-ProfilesPath }
Write-Output "Profiles root: $ProfilesPath"

$SelectedProfile = $setupState.SelectedProfileName
$SelectedPath = Join-Path $ProfilesPath $SelectedProfile
if ($setupState.SelectedProfileName) {
    Write-Output "Selected profile path: $SelectedPath"
}
if (Test-Path $SelectedPath) {
    $ConfigOut = Join-Path $DataPath "config.json"
    $ConfigPreview = Join-Path $DataPath ("config.preview_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".tmp")
    $previewConfig = Get-ConfigFromManifest -ProfilePath $SelectedPath
    if ($null -eq $previewConfig) {
        Write-Error "manifest.json missing or invalid in selected profile"
        throw
    }
    Write-PrettyJsonFile -Object $previewConfig -Path $ConfigPreview -Depth 20
    $hasConfigChanges = $false
    try {
        $hasConfigChanges = Show-ConfigDiff -OldPath $ConfigOut -NewPath $ConfigPreview
    } finally {
        if (Test-Path $ConfigPreview) {
            Remove-Item -Path $ConfigPreview -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $hasConfigChanges) {
        Write-Output "Config unchanged; skipping profile apply."
        goto UpdatePayload
    }

    $confirm = Read-YesNoDecision -Prompt "Confirm update?"
    if (-not $confirm) {
        exit 0
    }

    $usedManifest = Write-ConfigAtomic -ProfilePath $SelectedPath -DestinationConfig $ConfigOut
    if (-not $usedManifest) {
        Write-Error "manifest.json missing or invalid in selected profile"
        throw
    }
    try {
        $resApplied = Sync-ResourcesAtomic -ProfilePath $SelectedPath -DestinationRoot $DataResPath
        if (-not $resApplied) {
            Write-Error "manifest.json missing or invalid in selected profile"
            throw
        }
    } catch {
        Write-Error "Resource sync failed: $($_.Exception.Message)"
        throw
    }
    Write-Output "Profile applied: $SelectedProfile -> $ConfigOut"
} else {
    Write-Error "Selected profile not found: $SelectedPath"
    throw
}

:UpdatePayload
    if ($HasPayload) {
        try {
            if ($AppPayloadItems -and $AppPayloadItems.Count -gt 0) {
            Copy-PayloadAtomic -Source $AppPayloadRoot -Destination $AppPath -BackupPath (Join-Path (Get-BackupPath -Create) "app")
            }

            if ($TestPayloadItems -and $TestPayloadItems.Count -gt 0) {
            Copy-PayloadAtomic -Source $TestPayloadRoot -Destination $TestPath -BackupPath (Join-Path (Get-BackupPath -Create) "test")
            }
        } catch {
            Write-Error "Payload deploy failed: $($_.Exception.Message)"
            throw
        }
} else {
    Write-Output "No payload to deploy; profile/config update only"
}

$updateSucceeded = $true
if ($updateSucceeded) {
    if ($needsSave) {
        Save-SetupState -State $setupState
    }
    Clear-UpdatePayload
    Write-Output "Cleanup completed"
}

Write-Output "Update completed"
