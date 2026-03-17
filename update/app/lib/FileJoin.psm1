# FileJoin.psm1
# Join files - contract compliant

Import-Module -Name "$PSScriptRoot\GeneralUtil.psm1" -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\FileUtils.psm1"   -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\PhaseAlias.psm1"  -ErrorAction Stop

# ------------------------------------------------------------
# Single operation
# ------------------------------------------------------------
function Invoke-JoinFile {
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
        -LogContext $Context `
        -AllowSourceFolderOnly

    if ($resolved.Error) {
        $Logger.WrapLog(
            "Join skipped: invalid definition | Reason=$($resolved.Error)",
            "ERROR",
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "File" -TargetId $targetId -Context $Context
        return $result
    }

    $parts = $Item.parts
    if (-not $parts -and $EntryContext) {
        $parts = $EntryContext.parts
    }
    if (-not $parts) {
        $Logger.WrapLog(
            "Join skipped: missing parts list",
            "ERROR",
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "File" -TargetId $targetId -Context $Context
        return $result
    }

    $src = $resolved.SourcePath
    $dst = $resolved.TargetPath

    if (-not $src -or -not $dst) {
        $Logger.WrapLog(
            "Join skipped: invalid source or destination path",
            "ERROR",
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "File" -TargetId $targetId -Context $Context
        return $result
    }

    $Logger.WrapLog(
        "Join files into '$dst'.",
        'INFO',
        $Context
    )

    # TODO: Pre-verify only checks destination presence; may skip stale/mismatched join output.
    $verifyBlock = {
        $exists = Test-Path -LiteralPath $dst
        return @{
            Success = $exists
            Hint    = if ($exists) { "present.target" } else { "absent.target" }
            Detail  = $dst
        }
    }

    $r = Invoke-CheckDoReportPhase `
        -Action "Join files '$dst'" `
        -PreVerifyBlock $verifyBlock `
        -CheckBlock {
            foreach ($file in $parts) {
                if (-not (Test-Path -LiteralPath (Join-Path $src $file))) {
                    $Logger.WrapLog(
                        "Missing chunk '$file' in '$src'",
                        'ERROR',
                        $Context
                    )
                    return @{
                        Success = $false
                        Hint    = "missing.source"
                        Detail  = "$src\\$file"
                    }
                }
            }
            return @{ Success = $true }
        } `
        -DoBlock {
            $out = [System.IO.File]::Open($dst, 'Create')
            try {
                foreach ($file in $parts) {
                    $path = Join-Path $src $file
                    $fs   = [System.IO.File]::OpenRead($path)
                    $buf  = New-Object byte[] 4096

                    try {
                        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
                            $out.Write($buf, 0, $n)
                        }
                    } finally {
                        $fs.Close()
                    }
                }
            } finally {
                $out.Close()
            }
            return @{ Success = $true }
        } `
        -VerifyBlock $verifyBlock `
        -Logger $Logger `
        -PreVerifyContext $Context `
        -CheckContext $Context `
        -DoContext $Context `
        -VerifyContext $Context

    $Logger.WriteTargetNotice("File", $dst, $r, $Context, "join")
    return $r
}

# ------------------------------------------------------------
# Batch operation
# ------------------------------------------------------------
function Invoke-JoinFileBatch {
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
        $r = Invoke-JoinFile `
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

Export-ModuleMember -Function Invoke-JoinFile, Invoke-JoinFileBatch
