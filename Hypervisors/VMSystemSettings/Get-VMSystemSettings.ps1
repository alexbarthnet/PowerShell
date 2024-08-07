#requires -Modules 'Hyper-V'

[CmdletBinding()]
Param(
	[Parameter(ValueFromPipeline = $true, Position = 0, Mandatory = $true)][Alias('VM', 'VMName', 'Id')]
	[object]$InputObject,
	[Parameter()]
	[string]$ComputerName,
	[Parameter()]
	[string[]]$Property,
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
)

Begin {
	Function Get-VMFromParameters {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)][ValidateScript({ $_ -is [Microsoft.HyperV.PowerShell.VirtualMachine] -or $_ -is [guid] -or $_ -is [string] })][Alias('VM', 'VMName', 'Id')]
			[object]$InputObject,
			[string]$ComputerName,
			[switch]$Force
		)

		# if InputObject is a virtual machine object and Force not set...
		If ($InputObject -is [Microsoft.HyperV.PowerShell.VirtualMachine] -and -not $Force) {
			# ...return VM as-is
			Return $InputObject
		}

		# if computername not provided...
		If ([string]::IsNullOrEmpty($ComputerName)) {
			# ...and InputObject is a virtual machine...
			If ($InputObject -is [Microsoft.HyperV.PowerShell.VirtualMachine]) {
				# get computer name from VM
				$ComputerName = $InputObject.ComputerName
			}
			Else {
				# get computer name from hostname
				$ComputerName = $Hostname
			}
		}

		# define required parameters for Get-VM
		$GetVM = @{
			ComputerName = $ComputerName
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# if InputObject is a virtual machine object...
		If ($InputObject -is [Microsoft.HyperV.PowerShell.VirtualMachine]) {
			# ...set ID from Id property on VM object
			$GetVM['Id'] = $InputObject.Id
		}
		# if InputObject is a GUID...
		ElseIf ($InputObject -is [guid] -or [guid]::TryParse($InputObject, [ref][guid]::Empty)) {
			# ...set ID from value of VM cast as a GUID
			$GetVM['Id'] = [guid]$InputObject
		}
		# if InputObject is a string...
		Else {
			# ...set Name from value of VM
			$GetVM['Name'] = $InputObject
		}

		# get VM with arguments
		Try {
			$VM = Get-VM @GetVM
		}
		Catch {
			Throw $_
		}

		# return objects
		If ($VM -is [Microsoft.HyperV.PowerShell.VirtualMachine]) {
			Return $VM
		}
		ElseIf ($VM -is [array]) {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieved multiple VM objects with provided parameters")
			Throw $_
		}
		Else {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieved unexpected object type with provided parameters")
			Throw $_
		}
	}

	Function Get-CimInstanceForVM {
		[CmdletBinding()]
		Param(
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			[string[]]$Property
		)

		# get VM from parameters
		Try {
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			Throw $_
		}

		# define CIM instance for VM system settings
		$GetCimInstance = @{
			ComputerName = $ComputerName
			Namespace    = 'Root\Virtualization\V2'
			ClassName    = 'Msvm_VirtualSystemSettingData'
			Filter       = "ConfigurationId = '$($VM.Id)'"
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# define optional parameters for CIM instance
		If ($null -ne $Property) {
			$GetCimInstance['Property'] = $Property
		}

		# retrieve original VM system settings and host management service via CIM
		Try {
			Get-CimInstance @GetCimInstance
		}
		Catch {
			Throw $_
		}
	}
}

Process {
	# get VM from parameters
	Try {
		# cast return as type to force terminating error
		$VM = Get-VMFromParameters -ComputerName $ComputerName -InputObject $InputObject
	}
	Catch {
		Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
		Throw $_
	}

	# define CIM instance for VM system settings
	$GetCimInstanceForVM = @{
		VM          = $VM
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}
	# define optional parameters for Get-CimInstanceForVM
	If ($null -ne $Property) {
		$GetCimInstanceForVM['Property'] = $Property
	}

	# retrieve original VM system settings and host management service via CIM
	Try {
		$CimInstanceForVM = Get-CimInstanceForVM @GetCimInstanceForVM
	}
	Catch {
		Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve CIM instance for VM")
		Throw $_
	}

	# return CIM instance
	If ($null -ne $Property) {
		$CimInstanceForVM | Select-Object -Property $Property
	}
	Else {
		$CimInstanceForVM
	}
}
