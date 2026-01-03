function Test-ConfigValidity {
    param (
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [string[]]$RequiredFields,
        [object]$Logger = $null,
        [hashtable]$Context = @{}
    )

    if (-not $Config) {
        $msg = "Configuration object is null or empty."
        if ($Logger) { $Logger.WrapLog($msg, "ERROR", $Context) }
        throw $msg
    }

    foreach ($field in $RequiredFields) {
        if ($Logger) { $Logger.WrapLog("Validating presence of required field: $field", "DEBUG", $Context) }

        if (-not $Config.PSObject.Properties.Name -contains $field -or $null -eq $Config.$field) {
            $msg = "Missing or null required field in configuration: $field"
            if ($Logger) { $Logger.WrapLog($msg, "ERROR", $Context) }
            throw $msg
        }
    }
}

function Get-ScriptConfig {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ScriptName,

        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [string[]]$RequiredFields = @(),
        [object]$Logger = $null,
        [hashtable]$Context = @{}
    )

    if ($Logger) { $Logger.WrapLog("Loading config file: '$ConfigPath'", "DEBUG", $Context) }

    if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
        throw "Configuration file not found at path: '$ConfigPath'"
    }

    $json = Get-Content -Path $ConfigPath -Raw
    $fullConfig = $json | ConvertFrom-Json

    if (-not $fullConfig.PSObject.Properties.Name -contains $ScriptName) {
        throw "No configuration section for script '$ScriptName' in '$ConfigPath'"
    }

    $scriptConfig = $fullConfig.$ScriptName

    Test-ConfigValidity -Config $scriptConfig -RequiredFields $RequiredFields -Logger $Logger -Context $Context

    return $scriptConfig
}

Export-ModuleMember -Function Get-ScriptConfig
