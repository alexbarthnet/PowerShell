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
	Function Set-VMDvdDrivePath {
		[CmdletBinding()]
		param (
			[Parameter(Mandatory = $true)]
			[object]$VM
		)

		# retrieve VM to retrieve all properties
		$VM = Get-VM -Id $VM.Id

		# retrieve VM properties
		$Name = $VM.Name
		$State = $VM.State

		# if state is not off...
		If ($State -ne 'Off') {
			Write-Warning -Message "found '$Name' VM powered on; power off VM before dismounting VM DVD drive"
			Return
		}

		# add ACE to each VHD on VM
		:NextVMDvdDrive ForEach ($VMDvdDrive in $VM.DvdDrives) {
			# if VM DVD drive is empty...
			If ([string]::IsNullOrEmpty($VMDvdDrive.Path)) {
				Continue NextVMDvdDrive
			}
			# if VM DVD drive is not empty...
			Else {
				$Path = $VMDvdDrive.Path
			}

			# dismount image from VM DVD drive
			Try {
				Set-VMDvdDrive -VMDvdDrive $VMDvdDrive -Path $null
			}
			Catch {
				Write-Warning -Message "could not dismount '$Path' image from DVD drive on '$Name' VM on '$Hostname' computer: $($_.Exception.Message)"
				Continue NextVMDvdDrive
			}

			# report state
			Write-Host "dismounted image with '$Path' from DVD drive on '$Name' VM on '$Hostname' computer"
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
		Invoke-Command -ComputerName $VM.ComputerName -ScriptBlock ${function:Set-VMDvdDrivePath} -ArgumentList $VM
	}
	Else {
		Set-VMDvdDrivePath $VM
	}
}
