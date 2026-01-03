# Validate-Logs.ps1
# Compatible PowerShell 5.1
# Contract/logging validator with target pairing and summary reporting

param (
    [Parameter(Position = 0)]
    [string]$Path = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) "data\\logs"),

    [switch]$Recurse,
    [int]$NoticeWindow = 50,
    [switch]$AllowDuplicateNotice
)

if (-not (Test-Path $Path)) {
    Write-Error "Path not found: $Path"
    exit 1
}

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Write-Output "Validate-Logs: root=$root"
Write-Output "Validate-Logs: path=$Path"

$files = @()
if (Test-Path $Path -PathType Leaf) {
    $files = @($Path)
} else {
    $files = Get-ChildItem -Path $Path -Filter *.log -File -Recurse:$Recurse
}

if (-not $files -or $files.Count -eq 0) {
    Write-Error "No log files found under: $Path"
    exit 1
}

$fileCount = $files.Count
Write-Output "Validate-Logs: files=$fileCount"

$errors = @()
$summaries = @()

function Get-LogLines {
    param([string]$FilePath)
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    if (-not $bytes -or $bytes.Length -eq 0) { return @() }

    $nullCount = 0
    for ($i = 1; $i -lt $bytes.Length; $i += 2) {
        if ($bytes[$i] -eq 0) { $nullCount++ }
    }

    if ($nullCount -gt ($bytes.Length / 4)) {
        $text = [System.Text.Encoding]::Unicode.GetString($bytes)
    } else {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    }

    return $text -split "`r?`n"
}

function Test-RunMarker {
    param([string]$Line)
    return ($Line -match '^=== RUN \d+ (START|END) ===$')
}

function Assert-InfoNoticePairs {
    param(
        [string]$FilePath,
        [hashtable]$InfoTargets,
        [hashtable]$NoticeTargets
    )
    foreach ($key in $InfoTargets.Keys) {
        $candidate = $key
        if ($key.StartsWith("INFO|")) {
            $candidate = $key.Substring(5)
            $found = $false
            foreach ($nkey in $NoticeTargets.Keys) {
                if ($nkey.EndsWith("|$candidate") -or $nkey -match "\|$([regex]::Escape($candidate))$") {
                    $found = $true
                    break
                }
            }
            if (-not $found) {
                $errors += "${FilePath}: INFO without final NOTICE target '${candidate}'"
                Write-Output "Validate-Logs: INFO without final NOTICE target"
            }
        }
    }
}

function Get-NoticeTargetKey {
    param([string]$Line)
    $m = [regex]::Match($Line, '\[NOTICE\]\s+([A-Za-z_]+)\s+(.+?)(\s+\||$)')
    if (-not $m.Success) { return $null }
    $type = $m.Groups[1].Value.Trim()
    $id = $m.Groups[2].Value.Trim()
    if (-not $type -or -not $id) { return $null }
    return "$type|$id"
}

function Get-NoticeOperator {
    param([string]$Line)
    $m = [regex]::Match($Line, '\[NOTICE\]\s+[A-Za-z_]+\s+.+?\s+([A-Za-z_-]+)\s*\|')
    if (-not $m.Success) { return "unknown" }
    return $m.Groups[1].Value.Trim().ToLower()
}

function Get-SkippedOperatorFromError {
    param([string]$Line)
    $m = [regex]::Match($Line, '\[ERROR\]\s+(.+?)\s+skipped', 'IgnoreCase')
    if (-not $m.Success) { return $null }
    $text = $m.Groups[1].Value.Trim().ToLower()
    if ($text -like 'copy file*') { return 'copy' }
    if ($text -like 'remove file*') { return 'remove' }
    if ($text -like 'rename*') { return 'rename' }
    if ($text -like 'acl*') { return 'acl' }
    if ($text -like 'split*') { return 'split' }
    if ($text -like 'join*') { return 'join' }
    if ($text -like 'compression*') { return 'compress' }
    if ($text -like 'extract*') { return 'extract' }
    if ($text -like 'url shortcut*') { return 'shortcut' }
    if ($text -like 'registry value*') { return 'registry' }
    return $null
}

function Get-InfoTargetKey {
    param([string]$Line)
    # Prefer quoted target id if present.
    $m = [regex]::Match($Line, '\[INFO\].*?''([^'']+)''')
    if ($m.Success) { return "INFO|$($m.Groups[1].Value.Trim())" }
    $m = [regex]::Match($Line, '\[INFO\]\s+([A-Za-z_]+)\s+(.+)$')
    if (-not $m.Success) { return $null }
    $type = $m.Groups[1].Value.Trim()
    $id = $m.Groups[2].Value.Trim()
    if (-not $type -or -not $id) { return $null }
    return "$type|$id"
}

foreach ($file in $files) {
    Write-Output "Validate-Logs: scanning $file"
    $lines = Get-LogLines -FilePath $file.FullName
    $levelCounts = @{ INFO = 0; NOTICE = 0; DEBUG = 0; WARN = 0; ERROR = 0 }
    $reasonCounts = @{}
    $infoTargets = @{}
    $noticeTargets = @{}
    $errorLines = @()
    $warnLines = @()
    $lastSkippedOperator = $null

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '\[INFO\]') { $levelCounts.INFO++ }
        elseif ($line -match '\[NOTICE\]') { $levelCounts.NOTICE++ }
        elseif ($line -match '\[DEBUG\]') { $levelCounts.DEBUG++ }
        elseif ($line -match '\[WARN\]') { $levelCounts.WARN++ }
        elseif ($line -match '\[ERROR\]') { $levelCounts.ERROR++ }

        if (Test-RunMarker -Line $line) {
            if ($line -match 'END') {
                Assert-InfoNoticePairs -FilePath $file -InfoTargets $infoTargets -NoticeTargets $noticeTargets
            }
            $infoTargets = @{}
            $noticeTargets = @{}
            continue
        }

        if ($line -match '\[INFO\]') {
            $key = Get-InfoTargetKey -Line $line
            if ($key) { $infoTargets[$key] = $true }
        }

        if ($line -match '\[ERROR\]') {
            $op = Get-SkippedOperatorFromError -Line $line
            if ($op) { $lastSkippedOperator = $op }
        }

        if ($line -match '\[NOTICE\]') {
            $key = Get-NoticeTargetKey -Line $line
            if ($key) {
                $op = Get-NoticeOperator -Line $line
                if ($op -eq 'skipped' -and $key -match '\|<unresolved>' -and $lastSkippedOperator) {
                    $op = $lastSkippedOperator
                }
                if ($noticeTargets.ContainsKey($key)) {
                    if ($noticeTargets[$key].ContainsKey($op)) {
                        $errors += "${file}: duplicate NOTICE for target $key | $line"
                        Write-Output "Validate-Logs: duplicate NOTICE for target"
                    } else {
                        $noticeTargets[$key][$op] = $true
                    }
                } else {
                    $noticeTargets[$key] = @{}
                    $noticeTargets[$key][$op] = $true
                }
            }
            $mReason = [regex]::Match($line, 'Reason=([A-Za-z0-9_.-]+)')
            if ($mReason.Success) {
                $reason = $mReason.Groups[1].Value
                if (-not $reasonCounts.ContainsKey($reason)) { $reasonCounts[$reason] = 0 }
                $reasonCounts[$reason]++
            }
        }

        if ($line -match '\[ERROR\]') { $errorLines += $i }
        if ($line -match '\[WARN\]') { $warnLines += $i }
    }

    foreach ($line in $lines) {
        if (Test-RunMarker -Line $line) { continue }
        if ($line -notmatch '\[NOTICE\]') { continue }

        $hasObserved = $line -match 'observed='
        $hasApplied = $line -match 'applied='
        $hasChanged = $line -match 'changed='
        $hasFailed = $line -match 'failed='
        $hasSkipped = $line -match 'skipped='
        $hasReason = $line -match 'Reason='

        $isAggregate = ($line -match 'End script') -or ($line -match 'Reason=aggregate')

        if ($isAggregate) {
            if (-not $hasReason -or $line -notmatch 'Reason=aggregate') {
                $errors += "${file}: missing Reason=aggregate | $line"
                Write-Output "Validate-Logs: missing Reason=aggregate"
            }
            if (-not ($hasObserved -and $hasApplied -and $hasChanged -and $hasFailed -and $hasSkipped)) {
                $errors += "${file}: aggregate missing counters | $line"
                Write-Output "Validate-Logs: missing aggregate counters"
            }
            continue
        }

        if (-not $hasReason) {
            $errors += "${file}: missing Reason on target NOTICE | $line"
            Write-Output "Validate-Logs: missing Reason on target NOTICE"
        }

        if (-not ($hasObserved -and $hasApplied -and $hasChanged -and $hasFailed -and $hasSkipped)) {
            $errors += "${file}: missing counters on target NOTICE | $line"
            Write-Output "Validate-Logs: missing counters on target NOTICE"
        }

        if ($line -match 'already compliant' -and $line -notmatch 'Reason=match' -and $line -notmatch 'Reason=preverify\.ok' -and $line -notmatch 'Reason=verify\.ok') {
            $errors += "${file}: already compliant without Reason=match or Reason=preverify.ok | $line"
            Write-Output "Validate-Logs: already compliant without Reason=match or Reason=preverify.ok"
        }

        $matchObserved = [regex]::Match($line, 'observed=(\d+)')
        $matchApplied = [regex]::Match($line, 'applied=(\d+)')
        $matchChanged = [regex]::Match($line, 'changed=(\d+)')
        $matchFailed = [regex]::Match($line, 'failed=(\d+)')
        $matchSkipped = [regex]::Match($line, 'skipped=(\d+)')

        if ($matchObserved.Success -and $matchApplied.Success -and $matchChanged.Success -and $matchFailed.Success -and $matchSkipped.Success) {
            $obs = [int]$matchObserved.Groups[1].Value
            $app = [int]$matchApplied.Groups[1].Value
            $chg = [int]$matchChanged.Groups[1].Value
            $fail = [int]$matchFailed.Groups[1].Value
            $skip = [int]$matchSkipped.Groups[1].Value

            if ($chg -gt 0 -and ($app -eq 0 -or $obs -eq 0)) {
                $errors += "${file}: Changed implies Applied and Observed | $line"
                Write-Output "Validate-Logs: contract violation changed->applied/observed"
            }

            if ($fail -gt 0 -and ($app -eq 0 -or $obs -eq 0)) {
                $errors += "${file}: Failed implies Applied and Observed | $line"
                Write-Output "Validate-Logs: contract violation failed->applied/observed"
            }

            if ($skip -gt 0 -and $app -ne 0) {
                $errors += "${file}: Skipped implies Applied=0 | $line"
                Write-Output "Validate-Logs: contract violation skipped->applied=0"
            }

            if ($obs -eq 0 -and ($app -gt 0 -or $chg -gt 0 -or $fail -gt 0)) {
                $errors += "${file}: Observed=0 with non-zero action/failed/changed | $line"
                Write-Output "Validate-Logs: contract violation observed=0 with action"
            }
        }
    }

    Assert-InfoNoticePairs -FilePath $file -InfoTargets $infoTargets -NoticeTargets $noticeTargets

    foreach ($idx in $errorLines + $warnLines) {
        $start = $idx + 1
        $end = [Math]::Min($lines.Count - 1, $idx + $NoticeWindow)
        $hasNotice = $false
        for ($j = $start; $j -le $end; $j++) {
            if ($lines[$j] -match '\[NOTICE\]') { $hasNotice = $true; break }
        }
        if (-not $hasNotice) {
            $errors += "${file}: WARN/ERROR without nearby NOTICE (within $NoticeWindow lines) | $($lines[$idx])"
            Write-Output "Validate-Logs: WARN/ERROR without nearby NOTICE"
        }
    }

    $summaries += [pscustomobject]@{
        File = $file
        Info = $levelCounts.INFO
        Notice = $levelCounts.NOTICE
        Debug = $levelCounts.DEBUG
        Warn = $levelCounts.WARN
        Error = $levelCounts.ERROR
        Reasons = ($reasonCounts.Keys | Sort-Object | ForEach-Object { "$_=$($reasonCounts[$_])" }) -join ", "
    }
}

if ($errors.Count -gt 0) {
    Write-Output "Contract/logging validation failed:"
    $errors | ForEach-Object { Write-Output $_ }
    exit 1
}

Write-Output "Validate-Logs: summary"
$summaries | ForEach-Object {
    Write-Output ("- {0} | INFO={1} NOTICE={2} DEBUG={3} WARN={4} ERROR={5} | Reasons: {6}" -f $_.File, $_.Info, $_.Notice, $_.Debug, $_.Warn, $_.Error, $_.Reasons)
}

Write-Output "Contract/logging validation passed."
exit 0
