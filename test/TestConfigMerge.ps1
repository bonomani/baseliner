param([switch]$Debug, [string]$Mode)

. "$PSScriptRoot/_TestCommon.ps1"
Import-Module "$PSScriptRoot/../app/lib/ConfigMerge.psm1" -ErrorAction Stop -Force

# Helper: assert two values are equal
function Assert-Equal {
    param(
        [string]$Label,
        $Expected,
        $Actual
    )
    $e = if ($null -eq $Expected) { '<null>' } else { "$Expected" }
    $a = if ($null -eq $Actual)   { '<null>' } else { "$Actual" }
    if ($e -ne $a) {
        $script:TestFailed = $true
        Write-Host ("ASSERTION FAILED [{0}]: expected='{1}' actual='{2}'" -f $Label, $e, $a)
    }
}

function Assert-True {
    param([string]$Label, [bool]$Value)
    if (-not $Value) {
        $script:TestFailed = $true
        Write-Host ("ASSERTION FAILED [{0}]: expected true but got false" -f $Label)
    }
}

function Assert-False {
    param([string]$Label, [bool]$Value)
    if ($Value) {
        $script:TestFailed = $true
        Write-Host ("ASSERTION FAILED [{0}]: expected false but got true" -f $Label)
    }
}

# Only run in HappyClean (or when no mode specified)
if ($Mode -and $Mode -ne 'HappyClean') {
    Complete-Test
    return
}

Write-TestSection "Merge-ConfigDeep"

# -------------------------------------------------------
# 1. null source => no-op
# -------------------------------------------------------
Write-Host "--- null source: no-op ---"
$t = @{ a = 1 }
Merge-ConfigDeep -Target $t -Source $null
Assert-Equal "null-source.a" 1 $t['a']

# -------------------------------------------------------
# 2. null value => removes key
# -------------------------------------------------------
Write-Host "--- null value: removes key ---"
$t = @{ a = 1; b = 2 }
Merge-ConfigDeep -Target $t -Source @{ a = $null }
Assert-False "null-removes.a.exists" $t.ContainsKey('a')
Assert-Equal "null-removes.b" 2 $t['b']

# -------------------------------------------------------
# 3. absent key => inherit (no change to target)
# -------------------------------------------------------
Write-Host "--- absent key: inherit ---"
$t = @{ a = 1; b = 2 }
Merge-ConfigDeep -Target $t -Source @{ b = 99 }
Assert-Equal "absent-key.a" 1 $t['a']
Assert-Equal "absent-key.b" 99 $t['b']

# -------------------------------------------------------
# 4. explicit value => set / replace
# -------------------------------------------------------
Write-Host "--- explicit value: set ---"
$t = @{ x = 'old' }
Merge-ConfigDeep -Target $t -Source @{ x = 'new'; y = 'added' }
Assert-Equal "explicit.x" 'new' $t['x']
Assert-Equal "explicit.y" 'added' $t['y']

# -------------------------------------------------------
# 5. empty string => set (unset marker)
# -------------------------------------------------------
Write-Host "--- empty string: unset marker ---"
$t = @{ proxy = 'http://proxy:3128' }
Merge-ConfigDeep -Target $t -Source @{ proxy = '' }
Assert-Equal "empty-string.proxy" '' $t['proxy']

# -------------------------------------------------------
# 6. nested object => recurse
# -------------------------------------------------------
Write-Host "--- nested object: recurse ---"
$t = @{ db = @{ host = 'localhost'; port = 5432 } }
Merge-ConfigDeep -Target $t -Source @{ db = @{ port = 9999 } }
Assert-Equal "nested.host" 'localhost' $t['db']['host']
Assert-Equal "nested.port" 9999 $t['db']['port']

# -------------------------------------------------------
# 7. array with 'name' key => keyed merge
# -------------------------------------------------------
Write-Host "--- array merge by 'name' ---"
$t = @{
    items = @(
        @{ name = 'a'; val = 1 }
        @{ name = 'b'; val = 2 }
    )
}
Merge-ConfigDeep -Target $t -Source @{
    items = @(
        @{ name = 'b'; val = 99 }   # update existing
        @{ name = 'c'; val = 3 }    # add new
    )
}
$items = $t['items']
Assert-Equal "name-key.count" 3 $items.Count
$a = $items | Where-Object { $_['name'] -eq 'a' }
$b = $items | Where-Object { $_['name'] -eq 'b' }
$c = $items | Where-Object { $_['name'] -eq 'c' }
Assert-Equal "name-key.a.val" 1 $a['val']
Assert-Equal "name-key.b.val" 99 $b['val']
Assert-Equal "name-key.c.val" 3 $c['val']

# -------------------------------------------------------
# 8. array with 'operation' key => keyed merge
# -------------------------------------------------------
Write-Host "--- array merge by 'operation' ---"
$t = @{
    ops = @(
        @{ operation = 'install'; items = @('a') }
        @{ operation = 'remove';  items = @('x') }
    )
}
Merge-ConfigDeep -Target $t -Source @{
    ops = @(
        @{ operation = 'install'; items = @('b') }  # replace items (unkeyed sub-array)
    )
}
$ops = $t['ops']
Assert-Equal "op-key.count" 2 $ops.Count
$install = $ops | Where-Object { $_['operation'] -eq 'install' }
Assert-Equal "op-key.install.items[0]" 'b' ($install['items'][0])

# -------------------------------------------------------
# 9. $remove:true => removes matched item
# -------------------------------------------------------
Write-Host "--- `$remove:true: removes item ---"
$t = @{
    pkgs = @(
        @{ name = 'firefox' }
        @{ name = 'ccleaner' }
        @{ name = 'vlc' }
    )
}
Merge-ConfigDeep -Target $t -Source @{
    pkgs = @(
        @{ name = 'ccleaner'; '$remove' = $true }
    )
}
$pkgs = $t['pkgs']
Assert-Equal "remove.count" 2 $pkgs.Count
Assert-True  "remove.firefox-present" ($pkgs | Where-Object { $_['name'] -eq 'firefox' } | Measure-Object).Count -eq 1
Assert-False "remove.ccleaner-gone"   ($pkgs | Where-Object { $_['name'] -eq 'ccleaner' } | Measure-Object).Count -gt 0

# -------------------------------------------------------
# 10. $remove:true on non-existing item => no error
# -------------------------------------------------------
Write-Host "--- `$remove:true on missing item: no-op ---"
$t = @{ pkgs = @( @{ name = 'vlc' } ) }
Merge-ConfigDeep -Target $t -Source @{ pkgs = @( @{ name = 'ghost'; '$remove' = $true } ) }
Assert-Equal "remove-missing.count" 1 $t['pkgs'].Count

# -------------------------------------------------------
# 11. array without identity key => full replace
# -------------------------------------------------------
Write-Host "--- array without identity key: full replace ---"
$t = @{ drives = @('C', 'D') }
Merge-ConfigDeep -Target $t -Source @{ drives = @('E', 'F', 'G') }
Assert-Equal "replace-array.count" 3 $t['drives'].Count
Assert-Equal "replace-array.[0]" 'E' $t['drives'][0]

# -------------------------------------------------------
# 12. source adds new key to nested object
# -------------------------------------------------------
Write-Host "--- new key in nested object ---"
$t = @{ cfg = @{ a = 1 } }
Merge-ConfigDeep -Target $t -Source @{ cfg = @{ b = 2 } }
Assert-Equal "new-nested.a" 1 $t['cfg']['a']
Assert-Equal "new-nested.b" 2 $t['cfg']['b']

Complete-Test
