$host_path = (Get-CimInstance -Class Win32_OperatingSystem).WindowsDirectory
$host_name = (Get-CimInstance -Class Win32_ComputerSystem).Name
$host_file = Join-Path -Path $host_path -Child 'NetBTDisable.log'
Start-Transcript -Path $host_file -Append
Write-Output "Found current computer name: $host_name"
$nic_change = $false
Try {
	# retrieve NICs with NBT enabled
	$nbt_nics = $null
	$nbt_nics = Get-ChildItem 'HKLM:SYSTEM\CurrentControlSet\services\NetBT\Parameters\Interfaces' | Get-ItemProperty | Where-Object {$_.NetbiosOptions -eq '0'}
	# update NICs
	If ($nbt_nics.Count -gt 0) {
		$nic_change = $true
		ForEach ($nbt_nic in $nbt_nics) {
			Write-Output "Fixing $($nbt_nic.PSChildName)"
			Set-ItemProperty -Path $nbt_nic.PSPath -Name 'NetbiosOptions' -Value 2
		}
	}
}
Finally {
	Stop-Transcript
	If ($nic_change) {
		# Restart-Computer
	}
}
