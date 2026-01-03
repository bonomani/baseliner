# FileRename.psm1
# Contract compliant rename module

Import-Module -Name "$PSScriptRoot\GeneralUtil.psm1" -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\FileUtils.psm1"   -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\PhaseAlias.psm1"  -ErrorAction Stop

# ------------------------------------------------------------
# Single operation
# ------------------------------------------------------------
function Invoke-RenameFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $EntryContext,
        [Parameter(Mandatory)][object] $Item,
        [Parameter(Mandatory)][object] $Logger,
        [hashtable]                    $Context = @{}
    )

    $hasSource = $Item.srcPath -or $Item.srcName -or ($EntryContext -and ($EntryContext.srcPath -or $EntryContext.srcName))
    $hasDestination = $Item.path -or $Item.name -or ($EntryContext -and ($EntryContext.path -or $EntryContext.name))

    if (-not $hasSource -or -not $hasDestination) {
        $Logger.WrapLog(
            "Rename skipped: missing source or destination definition",
            "ERROR",
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "File" -TargetId $targetId -Context $Context
        return $result
    }

    $resolved = Resolve-FileTargetSourcePaths `
        -Context $EntryContext `
        -Item $Item `
        -Logger $Logger `
        -LogContext $Context `
        -AllowTargetNameOnly

    if ($resolved.Error) {
        $Logger.WrapLog(
            "Rename skipped: invalid definition | Reason=$($resolved.Error)",
            "ERROR",
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "File" -TargetId $targetId -Context $Context
        return $result
    }

    $oldPath = $resolved.SourcePath
    $newPath = $resolved.TargetPath

    if (-not $newPath) {
        $Logger.WrapLog(
            "Rename skipped: missing new name",
            "ERROR",
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "File" -TargetId $targetId -Context $Context
        return $result
    }

    $Logger.WrapLog(
        "Rename file '$oldPath' to '$newPath'.",
        "INFO",
        $Context
    )

    $verifyBlock = {
        $success = ((Test-Path -LiteralPath $newPath) -and (-not (Test-Path -LiteralPath $oldPath)))
        $hint = if ($success) { "present.target" } else { "mismatch" }
        return @{
            Success = $success
            Hint    = $hint
            Detail  = "$oldPath -> $newPath"
        }
    }

    $result = Invoke-CheckDoReportPhase `
        -Action "Rename file '$oldPath' -> '$newPath'" `
        -PreVerifyBlock $verifyBlock `
        -CheckBlock {
            if (-not (Test-Path -LiteralPath $oldPath)) {
                $Logger.WrapLog(
                    "File '$oldPath' does not exist",
                    "ERROR",
                    $Context
                )
                return @{
                    Success = $false
                    Hint    = "missing.source"
                    Detail  = $oldPath
                }
            }

            return @{ Success = $true }
        } `
        -DoBlock {
            $oldDir = Split-Path -Path $oldPath -Parent
            $newDir = Split-Path -Path $newPath -Parent

            if ($newDir -and ($oldDir -ne $newDir)) {
                Move-Item -LiteralPath $oldPath -Destination $newPath -Force -ErrorAction Stop
            } else {
                $newName = Split-Path -Path $newPath -Leaf
                Rename-Item -LiteralPath $oldPath -NewName $newName -ErrorAction Stop
            }

            return @{ Success = $true }
        } `
        -VerifyBlock $verifyBlock `
        -Logger $Logger `
        -PreVerifyContext $Context `
        -CheckContext $Context `
        -DoContext $Context `
        -VerifyContext $Context

    $Logger.WriteTargetNotice("File", $oldPath, $result, $Context, "rename")
    return $result
}

# ------------------------------------------------------------
# Batch operation
# ------------------------------------------------------------
function Invoke-RenameFileBatch {
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
        $r = Invoke-RenameFile `
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

Export-ModuleMember -Function Invoke-RenameFile, Invoke-RenameFileBatch
