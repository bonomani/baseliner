# FileSplit.psm1
# Split files - contract compliant

Import-Module -Name "$PSScriptRoot\GeneralUtil.psm1" -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\FileUtils.psm1"   -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\PhaseAlias.psm1"  -ErrorAction Stop

# ------------------------------------------------------------
# Single operation
# ------------------------------------------------------------
function Invoke-SplitFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $EntryContext,
        [Parameter(Mandatory)][object] $Item,
        [Parameter(Mandatory)][object] $Logger,
        [hashtable]                    $Context = @{}
    )

    $resolved = Resolve-FileTargetSourcePaths `
        -Context $EntryContext `
        -Item $Item `
        -Logger $Logger `
        -LogContext $Context `
        -AllowTargetFolderOnly

    if ($resolved.Error) {
        $Logger.WrapLog(
            "Split skipped: invalid definition | Reason=$($resolved.Error)",
            "ERROR",
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "Directory" -TargetId $targetId -Context $Context
        return $result
    }

    $chunkSize = $Item.chunkSize
    if (-not $chunkSize -and $EntryContext) {
        $chunkSize = $EntryContext.chunkSize
    }
    if (-not $chunkSize) {
        $Logger.WrapLog(
            "Split skipped: missing chunkSize",
            "ERROR",
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "Directory" -TargetId $targetId -Context $Context
        return $result
    }

    $src = $resolved.SourcePath
    $dest = $resolved.TargetPath
    $destBaseName = $null

    if ($resolved.Target -and $resolved.Target.path) {
        $destBaseName = Split-Path -Path $resolved.Target.path -Leaf
        $dest = Split-Path -Path $resolved.Target.path -Parent
    }

    if (-not $src -or -not $dest) {
        $Logger.WrapLog(
            "Split skipped: invalid source or destination path",
            "ERROR",
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "Directory" -TargetId $targetId -Context $Context
        return $result
    }

    $Logger.WrapLog(
        "Splitting '$src' into chunks of $chunkSize bytes",
        'INFO',
        $Context
    )

    # TODO: Pre-verify only checks destination presence; may skip stale/mismatched chunks.
    $verifyBlock = {
        $exists = Test-Path -LiteralPath $dest
        return @{
            Success = $exists
            Hint    = if ($exists) { "present.target" } else { "absent.target" }
            Detail  = $dest
        }
    }

    $r = Invoke-CheckDoReportPhase `
        -Action "Split file '$dest'" `
        -PreVerifyBlock $verifyBlock `
        -CheckBlock {
            if (-not (Test-Path -LiteralPath $src)) {
                $Logger.WrapLog(
                    "Split failed: file not found '$src'",
                    'ERROR',
                    $Context
                )
                return @{
                    Success = $false
                    Hint    = "missing.source"
                    Detail  = $src
                }
            }
            return @{ Success = $true }
        } `
        -DoBlock {
            New-DirectoryIfMissing -Path $dest -Logger $Logger -Context $Context
            $fileInfo = Get-Item -LiteralPath $src
            $fileSize = $fileInfo.Length
            $chunkCnt = [math]::Ceiling($fileSize / $chunkSize)
            $baseName = if ($destBaseName) { [System.IO.Path]::GetFileNameWithoutExtension($destBaseName) } else { $fileInfo.BaseName }
            $extension = if ($destBaseName) { [System.IO.Path]::GetExtension($destBaseName) } else { $fileInfo.Extension }

            $fs = [System.IO.File]::OpenRead($src)
            try {
                for ($i = 0; $i -lt $chunkCnt; $i++) {
                    $chunkPath = Join-Path $dest (
                        "{0}_part{1:D4}{2}" -f $baseName, ($i + 1), $extension
                    )

                    $buffer = New-Object byte[] $chunkSize
                    $read   = $fs.Read($buffer, 0, $chunkSize)

                    $cs = [System.IO.File]::OpenWrite($chunkPath)
                    try {
                        $cs.Write($buffer, 0, $read)
                    } finally {
                        $cs.Close()
                    }
                }
            } finally {
                $fs.Close()
            }

            return @{ Success = $true }
        } `
        -VerifyBlock $verifyBlock `
        -Logger $Logger `
        -PreVerifyContext $Context `
        -CheckContext $Context `
        -FixupContext $Context `
        -DoContext $Context `
        -VerifyContext $Context

    $Logger.WriteTargetNotice("Directory", $dest, $r, $Context, "split")
    return $r
}

# ------------------------------------------------------------
# Batch operation
# ------------------------------------------------------------
function Invoke-SplitFileBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]     $EntryContext,
        [Parameter(Mandatory)][psobject[]] $EntryItems,
        [Parameter(Mandatory)][object]     $Logger,
        [hashtable]                        $Context = @{}
    )

    $stats = @{
        Observed = 0
        Applied   = 0
        Changed   = 0
        Failed    = 0
        Skipped   = 0
    }

    foreach ($item in $EntryItems) {
        $r = Invoke-SplitFile `
            -EntryContext $EntryContext `
            -Item $item `
            -Logger $Logger `
            -Context $Context

        foreach ($k in @('Observed','Applied','Changed','Failed','Skipped')) {
            $stats[$k] += $r[$k]
        }
    }

    return $stats
}

Export-ModuleMember -Function Invoke-SplitFile, Invoke-SplitFileBatch
