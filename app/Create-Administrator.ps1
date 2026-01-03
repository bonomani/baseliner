$Username = "fadmin"
$Password = "p{Gs73Z8;x"
$group = "Administrators"

$adsi = [ADSI]"WinNT://$env:COMPUTERNAME"
$existing = $adsi.Children | Where-Object { $_.SchemaClassName -eq 'user' -and $_.Name -eq $Username }

if ($existing -eq $null) {
    Write-Host "Creating new local user $Username."
    net user $Username $Password /add /y /expires:never

    Write-Host "Adding local user $Username to $group."
    net localgroup $group $Username /add
}
else {
    Write-Host "Setting password for existing local user $Username."
    $existing.SetPassword($Password)
}

Write-Host "Ensuring password for $Username never expires."
Get-WmiObject -Class Win32_UserAccount -Filter "Name='$Username' AND LocalAccount=TRUE" |
    ForEach-Object { $_.PasswordExpires = $false; $_.Put() }
