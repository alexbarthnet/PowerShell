#Requires -Modules CmsCredentials

Function Start-TranscriptWithHostAndDate {
	Param(
		# name for transcript file
		[Parameter()]
		[string]$TranscriptName,
		# path for transcript file
		[Parameter()]
		[string]$TranscriptPath,
		# log start time
		[Parameter(DontShow)]
		[string]$TranscriptTime = ([datetime]::Now.ToString('yyyyMMddHHmmss')),
		# local hostname
		[Parameter(DontShow)]
		[string]$TranscriptHost = ([System.Environment]::MachineName)
	)

	# define default transcript name as basename of running script
	If (!$PSBoundParameters.ContainsKey('TranscriptName')) {
		$TranscriptName = (Get-Item -Path $PSCommandPath).BaseName
	}

	# define default transcript path as named folder under transcripts folder in common application data folder
	If (!$PSBoundParameters.ContainsKey('TranscriptPath')) {
		$TranscriptPath = [System.Environment]::GetFolderPath('CommonApplicationData'), 'PowerShell_transcript', $TranscriptName -join '\'
	}

	# verify transcript path
	If (!(Test-Path -Path $TranscriptPath -PathType 'Container')) {
		# define parameters for New-Item
		$NewItem = @{
			Path        = $TranscriptPath
			ItemType    = 'Directory'
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# create transcript path
		Try {
			$null = New-Item @NewItem
		}
		Catch {
			Throw $_
		}
	}

	# build transcript file name with defined prefix, hostname, transcript name and current datetime
	$TranscriptFile = "PowerShell_transcript.$TranscriptHost.$TranscriptName.$TranscriptTime.txt"

	# define parameters for Start-Transcript
	$StartTranscript = @{
		Path        = Join-Path -Path $TranscriptPath -ChildPath $TranscriptFile
		Force       = $true
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# start transcript
	Try	{
		$null = Start-Transcript @StartTranscript
	}
	Catch {
		Throw $_
	}
}

Function Stop-TranscriptWithHostAndDate {
	Param(
		# name for transcript file
		[Parameter()]
		[string]$TranscriptName,
		# path of transcript files
		[Parameter()]
		[string]$TranscriptPath,
		# minimum number of transcript files for removal
		[Parameter(DontShow)]
		[uint16]$TranscriptCount = 7,
		# minimum age of transcript files for removal
		[Parameter(DontShow)]
		[double]$TranscriptDays = 7,
		# datetime for transcript files for removal
		[Parameter(DontShow)]
		[datetime]$TranscriptDate = ([datetime]::Now.AddDays(-$TranscriptDays)),
		# local hostname
		[Parameter(DontShow)]
		[string]$TranscriptHost = ([System.Environment]::MachineName)
	)

	# define default transcript name as basename of running script
	If (!$PSBoundParameters.ContainsKey('TranscriptName')) {
		$TranscriptName = (Get-Item -Path $PSCommandPath).BaseName
	}

	# define default transcript path as named folder under transcripts folder in common application data folder
	If (!$PSBoundParameters.ContainsKey('TranscriptPath')) {
		$TranscriptPath = [System.Environment]::GetFolderPath('CommonApplicationData'), 'PowerShell_transcript', $TranscriptName -join '\'
		# LEGACY: re-define default transcript path as string array containing current path and original path in common application data folder
		[string[]]$TranscriptPath = @([System.Environment]::GetFolderPath('CommonApplicationData'), $TranscriptPath)
	}

	# define filter using default transcript prefix, hostname, and script name
	$TranscriptFilter = "PowerShell_transcript.$TranscriptHost.$TranscriptName*"

	# get transcript files matching filter
	$TranscriptFiles = Get-ChildItem -Path $TranscriptPath -Filter $TranscriptFilter -ErrorAction 'SilentlyContinue'

	# split transcript files on transcript date
	$NewFiles, $OldFiles = $TranscriptFiles.Where({ $_.LastWriteTime -ge $TranscriptDate }, [System.Management.Automation.WhereOperatorSelectionMode]::Split)
	
	# if count of files after transcript date is less than to cleanup threshold...
	If ($NewFiles.Count -lt $TranscriptCount) {
		# declare skip
		Write-Verbose -Message "Skipping transcript file cleanup; count of transcripts ($($NewFiles.Count)) would be below minimum transcript count ($TranscriptCount)" -Verbose
	}
	Else {
		# declare cleanup
		Write-Verbose -Message "Removing any transcript files matching '$TranscriptFilter' that are older than '$TranscriptDays' days from: $TranscriptPath" -Verbose
		# remove old logs
		ForEach ($OldFile in ($OldFiles | Sort-Object -Property FullName)) {
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
		$null = Stop-Transcript
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
		# name in transcript files
		[Parameter(DontShow)]
		[string]$TranscriptName,
		# path to transcript files
		[Parameter(DontShow)]
		[string]$TranscriptPath,
		# local hostname
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
	)

	Begin {
		# if running...
		If ($Run) {
			# define parameters
			If (!$PSBoundParameters.ContainsKey('TranscriptName')) { $TranscriptName = $MyInvocation.MyCommand -replace '\.ps[m|d]?1$' }
			If (!$PSBoundParameters.ContainsKey('TranscriptPath')) { $TranscriptPath = $PSScriptRoot }
			# call transcript function
			Try {
				Start-TranscriptWithHostAndDate -TranscriptPath $TranscriptPath -TranscriptName $TranscriptName
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
				Stop-TranscriptWithHostAndDate -TranscriptPath $TranscriptPath -TranscriptName $TranscriptName
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
		# path for transcript files
		[Parameter()]
		[string]$TranscriptName,
		# path for transcript files
		[Parameter()]
		[string]$TranscriptPath,
		# local hostname
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
	)

	Begin {
		# if running...
		If ($Run) {
			# define parameters
			If (!$PSBoundParameters.ContainsKey('TranscriptName')) { $TranscriptName = $MyInvocation.MyCommand -replace '\.ps[m|d]?1$' }
			If (!$PSBoundParameters.ContainsKey('TranscriptPath')) { $TranscriptPath = $PSScriptRoot }
			# call transcript function
			Try {
				Start-TranscriptWithHostAndDate -TranscriptPath $TranscriptPath -TranscriptName $TranscriptName
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
				Stop-TranscriptWithHostAndDate -TranscriptPath $TranscriptPath -TranscriptName $TranscriptName
			}
			Catch {
				Throw $_
			}
		}
	}
}
