# FileCopy.psm1

Import-Module -Name "$PSScriptRoot\GeneralUtil.psm1" -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\FileUtils.psm1"   -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\PhaseAlias.psm1"  -ErrorAction Stop

function Invoke-CopyFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]   $EntryContext,
        [Parameter(Mandatory)] [object]   $Item,
        [Parameter(Mandatory)]            $Logger,
        [hashtable]                       $Context = @{}
    )

    $resolved = Resolve-FileTargetSourcePaths `
        -Context $EntryContext `
        -Item $Item `
        -Logger $Logger `
        -LogContext $Context

    if ($resolved.Error) {
        $Logger.WrapLog(
            "Copy file skipped: invalid definition | Reason=$($resolved.Error)",
            'ERROR',
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "File" -TargetId $targetId -Context $Context
        return $result
    }

    $sourcePath = $resolved.SourcePath
    $destinationPath = $resolved.TargetPath

    $Logger.WrapLog(
        "Copy file '$sourcePath' to '$destinationPath'.",
        'INFO',
        $Context
    )

    # TODO: Pre-verify only checks target presence; may skip stale/mismatched content.
    $verifyBlock = {
        $success = (Test-Path -LiteralPath $destinationPath)
        $hint = if ($success) { "present.target" } else { "absent.target" }
        return @{
            Success = $success
            Hint    = $hint
            Detail  = $destinationPath
        }
    }

    $result = Invoke-CheckDoReportPhase `
        -Action "Copy file '$destinationPath'" `
        -PreVerifyBlock $verifyBlock `
        -CheckBlock {
            if (-not (Test-Path -LiteralPath $sourcePath)) {
                $Logger.WrapLog(
                    "Source file '$sourcePath' not found",
                    'ERROR',
                    $Context
                )
                return @{
                    Success = $false
                    Hint    = "missing.source"
                    Detail  = $sourcePath
                }
            }

            return @{ Success = $true }
        } `
        -DoBlock {
            Copy-Item -Path $sourcePath -Destination $destinationPath -Force -ErrorAction Stop
            return @{ Success = $true }
        } `
        -VerifyBlock $verifyBlock `
        -Logger $Logger `
        -PreVerifyContext $Context `
        -CheckContext $Context `
        -DoContext $Context `
        -VerifyContext $Context

    $Logger.WriteTargetNotice("File", $destinationPath, $result, $Context, "copy")
    return $result
}

function Invoke-CopyFileBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]     $EntryContext,
        [Parameter(Mandatory)] [psobject[]] $EntryItems,
        [Parameter(Mandatory)]              $Logger,
        [hashtable]                         $Context = @{}
    )

    $stats = @{
        Observed = 0
        Applied   = 0
        Changed   = 0
        Failed    = 0
        Skipped   = 0
    }

    foreach ($item in $EntryItems) {
        $r = Invoke-CopyFile `
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

Export-ModuleMember -Function Invoke-CopyFile, Invoke-CopyFileBatch
