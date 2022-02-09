$os_path = (Get-CimInstance -Class Win32_OperatingSystem).WindowsDirectory
$os_name = (Get-CimInstance -Class Win32_ComputerSystem).Name
$vm_name = (Get-Item 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters').GetValue('VirtualMachineName')
$vm_file = Join-Path -Path $os_path -Child 'VmRename.log'
If ($os_name -ne $vm_name) {
	Start-Transcript -Path $vm_file -Append
	Write-Output "Found current computer name: $os_name"
	Write-Output "Found hypervisor guest name: $vm_name"	
	Write-Output "Renaming computer to: $vm_name"
	Rename-Computer -NewName $vm_file -Restart -Force
	Stop-Transcript
}
