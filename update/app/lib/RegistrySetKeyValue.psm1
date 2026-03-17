Import-Module -Name "$PSScriptRoot\GeneralUtil.psm1"    -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\PhaseAlias.psm1"    -ErrorAction Stop

function Invoke-SetKeyValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object] $EntryContext,
        [Parameter(Mandatory)] [object] $Item,
        [Parameter(Mandatory)] [object] $Logger,
        [hashtable] $Context = @{}
    )

    function Get-RegistryTargetIdCandidate {
        param([object]$ContextObj, [object]$ItemObj)

        $ctxTable = @{}
        if ($ContextObj -is [hashtable]) {
            $ctxTable = $ContextObj
        } elseif ($ContextObj) {
            foreach ($prop in $ContextObj.PSObject.Properties) {
                $ctxTable[$prop.Name] = $prop.Value
            }
        }

        $itemTable = @{}
        if ($ItemObj -is [hashtable]) {
            $itemTable = $ItemObj
        } elseif ($ItemObj) {
            foreach ($prop in $ItemObj.PSObject.Properties) {
                $itemTable[$prop.Name] = $prop.Value
            }
        }

        $keyPath = if ($ctxTable.key) { $ctxTable.key } else { $itemTable.key }
        $name = if ($itemTable.name) { $itemTable.name } else { $ctxTable.name }

        if ($keyPath -and $name) { return ($keyPath.TrimEnd('\') + "\" + $name) }
        if ($keyPath) { return $keyPath }
        if ($name) { return $name }
        return "<unresolved>"
    }

    if ($Item.key) {
        $Logger.WrapLog(
            "Registry value skipped: key must be provided at context level",
            "ERROR",
            $Context
        )
        $targetId = Get-RegistryTargetIdCandidate -ContextObj $EntryContext -ItemObj $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "Registry" -TargetId $targetId -Context $Context
        return $result
    }

    $KeyPath = $null
    if ($EntryContext) {
        $KeyPath = $EntryContext.key
    }
    $Name  = $Item.name
    $Value = $Item.value
    $Type  = $Item.type

    if (-not $KeyPath -or -not $Name -or $null -eq $Value -or -not $Type) {
        $Logger.WrapLog(
            "Registry value skipped: invalid definition",
            "ERROR",
            $Context
        )
        $targetId = Get-RegistryTargetIdCandidate -ContextObj $EntryContext -ItemObj $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "Registry" -TargetId $targetId -Context $Context
        return $result
    }

    function Get-RegistryValueKind {
        param(
            [string]$Type
        )

        switch ($Type.ToLower()) {
            'string'       { return [Microsoft.Win32.RegistryValueKind]::String }
            'expandstring' { return [Microsoft.Win32.RegistryValueKind]::ExpandString }
            'dword'        { return [Microsoft.Win32.RegistryValueKind]::DWord }
            'qword'        { return [Microsoft.Win32.RegistryValueKind]::QWord }
            'binary'       { return [Microsoft.Win32.RegistryValueKind]::Binary }
            'multistring'  { return [Microsoft.Win32.RegistryValueKind]::MultiString }
            default        { return $null }
        }
    }

    $regType = Get-RegistryValueKind -Type $Type
    if (-not $regType) {
        $Logger.WrapLog(
            "Registry value skipped: unsupported type '$Type'",
            "ERROR",
            $Context
        )
        $targetId = Get-RegistryTargetIdCandidate -ContextObj $EntryContext -ItemObj $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "Registry" -TargetId $targetId -Context $Context
        return $result
    }

    $KeyPath = Expand-TemplateValue -Template $KeyPath
    if ($Type -in @('String','ExpandString')) {
        $Value = Expand-TemplateValue -Template $Value
    }

    # Normalize accidental double backslashes to avoid invalid subkey paths.
    $KeyPath = $KeyPath -replace '\\\\+', '\'

    switch -Regex ($KeyPath) {
        '^HKLM[:\\]' { $KeyPath = $KeyPath -replace '^HKLM[:]', 'HKEY_LOCAL_MACHINE' }
        '^HKCU[:\\]' { $KeyPath = $KeyPath -replace '^HKCU[:]', 'HKEY_CURRENT_USER' }
        '^HKU[:\\]'  { $KeyPath = $KeyPath -replace '^HKU[:]',  'HKEY_USERS' }
        '^HKCR[:\\]' { $KeyPath = $KeyPath -replace '^HKCR[:]', 'HKEY_CLASSES_ROOT' }
    }

    if ($KeyPath -notmatch '^HKEY_(LOCAL_MACHINE|CURRENT_USER|USERS|CLASSES_ROOT)\\') {
        $Logger.WrapLog(
            "Registry value skipped: unsupported root hive in '$KeyPath'",
            "ERROR",
            $Context
        )
        $targetId = Get-RegistryTargetIdCandidate -ContextObj $EntryContext -ItemObj $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "Registry" -TargetId $targetId -Context $Context
        return $result
    }

    $valuePath = $KeyPath.TrimEnd('\') + "\" + $Name

    $Logger.WrapLog(
        "Set registry value '$valuePath'.",
        "INFO",
        $Context
    )

    function Get-RegistryState {
        param([string]$KeyPath, [string]$Name)

        $rootKey, $subKeyPath = $KeyPath -split "\\", 2
        $regRoot = switch ($rootKey) {
            'HKEY_LOCAL_MACHINE' { [Microsoft.Win32.Registry]::LocalMachine }
            'HKEY_CURRENT_USER'  { [Microsoft.Win32.Registry]::CurrentUser }
            'HKEY_USERS'         { [Microsoft.Win32.Registry]::Users }
            'HKEY_CLASSES_ROOT'  { [Microsoft.Win32.Registry]::ClassesRoot }
        }

        if (-not $regRoot) {
            return @{
                Found = $false
                Value = $null
                Type  = $null
            }
        }

        $key = $regRoot.OpenSubKey($subKeyPath)
        if (-not $key) {
            return @{
                Found = $false
                Value = $null
                Type  = $null
            }
        }

        $currentValue = $key.GetValue(
            $Name,
            $null,
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
        )
        $currentType  = if ($null -ne $currentValue) {
            $key.GetValueKind($Name).ToString()
        } else { $null }
        $key.Close()

        return @{
            Found = $true
            Value = $currentValue
            Type  = $currentType
        }
    }

    function Get-RegistryMatchResult {
        param(
            [string]$KeyPath,
            [string]$Name,
            $ExpectedValue,
            [string]$ExpectedType
        )

        $state = Get-RegistryState -KeyPath $KeyPath -Name $Name
        if (-not $state.Found) {
            return @{
                Success = $false
                Hint    = "missing.target"
                Detail  = $null
            }
        }

        $valueMatches = $false
        if ($ExpectedType.ToLower() -eq 'binary' -and $null -ne $state.Value -and $null -ne $ExpectedValue) {
            $stateBytes = [byte[]]$state.Value
            $expectedBytes = [byte[]]$ExpectedValue
            $valueMatches = ($stateBytes.Length -eq $expectedBytes.Length) -and
                ($stateBytes -ceq $expectedBytes)
        } else {
            $valueMatches = ($state.Value -eq $ExpectedValue)
        }

        $match = $valueMatches -and
            ($state.Type.ToLower() -eq $ExpectedType.ToLower())

        return @{
            Success = $match
            Hint    = if ($match) { "match" } else { "mismatch" }
            Detail  = $null
        }
    }

    $verifyBlock = {
        try {
            $result = Get-RegistryMatchResult -KeyPath $KeyPath -Name $Name -ExpectedValue $Value -ExpectedType $Type
            return @{
                Success = $result.Success
                Hint    = $result.Hint
                Detail  = $valuePath
            }
        } catch {
            return @{ Success = $false; Hint = "exception"; Detail = $_.Exception.Message }
        }
    }

    $result = Invoke-CheckDoReportPhase `
        -Action "Set registry value '$valuePath'" `
        -PreVerifyBlock $verifyBlock `
        -CheckBlock {
            if ($Context -and $Context.OnlyInvalidState -eq $true) {
                return @{
                    Success = $false
                    Hint    = "mismatch"
                    Detail  = $valuePath
                }
            }
            return @{ Success = $true }
        } `
        -DoBlock {
            $rootKey, $subKeyPath = $KeyPath -split "\\", 2
            $regRoot = switch ($rootKey) {
                'HKEY_LOCAL_MACHINE' { [Microsoft.Win32.Registry]::LocalMachine }
                'HKEY_CURRENT_USER'  { [Microsoft.Win32.Registry]::CurrentUser }
                'HKEY_USERS'         { [Microsoft.Win32.Registry]::Users }
                'HKEY_CLASSES_ROOT'  { [Microsoft.Win32.Registry]::ClassesRoot }
                default              { $null }
            }

            if ($regRoot -and $subKeyPath) {
                $created = $regRoot.CreateSubKey($subKeyPath.TrimStart('\'))
                if ($created) { $created.Close() }
            }

            [Microsoft.Win32.Registry]::SetValue($KeyPath, $Name, $Value, $regType)
            return @{ Success = $true }
        } `
        -VerifyBlock $verifyBlock `
        -Logger $Logger `
        -PreVerifyContext $Context `
        -DoContext $Context `
        -VerifyContext $Context

    $Logger.WriteTargetNotice("Registry", $valuePath, $result, $Context, "set")
    return $result
}

function Invoke-SetKeyValueBatch {
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
        $r = Invoke-SetKeyValue `
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

Export-ModuleMember -Function Invoke-SetKeyValue, Invoke-SetKeyValueBatch
