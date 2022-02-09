$host_path = (Get-CimInstance -Class Win32_OperatingSystem).WindowsDirectory
$host_file = Join-Path -Path $host_path -Child 'NetBTDisable.log'
$nic_fixed = $false
$nic_w_nbt = $null
$nic_w_nbt = Get-ChildItem 'HKLM:SYSTEM\CurrentControlSet\services\NetBT\Parameters\Interfaces' | Get-ItemProperty | Where-Object { $_.NetbiosOptions -eq '0' }
If ($nic_w_nbt.Count -gt 0) {
	Start-Transcript -Path $host_file -Append
	$nic_fixed = $true
	ForEach ($nic_to_fix in $nic_w_nbt) {
		Write-Output "Fixing $($nic_to_fix.PSChildName)"
		Set-ItemProperty -Path $nic_to_fix.PSPath -Name 'NetbiosOptions' -Value 2
	}
	Stop-Transcript
}
If ($nic_fixed) {
	Write-Output 'Restarting...'
	Restart-Computer -Force
}
