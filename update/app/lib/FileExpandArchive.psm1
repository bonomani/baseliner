# FileExpandArchive.psm1
# Archive extraction - contract compliant

Import-Module -Name "$PSScriptRoot\GeneralUtil.psm1" -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\FileUtils.psm1"   -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\PhaseAlias.psm1"  -ErrorAction Stop

# ------------------------------------------------------------
# Single operation
# ------------------------------------------------------------
function Invoke-ExpandArchive {
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
            "Extract skipped: invalid definition | Reason=$($resolved.Error)",
            "ERROR",
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "Directory" -TargetId $targetId -Context $Context
        return $result
    }

    $archive = $resolved.SourcePath
    $dest = $resolved.TargetPath

    if (-not $archive -or -not $dest) {
        $Logger.WrapLog(
            "Extract skipped: invalid archive or destination path",
            "ERROR",
            $Context
        )
        $result = @{
            Observed = 0
            Applied  = 0
            Changed  = 0
            Failed   = 0
            Skipped  = 1
            Reason   = "invalid_definition"
        }
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $Logger.WriteTargetNotice("Directory", $targetId, $result, $Context, "skipped")
        return $result
    }

    $Logger.WrapLog(
        "Extract archive '$archive' to '$dest'.",
        "INFO",
        $Context
    )

    # TODO: Pre-verify only checks destination presence; may skip stale/mismatched extraction.
    $verifyBlock = {
        $exists = Test-Path -LiteralPath $dest
        return @{
            Success = $exists
            Hint    = if ($exists) { "present.target" } else { "absent.target" }
            Detail  = $dest
        }
    }

    $result = Invoke-CheckDoReportPhase `
        -Action "Extract archive '$dest'" `
        -PreVerifyBlock $verifyBlock `
        -CheckBlock {
            if (-not (Test-Path -LiteralPath $archive)) {
                $Logger.WrapLog(
                    "Archive '$archive' not found",
                    "ERROR",
                    $Context
                )
                return @{
                    Success = $false
                    Hint    = "missing.source"
                    Detail  = $archive
                }
            }

            return @{ Success = $true }
        } `
        -DoBlock {
            Expand-Archive `
                -Path $archive `
                -DestinationPath $dest `
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

    $Logger.WriteTargetNotice("Directory", $dest, $result, $Context, "extract")
    return $result
}

# ------------------------------------------------------------
# Batch operation
# ------------------------------------------------------------
function Invoke-ExpandArchiveBatch {
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
        $r = Invoke-ExpandArchive `
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

Export-ModuleMember -Function Invoke-ExpandArchive, Invoke-ExpandArchiveBatch
