#Requires -Modules CmsCredentials

Function Copy-PathFromPSDirect {
	[CmdletBinding()]
	param (
		[string]$VMName,
		[string]$Path,
		[string]$Destination,
		[boolean]$Purge
	)

	# check for VM on local system
	$vm_check = $null
	$vm_check = Get-VM | Where-Object { $_.Name -eq $VMName }
	If ($vm_check) {
		# retrieve VM credentials
		$Credential = $null
		$Credential = Unprotect-CmsCredentials -Target $VMName
		If ($Credential) {
			# connect to VM
			$vm_direct = $null
			$vm_direct = New-PSSession -VMName $VMName -Credential $Credential
			If ($vm_direct) {
				# verify Path
				If (Invoke-Command -Session $vm_direct -ScriptBlock { Test-Path -Path $using:Path }) {
					# retrieve files from Path
					$file_list = $null
					$file_list = Invoke-Command -Session $vm_direct -ScriptBlock { Get-ChildItem -Path $using:Path }
					If ($file_list) {
						# verify Destination
						$destination_check = $null
						$destination_check = { If ( Test-Path -Path $Destination ) { Get-Item -Path $Destination } Else { New-Item -ItemType Directory -Path $Destination } }
						If ($destination_check) {
							# determine if Destination should be cleaned before writing files
							If ($Purge) {
								Write-Output "Clearing '$Destination' before copy"
								Get-ChildItem -Path $Destination -Recurse -Force | Remove-Item -Force
							}
							# copy files from VM to Destination
							$file_list.FullName | Copy-Item -FromSession $vm_direct -Destination $Destination -Force -Verbose
						}
						Else {
							Write-Output "Could not locate destination folder: '$Destination'"
						}
					}
					Else {
						Write-Output "Could not retrieve files in '$Path' on VM"
					}
				}
				Else {
					Write-Output "Could not find '$Path' on VM"
				}
				# disconnect from VM
				$vm_direct | Remove-PSSession
			}
			Else {
				Write-Output "Could not create PowerShell Direct session for VM: '$VMName'"
			}
		}
		Else {
			Write-Output "Could not locate credentials for VM: '$VMName'"
		}
	}
	Else {
		Write-Output "Could not locate VM: '$VMName'"
	}
}

Function Copy-PathToPSDirect {
	[CmdletBinding()]
	param (
		[string]$VMName,
		[string]$Path,
		[string]$Destination,
		[boolean]$Purge
	)

	# check for VM on local system
	$vm_check = $null
	$vm_check = Get-VM | Where-Object { $_.Name -eq $VMName }
	If ($vm_check) {
		# retrieve VM credentials
		$Credential = $null
		$Credential = Unprotect-CmsCredentials -Target $VMName
		If ($Credential) {
			# connect to VM
			$vm_direct = $null
			$vm_direct = New-PSSession -VMName $VMName -Credential $Credential
			If ($vm_direct) {
				# verify Path
				If (Test-Path -Path $Path) {
					# retrieve files from path
					$file_list = $null
					$file_list = Get-ChildItem -Path $Path
					If ($file_list) {
						# verify destination on VM
						$destination_check = $null
						$destination_check = Invoke-Command -Session $vm_direct -ScriptBlock { If ( Test-Path -Path $using:Destination ) { Get-Item -Path $using:Destination } Else { New-Item -ItemType Directory -Path $using:Destination } }
						If ($destination_check) {
							# determine if Destination should be cleaned before writing files
							If ($Purge) {
								Write-Output "Clearing '$Destination' before copy"
								Invoke-Command -Session $vm_direct -ScriptBlock { Get-ChildItem -Path $using:Destination -Recurse -Force | Remove-Item -Force }
							}
							# copy files from Path to VM
							$file_list.FullName | Copy-Item -ToSession $vm_direct -Destination $Destination -Force -Verbose
						}
						Else {
							Write-Output "Could not find or create '$Destination' on VM"
						}
					}
					Else {
						Write-Output "Could not retrieve files in '$Path' on host"
					}
				}
				Else {
					Write-Output "Could not find '$Path' on host"
				}
				# disconnect from VM
				$vm_direct | Remove-PSSession
			}
			Else {
				Write-Output "Could not create PowerShell Direct session for VM: '$VMName'"
			}
		}
		Else {
			Write-Output "Could not locate credentials for VM: '$VMName'"
		}
	}
	Else {
		Write-Output "Could not locate VM: '$VMName'"
	}
}

Function Export-FilesWithPSDirect {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Mandatory = $True, ParameterSetName = 'Export')]
		[switch]$Export,
		[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
		[switch]$Clear,
		[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
		[switch]$Remove,
		[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
		[switch]$Add,
		[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
		[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
		[ValidatePattern('^[^\*]+$')]
		[string]$VMName,
		[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
		[ValidatePattern('^[^\*]+$')]
		[string]$Path,
		[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
		[ValidatePattern('^[^\*]+$')]
		[string]$Destination,
		[Parameter(ParameterSetName = 'Add')]
		[switch]$Purge,
		[Parameter()][ValidateScript({ Test-Path -Path $_ })]
		[string]$Json
	)


	# define configuration file from script path then verify path
	If ([string]::IsNullOrEmpty($Json)) {
		$json_path = $PSCommandPath.Replace('.ps1', '.json')	
	}
	Else {
		$json_path = $Json
	}
	$json_test = Test-Path -Path $json_path

	# clear required objects then check file
	$json_data = @()
	If ($json_test) {
		# retrieve JSON file name
		$json_name = (Get-Item -Path $json_path).Name
		# create object from JSON file
		$json_data += Get-Content -Path $json_path | ConvertFrom-Json
	}
	Else {
		# define expected JSON file name
		$json_name = Split-Path -Path $json_path -Leaf
	}

	# evaluate parameters
	switch ($true) {
		$Clear {
			Write-Output "`nClearing '$json_name'`n"
			If ($json_test) { Remove-Item -Path $json_path -Force }
		}
		$Remove {
			# remove matching entries from object
			$json_data = $json_data | Where-Object { $_.VMName -ne $VMName }
			$json_data | ConvertTo-Json | Set-Content -Path $json_path
			# declare changes then show current state
			Write-Output "`nUpdated '$json_name' to remove '$VMName':"
			$json_data | Select-Object VMName, Path, Destination, Purge
		}
		$Add {
			# create custom object from parameters then add to object
			$json_data += [pscustomobject]@{
				VMName = $VMName
				Purge  = $Purge.ToBool()
				Path = $Path
				Destination = $Destination
			}
			$json_data | ConvertTo-Json | Set-Content -Path $json_path
			# declare changes then show current state
			Write-Output "`nUpdated '$json_name' to add '$VMName':"
			$json_data | Select-Object VMName, Path, Destination, Purge
		}
		$Export {
			Try {
				# define transcript file from script path and start transcript
				Start-Transcript -Path $PSCommandPath.Replace('.ps1', '.txt') -Force

				# check entry count in configuration file
				If ($json_data.Count -eq 0) {
					Write-Host "ERROR: no entries found in configuration file: $json_name"
					Return
				}

				# process configuration file
				ForEach ($json_datum in $json_data) {
					If ([string]::IsNullOrEmpty($json_datum.VMName) -or [string]::IsNullOrEmpty($json_datum.Path) -or [string]::IsNullOrEmpty($json_datum.Destination)) {
						Write-Host "ERROR: invalid entry found in configuration file: $json_name"
					}
					Else {
						Copy-PathFromPSDirect -VMName $json_datum.VMName -Path $json_datum.Path -Destination $json_datum.Destination -Purge $json_datum.Purge
					}
				}
			}
			Finally {
				Write-Host ([string]::Empty)
				Stop-Transcript
			}
		}
		Default {
			Write-Output "`nDisplaying '$json_name':"
			$json_data | Select-Object VMName, Path, Destination, Purge
		}
	}
}

Function Import-FilesWithPSDirect {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Mandatory = $True, ParameterSetName = 'Import')]
		[switch]$Import,
		[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
		[switch]$Clear,
		[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
		[switch]$Remove,
		[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
		[switch]$Add,
		[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
		[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
		[ValidatePattern('^[^\*]+$')]
		[string]$VMName,
		[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
		[ValidatePattern('^[^\*]+$')]
		[string]$Path,
		[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
		[ValidatePattern('^[^\*]+$')]
		[string]$Destination,
		[Parameter(ParameterSetName = 'Add')]
		[switch]$Purge,
		[Parameter()][ValidateScript({ Test-Path -Path $_ })]
		[string]$Json
	)
	
	# define configuration file from script path then verify path
	If ([string]::IsNullOrEmpty($Json)) {
		$json_path = $PSCommandPath.Replace('.ps1', '.json')	
	}
	Else {
		$json_path = $Json
	}
	$json_test = Test-Path -Path $json_path

	# clear required objects then check file
	$json_data = @()
	If ($json_test) {
		# retrieve JSON file name
		$json_name = (Get-Item -Path $json_path).Name
		# create object from JSON file
		$json_data += Get-Content -Path $json_path | ConvertFrom-Json
	}
	Else {
		# define expected JSON file name
		$json_name = Split-Path -Path $json_path -Leaf
	}

	# evaluate parameters
	switch ($true) {
		$Clear {
			Write-Output "`nClearing '$json_name'`n"
			If ($json_test) { Remove-Item -Path $json_path -Force }
		}
		$Remove {
			# remove matching entries from object
			$json_data = $json_data | Where-Object { $_.VMName -ne $VMName }
			$json_data | ConvertTo-Json | Set-Content -Path $json_path
			# declare changes then show current state
			Write-Output "`nUpdated '$json_name' to remove '$VMName':"
			$json_data | Select-Object VMName, Path, Destination, Purge
		}
		$Add {
			# create custom object from parameters then add to object
			$json_data += [pscustomobject]@{
				VMName = $VMName
				Purge  = $Purge.ToBool()
				Path = $Path
				Destination = $Destination
			}
			$json_data | ConvertTo-Json | Set-Content -Path $json_path
			# declare changes then show current state
			Write-Output "`nUpdated '$json_name' to add '$VMName':"
			$json_data | Select-Object VMName, Path, Destination, Purge
		}
		$Import {
			Try {
				# define transcript file from script path and start transcript
				Start-Transcript -Path $PSCommandPath.Replace('.ps1', '.txt') -Force

				# # start logging
				# Start-LogToMultiple -ScriptPath $PSCommandPath

				# check entry count in configuration file
				If ($json_data.Count -eq 0) {
					Write-Host "ERROR: no entries found in configuration file: $json_name"
					Return
				}

				# process configuration file
				ForEach ($json_datum in $json_data) {
					If ([string]::IsNullOrEmpty($json_datum.VMName) -or [string]::IsNullOrEmpty($json_datum.Path) -or [string]::IsNullOrEmpty($json_datum.Destination)) {
						Write-Host "ERROR: invalid entry found in configuration file: $json_name"
					}
					Else {
						Copy-PathToPSDirect -VMName $json_datum.VMName -Path $json_datum.Path -Destination $json_datum.Destination -Purge $json_datum.Purge
					}
				}
			}
			Finally {
				Write-Host ([string]::Empty)
				Stop-Transcript
			}
		}
		Default {
			Write-Output "`nDisplaying '$json_name':"
			$json_data | Select-Object VMName, Path, Destination, Purge
		}
	}
}