function Get-StartupPrograms {
    $keyPaths = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
    )

    Write-Host "Scanning for startup programs..."
    foreach ($keyPath in $keyPaths) {
        try {
            Write-Host "Checking registry path: $keyPath"
            $items = Get-ItemProperty -Path $keyPath
            
            foreach ($item in $items.PSObject.Properties) {
                $name = $item.Name
                $value = $item.Value
                $status = 'Unknown'
                $enabledPath = $keyPath -replace 'Explorer\\StartupApproved\\', ''

                # Check if the entry is in the StartupApproved
                if ($keyPath -match 'StartupApproved') {
                    # Interpret the first byte to determine status
                    $statusByte = [byte]$value[0]
                    $status = switch ($statusByte) {
                        2 {'Enabled'}
                        3 {'Disabled'}
                        default {'Unknown'}
                    }
                    # Attempt to fetch the corresponding command from Run
                    $command = (Get-ItemProperty -Path $enabledPath -Name $name -ErrorAction SilentlyContinue).$name
                } else {
                    # This is a direct Run entry, check in StartupApproved for its status
                    $approvalPath = $keyPath -replace 'Run', 'Explorer\StartupApproved\Run'
                    $approvalData = (Get-ItemProperty -Path $approvalPath -Name $name -ErrorAction SilentlyContinue).$name
                    if ($approvalData) {
                        $statusByte = [byte]$approvalData[0]
                        $status = switch ($statusByte) {
                            2 {'Enabled'}
                            3 {'Disabled'}
                            default {'Unknown'}
                        }
                    } else {
                        $status = 'Not controlled by StartupApproved'
                    }
                    $command = $value
                }

                Write-Host "`tName: $name"
                Write-Host "`tCommand: $command"
                Write-Host "`tStatus: $status"
                Write-Host "---------------------"
            }
        } catch {
            Write-Host "Failed to access or process $keyPath"
        }
    }
}

# Execute the function to list startup programs
Get-StartupPrograms
