function Convert-FirewallProfileMask {
    param ($Mask, $Logger, $Context)

    if ($null -eq $Mask) {
        $Logger.WrapLog("ProfileMask: null (unspecified)", "DEBUG", $Context)
        return $null
    }

    try {
        $intMask = [int]$Mask
    } catch {
        $Logger.WrapLog("ProfileMask: invalid '$Mask'", "DEBUG", $Context)
        return $null
    }

    if ($intMask -eq 0) {
        $Logger.WrapLog("ProfileMask: 0 (unspecified)", "DEBUG", $Context)
        return $null
    }

    $map = @{
        1 = "Domain"
        2 = "Private"
        4 = "Public"
    }

    $profiles = @()
    foreach ($bit in ($map.Keys | Sort-Object)) {
        if ($intMask -band $bit) {
            $profiles += $map[$bit]
        }
    }

    return $profiles
}

function Convert-Protocol {
    param ($Protocol, $Logger, $Context)

    if ($null -eq $Protocol) {
        $Logger.WrapLog("Protocol: null (unspecified)", "DEBUG", $Context)
        return $null
    }

    if ($Protocol -is [int]) {
        return $Protocol
    }

    switch ("$Protocol".ToUpper()) {
        "TCP"    { return 6 }
        "UDP"    { return 17 }
        "ICMP"   { return 1 }
        "ICMPV4" { return 1 }
        "ICMPV6" { return 58 }
        "ANY"    { return "Any" }
        default {
            $Logger.WrapLog("Protocol: unknown '$Protocol'", "DEBUG", $Context)
            return $Protocol
        }
    }
}

function Convert-Profiles {
    param ($Profiles, $Logger, $Context)

    if ($null -eq $Profiles) {
        return $null
    }

    if ($Profiles -eq "Any") {
        return @()
    }

    if ($Profiles -is [array]) {
        return ($Profiles | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Sort-Object)
    }

    return (
        $Profiles -split "," |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ } |
        Sort-Object
    )
}

function Test-FirewallRuleMatch {
    param (
        [Microsoft.Management.Infrastructure.CimInstance] $ExistingRule,
        [hashtable] $Desired,
        $Logger,
        $Context
    )


    $portFilter = Get-NetFirewallPortFilter `
        -AssociatedNetFirewallRule $ExistingRule `
        -ErrorAction SilentlyContinue

    $appFilter = Get-NetFirewallApplicationFilter `
        -AssociatedNetFirewallRule $ExistingRule `
        -ErrorAction SilentlyContinue

    $result = @{}

    $result.DirectionMatch = ($ExistingRule.Direction -eq $Desired.Direction)
    if (-not $result.DirectionMatch) {
        $Logger.WrapLog(
            "Compare Direction mismatch: existing=$($ExistingRule.Direction) desired=$($Desired.Direction)",
            "DEBUG",
            $Context
        )
    }

    $result.ActionMatch = ($ExistingRule.Action -eq $Desired.Action)
    if (-not $result.ActionMatch) {
        $Logger.WrapLog(
            "Compare Action mismatch: existing=$($ExistingRule.Action) desired=$($Desired.Action)",
            "DEBUG",
            $Context
        )
    }

    $result.EnabledMatch = ($ExistingRule.Enabled -eq $true)
    if (-not $result.EnabledMatch) {
        $Logger.WrapLog(
            "Compare Enabled mismatch: existing=$($ExistingRule.Enabled) expected=True",
            "DEBUG",
            $Context
        )
    }

    $result.EdgeMatch = ($ExistingRule.EdgeTraversalPolicy -eq "Block")
    if (-not $result.EdgeMatch) {
        $Logger.WrapLog(
            "Compare EdgeTraversalPolicy mismatch: existing=$($ExistingRule.EdgeTraversalPolicy) expected=Block",
            "DEBUG",
            $Context
        )
    }

    $existingProto = if ($portFilter -and $portFilter.Protocol) {
        Convert-Protocol $portFilter.Protocol $Logger $Context
    } else {
        Convert-Protocol $ExistingRule.Protocol $Logger $Context
    }

    $desiredProto = Convert-Protocol $Desired.Protocol $Logger $Context

    $result.ProtocolMatch = (
        $existingProto -eq $desiredProto -or
        $existingProto -eq "Any" -or
        $desiredProto  -eq "Any"
    )

    if (-not $result.ProtocolMatch) {
        $Logger.WrapLog(
            "Compare Protocol mismatch: existing=$existingProto desired=$desiredProto",
            "DEBUG",
            $Context
        )
    }

    if ($Desired.ContainsKey("Port") -and $Desired.RequiresPort) {
        if (-not $portFilter) {
            $result.PortMatch = $false
            $Logger.WrapLog("Compare Port mismatch: missing PortFilter", "DEBUG", $Context)
        } else {
            $result.PortMatch = ("$($portFilter.LocalPort)" -eq "$($Desired.Port)")
            if (-not $result.PortMatch) {
                $Logger.WrapLog(
                    "Compare Port mismatch: existing=$($portFilter.LocalPort) desired=$($Desired.Port)",
                    "DEBUG",
                    $Context
                )
            }
        }
    } else {
        $result.PortMatch = $true
    }

    $existingProfiles = Convert-Profiles `
        (Convert-FirewallProfileMask $ExistingRule.Profile $Logger $Context) `
        $Logger $Context

    $desiredProfiles = Convert-Profiles $Desired.Profiles $Logger $Context

    $result.ProfilesMatch = (
        $existingProfiles -eq $null -or
        $desiredProfiles -eq $null -or
        (($existingProfiles -join ",") -eq ($desiredProfiles -join ","))
    )

    if (-not $result.ProfilesMatch) {
        $Logger.WrapLog(
            "Compare Profiles mismatch: existing=$($existingProfiles -join ',') desired=$($desiredProfiles -join ',')",
            "DEBUG",
            $Context
        )
    }

    if ($Desired.ContainsKey("Program") -and $Desired.Program -and $Desired.Program -ne "System") {
        $existingProgram = if ($appFilter) { $appFilter.Program } else { $null }
        $result.ProgramMatch = ($existingProgram -eq $Desired.Program)
        if (-not $result.ProgramMatch) {
            $Logger.WrapLog(
                "Compare Program mismatch: existing=$existingProgram desired=$($Desired.Program)",
                "DEBUG",
                $Context
            )
        }
    } else {
        $result.ProgramMatch = $true
    }

    if ($Desired.ContainsKey("Service")) {
        if ($ExistingRule.Service -ne $Desired.Service) {
            $Logger.WrapLog(
                "Compare Service mismatch: existing=$($ExistingRule.Service) desired=$($Desired.Service)",
                "DEBUG",
                $Context
            )
        }
    }

    foreach ($key in @(
        "DirectionMatch",
        "ActionMatch",
        "EnabledMatch",
        "EdgeMatch",
        "ProtocolMatch",
        "PortMatch",
        "ProfilesMatch",
        "ProgramMatch"
    )) {
        if (-not $result[$key]) {
            $Logger.WrapLog("Rule match: FAIL ($key)", "DEBUG", $Context)
            return $false
        }
    }

    return $true
}

Export-ModuleMember -Function `
    Convert-FirewallProfileMask, `
    Convert-Protocol, `
    Convert-Profiles, `
    Test-FirewallRuleMatch
