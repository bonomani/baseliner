# UserMapDrives.ps1
# Compatible PowerShell 5.1

param (
    $Logger,
    $Context,

    [string]$ConfigPath,

    [ValidateSet("DEBUG","INFO","NOTICE","WARN","ERROR")]
    [string]$LogLevel = "NOTICE",

    [int]$RetryCount   = 1,
    [int]$DelaySeconds = 0,

    [ValidateSet('Continue','Stop','SilentlyContinue','Inquire')]
    [string]$ErrorAction = 'Continue',

    [switch]$WhatIf,
    [switch]$Confirm,
    [switch]$Force,
    [switch]$Verbose,
    [switch]$Debug
)

# ------------------------------------------------------------
# Core imports (NO Logger import)
# ------------------------------------------------------------
$lib = Join-Path $PSScriptRoot 'lib'

Import-Module (Join-Path $lib 'GeneralUtil.psm1')            -ErrorAction Stop -Force
Import-Module (Join-Path $lib 'FileUtils.psm1')              -ErrorAction Stop -Force
Import-Module (Join-Path $lib 'LoadScriptConfig.psm1')       -ErrorAction Stop -Force
Import-Module (Join-Path $lib 'FileOperationUtils.psm1')     -ErrorAction Stop -Force
Import-Module (Join-Path $lib 'RegistryOperationUtils.psm1') -ErrorAction Stop -Force

# ------------------------------------------------------------
# Bootstrap (only if Logger / Context not provided)
# ------------------------------------------------------------
if (-not $Logger -or -not $Context) {

    $init = Initialize-Script `
        -ScriptPath   $PSCommandPath `
        -ConfigPath   $ConfigPath `
        -LogLevel     $LogLevel `
        -RetryCount   $RetryCount `
        -DelaySeconds $DelaySeconds `
        -ErrorAction  $ErrorAction `
        -WhatIf:$WhatIf `
        -Confirm:$Confirm `
        -Force:$Force `
        -Verbose:$Verbose `
        -Debug:$Debug

    if (-not $Logger)  { $Logger  = $init.Logger }
    if (-not $Context) { $Context = $init.Context }

    $DataRoot   = $init.DataRoot
    $ConfigPath = $init.ConfigPath
    $ScriptName = $init.ScriptName

$startTime = [datetime]::Now

}

# ------------------------------------------------------------
# Block elevated execution (user-context requirement)
# ------------------------------------------------------------
if (Test-IsAdministrator) {
    $Logger.WrapLog(
        "This script must not run elevated",
        "ERROR",
        $Context
    )
    exit 1
}

# ------------------------------------------------------------
# Script start (TARGET taken in charge)
# ------------------------------------------------------------
$Logger.WrapLog(
    "Start script '$ScriptName'.",
    "INFO",
    $Context
)

# ------------------------------------------------------------
# Load configuration
# ------------------------------------------------------------
$RequiredFields = @("DriveMappings")

try {
    $Config = Get-ScriptConfig `
        -ScriptName     $ScriptName `
        -ConfigPath     $ConfigPath `
        -RequiredFields $RequiredFields `
        -Logger         $Logger
} catch {
    $Logger.WrapLog("Failed to load configuration file", "ERROR", $Context)
    exit 1
}

$DriveMappings = $Config.DriveMappings

$Logger.WrapLog(
    "Start ${ScriptName} targets=$($DriveMappings.Count) scope=drives",
    "DEBUG",
    $Context
)


# Initialize data structures
$serverToDrives = @{}
$driveToServers = @{}
$serverToDrivesToNetworkPath = @{}
$serversToTest = @()
$drivesToTest = @()

# First loop to construct $serverToDrivesToNetworkPath
foreach ($drive in $driveMappings) {
    $driveLetter    = $drive.DriveLetter
    $primaryServer  = $drive.NetworkPath -replace "^\\\\([^\\]+)\\.*$", '$1'
    $backupServer   = $drive.BackupNetworkPath -replace "^\\\\([^\\]+)\\.*$", '$1'

    if ($primaryServer) {
        if (-not $serverToDrivesToNetworkPath.ContainsKey($primaryServer)) {
            $serverToDrivesToNetworkPath[$primaryServer] = @{}
        }
        if (-not $serverToDrivesToNetworkPath[$primaryServer].ContainsKey($driveLetter)) {
            $serverToDrivesToNetworkPath[$primaryServer][$driveLetter] = $drive.NetworkPath
        }
        if (-not $serversToTest.Contains($primaryServer)) {
            $serversToTest += $primaryServer
        }
    }

    if ($backupServer) {
        if (-not $serverToDrivesToNetworkPath.ContainsKey($backupServer)) {
            $serverToDrivesToNetworkPath[$backupServer] = @{}
        }
        if (-not $serverToDrivesToNetworkPath[$backupServer].ContainsKey($driveLetter)) {
            $serverToDrivesToNetworkPath[$backupServer][$driveLetter] = $drive.BackupNetworkPath
        }
        if (-not $serversToTest.Contains($backupServer)) {
            $serversToTest += $backupServer
        }
    }
}


# Second loop to construct all other variables
foreach ($server in $serverToDrivesToNetworkPath.Keys) {
    foreach ($driveLetter in $serverToDrivesToNetworkPath[$server].Keys) {

        # Update server to drives mapping
        if (-not $serverToDrives.ContainsKey($server)) {
            $serverToDrives[$server] = @()
        }
        if (-not $serverToDrives[$server].Contains($driveLetter)) {
            $serverToDrives[$server] += $driveLetter
        }

        # Update drive to servers mapping
        if (-not $driveToServers.ContainsKey($driveLetter)) {
            $driveToServers[$driveLetter] = @()
        }
        if (-not $driveToServers[$driveLetter].Contains($server)) {
            $driveToServers[$driveLetter] += $server
        }

        # Update drives to test
        if (-not $drivesToTest.Contains($driveLetter)) {
            $drivesToTest += $driveLetter
        }
    }
}

# Function to update servers to test
function Update-ServersToTest {
    param (
        [array]     $drivesToTest,
        [hashtable] $driveToServers,
        [string]    $currentServer,
        [array]     $serversToTest
    )
    return @(
        $drivesToTest |
        Where-Object { $_ -ne $null } |
        ForEach-Object {
            if ($driveToServers.ContainsKey($_)) {
                $driveToServers[$_]
            }
        } |
        Where-Object { $_ -ne $null } |
        Select-Object -Unique |
        Where-Object { $_ -ne $currentServer -and $serversToTest -contains $_ }
    )
}

# Function to update drives to test
function Update-DrivesToTest {
    param (
        [array]     $serversToTest,
        [hashtable] $serverToDrives
    )
    return @(
        $serversToTest |
        Where-Object { $_ -ne $null } |
        ForEach-Object {
            if ($serverToDrives.ContainsKey($_)) {
                $serverToDrives[$_]
            }
        } |
        Where-Object { $_ -ne $null } |
        Select-Object -Unique
    )
}

# Function to validate network path
function Test-NetworkPath {
    param (
        [string] $path
    )
    try {
        if (Test-Path -Path $path) {
            return $true
        } else {
            $Logger.WrapLog("Network path '$path' does not exist", "DEBUG", $Context)
            return $false
        }
    } catch {
        $Logger.WrapLog("Failed to validate network path '$path'", "ERROR", $Context)
        return $false
    }
}

# Function to map network path
function Map-NetworkPath {
    param (
        [string] $driveLetter,
        [string] $pathToMap
    )
    $Logger.WrapLog("Mapping drive '$driveLetter' to '$pathToMap'", "DEBUG", $context)
    if (-not (Test-NetworkPath -path $pathToMap)) {
        $Logger.WrapLog("Drive $driveLetter with path '$pathToMap' seems not valid.", "DEBUG", $context)
        #return
    }

    try {
        New-PSDrive -Name $driveLetter -PSProvider FileSystem -Root $pathToMap -Persist -Scope Global > $null 2>&1
    } catch {
        $Logger.WrapLog("Failed to map drive $driveLetter to network path '$pathToMap'", "ERROR", $Context)
    }
}

# Function to remove existing drives
function Remove-Drives {
    param (
        [hashtable] $workingDrive
    )
    foreach ($driveLetter in $workingDrive.Keys) {
        if (Test-Path -Path "$driveLetter`:") {
            Remove-PSDrive -Name $driveLetter -Force -ErrorAction SilentlyContinue
            net use "${driveLetter}:" /delete /y > $null 2>&1
        }
    }
}

# Function to map drives
function Map-Drives {
    param (
        [hashtable] $workingDrive
    )
    foreach ($driveLetter in $workingDrive.Keys) {
        $pathToMap = $workingDrive[$driveLetter]
        if ($pathToMap -and -not (Test-Path -Path "$driveLetter`:")) {
            Map-NetworkPath -driveLetter $driveLetter -pathToMap $pathToMap
        }
    }
}

# Test servers and map drives
$workingServer = @{}
$workingDrive = @{}

while ($serversToTest.Count -gt 0) {
    $server = $serversToTest[0]
    $Logger.WrapLog("Testing server: $server", "DEBUG", $context)
    if (Test-Connection -ComputerName $server -Count 2 -Quiet -ErrorAction SilentlyContinue) {
        $workingServer[$server] = $true
        $Logger.WrapLog("Server $server reachable", "DEBUG", $context)

        foreach ($drive in $serverToDrives[$server]) {
            $Logger.WrapLog("Map drive '$drive'.", "INFO", $context)
            $workingDrive[$drive] = $serverToDrivesToNetworkPath[$server][$drive]
            $drivesToTest = $drivesToTest | Where-Object { $_ -ne $drive }
        }
    } else {
        $Logger.WrapLog("Server $server not reachable", "DEBUG", $Context)
    }

    $serversToTest = @(
        $(Update-ServersToTest `
            -drivesToTest   $drivesToTest `
            -driveToServers $driveToServers `
            -currentServer  $server `
            -serversToTest  $serversToTest)
    )
    $drivesToTest = @(
        $(Update-DrivesToTest `
            -serversToTest $serversToTest `
            -serverToDrives $serverToDrives)
    )
}
# ------------------------------------------------------------
# No drives to process (explicit final state)
# ------------------------------------------------------------
if ($workingDrive.Count -eq 0) {
    $total = $DriveMappings.Count
    $duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)
    $observed = $total
    $applied  = 0
    $changed  = 0
    $failed   = 0
    $skipped  = $total
    $Logger.WrapLog(
        "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$observed applied=$applied changed=$changed failed=$failed skipped=$skipped | scope=drives",
        "NOTICE",
        $context
    )
    exit 1
}



Remove-Drives -workingDrive $workingDrive
Map-Drives -workingDrive $workingDrive

$validCount = 0
foreach ($drive in $workingDrive.Keys) {
    $path = "$drive`:"
    if (Test-Path -Path $path) {
        $validCount++
        $Logger.WrapLog("Drive '$drive' mapped to '$($workingDrive[$drive])' | Reason=mismatch", "NOTICE", $Context)
    } else {
        $Logger.WrapLog(
            "Drive '$drive' failed to map to '$($workingDrive[$drive])' | Reason=exception",
            "NOTICE",
            $Context
        )
    }
}

$total     = $workingDrive.Count
$failCount = $total - $validCount

$state = if ($failCount -eq 0) {
    "completed | Reason=aggregate | duration=${duration}s | observed=$observed applied=$applied changed=$changed failed=$failed skipped=$skipped | scope=drives"
} elseif ($validCount -gt 0) {
    "completed with degraded result"
} else {
    "failed"
}

$duration = [math]::Round(([datetime]::Now - $startTime).TotalSeconds, 2)
$observed = $total
$applied  = $total
$changed  = $validCount
$failed   = $failCount
$skipped  = 0

$Logger.WrapLog(
    "End script '$ScriptName' | Reason=aggregate | duration=${duration}s | observed=$observed applied=$applied changed=$changed failed=$failed skipped=$skipped | scope=drives",
    "NOTICE",
    $Context
)

exit 0
