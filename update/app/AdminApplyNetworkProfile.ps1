# AdminApplyNetworkProfile.ps1
param (
    [string]$ConfigPath,

    [ValidateSet("DEBUG","INFO","NOTICE","WARN","ERROR")]
    [string]$LogLevel = "INFO",

    [int]$RetryCount   = 1,
    [int]$DelaySeconds = 0,

    [ValidateSet('Continue','Stop','SilentlyContinue','Inquire')]
    [string]$ErrorAction = 'Continue',

    [switch]$WhatIf,
    [switch]$Verbose,
    [switch]$Debug
)

# ------------------------------------------------------------
# Core imports
# ------------------------------------------------------------
$lib = Join-Path $PSScriptRoot 'lib'

Import-Module "$lib\GeneralUtil.psm1"     -ErrorAction Stop -Force
Import-Module "$lib\LoadScriptConfig.psm1" -ErrorAction Stop -Force

# ------------------------------------------------------------
# Bootstrap
# ------------------------------------------------------------
$init = Initialize-Script `
    -ScriptPath   $PSCommandPath `
    -ConfigPath   $ConfigPath `
    -LogLevel     $LogLevel `
    -RetryCount   $RetryCount `
    -DelaySeconds $DelaySeconds `
    -ErrorAction  $ErrorAction `
    -WhatIf:$WhatIf `
    -Verbose:$Verbose `
    -Debug:$Debug

$Logger     = $init.Logger
$Context    = $init.Context
$ConfigPath = $init.ConfigPath
$ScriptName = $init.ScriptName


$startTime = [datetime]::Now

# ------------------------------------------------------------
# Administrator requirement
# ------------------------------------------------------------
if (-not (Test-IsAdministrator)) {
    $Logger.WrapLog(
        "Script $ScriptName cannot start: administrator privileges required",
        "ERROR",
        $Context
    )
    exit 1
}

# ------------------------------------------------------------
# Script TARGET taken in charge
# ------------------------------------------------------------
$Logger.WrapLog(
    "Start script '$ScriptName'.",
    "INFO",
    $Context
)

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
$requiredFields = @("network_profile")

try {
    $config = Get-ScriptConfig `
        -ScriptName     $ScriptName `
        -ConfigPath     $ConfigPath `
        -RequiredFields $requiredFields `
        -Logger         $Logger `
        -Context        $Context
} catch {
    $Logger.WrapLog(
        "Script $ScriptName failed: configuration loading error",
        "ERROR",
        $Context
    )
    exit 1
}

$networkProfile    = $config.network_profile
$fallbackProfile   = $config.fallback_profile
$dnsSuffixExpected = $config.conditions.dns_suffix
$ipv4Ranges        = $config.conditions.ipv4_ranges

$interfaces = @(Get-NetConnectionProfile)
$Logger.WrapLog(
    "Start ${ScriptName} targets=$($interfaces.Count) scope=network",
    "DEBUG",
    $Context
)

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
function Convert-IPv4ToUInt32BE {
    param ([byte[]]$Bytes)

    [uint32](
        ($Bytes[0] -shl 24) -bor
        ($Bytes[1] -shl 16) -bor
        ($Bytes[2] -shl 8)  -bor
        ($Bytes[3])
    )
}

function Test-IPv4InCidr {
    param ([string]$Ip, [string]$Cidr)

    $parts = $Cidr -split '/'
    $networkBytes = [System.Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
    $maskBits     = [int]$parts[1]
    $ipBytes      = [System.Net.IPAddress]::Parse($Ip).GetAddressBytes()

    [uint32]$mask = 0
    for ($i = 0; $i -lt $maskBits; $i++) {
        $mask = $mask -bor ([uint32]1 -shl (31 - $i))
    }

    [uint32]$netInt = Convert-IPv4ToUInt32BE $networkBytes
    [uint32]$ipInt  = Convert-IPv4ToUInt32BE $ipBytes

    (($netInt -band $mask) -eq ($ipInt -band $mask))
}

# ------------------------------------------------------------
# Apply network profile (TARGET = network interface)
# ------------------------------------------------------------
$processed = 0
$changed   = 0
$unchanged = 0
$skipped   = 0

$interfaces | ForEach-Object {

    $processed++

    $iface = $_
    $alias = $iface.InterfaceAlias

    $Logger.WrapLog(
        "Apply network profile to interface '$alias'.",
        "INFO",
        $Context
    )

    if ($iface.NetworkCategory -eq 'DomainAuthenticated') {
        $Logger.WrapLog("Interface '$alias' skipped (DomainAuthenticated) | Reason=not_applicable", "NOTICE", $Context)
        $skipped++
        return
    }

    if ($alias -match '(?i)vpn|tap|tun|ppp|vEthernet|WSL|Hyper-V|Docker') {
        $Logger.WrapLog("Interface '$alias' skipped (virtual or VPN) | Reason=not_applicable", "NOTICE", $Context)
        $skipped++
        return
    }

    if ($iface.IPv4Connectivity -eq 'Disconnected') {
        $Logger.WrapLog("Interface '$alias' skipped (disconnected) | Reason=not_applicable", "NOTICE", $Context)
        $skipped++
        return
    }

    $dnsClient = Get-DnsClient -InterfaceIndex $iface.InterfaceIndex -ErrorAction SilentlyContinue
    $dnsSuffixActual = $dnsClient.ConnectionSpecificSuffix

    $ipv4Addrs = Get-NetIPAddress `
        -InterfaceIndex $iface.InterfaceIndex `
        -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue

    $fqdn = ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME)).HostName
    $fqdnSuffix = if ($fqdn -match '\.') { $fqdn.Substring($fqdn.IndexOf('.') + 1) }

    $conditionsPresent = ($dnsSuffixExpected -or $ipv4Ranges)
    $conditionsMatch   = $true

    if ($conditionsPresent) {

        if ($dnsSuffixExpected -and $dnsSuffixActual -ne $dnsSuffixExpected) {
            $conditionsMatch = $false
        }

        if ($ipv4Ranges) {
            $ipMatch = $false
            foreach ($addr in $ipv4Addrs) {
                foreach ($range in $ipv4Ranges) {
                    if (Test-IPv4InCidr -Ip $addr.IPAddress -Cidr $range) {
                        $ipMatch = $true
                        break
                    }
                }
            }
            if (-not $ipMatch) {
                $conditionsMatch = $false
            }
        }

    } else {
        if (-not $fqdnSuffix -or -not $dnsSuffixActual -or ($fqdnSuffix -ne $dnsSuffixActual)) {
            $Logger.WrapLog("Interface '$alias' skipped (default condition mismatch) | Reason=condition_mismatch", "NOTICE", $Context)
            $skipped++
            return
        }
    }

    $targetProfile = if ($conditionsMatch) {
        $networkProfile
    } elseif ($fallbackProfile) {
        $fallbackProfile
    }

    if (-not $targetProfile) {
        $Logger.WrapLog("Interface '$alias' unchanged (no applicable profile) | Reason=not_applicable", "NOTICE", $Context)
        $unchanged++
        return
    }

    if ($iface.NetworkCategory -eq $targetProfile) {
        $Logger.WrapLog("Interface '$alias' already '$targetProfile' | Reason=match", "NOTICE", $Context)
        $unchanged++
        return
    }

    if (-not $WhatIf) {
        Set-NetConnectionProfile `
            -InterfaceAlias $alias `
            -NetworkCategory $targetProfile `
            -ErrorAction SilentlyContinue
    }

    $Logger.WrapLog("Interface '$alias' set to '$targetProfile' | Reason=mismatch", "NOTICE", $Context)
    $changed++
}

# ------------------------------------------------------------
# Script final observable state
# ------------------------------------------------------------
$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)
$observed = $processed
$applied  = $changed
$failed   = 0
$scope = "network"

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$observed applied=$applied changed=$changed failed=$failed skipped=$skipped | scope=$scope",
    "NOTICE",
    $Context
)

exit 0
