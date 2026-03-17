# FileUtils.psm1
# Core utilities for path resolution, expansion, directory creation, and file existence checking

Import-Module -Name "$PSScriptRoot\GeneralUtil.psm1" -ErrorAction Stop

# ------------------------------------------------------------
# Global file operation lock
# ------------------------------------------------------------
if (-not $Global:FileOperationLock) {
    $Global:FileOperationLock = New-Object System.Threading.Mutex(
        $false,
        "Global\FileOperationMutex"
    )
}

# Create directory if it doesn't exist
function New-DirectoryIfMissing {
    param(
        [string]$Path,
        [object]$Logger = $null,
        [hashtable]$Context = @{ }
    )

    $result = Invoke-SafeAction -Action {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -ItemType Directory -Force | Out-Null
        }
        return $true
    } -ActionName "NewDirIfMissing" -Logger $Logger -Context $Context -DryRun:$false

    if (-not $result) {
        if ($Logger) { $Logger.WrapLog("Failed to ensure directory exists: '$Path'", "ERROR", $Context) }
        throw "Failed to ensure directory exists: '$Path'"
    }

    return $true
}

# Test if a file exists
function Test-FileExists {
    param(
        [Parameter(Mandatory)] [string] $BaseDirectory,
        [Parameter(Mandatory)] [string] $File,
        [ValidateSet('Ignore', 'Warn', 'Error')] [string] $OnMissing = 'Warn',
        [scriptblock] $Logger = $null,
        [hashtable] $Context = @{ }
    )

    $fullPath = Join-Path $BaseDirectory $File

    if (-not (Test-Path -LiteralPath $fullPath)) {
        switch ($OnMissing) {
            'Warn' {
                if ($Logger) { $Logger.WrapLog("File '$File' not found in '$BaseDirectory', skipping operation", "WARN", $Context) }
            }
            'Error' {
                throw "File '$File' not found in '$BaseDirectory'"
            }
            # 'Ignore' → no action
        }
        return $false
    }

    return $true
}

function Get-FileChecksum {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]   $BaseDirectory,
        [Parameter(Mandatory)][string[]] $Files,
        [ValidateSet('SHA256','MD5','SHA1')]
        [string]                         $Algorithm = 'SHA256',
        [Parameter(Mandatory)][object]   $Logger,
        [hashtable]                      $Context = @{ }
    )

    $stats = @{
        Observed = 0
        Applied   = 0
        Changed   = 0
        Failed    = 0
        Skipped   = 0
    }

    foreach ($file in $Files) {
        $stats.Observed++
        $filePath = Join-Path $BaseDirectory $file

        if (-not (Test-Path -LiteralPath $filePath)) {
            $Logger.WrapLog(
                "File '$file' does not exist in '$BaseDirectory'",
                'ERROR',
                $Context
            )
            $stats.Skipped++
            continue
        }

        try {
            $hashAlgorithm = [System.Security.Cryptography.HashAlgorithm]::Create($Algorithm)
            $stream = [System.IO.File]::OpenRead($filePath)
            try {
                $hashBytes = $hashAlgorithm.ComputeHash($stream)
            }
            finally {
                $stream.Close()
            }

            $checksum = ([BitConverter]::ToString($hashBytes)) -replace '-',''

            $Logger.WrapLog(
                "Checksum [$Algorithm] for '$file' = $checksum",
                'INFO',
                $Context
            )
        }
        catch {
            $Logger.WrapLog(
                "Failed to calculate checksum for '$file': $_",
                'ERROR',
                $Context
            )
            $stats.Skipped++
        }
    }

    return $stats
}

function Compare-Directories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SourceDirectory,
        [Parameter(Mandatory)][string] $DestinationDirectory,
        [Parameter(Mandatory)][object] $Logger,
        [hashtable]                    $Context = @{}
    )

    $stats = @{
        Observed = 0
        Applied   = 0
        Changed   = 0
        Failed    = 0
        Skipped   = 0
    }

    try {
        $stats.Observed++

        $src = Expand-Path -Path $SourceDirectory      -Logger $Logger -Context $Context
        $dst = Expand-Path -Path $DestinationDirectory -Logger $Logger -Context $Context

        if (-not (Test-Path -LiteralPath $src) -or -not (Test-Path -LiteralPath $dst)) {
            $Logger.WrapLog(
                "Compare failed: source or destination does not exist",
                'ERROR',
                $Context
            )
            $stats.Skipped++
            return $stats
        }

        $srcFiles = Get-ChildItem -Path $src -File
        $dstFiles = Get-ChildItem -Path $dst -File

        foreach ($sf in $srcFiles) {
            $df = $dstFiles | Where-Object Name -eq $sf.Name
            if (-not $df) {
                $Logger.WrapLog(
                    "Missing file in destination: $($sf.Name)",
                    'WARN',
                    $Context
                )
                continue
            }

            if ($sf.Length -ne $df.Length) {
                $Logger.WrapLog(
                    "File differs (size): $($sf.Name)",
                    'WARN',
                    $Context
                )
            } else {
                $Logger.WrapLog(
                    "File identical (size): $($sf.Name)",
                    'INFO',
                    $Context
                )
            }
        }

        foreach ($df in $dstFiles) {
            if (-not ($srcFiles | Where-Object Name -eq $df.Name)) {
                $Logger.WrapLog(
                    "Extra file in destination: $($df.Name)",
                    'WARN',
                    $Context
                )
            }
        }
    }
    catch {
        $Logger.WrapLog(
            "Compare-Directories failed: $_",
            'ERROR',
            $Context
        )
        $stats.Skipped++
    }

    return $stats
}

function Compare-Files {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $File1,
        [Parameter(Mandatory)][string] $File2,
        [Parameter(Mandatory)][object] $Logger,
        [hashtable]                    $Context = @{}
    )

    $stats = @{
        Observed = 0
        Applied   = 0
        Changed   = 0
        Failed    = 0
        Skipped   = 0
    }

    try {
        $stats.Observed++

        if (-not (Test-Path -LiteralPath $File1) -or -not (Test-Path -LiteralPath $File2)) {
            $Logger.WrapLog(
                "Compare failed: one or both files missing",
                'ERROR',
                $Context
            )
            $stats.Skipped++
            return $stats
        }

        $f1 = Get-Item -LiteralPath $File1
        $f2 = Get-Item -LiteralPath $File2

        if ($f1.Length -ne $f2.Length) {
            $Logger.WrapLog(
                "Files differ (size): '$File1' vs '$File2'",
                'WARN',
                $Context
            )
        } else {
            $b1 = Get-Content -Path $File1 -Encoding Byte -ReadCount 0
            $b2 = Get-Content -Path $File2 -Encoding Byte -ReadCount 0

            if ($b1 -ne $b2) {
                $Logger.WrapLog(
                    "Files differ (content): '$File1' vs '$File2'",
                    'WARN',
                    $Context
                )
            } else {
                $Logger.WrapLog(
                    "Files identical: '$File1' and '$File2'",
                    'INFO',
                    $Context
                )
            }
        }
    }
    catch {
        $Logger.WrapLog(
            "Compare-Files failed: $_",
            'ERROR',
            $Context
        )
        $stats.Skipped++
    }

    return $stats
}

function Resolve-FileTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Item
    )

    $resolved = Resolve-Item `
        -Context $Context `
        -Item $Item `
        -ItemContextPairs @('path','folder','name') `
        -ErrorCode "missing_target"

    if ($resolved.path -and ($resolved.folder -or $resolved.name)) {
        return @{ Error = "conflict_target" }
    }

    $targetPath = $null
    if ($resolved.path) {
        if ($resolved.folder -or $resolved.name) {
            if ($resolved.folder -and $resolved.name) {
                $combinedPath = Join-Path $resolved.folder $resolved.name
                if ($combinedPath -ne $resolved.path) {
                    return @{ Error = "conflict_target" }
                }
            } else {
                return @{ Error = "conflict_target" }
            }
        }
        $targetPath = $resolved.path
    } elseif ($resolved.folder -and $resolved.name) {
        $targetPath = Join-Path $resolved.folder $resolved.name
    }

    if (-not $targetPath) {
        return @{ Error = "missing_target" }
    }

    return @{
        Path   = $targetPath
        Folder = $resolved.folder
        Name   = $resolved.name
    }
}

function Resolve-FileTargetSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Item
    )

    $target = Resolve-FileTarget `
        -Context $Context `
        -Item $Item

    if ($target.Error) {
        if ($target.Error -eq "conflict_target") {
            return @{ Error = $target.Error }
        }
        $target = Resolve-Item `
            -Context $Context `
            -Item $Item `
            -ItemContextPairs @('path','folder','name') `
            -ErrorCode "missing_target"

        if ($target.Error) {
            return @{ Error = $target.Error }
        }
    }

    $source = Resolve-Item `
        -Context $Context `
        -Item $Item `
        -ItemContextPairs @('srcPath','srcFolder','srcName') `
        -ErrorCode "missing_source"

    if ($source.Error) {
        return @{ Error = $source.Error }
    }

    if (-not $target.path -and $target.folder -and -not $target.name -and $source.srcName) {
        $target = @{
            Path   = Join-Path $target.folder $source.srcName
            Folder = $target.folder
            Name   = $source.srcName
        }
    }

    if (-not $target.path -and -not $target.name) {
        return @{ Error = "missing_target_name" }
    }

    return @{
        Target = $target
        Source = $source
    }
}

function Resolve-FileTargetSourcePaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Item,
        [Parameter(Mandatory)] [object] $Logger,
        [hashtable]                    $LogContext = @{},
        [switch]                       $AllowSourceFolderOnly,
        [switch]                       $AllowTargetFolderOnly,
        [switch]                       $AllowTargetNameOnly
    )

    $ctxTable = @{}
    if ($Context -is [hashtable]) {
        $ctxTable = $Context
    } elseif ($Context) {
        foreach ($prop in $Context.PSObject.Properties) {
            $ctxTable[$prop.Name] = $prop.Value
        }
    }

    $itemTable = @{}
    if ($Item -is [hashtable]) {
        $itemTable = $Item
    } elseif ($Item) {
        foreach ($prop in $Item.PSObject.Properties) {
            $itemTable[$prop.Name] = $prop.Value
        }
    }

    $targetNameProvided = ($itemTable.name -or $ctxTable.name -or $itemTable.path -or $ctxTable.path)

    $resolved = Resolve-FileTargetSource `
        -Context $Context `
        -Item $Item

    if ($resolved.Error) {
        if ($resolved.Error -eq "conflict_target" -and $Logger) {
            $pathValue = if ($itemTable.path) { $itemTable.path } else { $ctxTable.path }
            $folderValue = if ($itemTable.folder) { $itemTable.folder } else { $ctxTable.folder }
            $nameValue = if ($itemTable.name) { $itemTable.name } else { $ctxTable.name }
            if ($pathValue -and $folderValue -and $nameValue) {
                $combinedPath = Join-Path $folderValue $nameValue
                $Logger.WrapLog(
                    "File target conflict: path '$pathValue' differs from folder/name '$combinedPath'",
                    "ERROR",
                    $LogContext
                )
            } else {
                $Logger.WrapLog(
                    "File target conflict: path '$pathValue' with folder/name fields",
                    "ERROR",
                    $LogContext
                )
            }
        }
        if ($AllowTargetFolderOnly -and $resolved.Error -in @("missing_target_name","missing_target")) {
            $targetOnly = Resolve-Item `
                -Context $Context `
                -Item $Item `
                -ItemContextPairs @('path','folder','name') `
                -ErrorCode "missing_target"

            if ($targetOnly.Error) {
                return @{ Error = $targetOnly.Error }
            }

            $sourceOnly = Resolve-Item `
                -Context $Context `
                -Item $Item `
                -ItemContextPairs @('srcPath','srcFolder','srcName') `
                -ErrorCode "missing_source"

            if ($sourceOnly.Error) {
                return @{ Error = $sourceOnly.Error }
            }

            $resolved = @{
                Source = $sourceOnly
                Target = $targetOnly
            }
        } else {
            return @{ Error = $resolved.Error }
        }
    }

    $sourcePath = $null
    if ($resolved.Source.srcPath) {
        $sourcePath = Expand-Path -Path $resolved.Source.srcPath -Logger $Logger -Context $LogContext
        if ($resolved.Source.srcFolder -and $resolved.Source.srcName) {
            $expandedFolder = Expand-Path -Path $resolved.Source.srcFolder -Logger $Logger -Context $LogContext
            $combinedPath = Join-Path $expandedFolder $resolved.Source.srcName
            if ($combinedPath -ne $sourcePath) {
                if ($Logger) {
                    $Logger.WrapLog(
                        "File source conflict: srcPath '$sourcePath' differs from srcFolder/srcName '$combinedPath'",
                        "ERROR",
                        $LogContext
                    )
                }
                return @{ Error = "conflict_source" }
            }
        }
    } elseif ($resolved.Source.srcFolder -and $resolved.Source.srcName) {
        $expandedFolder = Expand-Path -Path $resolved.Source.srcFolder -Logger $Logger -Context $LogContext
        $sourcePath = Join-Path $expandedFolder $resolved.Source.srcName
    } elseif ($AllowSourceFolderOnly -and $resolved.Source.srcFolder) {
        $sourcePath = Expand-Path -Path $resolved.Source.srcFolder -Logger $Logger -Context $LogContext
    }

    $targetPath = $null
    if ($AllowTargetFolderOnly -and -not $targetNameProvided -and $resolved.Target.folder) {
        $targetPath = Expand-Path -Path $resolved.Target.folder -Logger $Logger -Context $LogContext
    } elseif ($resolved.Target.path) {
        $targetPath = Expand-Path -Path $resolved.Target.path -Logger $Logger -Context $LogContext
    } elseif ($resolved.Target.folder -and $resolved.Target.name) {
        $expandedFolder = Expand-Path -Path $resolved.Target.folder -Logger $Logger -Context $LogContext
        $targetPath = Join-Path $expandedFolder $resolved.Target.name
    } elseif ($AllowTargetNameOnly -and $resolved.Target.name -and $sourcePath) {
        $targetPath = Join-Path (Split-Path -Path $sourcePath -Parent) $resolved.Target.name
    }

    return @{
        SourcePath = $sourcePath
        TargetPath = $targetPath
        Source     = $resolved.Source
        Target     = $resolved.Target
    }
}

function Resolve-FileTargetPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Item,
        [Parameter(Mandatory)] [object] $Logger,
        [hashtable]                    $LogContext = @{},
        [switch]                       $AllowFolderOnly
    )

    $target = Resolve-FileTarget `
        -Context $Context `
        -Item $Item

    if ($target.Error) {
        if ($target.Error -eq "conflict_target" -and $Logger) {
            $resolvedTarget = Resolve-Item `
                -Context $Context `
                -Item $Item `
                -ItemContextPairs @('path','folder','name') `
                -ErrorCode "missing_target"

            $pathValue = $resolvedTarget.path
            $folderValue = $resolvedTarget.folder
            $nameValue = $resolvedTarget.name

            if ($pathValue -and $folderValue -and $nameValue) {
                $combinedPath = Join-Path $folderValue $nameValue
                $Logger.WrapLog(
                    "File target conflict: path '$pathValue' differs from folder/name '$combinedPath'",
                    "ERROR",
                    $LogContext
                )
            } else {
                $Logger.WrapLog(
                    "File target conflict: path '$pathValue' with folder/name fields",
                    "ERROR",
                    $LogContext
                )
            }
        }
        return @{ Error = $target.Error }
    }

    $targetPath = $null
    if ($target.Path) {
        $targetPath = Expand-Path -Path $target.Path -Logger $Logger -Context $LogContext
    } elseif ($target.Folder -and $target.Name) {
        $expandedFolder = Expand-Path -Path $target.Folder -Logger $Logger -Context $LogContext
        $targetPath = Join-Path $expandedFolder $target.Name
    } elseif ($AllowFolderOnly -and $target.Folder) {
        $targetPath = Expand-Path -Path $target.Folder -Logger $Logger -Context $LogContext
    }

    return @{
        TargetPath = $targetPath
        Target     = $target
    }
}

function Resolve-ItemPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Item,
        [Parameter(Mandatory)] [string[]] $ItemContextPairs,
        [Parameter(Mandatory)] [object] $Logger,
        [hashtable] $LogContext = @{},
        [switch] $AllowFolderOnly
    )

    $resolved = Resolve-Item `
        -Context $Context `
        -Item $Item `
        -ItemContextPairs $ItemContextPairs

    if ($resolved.Error) {
        return @{ Error = $resolved.Error }
    }

    $path = $null
    if ($resolved.path) {
        $path = Expand-Path -Path $resolved.path -Logger $Logger -Context $LogContext
    } elseif ($resolved.folder -and $resolved.name) {
        $expandedFolder = Expand-Path -Path $resolved.folder -Logger $Logger -Context $LogContext
        $path = Join-Path $expandedFolder $resolved.name
    } elseif ($AllowFolderOnly -and $resolved.folder) {
        $path = Expand-Path -Path $resolved.folder -Logger $Logger -Context $LogContext
    }

    return @{
        Path = $path
        Resolved = $resolved
    }
}

function Get-FileTargetIdCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $Context,
        [Parameter(Mandatory)] [object] $Item
    )

    $ctxTable = @{}
    if ($Context -is [hashtable]) {
        $ctxTable = $Context
    } elseif ($Context) {
        foreach ($prop in $Context.PSObject.Properties) {
            $ctxTable[$prop.Name] = $prop.Value
        }
    }

    $itemTable = @{}
    if ($Item -is [hashtable]) {
        $itemTable = $Item
    } elseif ($Item) {
        foreach ($prop in $Item.PSObject.Properties) {
            $itemTable[$prop.Name] = $prop.Value
        }
    }

    if ($itemTable.path) { return $itemTable.path }
    if ($itemTable.folder -and $itemTable.name) { return Join-Path $itemTable.folder $itemTable.name }
    if ($ctxTable.path) { return $ctxTable.path }
    if ($ctxTable.folder -and $ctxTable.name) { return Join-Path $ctxTable.folder $ctxTable.name }

    if ($itemTable.srcPath) { return $itemTable.srcPath }
    if ($itemTable.srcFolder -and $itemTable.srcName) { return Join-Path $itemTable.srcFolder $itemTable.srcName }
    if ($ctxTable.srcPath) { return $ctxTable.srcPath }
    if ($ctxTable.srcFolder -and $ctxTable.srcName) { return Join-Path $ctxTable.srcFolder $ctxTable.srcName }

    return "<unresolved>"
}

# ------------------------------------------------------------
# Lock helper
# ------------------------------------------------------------
function Invoke-FileLock {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][object]      $Logger,
        [hashtable]                         $Context = @{}
    )

    $acquired = $false

    try {
        $acquired = $Global:FileOperationLock.WaitOne(10000)

        if (-not $acquired) {
            $Logger.WrapLog(
                "File operation lock not acquired (timeout)",
                "ERROR",
                $Context
            )
            return $false
        }

        & $Action
    }
    catch {
        $Logger.WrapLog(
            "File operation lock execution failed: $_",
            "ERROR",
            $Context
        )
        return $false
    }
    finally {
        if ($acquired) {
            $Global:FileOperationLock.ReleaseMutex()
        }
    }

    return $true
}

Export-ModuleMember -Function `
    New-DirectoryIfMissing,
    Test-FileExists,
    Resolve-FileTarget,
    Resolve-FileTargetSource,
    Resolve-FileTargetSourcePaths,
    Resolve-FileTargetPath,
    Resolve-ItemPath,
    Get-FileTargetIdCandidate,
    Get-FileChecksum,
    Compare-Directories,
    Compare-Files,
    Invoke-FileLock
