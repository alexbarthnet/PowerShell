[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# path to JSON file with parameters
	[Parameter(ParameterSetName = 'Json', Mandatory = $true)][ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' })]
	[string]$ParametersFromJson,
	# optional parameter set to load from JSON file
	[Parameter(ParameterSetName = 'Json')]
	[string]$ParameterSetName,
	# name of VM to import files to
	[Parameter(ParameterSetName = 'Default', Mandatory = $true, Position = 0)]
	[string]$VMName,
	# path to folder containing files to import from hypervisor perspective
	[Parameter(ParameterSetName = 'Default', Mandatory = $true, Position = 1)]
	[string]$Path,
	# path to destination folder on VM for imported files
	[Parameter(ParameterSetName = 'Default', Mandatory = $true, Position = 2)]
	[string]$Destination,
	# credential for accessing the VM with PowerShell Direct
	[Parameter(ParameterSetName = 'Default', Mandatory = $true, Position = 3)]
	[System.Management.Automation.PSCredential]$Credential,
	# switch to empty destination folder before import
	[Parameter(Mandatory = $false)]
	[switch]$Purge
)

# if parameter from JSON file provided...
If ($PSBoundParameters.ContainsKey('ParametersFromJson')) {
	# retrieve content of JSON file as PSCustomObject
	Try {
		$ParametersFromJsonObject = Get-Content -Path $ParametersFromJson -ErrorAction 'Stop' | ConvertFrom-Json -ErrorAction 'Stop'
	}
	Catch {
		Return $_
	}

	# retrieve parameter sets for command
	Try {
		$ParameterSets = (Get-Command -Name $PSCommandPath).ParameterSets
	}
	Catch {
		Return $_
	}

	# if named parameter set name defined...
	If ($PSBoundParameters.ContainsKey('ParameterSetName')) {
		# get parameters available in named parameter set
		$ParametersFromScript = $ParameterSets.Where({ $_.Name -eq $ParameterSetName }).Parameters
	}
	# if default parameter set name defined...
	ElseIf ($ParameterSets.IsDefault) {
		# get parameters in default parameter set
		$ParametersFromScript = $ParameterSets.Where({ $_.IsDefault }).Parameters
	}
	Else {
		# get parameters
		$ParametersFromScript = $ParameterSets.Parameters
	}

	# get parameter names from property names in PSCustomObject for parameters not defined at runtime
	$ParameterNames = $ParametersFromScript.Where({ $ParametersFromJsonObject.PSObject.Properties.Name.Contains($_.Name) -and -not $PSBoundParameters.ContainsKey($_.Name) }).Name

	# define parameters from JSON
	ForEach ($ParameterName in $ParameterNames) {
		# add parameter to bound parameters
		Try {
			$PSBoundParameters.Add($ParameterName, $ParametersFromJsonObject.$ParameterName)
		}
		Catch {
			Return $_
		}
		# create variable from parameter
		Try {
			Set-Variable -Name $ParameterName -Value $ParametersFromJsonObject.$ParameterName -Scope 'Script'
		}
		Catch {
			Return $_
		}
	}
}

# retrieve VMs on local system
Try {
	$VMs = Get-VM -ErrorAction 'Stop' | Where-Object { $_.Name -eq $VMName }
}
Catch {
	Write-Warning -Message 'could call Get-VM'
	Return $_
}

# if multiple VMs found...
If ($VMs.Count -gt 1) {
	Write-Warning -Message "multiple VMs found by name: '$VMName'"
	Return
}

# if no VMs found...
If ($null -eq $VMs) {
	Write-Warning -Message "could not locate VM by name: '$VMName'"
	Return
}

# create PSDirect session
Try {
	$Session = New-PSSession -VMName $VMName -Credential $Credential -ErrorAction 'Stop'
}
Catch {
	Write-Warning -Message "could not create PowerShell Direct session for VM: '$VMName'"
	Return $_
}

# test path on host
If (!(Test-Path -Path $Path)) {
	Write-Warning -Message "could not find '$Path' on host"
	Return
}

# test destination on VM
Try {
	$TestDestination = Invoke-Command -Session $Session -ScriptBlock { Test-Path -Path $using:Destination -PathType Container } -ErrorAction 'Stop'
}
Catch {
	Write-Warning -Message "could not test path '$Destination' on VM: '$VMName'"
	Return $_
}

# verify path on VM
If (!$TestDestination) {
	Write-Warning -Message "could not find '$Destination' on VM: '$VMName'"
	Return
}

# retrieve files from path on host
Try {
	$Items = Get-ChildItem -Path $Path -ErrorAction 'Stop'
}
Catch {
	Write-Warning -Message "could not retrieve files in '$Path' on host"
	Return $_
}

# remove files in destination on VM before copying files from path on host
If ($Purge -and $Items) {
	Try {
		Invoke-Command -Session $Session -ScriptBlock { Get-ChildItem -Path $using:Destination -Recurse -Force -ErrorAction 'Stop' | Remove-Item -Force -Verbose -ErrorAction 'Stop' }
	}
	Catch {
		Write-Warning -Message "could not clear destination folder '$Destination' on VM before file copy"
		Return $_
	}
}

# copy files from path on host to destination on VM
Try {
	ForEach ($Item in $Items.FullName) {
		Copy-Item -ToSession $Session -Path $Item -Destination $Destination -Force -Verbose -ErrorAction 'Stop'
	}
}
Catch {
	Write-Warning -Message "could not copy files to destination folder '$Destination' on VM: '$VMName'"
	Return $_
}

# disconnect from VM
Try {
	Remove-PSSession -Session $Session -ErrorAction 'Stop'
}
Catch {
	Write-Warning -Message "could not remove PowerShell Direct session for VM: '$VMName'"
	Return $_
}
