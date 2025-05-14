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
	# path to file or folder on VM to export
	[Parameter(ParameterSetName = 'Default', Mandatory = $true, Position = 1)]
	[string]$Path,
	# path to destination folder from hypervisor perspective for exported files
	[Parameter(ParameterSetName = 'Default', Mandatory = $true, Position = 2)]
	[string]$Destination,
	# credential for accessing the VM with PowerShell Direct
	[Parameter(ParameterSetName = 'Default', Mandatory = $true, Position = 3)]
	[System.Management.Automation.PSCredential]$Credential,
	# switch to empty destination folder before import
	[Parameter(Mandatory = $false)]
	[switch]$Purge,
	# switch to create destination folder if missing
	[Parameter(Mandatory = $false)]
	[switch]$CreateDestination
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

# trim path
$Path = $Path.TrimEnd('\')

# test path as file on vm
Try {
	$PathIsFile = Invoke-Command -Session $Session -ScriptBlock { [System.IO.File]::Exists($using:Path) }
}
Catch {
	Write-Warning -Message "could not test '$Path' path as file on '$VMName' VM: $($_.Exception.Message)"
	Return $_
}

# test path as directory on vm
Try {
	$PathIsDirectory = Invoke-Command -Session $Session -ScriptBlock { [System.IO.Directory]::Exists($using:Path) }
}
Catch {
	Write-Warning -Message "could not test '$Path' path as directory on '$VMName' VM: $($_.Exception.Message)"
	Return $_
}

# if path not found on VM...
If (!$PathIsFile -and !$PathIsDirectory) {
	# warn and return
	Write-Warning -Message "could not locate '$Path' path on '$VMName' VM"
	Return
}

# trim destination
$Destination = $Destination.TrimEnd('\')

# test destination on host
Try {
	$DestinationExists = [System.IO.Directory]::Exists($Destination)
}
Catch {
	Write-Warning -Message "could not retrieve info for '$Destination' path on host: $($_.Exception.Message)"
	Return $_
}

# if destination not found on host...
If (!$DestinationExists) {
	# if create destination requested...
	If ($CreateDestination) {
		# create destination on host
		Try {
			[System.IO.Directory]::CreateDirectory($Destination)
		}
		Catch {
			Write-Warning -Message "could not create '$Destination' path on host: $($_.Exception.Message)"
			Return
		}
	}
	Else {
		Write-Warning -Message "could not locate '$Destination' path on host"
		Return
	}
}

# if path is a directory...
If ($PathIsDirectory) {
	# retrieve files from path on VM
	Try {
		$Items = Invoke-Command -Session $Session -ScriptBlock { Get-ChildItem -Path $using:Path -ErrorAction 'Stop' }
	}
	Catch {
		Write-Warning -Message "could not retrieve files in '$Path' on VM: '$VMName'"
		Return $_
	}
}
# if path is a file...
Else {
	# retrieve file from path on VM
	Try {
		$Item = Invoke-Command -Session $Session -ScriptBlock { Get-Item -Path $using:Path -ErrorAction 'Stop' }
	}
	Catch {
		Write-Warning -Message "could not retrieve file with '$Path' on VM: '$VMName'"
		Return $_
	}

	# create array containing item for file
	$Items = @($Item)

	# update path to parent directory of file
	$Path = $Item.DirectoryName.TrimEnd('\')
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
	# replace path with destination to define destination item path
	$DestinationPath = $Item.FullName -replace [System.Text.RegularExpressions.Regex]::Escape($Path), $Destination

	# retrieve file information for destination item
	$FileInfo = [System.IO.FileInfo]::new($DestinationPath)

	# if destination item found...
	If ($FileInfo.Exists) {
		# get hash of path in destination
		$DestinationHash = Get-FileHash -Path $DestinationPath -Algorithm SHA384 | Select-Object -ExpandProperty Hash

		# get hash of path in source
		$SourceHash = Invoke-Command -Session $Session -ScriptBlock { Get-FileHash -Path $using:Item.FullName -Algorithm SHA384 | Select-Object -ExpandProperty Hash }

		# if hashes match...
		If ($SourceHash -eq $DestinationHash) {
			Write-Verbose -Message "Skipped '$($Item.FullName)' file on '$VMName' VM; '$($DestinationPath)' file has matching file hash: $($DestinationHash)"
			Continue NextItem
		}
	}
	# if destination item not found...
	Else {
		# retrieve information for directory for destination item
		$DirectoryInfo = [System.IO.DirectoryInfo]::new($FileInfo.DirectoryName)

		# if directory for destination item not found...
		If (!$DirectoryInfo.Exists) {
			# create directory for destination item
			Try {
				[System.IO.Directory]::CreateDirectory($FileInfo.DirectoryName)
			}
			Catch {
				Write-Warning -Message "could not create '$($FileInfo.DirectoryName)' directory: $($_.Exception.Message)"
				Continue NextItem
			}
		}
	}

	# copy file from VM to destination
	Try {
		Copy-Item -FromSession $Session -Path $Item.FullName -Destination $DestinationPath -Force -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not copy '$($Item.FullName)' on '$VMName' VM to '$($DestinationPath)': $($_.Exception.Message)"
		Continue NextItem
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
