# FirewallSetRule.psm1
# Contract-compliant firewall rule application

Import-Module -Name "$PSScriptRoot\GeneralUtil.psm1"       -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\FirewallRuleUtils.psm1" -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\PhaseAlias.psm1"        -ErrorAction Stop

function Invoke-SetFirewallRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $EntryContext,
        [Parameter(Mandatory)] [object] $Item,
        [Parameter(Mandatory)] [object] $Logger,
        [hashtable]                     $Context = @{}
    )

    $name = $Item.name
    if (-not $name) {
        $Logger.WrapLog(
            "Firewall rule skipped: missing name",
            "ERROR",
            $Context
        )
        return Write-InvalidDefinitionNotice -Logger $Logger -TargetType "Firewall rule" -TargetId "<missing-name>" -Context $Context
    }

    $direction = if ($Item.direction) { $Item.direction } elseif ($EntryContext -and $EntryContext.direction) { $EntryContext.direction } else { $null }
    $action    = if ($Item.action)    { $Item.action }    elseif ($EntryContext -and $EntryContext.action)    { $EntryContext.action }    else { $null }
    $profiles  = if ($Item.profiles)  { $Item.profiles }  elseif ($EntryContext -and $EntryContext.profiles)  { $EntryContext.profiles }  else { $null }

    $program  = $Item.program
    $service  = $Item.service
    $port     = $Item.port
    $protocol = $Item.protocol

    $requiresPort = ($protocol -notmatch "^ICMP") -and ($protocol -ne "Any")

    $profilesEmpty = $false
    if ($profiles -is [array]) {
        $profilesEmpty = ($profiles.Count -eq 0)
    } elseif ($profiles -is [string]) {
        $profilesEmpty = ([string]::IsNullOrWhiteSpace($profiles))
    }

    if (-not $direction -or -not $action -or -not $protocol -or ($requiresPort -and -not $port) -or -not $profiles -or $profilesEmpty) {
        $Logger.WrapLog(
            "Firewall rule '$name' skipped: invalid definition",
            "ERROR",
            $Context
        )
        return Write-InvalidDefinitionNotice -Logger $Logger -TargetType "Firewall rule" -TargetId $name -Context $Context
    }

    $desired = @{
        Direction    = $direction
        Action       = $action
        Protocol     = $protocol
        Port         = $port
        Profiles     = $profiles
        Program      = $program
        Service      = $service
        RequiresPort = $requiresPort
    }

    $params = @{
        DisplayName         = $name
        Direction           = $direction
        Action              = $action
        Protocol            = $protocol
        Profile             = $profiles
        Enabled             = "True"
        EdgeTraversalPolicy = "Block"
        ErrorAction         = "SilentlyContinue"
    }

    if ($requiresPort)                       { $params.LocalPort = $port }
    if ($program -and $program -ne "System") { $params.Program   = $program }
    if ($service)                            { $params.Service   = $service }

    $Logger.WrapLog(
        "Set firewall rule '$name'.",
        "INFO",
        $Context
    )

    function Test-FirewallCompliance {
        $existingRules = @(Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)
        foreach ($existing in $existingRules) {
            if (Test-FirewallRuleMatch -ExistingRule $existing -Desired $desired -Logger $Logger -Context $Context) {
                return @{
                    Success = $true
                    Hint    = "match"
                    Detail  = $name
                }
            }
        }

        return @{
            Success = $false
            Hint    = "mismatch"
            Detail  = $name
        }
    }

    $verifyBlock = { Test-FirewallCompliance }

    $result = Invoke-CheckDoReportPhase `
        -Action "Set firewall rule '$name'" `
        -PreVerifyBlock $verifyBlock `
        -CheckBlock { return @{ Success = $true } } `
        -DoBlock {
            $existingRules = @(Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)
            if ($existingRules.Count -gt 0) {
                $Logger.WrapLog(
                    "Firewall rule '$name' differs from existing rules; recreating",
                    "DEBUG",
                    $Context
                )
                Remove-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue
            }

            New-NetFirewallRule @params | Out-Null
            return @{ Success = $true }
        } `
        -VerifyBlock $verifyBlock `
        -Logger $Logger `
        -PreVerifyContext $Context `
        -CheckContext $Context `
        -DoContext $Context `
        -VerifyContext $Context

    $Logger.WriteTargetNotice("Firewall rule", $name, $result, $Context, "set")
    return $result
}

function Invoke-SetFirewallRuleBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object]     $EntryContext,
        [Parameter(Mandatory)] [psobject[]] $EntryItems,
        [Parameter(Mandatory)] [object]     $Logger,
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
        $r = Invoke-SetFirewallRule `
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

Export-ModuleMember -Function Invoke-SetFirewallRule, Invoke-SetFirewallRuleBatch
