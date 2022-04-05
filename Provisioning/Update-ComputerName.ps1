# define logging
$log_root = (Get-CimInstance -Class Win32_OperatingSystem).WindowsDirectory
$log_file = (Split-Path -Path $PSCommandPath -Leaf).Replace((Get-Item -Path $PSCommandPath).Extension, '.txt')
$log_path = Join-Path -Path $log_root -Child $log_file
# retrieve computer and virtual machine names
$os_name = (Get-CimInstance -Class 'Win32_ComputerSystem').Name
$vm_name = (Get-Item 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters').GetValue('VirtualMachineName')
# check computer name
If ($os_name -ne $vm_name -and -not [string]::IsNullOrEmpty($vm_name)) {
	Start-Transcript -Path $log_path -Append
	Write-Output "Found active computer name: $os_name"
	Write-Output "Found virtual machine name: $vm_name"	
	Write-Output "Renaming computer to: $vm_name"
	Rename-Computer -NewName $vm_name -Restart -Force
	Stop-Transcript
}
