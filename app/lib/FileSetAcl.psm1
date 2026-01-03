# FileSetAcl.psm1
# Contract compliant ACL module

Import-Module -Name "$PSScriptRoot\GeneralUtil.psm1" -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\FileUtils.psm1"   -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\PhaseAlias.psm1"  -ErrorAction Stop

# ------------------------------------------------------------
# Single operation
# ------------------------------------------------------------
function Invoke-SetAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]   $EntryContext,
        [Parameter(Mandatory)][object]   $Item,
        [Parameter(Mandatory)][object]   $Logger,
        [hashtable]                      $Context = @{}
    )

    $accessRules = $Item.accessRules
    if (-not $accessRules -and $EntryContext) {
        $accessRules = $EntryContext.accessRules
    }
    if (-not $accessRules) {
        $Logger.WrapLog(
            "ACL skipped: missing accessRules",
            "ERROR",
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "File" -TargetId $targetId -Context $Context
        return $result
    }

    function Test-PermissionsCompliance {
        param([string]$Path)

        if (-not (Test-Path -LiteralPath $Path)) {
            return @{
                Success = $false
                Hint    = "absent.target"
                Detail  = $Path
            }
        }

        $acl = Get-Acl -LiteralPath $Path
        $currentSddl = $acl.Sddl
        $desiredAcl = $acl.GetType().GetConstructor(@()).Invoke(@())
        $desiredAcl.SetSecurityDescriptorSddlForm($currentSddl)
        foreach ($rule in $accessRules) {
            $desiredAcl.AddAccessRule($rule)
        }
        $desiredSddl = $desiredAcl.Sddl

        if ($currentSddl -eq $desiredSddl) {
            return @{
                Success = $true
                Hint    = "match"
                Detail  = $Path
            }
        }

        return @{
            Success = $false
            Hint    = "mismatch"
            Detail  = $Path
        }
    }

    $target = Resolve-FileTargetPath `
        -Context $EntryContext `
        -Item $Item `
        -Logger $Logger `
        -LogContext $Context

    if ($target.Error) {
        $Logger.WrapLog(
            "ACL skipped: invalid definition | Reason=$($target.Error)",
            "ERROR",
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "File" -TargetId $targetId -Context $Context
        return $result
    }

    $filePath = $target.TargetPath
    if (-not $filePath) {
        $Logger.WrapLog(
            "ACL skipped: invalid target path",
            "ERROR",
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "File" -TargetId $targetId -Context $Context
        return $result
    }

    $Logger.WrapLog(
        "Set ACL on '$filePath'.",
        "INFO",
        $Context
    )

    $verifyBlock = { Test-PermissionsCompliance -Path $filePath }

    $r = Invoke-CheckDoReportPhase `
        -Action "Set ACL on '$filePath'" `
        -PreVerifyBlock $verifyBlock `
        -CheckBlock {
            if (-not (Test-Path -LiteralPath $filePath)) {
                $Logger.WrapLog(
                    "File '$filePath' does not exist",
                    "ERROR",
                    $Context
                )
                return @{
                    Success = $false
                    Hint    = "absent.target"
                    Detail  = $filePath
                }
            }

            return @{ Success = $true }
        } `
        -DoBlock {
            $acl = Get-Acl -LiteralPath $filePath
            foreach ($rule in $accessRules) {
                $acl.AddAccessRule($rule)
            }
            Set-Acl -LiteralPath $filePath -AclObject $acl
            return @{ Success = $true }
        } `
        -VerifyBlock $verifyBlock `
        -Logger $Logger `
        -PreVerifyContext $Context `
        -CheckContext $Context `
        -DoContext $Context `
        -VerifyContext $Context

    $Logger.WriteTargetNotice("File", $filePath, $r, $Context, "acl")
    return $r
}

# ------------------------------------------------------------
# Batch operation
# ------------------------------------------------------------
function Invoke-SetAclBatch {
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
        $r = Invoke-SetAcl `
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

Export-ModuleMember -Function Invoke-SetAcl, Invoke-SetAclBatch
