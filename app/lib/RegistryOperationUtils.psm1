# Shared utilities for registry operations (batch dispatch, handling set-keyvalue, etc.)

Import-Module -Name "$PSScriptRoot\GeneralUtil.psm1"           -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\RegistrySetKeyValue.psm1"  -ErrorAction Stop
#Import-Module -Name "$PSScriptRoot\RegistryRemove.psm1"      -ErrorAction Stop
#Import-Module -Name "$PSScriptRoot\RegistryCreate.psm1"      -ErrorAction Stop
#Import-Module -Name "$PSScriptRoot\RegistryUpdate.psm1"      -ErrorAction Stop

function Invoke-RegistryBatchOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $Operation,
        [Parameter(Mandatory)] [psobject] $Entry,
        [Parameter(Mandatory)] [object]   $Logger,
        [hashtable]                       $Context = @{ }
    )

    $entryTargetCount = 0
    if ($Entry.items) {
        $entryTargetCount = $Entry.items.Count
    }
        # Entry summary is covered by batch start + dispatch logs below.

    $EntryContext = $Entry.context
    $EntryItems   = $Entry.items

    $targetCount = 0
    if ($EntryItems) {
        $targetCount = $EntryItems.Count
    }

    if ($null -eq $EntryItems -or -not ($EntryItems -is [array])) {
        $Logger.WrapLog(
            "Registry operation skipped: invalid definition (items missing or not an array)",
            "ERROR",
            $Context
        )
        $Logger.WrapLog(
            "Registry operation skipped: invalid definition | Reason=invalid_definition | observed=0 applied=0 changed=0 failed=0 skipped=1",
            "NOTICE",
            $Context
        )
        return @{
            Observed  = 0
            Applied   = 0
            Changed   = 0
            Failed    = 0
            Skipped   = 1
            Reason    = "invalid_definition"
        }
    }

    if ($EntryItems.Count -eq 0) {
        $Logger.WrapLog(
            "Registry operation has no items (noop)",
            "WARN",
            $Context
        )
        $Logger.WrapLog(
            "Registry operation skipped: no items | Reason=not_applicable | observed=0 applied=0 changed=0 failed=0 skipped=1",
            "NOTICE",
            $Context
        )
        return @{
            Observed  = 0
            Applied   = 0
            Changed   = 0
            Failed    = 0
            Skipped   = 1
            Reason    = "not_applicable"
        }
    }

    $handlerName = "Invoke-$($Operation -replace '-','')Batch"
    $cmd = Get-Command $handlerName -ErrorAction SilentlyContinue

    if (-not $cmd) {
        $Logger.WrapLog(
            "Unsupported registry operation '$Operation' (handler '$handlerName' not found)",
            "ERROR",
            $Context
        )
        $Logger.WrapLog(
            "Registry operation skipped: invalid definition | Reason=invalid_definition | observed=0 applied=0 changed=0 failed=0 skipped=1",
            "NOTICE",
            $Context
        )
        return @{
            Observed  = 0
            Applied   = 0
            Changed   = 0
            Failed    = 0
            Skipped   = 1
            Reason    = "invalid_definition"
        }
    }

    $allParams = @{
        EntryContext = $EntryContext
        EntryItems   = $EntryItems
        Logger       = $Logger
        Context      = $Context
    }

    $splat = @{ }
    foreach ($paramName in $cmd.Parameters.Keys) {
        if ($allParams.ContainsKey($paramName)) {
            $splat[$paramName] = $allParams[$paramName]
        }
    }

    $Logger.WrapLog(
        "Registry batch: op=$Operation targets=$targetCount scope=registry handler=$handlerName",
        "DEBUG",
        $Context
    )

    $result = & $cmd @splat

    if (-not $result -or -not ($result -is [hashtable])) {
        $Logger.WrapLog(
            "Handler '$handlerName' returned invalid result (not a hashtable)",
            "ERROR",
            $Context
        )
        $Logger.WrapLog(
            "Registry operation failed: invalid handler result | Reason=exception | observed=0 applied=0 changed=0 failed=1 skipped=0",
            "NOTICE",
            $Context
        )
        return @{
            Observed  = 0
            Applied   = 0
            Changed   = 0
            Failed    = 1
            Skipped   = 0
            Reason    = "exception"
        }
    }

    foreach ($k in @('Observed','Applied','Changed','Failed','Skipped')) {
        if (-not $result.ContainsKey($k)) {
            $result[$k] = 0
        }
    }

    return @{
        Observed  = [int]$result.Observed
        Applied   = [int]$result.Applied
        Changed   = [int]$result.Changed
        Failed    = [int]$result.Failed
        Skipped   = [int]$result.Skipped
    }
}

Export-ModuleMember -Function Invoke-RegistryBatchOperation
