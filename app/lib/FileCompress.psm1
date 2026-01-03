# FileCompress.psm1
# File compression - contract compliant

Import-Module -Name "$PSScriptRoot\GeneralUtil.psm1" -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\FileUtils.psm1"   -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\PhaseAlias.psm1"  -ErrorAction Stop

# ------------------------------------------------------------
# Single operation
# ------------------------------------------------------------
function Invoke-CompressFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]   $EntryContext,
        [Parameter(Mandatory)][object]   $Item,
        [Parameter(Mandatory)][object]   $Logger,
        [hashtable]                      $Context = @{}
    )

    $resolved = Resolve-FileTargetSourcePaths `
        -Context $EntryContext `
        -Item $Item `
        -Logger $Logger `
        -LogContext $Context

    if ($resolved.Error) {
        $Logger.WrapLog(
            "Compression skipped: invalid definition | Reason=$($resolved.Error)",
            "ERROR",
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "File" -TargetId $targetId -Context $Context
        return $result
    }

    $hasTargetName = $Item.name -or $Item.path -or ($EntryContext -and ($EntryContext.name -or $EntryContext.path))
    if (-not $hasTargetName) {
        $Logger.WrapLog(
            "Compression skipped: missing archive name",
            "ERROR",
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "File" -TargetId $targetId -Context $Context
        return $result
    }

    $srcPath = $resolved.SourcePath
    $dstPath = $resolved.TargetPath

    if (-not $srcPath -or -not $dstPath) {
        $Logger.WrapLog(
            "Compression skipped: invalid source or destination path",
            "ERROR",
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "File" -TargetId $targetId -Context $Context
        return $result
    }

    $Logger.WrapLog(
        "Compress file '$srcPath' to '$dstPath'.",
        "INFO",
        $Context
    )

    # TODO: Pre-verify only checks archive presence; may skip stale/mismatched output.
    $verifyBlock = {
        $exists = Test-Path -LiteralPath $dstPath
        return @{
            Success = $exists
            Hint    = if ($exists) { "present.target" } else { "absent.target" }
            Detail  = $dstPath
        }
    }

    $r = Invoke-CheckDoReportPhase `
        -Action "Compress file '$dstPath'" `
        -PreVerifyBlock $verifyBlock `
        -CheckBlock {
            if (-not (Test-Path -LiteralPath $srcPath)) {
                $Logger.WrapLog(
                    "Source file '$srcPath' not found",
                    "ERROR",
                    $Context
                )
                return @{
                    Success = $false
                    Hint    = "missing.source"
                    Detail  = $srcPath
                }
            }

            return @{ Success = $true }
        } `
        -DoBlock {
            Compress-Archive `
                -Path $srcPath `
                -DestinationPath $dstPath `
                -Force `
                -ErrorAction Stop
            return @{ Success = $true }
        } `
        -VerifyBlock $verifyBlock `
        -Logger $Logger `
        -PreVerifyContext $Context `
        -CheckContext $Context `
        -DoContext $Context `
        -VerifyContext $Context

    $Logger.WriteTargetNotice("File", $dstPath, $r, $Context, "compress")
    return $r
}

# ------------------------------------------------------------
# Batch operation
# ------------------------------------------------------------
function Invoke-CompressFileBatch {
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
        $r = Invoke-CompressFile `
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

Export-ModuleMember -Function Invoke-CompressFile, Invoke-CompressFileBatch
