[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# path to JSON file with parameters
	[Parameter(ParameterSetName = 'Json', Mandatory = $true)][ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' })]
	[string]$ParametersFromJson,
	# optional parameter set to load from JSON file
	[Parameter(ParameterSetName = 'Json')]
	[string]$ParameterSetName,
	# name of VM to export files from
	[Parameter(ParameterSetName = 'Default', Mandatory = $true, Position = 0)]
	[string]$VMName,
	# path to folder on VM containing files to export
	[Parameter(ParameterSetName = 'Default', Mandatory = $true, Position = 1)]
	[string]$Path,
	# path to destination folder for exported files from hypervisor perspective
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
	Write-Warning -Message 'could not call Get-VM'
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

# test path on VM
Try {
	$TestPath = Invoke-Command -Session $Session -ScriptBlock { Test-Path -Path $using:Path } -ErrorAction 'Stop'
}
Catch {
	Write-Warning -Message "could not test path '$Path' on VM: '$VMName'"
	Return $_
}

# verify path on VM
If (!$TestPath) {
	Write-Warning -Message "could not find '$Path' on VM: '$VMName'"
	Return
}

# test destination on host
If (!(Test-Path -Path $Destination -PathType Container )) {
	Write-Warning -Message "could not find '$Destination' on host"
	Return
}

# retrieve files from path on VM
Try {
	$Items = Invoke-Command -Session $Session -ScriptBlock { Get-ChildItem -Path $using:Path -ErrorAction 'Stop' }
}
Catch {
	Write-Warning -Message "could not retrieve files in '$Path' on VM: '$VMName'"
	Return $_
}

# remove files in destination on host before copying files from path on VM
If ($Purge -and $Items) {
	Try {
		Get-ChildItem -Path $Destination -Recurse -Force -ErrorAction 'Stop' | Remove-Item -Force -Verbose -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not clear destination folder '$Destination' on host before file copy"
		Return $_
	}
}

# copy files from path on VM to destination on host
:NextItem ForEach ($Item in $Items) {
	# define destination item path
	$DestinationPath = Join-Path -Path $Destination -ChildPath $Item.Name

	# check if path in destination exists...
	$DestinationExists = [System.IO.File]::Exists($DestinationPath)

	# if path in destination found...
	If ($DestinationExists) {
		# get hash of path in destination
		$DestinationHash = Get-FileHash -Path $DestinationPath -Algorithm SHA384 | Select-Object -ExpandProperty Hash
		# get hash of path in source
		$SourceHash = Invoke-Command -Session $Session -ScriptBlock { Get-FileHash -Path $using:Item.FullName -Algorithm SHA384 | Select-Object -ExpandProperty Hash }
		# if hashes match...
		If ($SourceHash -eq $DestinationHash) {
			Write-Verbose -Message "Found matching file hashes for '$($Item.FullName)' file on '$VMName' VM and '$($DestinationPath)' file"
			Continue NextItem
		}
	}

	# copy file from VM to destination
	Try {
		Copy-Item -FromSession $Session -Path $Item.FullName -Destination $DestinationPath -Force -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not copy '$($Item.FullName)' on '$VMName' VM to '$($DestinationPath)': $($_.Exception.Message)"
	}

	# report file copied
	Write-Verbose -Message "Copied '$($Item.FullName)' file on '$VMName' VM to '$($DestinationPath)' file"
}

# disconnect from VM
Try {
	Remove-PSSession -Session $Session -ErrorAction 'Stop'
}
Catch {
	Write-Warning -Message "could not remove PowerShell Direct session for VM: '$VMName'"
	Return $_
}
