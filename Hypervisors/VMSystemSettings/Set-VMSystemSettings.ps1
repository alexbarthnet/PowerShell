[CmdletBinding(DefaultParameterSetName = 'Single')]
Param(
	[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
	[object]$VM,
	[Parameter()]
	[string]$ComputerName,
	[Parameter(Mandatory = $true, ParameterSetName = 'Single')]
	[string]$Name,
	[Parameter(Mandatory = $true, ParameterSetName = 'Single')]
	[string]$Value,
	[Parameter(Mandatory = $true, ParameterSetName = 'Multiple')]
	[hashtable]$SystemSettings,
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
)

Begin {
	Function Get-VMFromParameters {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)][ValidateScript({ $_ -is [Microsoft.HyperV.PowerShell.VirtualMachine] -or $_ -is [guid] -or $_ -is [string] })]
			[object]$VM,
			[string]$ComputerName,
			[switch]$Force
		)

		# if VM is a virtual machine object and Force not set...
		If ($VM -is [Microsoft.HyperV.PowerShell.VirtualMachine] -and -not $Force) {
			# ...return VM as-is
			Return $VM
		}

		# if computername not provided...
		If ([string]::IsNullOrEmpty($ComputerName)) {
			# ...and VM is a virtual machine...
			If ($VM -is [Microsoft.HyperV.PowerShell.VirtualMachine]) {
				# get computer name from VM
				$ComputerName = $VM.ComputerName
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

		# if VM is a virtual machine object...
		If ($VM -is [Microsoft.HyperV.PowerShell.VirtualMachine]) {
			# ...set ID from Id property on VM object
			$GetVM['Id'] = $VM.Id
		}
		# if VM is a GUID...
		ElseIf ($VM -is [guid] -or [guid]::TryParse($VM, [ref][guid]::Empty)) {
			# ...set ID from value of VM cast as a GUID
			$GetVM['Id'] = [guid]$VM
		}
		# if VM is a string...
		Else {
			# ...set Name from value of VM
			$GetVM['Name'] = $VM
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
			[string]$ComputerName = $VM.ComputerName.ToLower()
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

	Function Get-CimInstanceForVMMS {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName
		)

		# define CIM instance for host management service
		$GetCimInstance = @{
			ComputerName = $ComputerName
			Namespace    = 'Root\Virtualization\V2'
			ClassName    = 'Msvm_VirtualSystemManagementService'
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve CIM instance for host management service
		Try {
			Get-CimInstance @GetCimInstance
		}
		Catch {
			Throw $_
		}
	}

	# create hashtable from parameters
	If ($PSCmdlet.ParameterSetName -eq 'Single') {
		$SystemSettings = @{
			$Name = $Value
		}
	}

	# get property from hashtable
	$Property = $SystemSettings.Keys
}

Process {
	# get VM from parameters
	Try {
		# cast return as type to force terminating error
		$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
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
		Write-Host ("$Hostname,$ComputerName,$Name - ...retrieving CIM instance for VM...")
		$CimInstanceForVM = Get-CimInstanceForVM @GetCimInstanceForVM
	}
	Catch {
		Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve CIM instance for VM")
		Throw $_
	}

	# define counter for changes
	$SystemSettingsCounter = [int32]0

	# modify VM system settings
	ForEach ($SystemSetting in $SystemSettings.Keys) {
		If ($CimInstanceForVM.$SystemSetting -eq $SystemSettings[$SystemSetting]) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...found '$SystemSetting' set to '$($SystemSettings[$SystemSetting])'")
		}
		Else {
			Write-Host ("$Hostname,$ComputerName,$Name - ...updating '$SystemSetting' from '$($CimInstanceForVM.$SystemSetting)' to '$($SystemSettings[$SystemSetting])'")
			$CimInstanceForVM.$SystemSetting = $SystemSettings[$SystemSetting]
			$SystemSettingsCounter++
		}
	}

	# check counter for changes
	If ($SystemSettingsCounter -eq 0) {
		Write-Host ("$Hostname,$ComputerName,$Name - ...existing firmware settings match requested settings")
		Return
	}

	# serialize and encode VM system settings
	Try {
		$CimSerializer = [Microsoft.Management.Infrastructure.Serialization.CimSerializer]::Create()
		$CimSerialized = $CimSerializer.Serialize($CimInstanceForVM, [Microsoft.Management.Infrastructure.Serialization.InstanceSerializationOptions]::None)
		$CimEncodedData = [System.Text.Encoding]::Unicode.GetString($CimSerialized)
	}
	Catch {
		Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not serialize the CIM objects for VM firmware")
		Throw $_
	}

	# define CIM instance for VM management service
	$GetCimInstanceForVMMS = @{
		ComputerName = $ComputerName
		ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
	}

	# retrieve CIM instance for host management service
	Write-Host ("$Hostname,$ComputerName,$Name - ...retrieving CIM instance for VM management service")
	Try {
		$CimInstanceForVMMS = Get-CimInstanceForVMMS @GetCimInstanceForVMMS
	}
	Catch {
		Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve CIM instance for VM management service")
		Throw $_
	}

	# define CIM method for host management service
	$InvokeCimMethod = @{
		CimInstance = $CimInstanceForVMMS
		MethodName  = 'ModifySystemSettings'
		Arguments   = @{ SystemSettings = $CimEncodedData }
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# invoke CIM method on host management service to update VM system settings with modified values
	Write-Host ("$Hostname,$ComputerName,$Name - updating firmware settings via CIM...")
	Try {
		$CimMethod = Invoke-CimMethod @InvokeCimMethod
	}
	Catch {
		Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not call method to update firmware settings via CIM")
		Throw $_
	}

	# check CIM return value
	If ($CimMethod.ReturnValue -eq 0) {
		Write-Host ("$Hostname,$ComputerName,$Name - ...firmware settings updated...")
	}
	Else {
		Write-Host ("$Hostname,$ComputerName,$Name - ERROR: firmware settings not updated, CIM returned: '$($CimMethod.ReturnValue)'")
	}
}
