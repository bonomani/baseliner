# FileRemove.psm1

Import-Module -Name "$PSScriptRoot\GeneralUtil.psm1" -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\FileUtils.psm1"   -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\PhaseAlias.psm1"  -ErrorAction Stop

function Invoke-RemoveFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]    $EntryContext,
        [Parameter(Mandatory)][object]    $Item,
        [Parameter(Mandatory)][object]    $Logger,
        [hashtable]                       $Context = @{}
    )

    $resolved = Resolve-FileTargetPath `
        -Context $EntryContext `
        -Item $Item `
        -Logger $Logger `
        -LogContext $Context

    if ($resolved.Error) {
        $Logger.WrapLog(
            "Remove file skipped: invalid target | Reason=$($resolved.Error)",
            'ERROR',
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "File" -TargetId $targetId -Context $Context
        return $result
    }

    $filePath = $resolved.TargetPath

    $Logger.WrapLog(
        "Remove file '$filePath'.",
        'INFO',
        $Context
    )

    $verifyBlock = {
        $success = -not (Test-Path -LiteralPath $filePath)
        $hint = if ($success) { "absent.target" } else { "present.target" }
        return @{
            Success = $success
            Hint    = $hint
            Detail  = $filePath
        }
    }

    $result = Invoke-CheckDoReportPhase `
        -Action "Remove file '$filePath'" `
        -PreVerifyBlock $verifyBlock `
        -CheckBlock {
            return @{ Success = $true }
        } `
        -DoBlock {
            Remove-Item -LiteralPath $filePath -Force -ErrorAction Stop
            return @{ Success = $true }
        } `
        -VerifyBlock $verifyBlock `
        -Logger $Logger `
        -PreVerifyContext $Context `
        -CheckContext $Context `
        -DoContext $Context `
        -VerifyContext $Context

    $Logger.WriteTargetNotice("File", $filePath, $result, $Context, "remove")
    return $result
}

function Invoke-RemoveFileBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]     $EntryContext,
        [Parameter(Mandatory)][psobject[]] $EntryItems,
        [Parameter(Mandatory)][object]     $Logger,
        [hashtable]                        $Context = @{}
    )

    $stats = @{
        Observed  = 0
        Applied   = 0
        Changed   = 0
        Failed    = 0
        Skipped   = 0
    }

    foreach ($item in $EntryItems) {
        $r = Invoke-RemoveFile `
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

Export-ModuleMember -Function Invoke-RemoveFile, Invoke-RemoveFileBatch
