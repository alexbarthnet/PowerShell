$vmname = (Get-Item 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters').GetValue('VirtualMachineName') 
If ($vmname -ne $env:COMPUTERNAME) {Rename-Computer -NewName $vmname -Restart -Force}
