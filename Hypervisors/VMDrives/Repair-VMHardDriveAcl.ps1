#requires -Modules 'Hyper-V'

[CmdletBinding(DefaultParameterSetName = 'VM')]
param (
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant(),
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName = 'Name')]
	[string]$Name,
	[Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName = 'VM')]
	[object]$VM,
	[Parameter(Mandatory = $false)]
	[string]$ComputerName = $Hostname
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
	# if name provided...
	If ($PSCmdlet.ParameterSetName.StartsWith('Name')) {
		# define required parameters for Get-VM
		$GetVM = @{
			Name         = $Name
			ComputerName = $ComputerName
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# get VM object from input
		Try {
			$VM = Get-VM @GetVM
		}
		Catch {
			Throw $_
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
