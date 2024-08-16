#requires -Modules 'Hyper-V'

[CmdletBinding(DefaultParameterSetName = 'VM')]
param (
	[Parameter(ParameterSetName = 'VM', Mandatory = $true, ValueFromPipeline = $true)]
	[object]$VM,
	[Parameter(ParameterSetName = 'VMName', Mandatory = $true)]
	[string]$VMName,
	[Parameter(ParameterSetName = 'VMName')]
	[string]$ComputerName,
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
)

Begin {
	Function Update-VMHardDriveAcl {
		[CmdletBinding()]
		param (
			[Parameter(Mandatory = $true)]
			[object]$VM
		)

		# retrieve VM to retrieve all properties
		$VM = Get-VM -Id $VM.Id

		# retrieve VM properties
		$VMName = $VM.Name
		$VMId = $VM.VMid

		# create VM principal
		$VMPrincipal = [System.Security.Principal.NTAccount]::new("NT VIRTUAL MACHINE\$VMId")

		# create access rule
		$AccessRule = [System.Security.AccessControl.FileSystemAccessRule]::new($VMPrincipal, @('Read', 'Write', 'Synchronize'), 'None', 'None', 'Allow')

		# add ACE to each VHD on VM
		Write-Output "Updating permissions on VHDs for VM: $VMName"

		# add ACE to each VHD on VM
		:NextVHD ForEach ($VHD in $VM.HardDrives.Path) {
			# retrieve ACL
			Try {
				$ACL = Get-Acl -Path $VHD
				Write-Output "...retrieved permissions for VHD: $VHD"
			}
			Catch {
				Write-Warning -Message "could not retrieve permissions for VHD: $VHD"
			}

			# add access rule to ACL
			Try {
				$ACL.AddAccessRule($AccessRule)
			}
			Catch {
				Write-Warning -Message "could not add access rult to ACL for VHD: $VHD"
			}

			# update ACL
			Try {
				$ACL | Set-Acl -Path $VHD
				Write-Output "...updated permissions for VHD: $VHD"
			}
			Catch {
				Write-Warning -Message "could not update permissions for VHD: $VHD"
			}
		}
	}
}

Process {
	# if VM names provided...
	If ($PSCmdlet.ParameterSetName -eq 'VMName') {
		# define required parameters for Get-VM
		$GetVM = @{
			Name = $VMName
		}

		# define optional parameters for Get-VM
		If ($PSBoundParameters.ContainsKey('ComputerName')) {
			$GetVM['ComputerName'] = $ComputerName
		}

		# retrieve VM
		Try {
			$VM = Get-VM @GetVM
		}
		Catch {
			Write-Warning -Message "could not retrieve VM with name: $Name"
			Return $_
		}
	}

	# process VM
	If ($VM.ComputerName -ne $Hostname) {
		Invoke-Command -ComputerName $VM.ComputerName -ScriptBlock ${function:Update-VMHardDriveAcl} -ArgumentList $VM
	}
	Else {
		Update-VMHardDriveAcl $VM
	}
}
