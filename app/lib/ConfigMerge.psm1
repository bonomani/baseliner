# ConfigMerge.psm1
# Deep config merge following RFC 7396 (JSON Merge Patch) semantics:
#   - null value        => remove the key (tool falls back to built-in default)
#   - absent key        => inherit from target (no change)
#   - explicit value    => set
#   - keyed array item with '$remove':true => remove matched item by identity key
#   - keyed array       => merge by 'name' or 'operation' identity key
#   - unkeyed array     => full replacement
#   - object            => recurse

function ConvertTo-Hashtable {
    param ($Value)
    if ($Value -is [hashtable]) { return $Value }
    $ht = @{}
    if ($Value) {
        foreach ($prop in $Value.PSObject.Properties) { $ht[$prop.Name] = $prop.Value }
    }
    return $ht
}

function Merge-ConfigDeep {
    param (
        [hashtable]$Target,
        $Source
    )
    if ($null -eq $Source) { return }

    $srcHT = ConvertTo-Hashtable $Source

    foreach ($key in @($srcHT.Keys)) {
        $srcVal = $srcHT[$key]

        # null => remove key
        if ($null -eq $srcVal) {
            $Target.Remove($key)
            continue
        }

        $tgtVal = $Target[$key]

        # Array handling
        $srcIsArray = $srcVal -is [array] -or $srcVal -is [System.Collections.ArrayList]
        if ($srcIsArray) {
            $srcArr = @($srcVal)
            $tgtArr = if ($tgtVal -is [array] -or $tgtVal -is [System.Collections.ArrayList]) { @($tgtVal) } else { $null }

            if ($null -ne $tgtArr) {
                # Detect identity key from first object element
                $idKey = $null
                foreach ($item in $srcArr) {
                    if ($item -is [hashtable] -or $item -is [System.Management.Automation.PSCustomObject]) {
                        $itemHT = ConvertTo-Hashtable $item
                        if ($itemHT.ContainsKey('name'))      { $idKey = 'name';      break }
                        if ($itemHT.ContainsKey('operation')) { $idKey = 'operation'; break }
                    }
                }

                if ($idKey) {
                    # Keyed merge
                    $merged = [System.Collections.Generic.List[object]]::new()
                    foreach ($item in $tgtArr) { $merged.Add((ConvertTo-Hashtable $item)) }

                    foreach ($srcItem in $srcArr) {
                        $srcItemHT = ConvertTo-Hashtable $srcItem
                        $idVal = $srcItemHT[$idKey]

                        $existingIdx = -1
                        for ($i = 0; $i -lt $merged.Count; $i++) {
                            if ($merged[$i][$idKey] -eq $idVal) { $existingIdx = $i; break }
                        }

                        # $remove:true => delete the matched item
                        if ($srcItemHT['$remove'] -eq $true) {
                            if ($existingIdx -ge 0) { $merged.RemoveAt($existingIdx) }
                            continue
                        }

                        if ($existingIdx -ge 0) {
                            Merge-ConfigDeep -Target $merged[$existingIdx] -Source $srcItemHT
                        } else {
                            $merged.Add($srcItemHT)
                        }
                    }
                    $Target[$key] = $merged.ToArray()
                    continue
                }
            }
            # No identity key or no target array => replace
            $Target[$key] = $srcArr
            continue
        }

        # Object handling => recurse
        $srcIsObj = $srcVal -is [hashtable] -or $srcVal -is [System.Management.Automation.PSCustomObject]
        $tgtIsObj = $tgtVal -is [hashtable] -or $tgtVal -is [System.Management.Automation.PSCustomObject]
        if ($srcIsObj -and $tgtIsObj) {
            if (-not ($tgtVal -is [hashtable])) {
                $tgtVal = ConvertTo-Hashtable $tgtVal
                $Target[$key] = $tgtVal
            }
            Merge-ConfigDeep -Target $tgtVal -Source $srcVal
            continue
        }

        # Scalar or type mismatch => replace
        $Target[$key] = $srcVal
    }
}

Export-ModuleMember -Function ConvertTo-Hashtable, Merge-ConfigDeep
