param (
    [string]$Replace,
    [switch]$ForceUpdate
)

$Root = Get-Location | Select-Object -ExpandProperty Path
$Self = $PSCommandPath
$RepoWebBase = "https://github.com/bonomani/baseliner"
$LatestTagUrl = "$RepoWebBase/releases/latest/download/latest.txt"
$DefaultCustomProfileZipUrl = "https://example.com/custom_profiles.zip"

function Join-PathParts {
    param (
        [string]$Base,
        [string[]]$Parts
    )
    $path = $Base
    foreach ($part in $Parts) {
        $path = Join-Path $path $part
    }
    return $path
}

$New  = Join-PathParts -Base $Root -Parts @("update", "root", "setup.core.ps1")
$SetupFile = Join-PathParts -Base $Root -Parts @("data", "db", "setup.json")
$UpdateZipPath = Join-PathParts -Base $Root -Parts @("update", "package.zip")

# --- Self update ---
if ($Replace) {
    Copy-Item -Path $Self -Destination $Replace -Force
    Remove-Item -Path $Self -Force
    Write-Host "setup.core.ps1 updated"
    exit
}

if ((Test-Path $New) -and ($New -ne $Self)) {
    $currentHash = (Get-FileHash -Algorithm SHA256 -Path $Self).Hash.ToLower()
    $newHash = (Get-FileHash -Algorithm SHA256 -Path $New).Hash.ToLower()
    if ($currentHash -ne $newHash) {
        Write-Host "New version of setup.core.ps1 detected"
        Start-Process powershell -ArgumentList @(
            "-ExecutionPolicy", "Bypass",
            "-File", $New,
            "-Replace", $Self
        ) -Wait
        exit
    } else {
        Write-Host "setup.core.ps1 already up to date"
    }
}

# --- Update check (release + commit) ---
#region JSON Utilities
function Read-JsonFileSafe {
    param (
        [string]$Path,
        $Default = $null
    )
    if (-not (Test-Path $Path)) {
        return $Default
    }
    try {
        return Get-JsonFile -Path $Path
    } catch {
        return $Default
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
        $backupDb = Join-PathParts -Base $backupRoot -Parts @("data", "db")
        if (-not (Test-Path $backupDb)) {
            New-Item -ItemType Directory -Force -Path $backupDb | Out-Null
        }
        Copy-Item -Path $SetupFile -Destination (Join-Path $backupDb "setup.json") -Force
    }
    Write-JsonFileAtomic -Object $State -Path $SetupFile -Depth 10
}

function Write-PrettyJsonFile {
    param (
        $Object,
        [string]$Path,
        [int]$Depth = 20
    )
    $json = $Object | ConvertTo-Json -Depth $Depth -Compress
    try {
        $null = $json | ConvertFrom-Json
    } catch {
        Write-Error "Generated JSON is invalid."
        throw
    }
    $pretty = Format-JsonString -Json $json -Indent 2
    Set-Content -Path $Path -Value $pretty
}

function Write-JsonFileAtomic {
    param (
        $Object,
        [string]$Path,
        [int]$Depth = 20,
        [string]$BackupPath
    )
    $tmp = Join-Path (Split-Path -Parent $Path) ("tmp_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".json")
    try {
        Write-PrettyJsonFile -Object $Object -Path $tmp -Depth $Depth
        if ($BackupPath -and (Test-Path $Path)) {
            $backupDir = Split-Path -Parent $BackupPath
            if ($backupDir) {
                if (-not (Test-Path $backupDir)) {
                    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
                }
            }
            Copy-Item -Path $Path -Destination $BackupPath -Force
        }
        Move-Item -Path $tmp -Destination $Path -Force -ErrorAction Stop
    } catch {
        if (Test-Path $tmp) {
            Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function ConvertTo-NormalizedJsonObject {
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
            $sorted[$key] = ConvertTo-NormalizedJsonObject -Object $Object[$key]
        }
        return $sorted
    }
    if ($Object -is [System.Management.Automation.PSCustomObject]) {
        $sorted = [ordered]@{}
        foreach ($p in ($Object.PSObject.Properties.Name | Sort-Object)) {
            $sorted[$p] = ConvertTo-NormalizedJsonObject -Object $Object.$p
        }
        return $sorted
    }
    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        $list = @()
        foreach ($item in $Object) {
            $list += ,(ConvertTo-NormalizedJsonObject -Object $item)
        }
        return $list
    }
    $props = $Object.PSObject.Properties
    if ($props -and $props.Count -gt 0) {
        $sorted = [ordered]@{}
        foreach ($p in ($props.Name | Sort-Object)) {
            $sorted[$p] = ConvertTo-NormalizedJsonObject -Object $Object.$p
        }
        return $sorted
    }
    return $Object
}

#endregion JSON Utilities

function Get-BackupPath {
    param ([switch]$Create)
    if (-not $script:BackupPath) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $script:BackupPath = Join-PathParts -Base $Root -Parts @("backup", $timestamp)
    }
    if ($Create -and -not (Test-Path $script:BackupPath)) {
        New-Item -ItemType Directory -Force -Path $script:BackupPath | Out-Null
    }
    return $script:BackupPath
}


function Get-ConfigDiff {
    param (
        [string]$OldPath,
        [string]$NewPath
    )
    if (-not (Test-Path $OldPath)) {
        return [pscustomobject]@{
            HasChanges = $false
            ChangedKeys = @()
            DiffLines = @("No existing config to diff: $OldPath")
        }
    }
    if (-not (Test-Path $NewPath)) {
        return [pscustomobject]@{
            HasChanges = $false
            ChangedKeys = @()
            DiffLines = @("No generated config to diff: $NewPath")
        }
    }
    $oldObj = ConvertTo-NormalizedJsonObject -Object (Get-JsonFile -Path $OldPath)
    $newObj = ConvertTo-NormalizedJsonObject -Object (Get-JsonFile -Path $NewPath)
    if ($null -eq $oldObj -or $null -eq $newObj) {
        return [pscustomobject]@{
            HasChanges = $false
            ChangedKeys = @()
            DiffLines = @("Unable to normalize config for diff.")
        }
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
    $oldJson = Format-JsonString -Json ($oldObj | ConvertTo-Json -Depth 50 -Compress) -Indent 2
    $newJson = Format-JsonString -Json ($newObj | ConvertTo-Json -Depth 50 -Compress) -Indent 2
    $oldLines = $oldJson -split "`r?`n"
    $newLines = $newJson -split "`r?`n"
    $diff = Compare-Object -ReferenceObject $oldLines -DifferenceObject $newLines
    $diffLines = @()
    if ($diff -and $diff.Count -gt 0) {
        $diffLines = $diff | ForEach-Object { ("{0} {1}" -f $_.SideIndicator, $_.InputObject) }
    }

    return [pscustomobject]@{
        HasChanges = ($diffLines.Count -gt 0)
        ChangedKeys = $changedKeys
        DiffLines = $diffLines
    }
}

function Show-ConfigDiff {
    param (
        [string]$OldPath,
        [string]$NewPath
    )
    $diff = Get-ConfigDiff -OldPath $OldPath -NewPath $NewPath
    if ($diff.DiffLines.Count -eq 1 -and $diff.ChangedKeys.Count -eq 0 -and -not $diff.HasChanges) {
        Write-Host $diff.DiffLines[0]
        return $false
    }
    if ($diff.ChangedKeys.Count -gt 0) {
        Write-Host "Changed top-level keys:"
        $diff.ChangedKeys | ForEach-Object { Write-Host "- $_" }
    }
    if ($diff.DiffLines.Count -gt 0) {
        Write-Host "Config diff (<= current, => new):"
        $diff.DiffLines | ForEach-Object { Write-Host $_ }
    }
    return $diff.HasChanges
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

function Invoke-StageAndMove {
    param (
        [string]$StagingPath,
        [string]$DestinationPath,
        [string]$BackupPath,
        [scriptblock]$Populate
    )
    if (-not (Test-Path $StagingPath)) {
        New-Item -ItemType Directory -Force -Path $StagingPath | Out-Null
    }
    try {
        $populateResult = & $Populate
        if ($populateResult -eq $false) {
            return $false
        }
        Move-Atomic -StagingPath $StagingPath -DestinationPath $DestinationPath -BackupPath $BackupPath
    } finally {
        if (Test-Path $StagingPath) {
            Remove-Item -Path $StagingPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return $true
}

function Copy-UpdatePayloadFromZip {
    param (
        [string]$ZipPath,
        [string]$DestinationPath
    )
    if (-not (Test-Path $ZipPath)) { return $false }

    $tempRoot = Join-Path $Root ("update_extract_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
    $staging = $null
    if (-not (Test-Path $tempRoot)) {
        New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
    }
    try {
        Expand-Archive -Path $ZipPath -DestinationPath $tempRoot -Force
        $updateSource = Get-ChildItem -Path $tempRoot -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq "update" } |
            Select-Object -First 1
        if (-not $updateSource) {
            throw "Update folder not found in package"
        }
        $staging = Join-Path $Root ("update_staging_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
        if (-not (Test-Path $staging)) {
            New-Item -ItemType Directory -Force -Path $staging | Out-Null
        }
        Copy-Item -Path (Join-Path $updateSource.FullName "*") -Destination $staging -Recurse -Force -ErrorAction Stop
        $customProfilesUpdate = Join-Path $staging "profiles_custom"
        if (Test-Path $customProfilesUpdate) {
            throw "Update payload contains profiles_custom; aborting."
        }
        $requiredCore = Join-PathParts -Base $staging -Parts @("root", "setup.core.ps1")
        $requiredApp = Join-Path $staging "app"
        if (-not (Test-Path $requiredCore) -or -not (Test-Path $requiredApp)) {
            throw "Update payload missing required root/setup.core.ps1 or app directory"
        }
        $backup = Join-Path (Get-BackupPath -Create) "update"
        Move-Atomic -StagingPath $staging -DestinationPath $DestinationPath -BackupPath $backup
        return $true
    } finally {
        if ($staging -and (Test-Path $staging)) {
            Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $tempRoot) {
            Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Update-RootFilesFromUpdateRoot {
    param (
        [string]$UpdateRoot,
        [string]$DestinationRoot
    )
    $rootSource = Join-Path $UpdateRoot "root"
    if (-not (Test-Path $rootSource)) { return $null }

    $restartRequired = $false
    $changed = $false
    $backupRoot = Join-Path (Get-BackupPath -Create) "root"
    if (-not (Test-Path $backupRoot)) {
        New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    }
    $stagingRoot = Join-Path $Root ("root_staging_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
    if (-not (Test-Path $stagingRoot)) {
        New-Item -ItemType Directory -Force -Path $stagingRoot | Out-Null
    }
    try {
        foreach ($item in (Get-ChildItem -Path $rootSource -File -Force)) {
            $src = $item.FullName
            $dst = Join-Path $DestinationRoot $item.Name
            if (Test-Path $dst) {
                $srcHash = (Get-FileHash -Algorithm SHA256 -Path $src).Hash.ToLower()
                $dstHash = (Get-FileHash -Algorithm SHA256 -Path $dst).Hash.ToLower()
                if ($srcHash -eq $dstHash) { continue }
            }
            $stagingFile = Join-Path $stagingRoot $item.Name
            Copy-Item -Path $src -Destination $stagingFile -Force
            $backupFile = Join-Path $backupRoot $item.Name
            Move-Atomic -StagingPath $stagingFile -DestinationPath $dst -BackupPath $backupFile
            $changed = $true
            if (($item.Name -eq "setup.ps1") -or ($item.Name -eq "setup.core.ps1")) {
                $restartRequired = $true
            }
        }
    } finally {
        if (Test-Path $stagingRoot) {
            Remove-Item -Path $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return [pscustomobject]@{
        Changed = $changed
        RestartRequired = $restartRequired
    }
}

function Invoke-UpdatePayloadFlow {
    param (
        [bool]$UpdateRootAvailable,
        [bool]$HasPayload,
        [string]$UpdateRoot,
        [string]$DestinationRoot,
        [scriptblock]$Between
    )
    $result = [pscustomobject]@{
        RootUpdated = $false
        RestartRequired = $false
        PayloadDeployed = $false
        BetweenResult = $null
    }

    if ($UpdateRootAvailable) {
        $rootUpdateResult = Update-RootFilesFromUpdateRoot -UpdateRoot $UpdateRoot -DestinationRoot $DestinationRoot
        if ($rootUpdateResult.RestartRequired) {
            Write-Host "Root files updated (setup changed). Please re-run setup."
            $result.RestartRequired = $true
            return $result
        }
        if ($rootUpdateResult.Changed) {
            Write-Host "Root files updated."
            $result.RootUpdated = $true
        }
    } else {
        Write-Host "Update root missing; skipping root file updates."
    }

    if ($Between) {
        $result.BetweenResult = & $Between
    }

    if ($HasPayload -and $UpdateRootAvailable) {
        try {
            $payloadOk = Install-PayloadsIfPresent
            if (-not $payloadOk) {
                throw "Payload deploy failed"
            }
            $result.PayloadDeployed = $true
        } catch {
            Write-Error "Payload deploy failed: $($_.Exception.Message)"
            throw
        }
    }

    return $result
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

function Write-UpdateStatus {
    param (
        [string]$LatestTag,
        [string]$LocalVersion,
        [string]$Status
    )
    $localLabel = if ($LocalVersion) { $LocalVersion } else { "<missing>" }
    $statusLabel = if ($Status) { $Status } else { "unknown" }
    Write-Host ("Update check: latest={0}; local={1}; status={2}" -f $LatestTag, $localLabel, $statusLabel)
}

function Get-VerifiedUpdatePackage {
    param (
        [string]$ZipUrl,
        [string]$ShaUrl
    )
    if (Test-Path $UpdateZipPath) {
        Remove-Item -Path $UpdateZipPath -Force
    }
    Invoke-WebRequest -Uri $ZipUrl -OutFile $UpdateZipPath -UseBasicParsing
    $shaPath = "$UpdateZipPath.sha256"
    if (Test-Path $shaPath) {
        Remove-Item -Path $shaPath -Force
    }
    Invoke-WebRequest -Uri $ShaUrl -OutFile $shaPath -UseBasicParsing
    $expectedHash = Read-HashFromFile -Path $shaPath
    if (-not $expectedHash) {
        throw "SHA256 file is empty or invalid. Aborting update."
    }
    $actualHash = (Get-FileHash -Algorithm SHA256 -Path $UpdateZipPath).Hash.ToLower()
    if ($expectedHash -ne $actualHash) {
        throw "Update ZIP hash mismatch. Aborting update."
    }
    return $true
}

function Read-HashFromFile {
    param ([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $content = (Get-Content -Path $Path -Raw)
    $content = $content -replace '^\uFEFF', ''
    $content = $content.Trim()
    if (-not $content) { return $null }
    $match = [regex]::Match($content, '(?i)\b[0-9a-f]{64}\b')
    if (-not $match.Success) { return $null }
    return $match.Value.ToLower()
}

function Update-CoreIfNeeded {
    param (
        $SetupState,
        [switch]$ForceUpdate
    )
    $latestTag = $null
    $updateStatus = $null
    try {
        $latestTag = Get-LatestTag
    } catch {
        $updateStatus = "check_failed"
        Write-UpdateStatus -LatestTag $latestTag -LocalVersion $null -Status $updateStatus
        Write-Host ("Update check failed (network). Continuing. Details: {0}" -f $_.Exception.Message)
    }

    if ($latestTag) {
        $releaseTag = $latestTag
        $isNewRelease = $releaseTag -and ($releaseTag -ne $SetupState.CoreReleaseTag)
        $updateVersionPath = Join-PathParts -Base $Root -Parts @("update", "VERSION.txt")
        $hasMatchingUpdateVersion = $false
        $localVersion = $null
        if (Test-Path $updateVersionPath) {
            $localVersion = (Get-Content -Path $updateVersionPath -Raw).Trim()
        }
        if (-not $localVersion -and $SetupState.CoreReleaseTag) {
            $localVersion = $SetupState.CoreReleaseTag
        }
        if ($localVersion -and ($localVersion -eq $releaseTag)) {
            $hasMatchingUpdateVersion = $true
        }

        if ($hasMatchingUpdateVersion -and -not $ForceUpdate) {
            $updateStatus = "up_to_date"
            Set-SetupStateValue -State $SetupState -Name "CoreReleaseTag" -Value $releaseTag
            Set-SetupStateValue -State $SetupState -Name "CoreCommitSha" -Value $null
            Save-SetupState -State $SetupState
        } elseif ($isNewRelease -or $ForceUpdate) {
            $updateStatus = "update_available"
            Write-Host ("Update available: {0}. Downloading package..." -f $releaseTag)
            $zipName = "package_$releaseTag.zip"
            $zipUrl = "$RepoWebBase/releases/download/$releaseTag/$zipName"
            $shaUrl = "$zipUrl.sha256"
            Write-Host "Update ZIP URL: $zipUrl"
            Write-Host "Update SHA URL: $shaUrl"
            $null = Get-VerifiedUpdatePackage -ZipUrl $zipUrl -ShaUrl $shaUrl
            if (Copy-UpdatePayloadFromZip -ZipPath $UpdateZipPath -DestinationPath (Join-Path $Root "update")) {
                Set-SetupStateValue -State $SetupState -Name "CoreReleaseTag" -Value $releaseTag
                Set-SetupStateValue -State $SetupState -Name "CoreCommitSha" -Value $null
                Save-SetupState -State $SetupState
                $rootUpdateResult = Update-RootFilesFromUpdateRoot -UpdateRoot (Join-Path $Root "update") -DestinationRoot $Root
                if ($rootUpdateResult.RestartRequired) {
                    Write-Host "Core update applied (setup changed). Please re-run setup."
                    return [pscustomobject]@{
                        SetupState = $SetupState
                        RestartRequired = $true
                    }
                }
                if ($rootUpdateResult.Changed) {
                    Write-Host "Core update applied; setup files unchanged, continuing."
                }
            }
        } else {
            $updateStatus = "up_to_date"
        }
        Write-UpdateStatus -LatestTag $releaseTag -LocalVersion $localVersion -Status $updateStatus
    } else {
        Write-UpdateStatus -LatestTag $latestTag -LocalVersion $null -Status "unavailable"
    }

    return [pscustomobject]@{
        SetupState = $SetupState
        RestartRequired = $false
    }
}

$setupState = Read-JsonFileSafe -Path $SetupFile -Default @{}
$coreUpdateResult = Update-CoreIfNeeded -SetupState $setupState -ForceUpdate:$ForceUpdate
if ($coreUpdateResult.RestartRequired) {
    return
}
$setupState = $coreUpdateResult.SetupState

# --- Paths ---
$AppPath        = Join-Path $Root "app"
$UpdateAppPath  = Join-PathParts -Base $Root -Parts @("update", "app")
$TestPath       = Join-Path $Root "test"
$UpdateTestPath = Join-PathParts -Base $Root -Parts @("update", "test")
$CustomProfilesPath = Join-Path $Root "profiles_custom"
$DefaultProfilesPath = Join-Path $Root "profiles_default"
$UpdateProfilesPath = Join-PathParts -Base $Root -Parts @("update", "profiles_default")
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

function Sync-DefaultProfilesFromUpdateAtomic {
    if (-not (Test-Path $UpdateProfilesPath)) { return }
    $items = Get-ChildItem -Path $UpdateProfilesPath -Force -ErrorAction SilentlyContinue
    if (-not $items -or $items.Count -eq 0) { return }

    $staging = Join-Path $Root ("profiles_default_staging_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
    $backup = Join-Path (Get-BackupPath -Create) "profiles_default"
    return Invoke-StageAndMove -StagingPath $staging -DestinationPath $DefaultProfilesPath -BackupPath $backup -Populate {
        Copy-Item -Path (Join-Path $UpdateProfilesPath "*") -Destination $staging -Recurse -Force -ErrorAction Stop
    }
}

function Resolve-SelectedProfileSource {
    param ([string]$ProfileName)
    if (-not $ProfileName) { return $null }
    $customManifest = Join-PathParts -Base $CustomProfilesPath -Parts @($ProfileName, "manifest.json")
    if (Test-Path $customManifest) { return "profiles_custom" }
    $updateManifest = Join-PathParts -Base $DefaultProfilesPath -Parts @($ProfileName, "manifest.json")
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
        if (-not (Test-Path $CustomProfilesPath)) {
            New-Item -ItemType Directory -Force -Path $CustomProfilesPath | Out-Null
        }
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
    $manifest = Get-JsonFile -Path $manifestPath
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


function Set-ProfileState {
    param (
        [string]$ProfilePath,
        [string]$DestinationConfig,
        [string]$ResourceRoot,
        [string]$ProfileName,
        [switch]$LogApplied
    )
    $config = Get-ConfigFromManifest -ProfilePath $ProfilePath
    if ($null -eq $config) { return $false }
    $backupConfig = $null
    if (Test-Path $DestinationConfig) {
        $backupConfig = Join-PathParts -Base (Get-BackupPath -Create) -Parts @("data", "config.json")
    }
    Write-JsonFileAtomic -Object $config -Path $DestinationConfig -Depth 20 -BackupPath $backupConfig
    $usedManifest = $true
    if (-not $usedManifest) {
        Write-Error "manifest.json missing or invalid in selected profile"
        throw
    }
    try {
        $staging = Join-Path $Root ("resources_staging_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
        $backup = Join-PathParts -Base (Get-BackupPath -Create) -Parts @("data", "resources")
        $resApplied = Invoke-StageAndMove -StagingPath $staging -DestinationPath $ResourceRoot -BackupPath $backup -Populate {
            return (New-ResourcesToPath -ProfilePath $ProfilePath -DestinationRoot $staging)
        }
        if (-not $resApplied) {
            Write-Error "manifest.json missing or invalid in selected profile"
            throw
        }
    } catch {
        Write-Error "Resource sync failed: $($_.Exception.Message)"
        throw
    }
    if ($LogApplied) {
        Write-Host "Profile applied: $ProfileName -> $DestinationConfig"
    }
}

function Test-ProfileChanges {
    param (
        [string]$SelectedPath,
        [string]$ConfigOut,
        [string]$DataPath
    )
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
    return $hasConfigChanges
}

function New-ResourcesToPath {
    param (
        [string]$ProfilePath,
        [string]$DestinationRoot
    )
    $manifestPath = Join-Path $ProfilePath "manifest.json"
    if (-not (Test-Path $manifestPath)) { return $false }
    $manifest = Get-JsonFile -Path $manifestPath
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
    Write-Host "Custom profile hash matches stored value; no update needed."
        return
    }

    Invoke-CustomProfileDownload -ZipUrl $zipUrl -ExpectedSha256 $expected
    $SetupState.CustomProfileZipUrl = $zipUrl
    $SetupState.CustomProfileZipSha256 = $expected
    $SetupState.LastProfileUpdateUtc = (Get-Date).ToString("o")
    Save-SetupState -State $SetupState
}

Write-Host "=== Setup ==="
Write-Host "Directory: $Root"
Write-Host ""

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
            $synced = Sync-DefaultProfilesFromUpdateAtomic
            if (-not $synced) {
                Write-Error "Default profile sync failed."
                throw "Default profile sync failed"
            }
            Clear-PayloadFolder -Path $UpdateProfilesPath
        } catch {
            Write-Error "Default profile sync failed: $($_.Exception.Message)"
            throw
        }
    } else {
        Write-Host "Profiles sync skipped (no update profiles)"
    }
}

function Resolve-ProfileSelection {
    param (
        $SetupState,
        [switch]$AllowChange
    )
    $needsSave = $false
    $availableProfiles = Get-AvailableProfiles
    if (-not $availableProfiles -or $availableProfiles.Count -eq 0) {
        Write-Error "No profiles found"
        throw
    }

    if ($SetupState.SelectedProfileName -and -not $SetupState.SelectedProfileSource) {
        $resolvedSource = Resolve-SelectedProfileSource -ProfileName $SetupState.SelectedProfileName
        if ($resolvedSource) {
            Set-SetupStateValue -State $SetupState -Name "SelectedProfileSource" -Value $resolvedSource
            $needsSave = $true
        }
    }

    $selected = $null
    if ($SetupState.SelectedProfileName -and $AllowChange -and $availableProfiles.Count -gt 1) {
        $changeProfile = Read-YesNoDecision -Prompt "Change selected profile?"
        if ($changeProfile) {
            $selected = Select-Profile -Profiles $availableProfiles -CurrentName $SetupState.SelectedProfileName -CurrentSource $SetupState.SelectedProfileSource
            Set-SetupStateValue -State $SetupState -Name "SelectedProfileName" -Value $selected.Name
            Set-SetupStateValue -State $SetupState -Name "SelectedProfileSource" -Value $selected.Source
            $needsSave = $true
        }
    }

    if (-not $SetupState.SelectedProfileName) {
        $selected = Select-Profile -Profiles $availableProfiles
        Set-SetupStateValue -State $SetupState -Name "SelectedProfileName" -Value $selected.Name
        Set-SetupStateValue -State $SetupState -Name "SelectedProfileSource" -Value $selected.Source
        $needsSave = $true
    }

    if (-not $selected) {
        $selected = $availableProfiles | Where-Object {
            $_.Name -eq $SetupState.SelectedProfileName -and $_.Source -eq $SetupState.SelectedProfileSource
        } | Select-Object -First 1
    }
    if (-not $selected) {
        $selected = $availableProfiles | Where-Object { $_.Name -eq $SetupState.SelectedProfileName } | Select-Object -First 1
    }

    $profilesPath = if ($SetupState.SelectedProfileSource -eq "profiles_custom") { $CustomProfilesPath } `
        elseif ($SetupState.SelectedProfileSource -eq "profiles_default") { $DefaultProfilesPath } `
        else { Resolve-ProfilesPath }
    $selectedPath = if ($selected) { $selected.FullName } else { Join-Path $profilesPath $SetupState.SelectedProfileName }

    return [pscustomobject]@{
        Selected     = $selected
        SelectedPath = $selectedPath
        NeedsSave    = $needsSave
    }
}

function Invoke-ProfileSelectionAndApply {
    param (
        $Selection,
        $SetupState,
        [string]$DataPath,
        [string]$DataResPath,
        [string]$CustomProfilesPath,
        [switch]$AllowChange,
        [ValidateSet("INSTALL", "UPDATE")]
        [string]$Mode
    )
    $resolved = if ($Selection) { $Selection } else { Resolve-ProfileSelection -SetupState $SetupState -AllowChange:$AllowChange }
    $localNeedsSave = $resolved.NeedsSave
    if ($Mode -eq "UPDATE" -and (Test-Path $CustomProfilesPath)) {
        Read-CustomProfileDownloadDecision -Phase "UPDATE" -SetupState $SetupState
    }
    $selectedProfile = if ($resolved.Selected) { $resolved.Selected.Name } else { $SetupState.SelectedProfileName }
    $selectedPath = $resolved.SelectedPath
    if (Test-Path $selectedPath) {
        $configOut = Join-Path $DataPath "config.json"
        if ($Mode -eq "UPDATE") {
            Write-Host "Running profile diff and apply check..."
            $hasConfigChanges = Test-ProfileChanges -SelectedPath $selectedPath -ConfigOut $configOut -DataPath $DataPath
            if ($hasConfigChanges) {
                Write-Host "Config changed."
            } else {
                Write-Host "Config unchanged."
                Write-Host "Profile apply skipped."
                return [pscustomobject]@{
                    Selected = $resolved.Selected
                    Applied = $false
                    NeedsSave = $localNeedsSave
                }
            }

            $confirm = Read-YesNoDecision -Prompt "Confirm update?"
            if (-not $confirm) {
                return [pscustomobject]@{
                    Selected = $resolved.Selected
                    Applied = $false
                    NeedsSave = $localNeedsSave
                }
            }
            Set-ProfileState -ProfilePath $selectedPath -DestinationConfig $configOut -ResourceRoot $DataResPath -ProfileName $selectedProfile -LogApplied
            $applied = $true
        } else {
            Set-ProfileState -ProfilePath $selectedPath -DestinationConfig $configOut -ResourceRoot $DataResPath -ProfileName $selectedProfile -LogApplied
            $applied = $true
        }
        return [pscustomobject]@{
            Selected = $resolved.Selected
            Applied = $applied
            NeedsSave = $localNeedsSave
        }
    }
    Write-Error "Selected profile not found: $selectedPath"
    throw
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
    Write-Host "No application or test payload found (expected after cleanup/install)."
}

# --- Safe deploy function (content only) ---
function Install-PayloadsIfPresent {
    if ($AppPayloadItems -and $AppPayloadItems.Count -gt 0) {
        $appBackup = Join-Path (Get-BackupPath -Create) "app"
        $appStaging = Join-Path $Root ("staging_" + [IO.Path]::GetFileName($AppPath) + "_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
        $appOk = Invoke-StageAndMove -StagingPath $appStaging -DestinationPath $AppPath -BackupPath $appBackup -Populate {
            Get-ChildItem -Path $AppPayloadRoot -Force | ForEach-Object {
                Copy-Item -Path $_.FullName -Destination $appStaging -Force -Recurse -ErrorAction Stop
            }
            $backupDir = Split-Path -Parent $appBackup
            if ($backupDir -and -not (Test-Path $backupDir)) {
                if (-not (Test-Path $backupDir)) {
                    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
                }
            }
        }
        if (-not $appOk) { return $false }
    }
    if ($TestPayloadItems -and $TestPayloadItems.Count -gt 0) {
        $testBackup = Join-Path (Get-BackupPath -Create) "test"
        $testStaging = Join-Path $Root ("staging_" + [IO.Path]::GetFileName($TestPath) + "_" + (Get-Date -Format "yyyyMMdd_HHmmss"))
        $testOk = Invoke-StageAndMove -StagingPath $testStaging -DestinationPath $TestPath -BackupPath $testBackup -Populate {
            Get-ChildItem -Path $TestPayloadRoot -Force | ForEach-Object {
                Copy-Item -Path $_.FullName -Destination $testStaging -Force -Recurse -ErrorAction Stop
            }
            $backupDir = Split-Path -Parent $testBackup
            if ($backupDir -and -not (Test-Path $backupDir)) {
                if (-not (Test-Path $backupDir)) {
                    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
                }
            }
        }
        if (-not $testOk) { return $false }
    }
    return $true
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
    $defaultIndex = 0
    if ($CurrentName -or $CurrentSource) {
        for ($j = 0; $j -lt $Profiles.Count; $j++) {
            if (($Profiles[$j].Name -eq $CurrentName) -and ($Profiles[$j].Source -eq $CurrentSource)) {
                $defaultIndex = $j
                break
            }
        }
    }
    $idxInput = Read-Host ("Select profile index [default: {0}]" -f $defaultIndex)
    $idx = if ($idxInput) { $idxInput } else { $defaultIndex }
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
    Write-Host "Action detected: INSTALL"
    $updateRootPath = Join-PathParts -Base $Root -Parts @("update", "root")
    $updateRootAvailable = (Test-Path (Join-Path $updateRootPath "setup.ps1")) -and (Test-Path (Join-Path $updateRootPath "setup.core.ps1"))
    if (-not $updateRootAvailable) {
        Write-Error "Update root missing; install requires update\\root payload."
        throw
    }
    if (-not $HasPayload) {
        Write-Error "No payload available for install"
        throw
    }
    $setupState = Read-JsonFileSafe -Path $SetupFile -Default @{}
    Read-CustomProfileDownloadDecision -Phase "INSTALL" -SetupState $setupState
    Sync-DefaultProfilesIfPresent

    $ProfilesPath = Resolve-ProfilesPath
    # Profiles root is implicit; avoid noisy logs.

    if (-not (Test-Path $ProfilesPath) -and (Test-Path $UpdateProfilesPath)) {
        $ProfilesPath = $UpdateProfilesPath
        # Profiles root (update) is implicit; avoid noisy logs.
    }

    if (-not (Test-Path $ProfilesPath)) {
        Write-Error "No profiles directory found: $ProfilesPath"
        throw
    }

    $selection = Resolve-ProfileSelection -SetupState $setupState
    $selectedProfile = $selection.Selected
    if (-not $selectedProfile) {
        $selectedProfile = [pscustomobject]@{
            Name = $setupState.SelectedProfileName
            Source = $setupState.SelectedProfileSource
            FullName = $selection.SelectedPath
        }
    }
    $ProfilePath = $selectedProfile.FullName
    # Selected profile path is implicit; avoid noisy logs.
    $manifestPath = Join-Path $ProfilePath "manifest.json"
    if (-not (Test-Path $manifestPath)) {
        Write-Error "manifest.json missing or invalid in selected profile"
        throw
    }

    $confirm = Read-YesNoDecision -Prompt "Confirm installation in this directory?" -Default "YES"
    if (-not $confirm) {
        exit 0
    }

    # Create structure
    if (-not (Test-Path $DataPath)) {
        New-Item -ItemType Directory -Force -Path $DataPath | Out-Null
    }
    $dataDbPath = Join-Path $DataPath "db"
    if (-not (Test-Path $dataDbPath)) {
        New-Item -ItemType Directory -Force -Path $dataDbPath | Out-Null
    }
    $dataLogsPath = Join-Path $DataPath "logs"
    if (-not (Test-Path $dataLogsPath)) {
        New-Item -ItemType Directory -Force -Path $dataLogsPath | Out-Null
    }

    # Create custom profile scaffold (empty by default)
    $DefaultProfile = Join-Path $CustomProfilesPath "default"
    $DefaultResources = Join-Path $DefaultProfile "resources"
    $ReadmePath = Join-Path $CustomProfilesPath "README.txt"

    if (-not (Test-Path $DefaultResources)) {
        New-Item -ItemType Directory -Force -Path $DefaultResources | Out-Null
    }
    if (-not (Test-Path $ReadmePath)) {
        @'
profiles_custom is optional.
Create profiles_custom\<name>\manifest.json to override profiles_default.
If no manifest.json exists under profiles_custom, setup uses profiles_default.
'@ | Set-Content -Path $ReadmePath
    }

    # Apply profile (ONCE)
    $null = Invoke-ProfileSelectionAndApply -Selection $selection -SetupState $setupState -DataPath $DataPath -DataResPath $DataResPath `
        -CustomProfilesPath $CustomProfilesPath -Mode "INSTALL"

    # Deploy app/test (atomic)
    try {
        $payloadOk = Install-PayloadsIfPresent
        if (-not $payloadOk) {
            throw "Payload deploy failed"
        }
    } catch {
        Write-Error "Payload deploy failed: $($_.Exception.Message)"
        throw
    }

    Clear-UpdatePayload

    Save-SetupState -State $setupState

    Write-Host "Installation completed"
    exit
}

# ==================================================
# UPDATE
# ==================================================
Write-Host "Action detected: UPDATE"

$setupState = Read-JsonFileSafe -Path $SetupFile -Default @{}
$needsSave = $false
$updateRootPath = Join-PathParts -Base $Root -Parts @("update", "root")
$updateRootAvailable = (Test-Path (Join-Path $updateRootPath "setup.ps1")) -and (Test-Path (Join-Path $updateRootPath "setup.core.ps1"))

# Prefer update profiles if present; otherwise use existing profiles_default.
Sync-DefaultProfilesIfPresent
if ($setupState.SelectedProfileName) {
    if ($setupState.SelectedProfileSource) {
        Write-Host "Selected profile: $($setupState.SelectedProfileName) [$($setupState.SelectedProfileSource)]"
    } else {
        Write-Host "Selected profile: $($setupState.SelectedProfileName)"
    }
}
$payloadResult = Invoke-UpdatePayloadFlow -UpdateRootAvailable $updateRootAvailable -HasPayload $HasPayload -UpdateRoot (Join-Path $Root "update") -DestinationRoot $Root -Between {
    Invoke-ProfileSelectionAndApply -SetupState $setupState -DataPath $DataPath -DataResPath $DataResPath -CustomProfilesPath $CustomProfilesPath `
        -AllowChange -Mode "UPDATE"
}
if ($payloadResult.RestartRequired) {
    return
}
$appliedProfile = $null
if ($payloadResult.BetweenResult) {
    $appliedProfile = $payloadResult.BetweenResult.Applied
    if ($payloadResult.BetweenResult.NeedsSave) {
        $needsSave = $true
    }
}
if (-not $payloadResult.PayloadDeployed) {
    if ($appliedProfile) {
        if (-not $updateRootAvailable) {
            Write-Host "Update payload missing; profile/config update only."
        } else {
            Write-Host "No payload to deploy; profile/config update only"
        }
    } elseif (-not $HasPayload) {
        Write-Host "Summary: up to date; profile unchanged; no payload."
    }
}

if ($needsSave) {
    Save-SetupState -State $setupState
}
Clear-UpdatePayload

Write-Host "Update completed"
