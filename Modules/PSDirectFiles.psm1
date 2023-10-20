#Requires -Modules CmsCredentials

Function Start-TranscriptWithHostAndDate {
	Param(
		[switch]$RelativePath,
		[switch]$AbsolutePath
	)

	# get basename from command path
	$PSCommandBase = Get-Item -Path $PSCommandPath | Select-Object -ExpandProperty BaseName
	# append hostname and datetime to basename of command path to define transcript base
	$TranscriptBase = "$PSCommandBase`_$HostName`_$LogStart`.txt"
	# define ideal log path
	$TranscriptPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Logs'
	# if ideal log path found...
	If (Test-Path -Path $TranscriptPath -PathType 'Container') {
		# ...log to ideal location
		$TranscriptFile = Join-Path -Path $TranscriptPath -ChildPath $TranscriptBase
	}
	# if ideal log path not found...
	Else {
		# ...log to script root
		$TranscriptFile = Join-Path -Path $PSScriptRoot -ChildPath $TranscriptBase
	}
	# define parameters for Start-Transcript
	$script:StartTranscript = @{
		Path        = $TranscriptFile
		Force       = $true
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}
	# start transcript
	Try	{
		Start-Transcript @script:StartTranscript
	}
	Catch {
		# get program data path
		$TranscriptRoot = [System.Environment]::GetFolderPath('CommonApplicationData')
		# define path in program data
		$TranscriptPath = Join-Path -Path $TranscriptRoot -ChildPath $PSCommandBase
		# if path in program data not found...
		If ((Test-Path -Path $TranscriptPath -PathType 'Container') -eq $false) {
			Try {
				# create path in program data
				$null = New-Item -Path $TranscriptPath -ItemType 'Directory' -ErrorAction Stop
				# redirect transcript file from script directory to path in program data
				$script:StartTranscript['Path'] = Join-Path -Path $TranscriptPath -ChildPath $TranscriptBase
			}
			Catch {
				# clear errors before starting script
				$Error.Clear()
				# redirect transcript file from script directory to root of program data
				$script:StartTranscript['Path'] = Join-Path -Path $TranscriptRoot -ChildPath $TranscriptBase
			}
		}
		# start transcript
		Try {
			Start-Transcript @script:StartTranscript
		}
		Catch {
			Throw $_
		}
	}
}

Function Stop-TranscriptWithHostAndDate {
	# get transcript path
	$PathForTranscript = Split-Path -Path $script:StartTranscript['Path'] -Parent
	# get transcript name
	$NameForTranscript = (Split-Path -Path $script:StartTranscript['Path'] -Leaf).Replace("_$LogStart.txt", $null)
	# declare transcript cleanup
	Write-Verbose -Message "Removing old transcript files named '$NameForTranscript' from '$PathForTranscript'" -Verbose
	# get transcript files
	$TranscriptFiles = Get-ChildItem -Path $PathForTranscript | Where-Object { $_.BaseName.StartsWith($NameForTranscript, [System.StringComparison]::InvariantCultureIgnoreCase) -and $_.LastWriteTime -lt (Get-Date).AddDays(-$LogDays) }
	# get transcript files newer than cleanup date
	$NewFiles = $TranscriptFiles | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-$LogDays) }
	
	# if count of transcript files count is less than cleanup threshold...
	If ($LogCount -lt $NewFiles.Count ) {
		# declare and continue
		Write-Verbose -Message "Skipping transcript file cleanup; count of transcript files ($($NewFiles.Count)) is below cleanup threshold ($LogCount)" -Verbose
	}
	# if count of transcript files is not less than cleanup threshold...
	Else {
		# get log files older than cleanup date
		$OldFiles = $TranscriptFiles | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogDays) } | Sort-Object -Property FullName
		# remove old logs
		ForEach ($OldFile in $OldFiles) {
			Try {
				Remove-Item -Path $OldFile.FullName -Force -Verbose -ErrorAction Stop
			}
			Catch {
				$_
			}
		}
	}

	# stop transcript
	Try {
		Stop-Transcript
	}
	Catch {
		Throw $_
	}
}

Function Copy-PathFromPSDirect {
	[CmdletBinding()]
	param (
		[string]$VMName,
		[string]$Path,
		[string]$Destination,
		[switch]$Purge
	)

	# check for VM on local system
	Try {
		$null = Get-VM -VMName $VMName -ErrorAction Stop
	}
	Catch {
		Write-Output "Could not locate VM: '$VMName'"
		Return
	}

	# retrieve VM credentials
	Try {
		$Credential = Unprotect-CmsCredentials -Identity $VMName
	}
	Catch {
		Write-Output "Could not unprotect credentials for VM: '$VMName'"
		Return
	}

	# verify VM credentials
	If (!$Credential) {
		Write-Output "Could not locate credentials for VM: '$VMName'"
		Return
	}

	# create PSDirect session
	Try {
		$Session = New-PSSession -VMName $VMName -Credential $Credential -ErrorAction Stop
	}
	Catch {
		Write-Output "Could not create PowerShell Direct session for VM: '$VMName'"
		Return
	}

	# test path on VM
	Try {
		$TestPath = Invoke-Command -Session $Session -ScriptBlock { Test-Path -Path $using:Path } -ErrorAction Stop
	}
	Catch {
		Write-Output "Could test path '$Path' on VM: '$VMName'"
		Return
	}

	# verify path on VM
	If (!$TestPath) {
		Write-Output "Could not find '$Path' on VM: '$VMName'"
		Return
	}

	# test destination on host
	If (!(Test-Path -Path $Destination -PathType Container )) {
		Write-Output "Could not find '$Destination' on host"
		Return
	}

	# retrieve files from path on VM
	Try {
		$Items = Invoke-Command -Session $Session -ScriptBlock { Get-ChildItem -Path $using:Path -ErrorAction Stop }
	}
	Catch {
		Write-Output "Could not retrieve files in '$Path' on VM: '$VMName'"
		Return
	}

	# remove files in destination on host before copying files from path on VM
	If ($Purge -and $Items) {
		Try {
			Get-ChildItem -Path $Destination -Recurse -Force -ErrorAction Stop | Remove-Item -Force -Verbose -ErrorAction Stop
		}
		Catch {
			Write-Output "Could not clear destination folder '$Destination' on host before file copy"
		}
	}

	# copy files from path on VM to destination on host
	Try {
		ForEach ($Item in $Items.FullName) {
			Copy-Item -FromSession $Session -Path $Item -Destination $Destination -Force -Verbose -ErrorAction Stop
		}
	}
	Catch {
		Write-Output "Could not copy files to destination folder '$Destination' on host"
	}

	# disconnect from VM
	Try {
		Remove-PSSession -Session $Session -ErrorAction Stop
	}
	Catch {
		Write-Output "Could not remove PowerShell Direct session for VM: '$VMName'"
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

	# check for VM on local system
	Try {
		$null = Get-VM -VMName $VMName -ErrorAction Stop
	}
	Catch {
		Write-Output "Could not locate VM: '$VMName'"
		Return
	}

	# retrieve VM credentials
	Try {
		$Credential = Unprotect-CmsCredentials -Identity $VMName
	}
	Catch {
		Write-Output "Could not unprotect credentials for VM: '$VMName'"
		Return
	}

	# verify VM credentials
	If (!$Credential) {
		Write-Output "Could not locate credentials for VM: '$VMName'"
		Return
	}

	# create PSDirect session
	Try {
		$Session = New-PSSession -VMName $VMName -Credential $Credential -ErrorAction Stop
	}
	Catch {
		Write-Output "Could not create PowerShell Direct session for VM: '$VMName'"
		Return
	}

	# test path on host
	If (!(Test-Path -Path $Path)) {
		Write-Output "Could not find '$Path' on host"
		Return
	}

	# test destination on VM
	Try {
		$TestDestination = Invoke-Command -Session $Session -ScriptBlock { Test-Path -Path $using:Destination -PathType Container } -ErrorAction Stop
	}
	Catch {
		Write-Output "Could test path '$Destination' on VM: '$VMName'"
		Return
	}

	# verify path on VM
	If (!$TestDestination) {
		Write-Output "Could not find '$Destination' on VM: '$VMName'"
		Return
	}

	# retrieve files from path on host
	Try {
		$Items = Get-ChildItem -Path $Path -ErrorAction Stop
	}
	Catch {
		Write-Output "Could not retrieve files in '$Path' on host"
		Return
	}

	# remove files in destination on VM before copying files from path on host
	If ($Purge -and $Items) {
		Try {
			Invoke-Command -Session $Session -ScriptBlock { Get-ChildItem -Path $using:Destination -Recurse -Force -ErrorAction Stop | Remove-Item -Force -Verbose -ErrorAction Stop }
		}
		Catch {
			Write-Output "Could not clear destination folder '$Destination' on VM before file copy"
		}
	}

	# copy files from path on host to destination on VM
	Try {
		ForEach ($Item in $Items.FullName) {
			Copy-Item -ToSession $Session -Path $Item -Destination $Destination -Force -Verbose -ErrorAction Stop
		}
	}
	Catch {
		Write-Output "Could not copy files to destination folder '$Destination' on VM: '$VMName'"
	}

	# disconnect from VM
	Try {
		Remove-PSSession -Session $Session -ErrorAction Stop
	}
	Catch {
		Write-Output "Could not remove PowerShell Direct session for VM: '$VMName'"
	}
}

Function Export-FilesWithPSDirect {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
		[switch]$Clear,
		[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
		[switch]$Remove,
		[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
		[switch]$Add,
		[Parameter(Mandatory = $True, ParameterSetName = 'Run')]
		[switch]$Run,
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
		[Parameter()]
		[string]$Json = $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.json'),
		# log file max age
		[Parameter(DontShow)]
		[double]$LogDays = 7,
		# log file min count
		[Parameter(DontShow)]
		[uint16]$LogCount = 7,
		# log start time
		[Parameter(DontShow)]
		[string]$LogStart = (Get-Date -Format FileDateTimeUniversal),
		# local hostname
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
	)

	Begin {
		# if running...
		If ($Run) {
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
				Write-Output "`nERROR: could not read configuration file: '$Json'"
				Return $_
			}
		}
		# if JSON file was not found...
		Else {
			# ...and Add set...
			If ($Add) {
				# ...try to create the JSON file
				Try {
					$null = New-Item -ItemType 'File' -Path $Json -ErrorAction Stop
				}
				Catch {
					Write-Output "`nERROR: could not create configuration file: '$Json'"
					Return $_
				}
				# ...create JSON data object as empty array
				$JsonData = @()
			}
			# ...and Add not set...
			Else {
				# ...report and return
				Write-Output "`nERROR: could not find configuration file: '$Json'"
				Return
			}
		}

		# evaluate parameters
		switch ($true) {
			# clear configuration file
			$Clear {
				Try {
					Remove-Item -Path $Json -Force
					Write-Output "`nCleared configuration file: '$Json'"
				}
				Catch {
					Write-Output "`nERROR: could not clear configuration file: '$Json'"
				}
			}
			# remove entry from configuration file
			$Remove {
				Try {
					$JsonData = $JsonData | Where-Object { $_.VMName -ne $VMName }
					If ($null -eq $JsonData) {
						[string]::Empty | Set-Content -Path $Json
						Write-Output "`nRemoved '$VMName' from configuration file: '$Json'"
					}
					Else {
						$JsonData | ConvertTo-Json | Set-Content -Path $Json
						Write-Output "`nRemoved '$VMName' from configuration file: '$Json'"
					}
					$JsonData | Format-List

				}
				Catch {
					Write-Output "`nERROR: could not update configuration file: '$Json'"
				}
			}
			# add entry to configuration file
			$Add {
				Try {
					# create hashtable for custom object
					$JsonValues = [ordered]@{
						VMName      = $VMName
						Path        = $Path
						Destination = $Destination
						Purge       = $Purge.ToBool()
					}

					# create custom object from hashtable
					$JsonEntry = [pscustomobject]$JsonValues

					# remove existing entry with same name
					If ($JsonData | Where-Object { $_.VMName -eq $VMName }) {
						Write-Warning -Message "Will overwrite existing entry for '$VMName' in configuration file: '$Json' `nAny previous configuration for this entry will **NOT** be preserved" -WarningAction Inquire
						$JsonData = $JsonData | Where-Object { $_.VMName -ne $VMName }
					}

					# add datum to data
					$JsonData += $JsonEntry
					$JsonData | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
					Write-Output "`nAdded '$VMName' to configuration file: '$Json'"
					$JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
				}
				Catch {
					Write-Output "`nERROR: could not update configuration file: '$Json'"
				}
			}
			# run through entries in configuration file
			$Run {
				# check entry count in configuration file
				If ($JsonData.Count -eq 0) {
					Write-Output "`nERROR: no entries found in configuration file: '$Json'"
					Return
				}

				# process configuration file
				ForEach ($JsonEntry in $JsonData) {
					If ([string]::IsNullOrEmpty($JsonEntry.VMName) -or [string]::IsNullOrEmpty($JsonEntry.Path) -or [string]::IsNullOrEmpty($JsonEntry.Destination)) {
						Write-Output "`nERROR: invalid entry found in configuration file: '$Json'"
					}
					Else {
						Try {
							Copy-PathFromPSDirect -VMName $JsonEntry.VMName -Path $JsonEntry.Path -Destination $JsonEntry.Destination -Purge:$JsonEntry.Purge
						}
						Catch {
							Return $_
						}
					}
				}
			}
			Default {
				Write-Output "`nDisplaying configuration file: '$Json'"
				$JsonData | Select-Object VMName, Path, Destination, Purge
			}
		}
	}

	End {
		# if running...
		If ($Run) {
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
		[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
		[switch]$Clear,
		[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
		[switch]$Remove,
		[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
		[switch]$Add,
		[Parameter(Mandatory = $True, ParameterSetName = 'Run')]
		[switch]$Run,
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
		[Parameter()]
		[string]$Json = $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.json'),
		# log file max age
		[Parameter(DontShow)]
		[double]$LogDays = 7,
		# log file min count
		[Parameter(DontShow)]
		[uint16]$LogCount = 7,
		# log start time
		[Parameter(DontShow)]
		[string]$LogStart = (Get-Date -Format FileDateTimeUniversal),
		# local hostname
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
	)

	Begin {
		# if running...
		If ($Run) {
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
				Write-Output "`nERROR: could not read configuration file: '$Json'"
				Return $_
			}
		}
		# if JSON file was not found...
		Else {
			# ...and Add set...
			If ($Add) {
				# ...try to create the JSON file
				Try {
					$null = New-Item -ItemType 'File' -Path $Json -ErrorAction Stop
				}
				Catch {
					Write-Output "`nERROR: could not create configuration file: '$Json'"
					Return $_
				}
				# ...create JSON data object as empty array
				$JsonData = @()
			}
			# ...and Add not set...
			Else {
				# ...report and return
				Write-Output "`nERROR: could not find configuration file: '$Json'"
				Return
			}
		}

		# evaluate parameters
		switch ($true) {
			# clear configuration file
			$Clear {
				If (Test-Path -Path $Json) {
					Try {
						Remove-Item -Path $Json -Force
						Write-Output "`nCleared configuration file: '$Json'"
					}
					Catch {
						Write-Output "`nERROR: could not clear configuration file: '$Json'"
					}
				}
			}
			# remove entry from configuration file
			$Remove {
				Try {
					$JsonData = $JsonData | Where-Object { $_.VMName -ne $VMName }
					If ($null -eq $JsonData) {
						[string]::Empty | Set-Content -Path $Json
						Write-Output "`nRemoved '$VMName' from configuration file: '$Json'"
					}
					Else {
						$JsonData | ConvertTo-Json | Set-Content -Path $Json
						Write-Output "`nRemoved '$VMName' from configuration file: '$Json'"
					}
					$JsonData | Format-List

				}
				Catch {
					Write-Output "`nERROR: could not update configuration file: '$Json'"
				}
			}
			# add entry to configuration file
			$Add {
				Try {
					# create hashtable for custom object
					$JsonValues = [ordered]@{
						VMName      = $VMName
						Path        = $Path
						Destination = $Destination
						Purge       = $Purge.ToBool()
					}

					# create custom object from hashtable
					$JsonEntry = [pscustomobject]$JsonValues

					# remove existing entry with same name
					If ($JsonData | Where-Object { $_.VMName -eq $VMName }) {
						Write-Warning -Message "Will overwrite existing entry for '$VMName' in configuration file: '$Json' `nAny previous configuration for this entry will **NOT** be preserved" -WarningAction Inquire
						$JsonData = $JsonData | Where-Object { $_.VMName -ne $VMName }
					}

					# add datum to data
					$JsonData += $JsonEntry
					$JsonData | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
					Write-Output "`nAdded '$VMName' to configuration file: '$Json'"
					$JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
				}
				Catch {
					Write-Output "`nERROR: could not update configuration file: '$Json'"
				}
			}
			# run through entries in configuration file
			$Run {
				# define transcript file from script path and start transcript
				Start-Transcript -Path $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.txt') -Force

				# check entry count in configuration file
				If ($JsonData.Count -eq 0) {
					Write-Output "`nERROR: no entries found in configuration file: '$Json'"
					Return
				}

				# process configuration file
				ForEach ($JsonEntry in $JsonData) {
					If ([string]::IsNullOrEmpty($JsonEntry.VMName) -or [string]::IsNullOrEmpty($JsonEntry.Path) -or [string]::IsNullOrEmpty($JsonEntry.Destination)) {
						Write-Output "`nERROR: invalid entry found in configuration file: '$Json'"
					}
					Else {
						Try {
							Copy-PathToPSDirect -VMName $JsonEntry.VMName -Path $JsonEntry.Path -Destination $JsonEntry.Destination -Purge:$JsonEntry.Purge
						}
						Catch {
							Return $_
						}
					}
				}
			}
			Default {
				Write-Output "`nDisplaying configuration file: '$Json'"
				$JsonData | Select-Object VMName, Path, Destination, Purge
			}
		}
	}

	End {
		# if running...
		If ($Run) {
			Try {
				Stop-TranscriptWithHostAndDate
			}
			Catch {
				Throw $_
			}
		}
	}
}
