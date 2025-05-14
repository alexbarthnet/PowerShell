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
	# path to file or folder to import from hypervisor perspective
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

# test path as file on host
Try {
	$PathIsFile = [System.IO.File]::Exists($Path)
}
Catch {
	Write-Warning -Message "could not test '$Path' path as file on host: $($_.Exception.Message)"
	Return $_
}

# test path as directory on host
Try {
	$PathIsDirectory = [System.IO.Directory]::Exists($Path)
}
Catch {
	Write-Warning -Message "could not test '$Path' path as directory on host: $($_.Exception.Message)"
	Return $_
}

# if path not found on host...
If (!$PathIsFile -and !$PathIsDirectory) {
	# warn and return
	Write-Warning -Message "could not locate '$Path' path on host"
	Return
}

# trim destination
$Destination = $Destination.TrimEnd('\')

# test destination on VM
Try {
	$DestinationExists = Invoke-Command -Session $Session -ScriptBlock { [System.IO.Directory]::Exists($using:Destination) }
}
Catch {
	Write-Warning -Message "could not retrieve info for '$Destination' path on '$VMName' VM: $($_.Exception.Message)"
	Return $_
}

# if destination not found on VM...
If (!$DestinationExists) {
	# if create destination requested...
	If ($CreateDestination) {
		# create destination on VM
		Try {
			Invoke-Command -Session $Session -ScriptBlock { [System.IO.Directory]::CreateDirectory($using:Destination) }
		}
		Catch {
			Write-Warning -Message "could not create '$Destination' path on '$VMName' VM: $($_.Exception.Message)"
			Return
		}
	}
	Else {
		Write-Warning -Message "could not locate '$Destination' path on '$VMName' VM"
		Return
	}
}

# if path is a directory...
If ($PathIsDirectory) {
	# retrieve files from path on VM
	Try {
		$Items = Get-ChildItem -Path $Path -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not retrieve files in '$Path' on host"
		Return $_
	}
}
# if path is a file...
Else {
	# retrieve file from path on VM
	Try {
		$Item = Get-Item -Path $Path -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not retrieve file with '$Path' on host"
		Return $_
	}

	# create array containing item for file
	$Items = @($Item)

	# update path to parent directory of file
	$Path = $Item.DirectoryName.TrimEnd('\')
}

# remove files in destination on VM before copying files from path on host
If ($Purge -and $Items) {
	Try {
		Invoke-Command -Session $Session -ScriptBlock { Get-ChildItem -Path $using:Destination -Recurse -Force -ErrorAction 'Stop' | Remove-Item -Force -Verbose -ErrorAction 'Stop' }
	}
	Catch {
		Write-Warning -Message "could not clear destination folder '$Destination' on '$VMName' VM before file copy"
		Return $_
	}
}

# copy files from path on host to destination on VM
:NextItem ForEach ($Item in $Items) {
	# replace path with destination to define destination item path
	$DestinationPath = $Item.FullName -replace [System.Text.RegularExpressions.Regex]::Escape($Path), $Destination

	# retrieve file information for destination item
	$FileInfo = Invoke-Command -Session $Session -ScriptBlock { [System.IO.FileInfo]::new($using:DestinationPath) }

	# if destination item found...
	If ($FileInfo.Exists) {
		# get hash of path in destination
		$DestinationHash = Invoke-Command -Session $Session -ScriptBlock { Get-FileHash -Path $using:DestinationPath -Algorithm SHA384 | Select-Object -ExpandProperty Hash }

		# get hash of path in source
		$SourceHash = Get-FileHash -Path $Item.FullName -Algorithm SHA384 | Select-Object -ExpandProperty Hash

		# if hashes match...
		If ($SourceHash -eq $DestinationHash) {
			Write-Verbose -Message "Skipped '$($Item.FullName)' file; '$($DestinationPath)' file on '$VMName' VM has matching file hash: $($DestinationHash)"
			Continue NextItem
		}
	}
	# if destination item not found...
	Else {
		# retrieve directory information for destination item
		$DirectoryInfo = Invoke-Command -Session $Session -ScriptBlock { [System.IO.DirectoryInfo]::new($using:FileInfo.DirectoryName) }

		# if directory for destination item not found...
		If (!$DirectoryInfo.Exists) {
			# create directory for destination item
			Try {
				Invoke-Command -Session $Session -ScriptBlock { [System.IO.Directory]::CreateDirectory($using:FileInfo.DirectoryName) }
			}
			Catch {
				Write-Warning -Message "could not create '$($FileInfo.DirectoryName)' directory: $($_.Exception.Message)"
				Continue NextItem
			}
		}
	}

	# copy item to destination on VM
	Try {
		Copy-Item -ToSession $Session -Path $Item.FullName -Destination $Destination -Force -Verbose -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not copy '$($Item.FullName)' to '$($DestinationPath)' on '$VMName' VM: $($_.Exception.Message)"
		Continue NextItem
	}

	# report file copied
	Write-Verbose -Message "Copied '$($Item.FullName)' file to '$($DestinationPath)' file on '$VMName' VM"
}

# disconnect from VM
Try {
	Remove-PSSession -Session $Session -ErrorAction 'Stop'
}
Catch {
	Write-Warning -Message "could not remove PowerShell Direct session for VM: '$VMName'"
	Return $_
}
