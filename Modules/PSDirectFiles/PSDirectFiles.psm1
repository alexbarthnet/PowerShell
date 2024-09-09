#Requires -Modules TranscriptWithHostAndDate,CmsCredentials

Function Copy-PathFromPSDirect {
	[CmdletBinding()]
	param (
		[string]$VMName,
		[string]$Path,
		[string]$Destination,
		[switch]$Purge
	)

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

	# retrieve VM credentials
	Try {
		$Credential = Get-CmsCredential -Identity $VMName
	}
	Catch {
		Write-Warning -Message "could not unprotect credentials for VM: '$VMName'"
		Return $_
	}

	# verify VM credentials
	If (!$Credential) {
		Write-Warning -Message "could not locate credentials for VM: '$VMName'"
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
	Try {
		ForEach ($Item in $Items.FullName) {
			Copy-Item -FromSession $Session -Path $Item -Destination $Destination -Force -Verbose -ErrorAction 'Stop'
		}
	}
	Catch {
		Write-Warning -Message "could not copy files to destination folder '$Destination' on host"
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
}

Function Copy-PathToPSDirect {
	[CmdletBinding()]
	param (
		[string]$VMName,
		[string]$Path,
		[string]$Destination,
		[switch]$Purge
	)

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

	# retrieve VM credentials
	Try {
		$Credential = Get-CmsCredential -Identity $VMName
	}
	Catch {
		Write-Warning -Message "could not unprotect credentials for VM: '$VMName'"
		Return $_
	}

	# verify VM credentials
	If (!$Credential) {
		Write-Warning -Message "could not locate credentials for VM: '$VMName'"
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
}

Function Export-FilesWithPSDirect {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		# path to JSON configuration file
		[Parameter(Mandatory = $True, Position = 0)]
		[string]$Json,
		# script parameters - mode
		[Parameter(Mandatory = $True, ParameterSetName = 'Show')]
		[switch]$Show,
		[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
		[switch]$Clear,
		[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
		[switch]$Remove,
		[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
		[switch]$Add,
		# copy parameter - VM name
		[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
		[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
		[ValidatePattern('^[^\*]+$')]
		[string]$VMName,
		# copy parameter - path on VM
		[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
		[ValidatePattern('^[^\*]+$')]
		[string]$Path,
		# copy parameter - path on hosst
		[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
		[ValidatePattern('^[^\*]+$')]
		[string]$Destination,
		# copy parameter - clear destination on host first
		[Parameter(ParameterSetName = 'Add')]
		[switch]$Purge,
		# switch to skip transcript logging
		[Parameter(DontShow)]
		[switch]$SkipTranscript,
		# local host name
		[Parameter(DontShow)]
		[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
		# local domain name
		[Parameter(DontShow)]
		[string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
		# local DNS hostname
		[Parameter(DontShow)]
		[string]$DnsHostName = ($HostName, $DomainName -join '.').TrimEnd('.')
	)

	Begin {
		# if parameter set is Default and SkipTranscript not set...
		If ($PSCmdlet.ParameterSetName -eq 'Default' -and -not $PSBoundParameters.ContainsKey('SkipTranscript')) {
			# start transcript with default parameters
			Try {
				Start-TranscriptWithHostAndDate
			}
			Catch {
				Throw $_
			}
		}
	}

	Process {
		# if JSON file found...
		If (Test-Path -Path $Json) {
			# ...create JSON data object as array of PSCustomObjects from JSON file content
			Try {
				$JsonData = [array](Get-Content -Path $Json | ConvertFrom-Json)
			}
			Catch {
				Write-Warning -Message "could not read configuration file: '$Json'"
				Return $_
			}
		}
		# if JSON file was not found...
		Else {
			# ...and Add set...
			If ($Add) {
				# ...try to create the JSON file
				Try {
					$null = New-Item -ItemType 'File' -Path $Json -ErrorAction 'Stop'
				}
				Catch {
					Write-Warning -Message "could not create configuration file: '$Json'"
					Return $_
				}
				# ...create JSON data object as empty array
				$JsonData = @()
			}
			# ...and Add not set...
			Else {
				# ...report and return
				Write-Warning -Message "could not find configuration file: '$Json'"
				Return
			}
		}

		# evaluate parameters
		switch ($true) {
			# show configuration file
			$Show {
				Write-Output "`nDisplaying '$Json'"
				$JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
			}
			# clear configuration file
			$Clear {
				Try {
					[string]::Empty | Set-Content -Path $Json
					Write-Output "`nCleared configuration file: '$Json'"
				}
				Catch {
					Write-Warning -Message "could not clear configuration file: '$Json'"
					Return $_
				}
			}
			# remove entry from configuration file
			$Remove {
				Try {
					# remove existing entry by primary key(s)...
					$JsonData = $JsonData | Where-Object { $_.VMName -ne $VMName }
					# if JSON data empty...
					If ($null -eq $JsonData) {
						# clear JSON data
						[string]::Empty | Set-Content -Path $Json
						Write-Output "`nRemoved '$VMName' from configuration file: '$Json'"
					}
					Else {
						# export JSON data
						$JsonData | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
						Write-Output "`nRemoved '$VMName' from configuration file: '$Json'"
						$JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
					}
				}
				Catch {
					Write-Warning -Message "could not update configuration file: '$Json'"
				}
			}
			# add entry to configuration file
			$Add {
				Try {
					# create hashtable for custom object
					$JsonParameters = [ordered]@{
						VMName      = $VMName
						Path        = $Path
						Destination = $Destination
						Purge       = $Purge.ToBool()
					}

					# create custom object from hashtable
					$JsonEntry = [pscustomobject]$JsonParameters

					# if existing entry has same primary key(s)...
					If ($JsonData | Where-Object { $_.VMName -eq $VMName }) {
						# inquire before removing existing entry
						Write-Warning -Message "Will overwrite existing entry for '$VMName' in configuration file: '$Json' `nAny previous configuration for this entry will **NOT** be preserved" -WarningAction Inquire
						# remove existing entry with same primary key(s)
						$JsonData = $JsonData | Where-Object { $_.VMName -ne $VMName }
					}

					# add entry to data
					$JsonData += $JsonEntry

					# export JSON data
					$JsonData | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
					Write-Output "`nAdded '$VMName' to configuration file: '$Json'"
					$JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
				}
				Catch {
					Write-Warning -Message "could not update configuration file: '$Json'"
				}
			}
			# process entries in configuration file
			Default {
				# declare start
				Write-Verbose -Verbose -Message "Exporting files from VM with PSDirect per '$Json'"

				# check entry count in configuration file
				If ($JsonData.Count -eq 0) {
					Write-Warning -Message "no entries found in configuration file: '$Json'"
					Return
				}

				# process configuration file
				:JsonEntry ForEach ($JsonEntry in $JsonData) {
					# validate values in JSON file
					Switch ($true) {
						([string]::IsNullOrEmpty($JsonEntry.VMName)) {
							Write-Warning -Message "required entry (VMName) not found in configuration file: $Json"; Continue JsonEntry
						}
						([string]::IsNullOrEmpty($JsonEntry.Path)) {
							Write-Warning -Message "required value (Path) not found in configuration file: $Json"; Continue JsonEntry
						}
						([string]::IsNullOrEmpty($JsonEntry.Destination)) {
							Write-Warning -Message "required value (Destination) not found in configuration file: $Json"; Continue JsonEntry
						}
						Default {
							# define parameters
							$CopyPathFromPSDirect = @{
								VMName      = $JsonEntry.VMName
								Path        = $JsonEntry.Path
								Destination = $JsonEntry.Destination
								Purge       = $JsonEntry.Purge
							}

							# copy files from VM
							Try {
								Copy-PathFromPSDirect @CopyPathFromPSDirect
							}
							Catch {
								Return $_
							}
						}
					}
				}
			}
		}
	}

	End {
		# if parameter set is Default and SkipTranscript not set...
		If ($PSCmdlet.ParameterSetName -eq 'Default' -and -not $PSBoundParameters.ContainsKey('SkipTranscript')) {
			# stop transcript with default parameters
			Try {
				Stop-TranscriptWithHostAndDate
			}
			Catch {
				Throw $_
			}
		}
	}
}

Function Import-FilesWithPSDirect {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		# path to JSON configuration file
		[Parameter(Mandatory = $True, Position = 0)]
		[string]$Json,
		# script parameters - mode
		[Parameter(Mandatory = $True, ParameterSetName = 'Show')]
		[switch]$Show,
		[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
		[switch]$Clear,
		[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
		[switch]$Remove,
		[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
		[switch]$Add,
		# copy parameter - VM name
		[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
		[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
		[ValidatePattern('^[^\*]+$')]
		[string]$VMName,
		# copy parameter - path on host
		[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
		[ValidatePattern('^[^\*]+$')]
		[string]$Path,
		# copy parameter - path on VM
		[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
		[ValidatePattern('^[^\*]+$')]
		[string]$Destination,
		# copy parameter - clear destination on VM first
		[Parameter(ParameterSetName = 'Add')]
		[switch]$Purge,
		# switch to skip transcript logging
		[Parameter(DontShow)]
		[switch]$SkipTranscript,
		# local host name
		[Parameter(DontShow)]
		[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
		# local domain name
		[Parameter(DontShow)]
		[string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
		# local DNS hostname
		[Parameter(DontShow)]
		[string]$DnsHostName = ($HostName, $DomainName -join '.').TrimEnd('.')
	)

	Begin {
		# if parameter set is Default and SkipTranscript not set...
		If ($PSCmdlet.ParameterSetName -eq 'Default' -and -not $PSBoundParameters.ContainsKey('SkipTranscript')) {
			# start transcript with default parameters
			Try {
				Start-TranscriptWithHostAndDate
			}
			Catch {
				Throw $_
			}
		}
	}

	Process {
		# if JSON file found...
		If (Test-Path -Path $Json) {
			# ...create JSON data object as array of PSCustomObjects from JSON file content
			Try {
				$JsonData = [array](Get-Content -Path $Json -ErrorAction 'Stop' | ConvertFrom-Json -ErrorAction 'Stop')
			}
			Catch {
				Write-Warning -Message "could not read configuration file: '$Json'"
				Return $_
			}
		}
		# if JSON file was not found...
		Else {
			# ...and Add set...
			If ($Add) {
				# ...try to create the JSON file
				Try {
					$null = New-Item -ItemType 'File' -Path $Json -ErrorAction 'Stop'
				}
				Catch {
					Write-Warning -Message "could not create configuration file: '$Json'"
					Return $_
				}
				# ...create JSON data object as empty array
				$JsonData = @()
			}
			# ...and Add not set...
			Else {
				# ...report and return
				Write-Warning -Message "could not find configuration file: '$Json'"
				Return
			}
		}

		# evaluate parameters
		switch ($true) {
			# show configuration file
			$Show {
				Write-Verbose -Verbose -Message "Displaying '$Json'"
				$JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
			}
			# clear configuration file
			$Clear {
				Try {
					[string]::Empty | Set-Content -Path $Json
					Write-Verbose -Verbose -Message "Cleared configuration file: '$Json'"
				}
				Catch {
					Write-Warning -Message "could not clear configuration file: '$Json'"
					Return $_
				}
			}
			# remove entry from configuration file
			$Remove {
				Try {
					# remove existing entry by primary key(s)...
					$JsonData = $JsonData | Where-Object { $_.VMName -ne $VMName }
					# if JSON data empty...
					If ($null -eq $JsonData) {
						# clear JSON data
						[string]::Empty | Set-Content -Path $Json
						Write-Verbose -Verbose -Message "Removed '$VMName' from configuration file: '$Json'"
					}
					Else {
						# export JSON data
						$JsonData | Sort-Object -Property 'VMName' | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
						Write-Verbose -Verbose -Message "Removed '$VMName' from configuration file: '$Json'"
						$JsonData | Sort-Object -Property 'VMName' | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
					}
				}
				Catch {
					Write-Warning -Message "could not update configuration file: '$Json'"
					Return $_
				}
			}
			# add entry to configuration file
			$Add {
				Try {
					# create hashtable for custom object
					$JsonParameters = [ordered]@{
						VMName      = $VMName
						Path        = $Path
						Destination = $Destination
						Purge       = $Purge.ToBool()
					}

					# create custom object from hashtable
					$JsonEntry = [pscustomobject]$JsonParameters

					# if existing entry has same primary key(s)...
					If ($JsonData | Where-Object { $_.VMName -eq $VMName }) {
						# inquire before removing existing entry
						Write-Warning -Message "Will overwrite existing entry for '$VMName' in configuration file: '$Json' `nAny previous configuration for this entry will **NOT** be preserved" -WarningAction 'Inquire'
						# remove existing entry with same primary key(s)
						$JsonData = $JsonData | Where-Object { $_.VMName -ne $VMName }
					}

					# add entry to data
					$JsonData += $JsonEntry

					# export JSON data
					$JsonData | Sort-Object -Property 'VMName' | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
					Write-Verbose -Verbose -Message "Added '$VMName' to configuration file: '$Json'"
					$JsonData | Sort-Object -Property 'VMName' | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
				}
				Catch {
					Write-Warning -Message "could not update configuration file: '$Json'"
				}
			}
			# process entries in configuration file
			Default {
				# declare start
				Write-Verbose -Verbose -Message "Importing files to VM with PSDirect per '$Json'"

				# check entry count in configuration file
				If ($JsonData.Count -eq 0) {
					Write-Warning -Message "no entries found in configuration file: $Json"
					Return
				}

				# process configuration file
				:JsonEntry ForEach ($JsonEntry in $JsonData) {
					# validate values in JSON file
					Switch ($true) {
						([string]::IsNullOrEmpty($JsonEntry.VMName)) {
							Write-Warning -Message "required entry (VMName) not found in configuration file: $Json"; Continue JsonEntry
						}
						([string]::IsNullOrEmpty($JsonEntry.Path)) {
							Write-Warning -Message "required value (Path) not found in configuration file: $Json"; Continue JsonEntry
						}
						([string]::IsNullOrEmpty($JsonEntry.Destination)) {
							Write-Warning -Message "required value (Destination) not found in configuration file: $Json"; Continue JsonEntry
						}
						Default {
							# define parameters
							$CopyPathToPSDirect = @{
								VMName      = $JsonEntry.VMName
								Path        = $JsonEntry.Path
								Destination = $JsonEntry.Destination
								Purge       = $JsonEntry.Purge
							}

							# copy files to VM
							Try {
								Copy-PathToPSDirect @CopyPathToPSDirect
							}
							Catch {
								Return $_
							}
						}
					}
				}
			}
		}
	}

	End {
		# if parameter set is Default and SkipTranscript not set...
		If ($PSCmdlet.ParameterSetName -eq 'Default' -and -not $PSBoundParameters.ContainsKey('SkipTranscript')) {
			# stop transcript with default parameters
			Try {
				Stop-TranscriptWithHostAndDate
			}
			Catch {
				Throw $_
			}
		}
	}
}

# define functions to export
$FunctionsToExport = @(
	'Export-FilesWithPSDirect'
	'Import-FilesWithPSDirect'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport
