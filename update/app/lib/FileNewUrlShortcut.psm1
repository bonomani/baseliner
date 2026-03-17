Import-Module -Name "$PSScriptRoot\GeneralUtil.psm1" -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\FileUtils.psm1"   -ErrorAction Stop
Import-Module -Name "$PSScriptRoot\PhaseAlias.psm1"  -ErrorAction Stop

function Invoke-NewUrlShortcut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $EntryContext,
        [Parameter(Mandatory)][object] $Item,
        [Parameter(Mandatory)][object] $Logger,
        [hashtable] $Context = @{}
    )

    $resolved = Resolve-FileTargetPath `
        -Context $EntryContext `
        -Item $Item `
        -Logger $Logger `
        -LogContext $Context

    if ($resolved.Error) {
        $Logger.WrapLog(
            "URL shortcut skipped: invalid definition | Reason=$($resolved.Error)",
            'ERROR',
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "File" -TargetId $targetId -Context $Context
        return $result
    }

    $lnkPath = $resolved.TargetPath
    if (-not $lnkPath) {
        $Logger.WrapLog(
            "URL shortcut skipped: missing name",
            'ERROR',
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "File" -TargetId $targetId -Context $Context
        return $result
    }
    $skipCom = $false
    if ($Context -and $Context.SkipCom -eq $true) {
        $skipCom = $true
    }

    if ([System.IO.Path]::GetExtension($lnkPath) -eq '') {
        $lnkPath = if ($skipCom) { "$lnkPath.url" } else { "$lnkPath.lnk" }
    } elseif ($skipCom -and [System.IO.Path]::GetExtension($lnkPath) -ne '.url') {
        $lnkPath = [System.IO.Path]::ChangeExtension($lnkPath, '.url')
    }

    $shortcutUrl = $Item.url
    if (-not $shortcutUrl -and $EntryContext) {
        $shortcutUrl = $EntryContext.url
    }
    if (-not $shortcutUrl) {
        $Logger.WrapLog(
            "URL shortcut skipped: missing url",
            'ERROR',
            $Context
        )
        $targetId = Get-FileTargetIdCandidate -Context $EntryContext -Item $Item
        $result = Write-InvalidDefinitionNotice -Logger $Logger -TargetType "File" -TargetId $targetId -Context $Context
        return $result
    }

    $iconResolved = Resolve-Item `
        -Context $EntryContext `
        -Item $Item `
        -ItemContextPairs @('iconPath','iconFolder','iconName') `
        -ErrorCode "missing_icon"

    $expandedIcon = $null
    if (-not $iconResolved.Error) {
        if ($iconResolved.iconPath) {
            $expandedIcon = Expand-Path -Path $iconResolved.iconPath -Logger $Logger -Context $Context
        } elseif ($iconResolved.iconFolder -and $iconResolved.iconName) {
            $iconFolder = Expand-Path -Path $iconResolved.iconFolder -Logger $Logger -Context $Context
            $expandedIcon = Join-Path $iconFolder $iconResolved.iconName
        }
    }

    $lnkLeaf = Split-Path -Path $lnkPath -Leaf
    $lnkDir  = Split-Path -Path $lnkPath -Parent
    $Logger.WrapLog(
        "Create URL shortcut '$lnkLeaf' in '$lnkDir'.",
        'INFO',
        $Context
    )

    function Test-UrlShortcutCompliance {
        param([string]$Path)

        if (-not (Test-Path -LiteralPath $Path)) {
            return @{
                Success = $false
                Hint    = "absent.target"
                Detail  = $Path
            }
        }

        if ($skipCom) {
            $content = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue
            $urlOk = $content -contains "URL=$shortcutUrl"
            $iconOk = if ($expandedIcon) { $content -contains "IconFile=$expandedIcon" } else { $true }
            if ($urlOk -and $iconOk) {
                return @{ Success = $true; Hint = "present.target"; Detail = $Path }
            }
            return @{
                Success = $false
                Hint    = "mismatch"
                Detail  = $Path
            }
        }

        $shell = New-Object -ComObject WScript.Shell
        try {
            $sc = $shell.CreateShortcut($Path)
            $currentArgs = $sc.Arguments
            $currentIcon = $sc.IconLocation -replace ',\d+$', ''

            $argsOk = ($currentArgs -eq $shortcutUrl)
            $iconOk = if ($expandedIcon) { $currentIcon -ieq $expandedIcon } else { $true }

            if ($argsOk -and $iconOk) {
                return @{ Success = $true; Hint = "present.target"; Detail = $Path }
            }

            return @{
                Success = $false
                Hint    = "mismatch"
                Detail  = $Path
            }
        } catch {
            return @{
                Success = $false
                Hint    = "exception"
                Detail  = $_.Exception.Message
            }
        } finally {
            Close-ComObject $shell
        }
    }

    $verifyBlock = { Test-UrlShortcutCompliance -Path $lnkPath }

    $result = Invoke-CheckDoReportPhase `
        -Action "Create URL shortcut '$lnkPath'" `
        -PreVerifyBlock $verifyBlock `
        -CheckBlock {
            if ($expandedIcon -and -not (Test-Path -LiteralPath $expandedIcon)) {
                $Logger.WrapLog(
                    "Icon file '$expandedIcon' not found",
                    'ERROR',
                    $Context
                )
                return @{
                    Success = $false
                    Hint    = "missing.icon"
                    Detail  = $expandedIcon
                }
            }

            return @{ Success = $true }
        } `
        -DoBlock {
            if ($skipCom) {
                $lines = @(
                    "[InternetShortcut]",
                    "URL=$shortcutUrl"
                )
                if ($expandedIcon) {
                    $lines += "IconFile=$expandedIcon"
                    $lines += "IconIndex=0"
                }
                Set-Content -Path $lnkPath -Value $lines -Encoding ASCII
                return @{ Success = $true }
            }

            $shell = New-Object -ComObject WScript.Shell
            try {
                $sc = $shell.CreateShortcut($lnkPath)
                $sc.TargetPath = 'explorer.exe'
                $sc.Arguments  = $shortcutUrl
                if ($expandedIcon) {
                    $sc.IconLocation = "$expandedIcon,0"
                }
                $sc.Save()
                return @{ Success = $true }
            } catch {
                $Logger.WrapLog(
                    "URL shortcut failed: $_",
                    'ERROR',
                    $Context
                )
                return @{
                    Success = $false
                    Hint    = "exception"
                    Detail  = $_.Exception.Message
                }
            } finally {
                Close-ComObject $shell
            }
        } `
        -VerifyBlock $verifyBlock `
        -Logger $Logger `
        -PreVerifyContext $Context `
        -CheckContext $Context `
        -DoContext $Context `
        -VerifyContext $Context

    $Logger.WriteTargetNotice("File", $lnkPath, $result, $Context, "shortcut")
    return $result
}

function Invoke-NewUrlShortcutBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]     $EntryContext,
        [Parameter(Mandatory)][psobject[]] $EntryItems,
        [Parameter(Mandatory)][object] $Logger,
        [hashtable] $Context = @{}
    )

    $stats = @{
        Observed = 0
        Applied   = 0
        Changed   = 0
        Failed    = 0
        Skipped   = 0
    }

    foreach ($item in $EntryItems) {
        $r = Invoke-NewUrlShortcut `
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

Export-ModuleMember -Function Invoke-NewUrlShortcut, Invoke-NewUrlShortcutBatch
