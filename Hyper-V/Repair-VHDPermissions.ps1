[CmdletBinding()]
param (
	[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
	[object[]]$VM,
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
)

Function Add-VmToAcl {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[object]$VM
	)

	# load local instance of VM
	$local_vm = $VM | Get-VM

	# build ACE objects
	$vhd_user = New-Object System.Security.Principal.NTAccount("NT VIRTUAL MACHINE\$($local_vm.VMId)")
	$vhd_rule = New-Object System.Security.AccessControl.FileSystemAccessRule ($vhd_user, @('Read', 'Write', 'Synchronize'), 'None', 'None', 'Allow')
	
	# add ACE to each VHD on VM
	Write-Output "Updating permissions on VHDs for VM: '$($local_vm.Name)'"
	ForEach ($VHD in $local_vm.HardDrives.Path) {
		Write-Output "...reviewing permissions on VHD: '$VHD'"
		Try {
			$vhd_acl = Get-Acl -Path $VHD
			$vhd_acl.AddAccessRule($vhd_rule)
			$vhd_acl | Set-Acl -Path $VHD
			Write-Output "...updated permissions on VHD: '$VHD'"
		}
		Catch {
			Write-Output "ERROR: could not update permissions on VHD: '$VHD'"
		}
	}
}

# process each input
ForEach ($virtual_machine in $VM) {
	# try to convert string into VM
	If ($virtual_machine -is [string]) {
		Try {
			$virtual_machine = Get-VM -Name $virtual_machine
		}
		Catch {
			Write-Host "ERROR: could not retrieve VM with input '$virtual_machine'"
			Continue
		}
	}
	# process VM
	If ($virtual_machine -is [Microsoft.HyperV.PowerShell.VirtualMachine]) {
		If ($virtual_machine.ComputerName -ne $Hostname) {
			Invoke-Command -ComputerName $virtual_machine.ComputerName -ScriptBlock ${function:Add-VmToAcl} -ArgumentList $virtual_machine
		}
		Else {
			Add-VmToAcl $virtual_machine
		}
	}
}
