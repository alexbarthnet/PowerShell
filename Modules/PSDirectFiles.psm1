#Requires -Modules CmsCredentials

Function Copy-PathFromPSDirect {
	[CmdletBinding()]
	param (
		[string]$VMName,
		[string]$Path,
		[string]$Destination,
		[switch]$Purge
	)

	# check for VM on local system
	$vm_check = $null
	$vm_check = Get-VM | Where-Object { $_.Name -eq $VMName }
	If ($vm_check) {
		# retrieve VM credentials
		$Credential = $null
		$Credential = Unprotect-CmsCredentials -Identity $VMName
		If ($Credential) {
			# connect to VM
			$vm_direct = $null
			$vm_direct = New-PSSession -VMName $VMName -Credential $Credential
			If ($vm_direct) {
				# verify Path
				If (Invoke-Command -Session $vm_direct -ScriptBlock { Test-Path -Path $using:Path }) {
					# retrieve files from Path
					$file_list = @()
					$file_list += Invoke-Command -Session $vm_direct -ScriptBlock { Get-ChildItem -Path $using:Path }
					If ($file_list) {
						# verify Destination
						$destination_check = $null
						$destination_check = Test-Path -Path $Destination -PathType Container
						If ($destination_check) {
							# determine if Destination should be cleared before writing files
							If ($Purge) {
								Get-ChildItem -Path $Destination -Recurse -Force | Remove-Item -Force -Verbose
							}
							# copy files from VM to Destination
							Try {
								ForEach ($file in $file_list.FullName) {
									Copy-Item -FromSession $vm_direct -Path $file -Destination $Destination -Force -Verbose
								}
							}
							Catch {
								Write-Output "Could not copy files to destination folder '$Destination' on host"
							}
						}
						Else {
							Write-Output "Could not locate destination folder '$Destination' on host"
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
		[switch]$Purge
	)

	# check for VM on local system
	$vm_check = $null
	$vm_check = Get-VM | Where-Object { $_.Name -eq $VMName }
	If ($vm_check) {
		# retrieve VM credentials
		$Credential = $null
		$Credential = Unprotect-CmsCredentials -Identity $VMName
		If ($Credential) {
			# connect to VM
			$vm_direct = $null
			$vm_direct = New-PSSession -VMName $VMName -Credential $Credential
			If ($vm_direct) {
				# verify Path
				If (Test-Path -Path $Path) {
					# retrieve files from path
					$file_list = @()
					$file_list += Get-ChildItem -Path $Path
					If ($file_list) {
						# verify destination on VM
						$destination_check = $null
						$destination_check = Invoke-Command -Session $vm_direct -ScriptBlock { Test-Path -Path $using:Destination -PathType Container }
						If ($destination_check) {
							# determine if Destination should be cleared before writing files
							If ($Purge) {
								Invoke-Command -Session $vm_direct -ScriptBlock { Get-ChildItem -Path $using:Destination -Recurse -Force | Remove-Item -Force -Verbose }
							}
							# copy files from VM to Destination
							Try {
								ForEach ($file in $file_list.FullName) {
									Copy-Item -ToSession $vm_direct -Path $file -Destination $Destination -Force -Verbose
								}
							}
							Catch {
								Write-Output "Could not copy files to destination folder '$Destination' on VM"
							}
						}
						Else {
							Write-Output "Could not locate destination folder '$Destination' on VM"
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
		[Parameter(Mandatory = $True, ParameterSetName = 'Run')]
		[switch]$Run,
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
		[Parameter()]
		[string]$Json = $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.json')
	)

	Begin {
		# if running...
		If ($Run) {
			# append hostname and datetime to script path to define transcript path
			$TranscriptFile = $PSCommandPath.Replace('.ps1', "_$HostName.txt").Replace('.txt', "_$LogStart.txt")
			# define ideal log path
			$TranscriptPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Logs'
			# if ideal log path found...
			If (Test-Path -Path $TranscriptPath -PathType 'Container') {
				# update transcript path
				$TranscriptFile = $TranscriptFile.Replace($PSScriptRoot, $TranscriptPath)
			}
			# define parameters for Start-Transcript
			$StartTranscript = @{
				Path        = $TranscriptFile
				Force       = $true
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}
			# start transcript
			Try	{
				Start-Transcript @StartTranscript
			}
			Catch {
				# get program data path
				$TranscriptRoot = [System.Environment]::GetFolderPath('CommonApplicationData')
				# get basename of script
				$TranscriptBase = Get-Item -Path $PSCommandPath | Select-Object -ExpandProperty 'BaseName'
				# define path in program data
				$TranscriptPath = Join-Path -Path $TranscriptRoot -ChildPath $TranscriptBase
				# if path in program data not found...
				If ((Test-Path -Path $TranscriptPath -PathType 'Container') -eq $false) {
					Try {
						# create path in program data
						$null = New-Item -Path $TranscriptPath -ItemType 'Directory' -ErrorAction Stop
						# redirect transcript file from script directory to path in program data
						$TranscriptFile = $TranscriptFile.Replace($PSScriptRoot, $TranscriptPath)
					}
					Catch {
						# clear errors before starting script
						$Error.Clear()
						# redirect transcript file from script directory to root of program data
						$TranscriptFile = $TranscriptFile.Replace($PSScriptRoot, $TranscriptRoot)
					}
				}
				# update parameters for Start-Transcript
				$StartTranscript['Path'] = $TranscriptFile
				# start transcript
				Try {
					Start-Transcript @StartTranscript
				}
				Catch {
					Throw $_
				}
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
				Try {
					# define transcript file from script path and start transcript
					Start-Transcript -Path $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.txt') -Force

					# check entry count in configuration file
					If ($JsonData.Count -eq 0) {
						Write-Output "`nERROR: no entries found in configuration file: '$Json'"
						Return
					}

					# process configuration file
					ForEach ($json_datum in $JsonData) {
						If ([string]::IsNullOrEmpty($json_datum.VMName) -or [string]::IsNullOrEmpty($json_datum.Path) -or [string]::IsNullOrEmpty($json_datum.Destination)) {
							Write-Output "`nERROR: invalid entry found in configuration file: '$Json'"
						}
						Else {
							Copy-PathFromPSDirect -VMName $json_datum.VMName -Path $json_datum.Path -Destination $json_datum.Destination -Purge:$json_datum.Purge
						}
					}
				}
				Finally {
					Write-Output ([string]::Empty)
					Stop-Transcript
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
			# get transcript path
			$PathForTranscript = Split-Path -Path $StartTranscript['Path'] -Parent
			# get transcript name
			$NameForTranscript = (Split-Path -Path $StartTranscript['Path'] -Leaf).Replace("_$LogStart.txt", $null)
			# get transcript files
			$TranscriptFiles = Get-ChildItem -Path $PathForTranscript | Where-Object { $_.BaseName.StartsWith($NameForTranscript, [System.StringComparison]::InvariantCultureIgnoreCase) -and $_.LastWriteTime -lt (Get-Date).AddDays(-$LogDays) }
			# get transcript files newer than cleanup date
			$NewFiles = $TranscriptFiles | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-$LogDays) }
			# if count of transcript files count is less than cleanup threshold...
			If ($LogCount -lt $NewFiles.Count ) {
				# declare and continue
				Write-Output "Skipping transcript file cleanup; count of transcript files ($($NewFiles.Count)) is below cleanup threshold ($LogCount)"
			}
			# if count of transcript files is not less than cleanup threshold...
			Else {
				# get log files older than cleanup date
				$OldFiles = $TranscriptFiles | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogDays) } | Sort-Object -Property FullName
				# remove old logs
				ForEach ($OldFile in $OldFiles) {
					Write-Output "Removing old transcript file: $($OldFile.FullName)"
					Try { 
						Remove-Item -Path $OldFile.FullName -Force -ErrorAction Stop
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
	}
}

Function Import-FilesWithPSDirect {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Mandatory = $True, ParameterSetName = 'Run')]
		[switch]$Run,
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
		[Parameter()]
		[string]$Json = $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.json')
	)

	Begin {
		# if running...
		If ($Run) {
			# append hostname and datetime to script path to define transcript path
			$TranscriptFile = $PSCommandPath.Replace('.ps1', "_$HostName.txt").Replace('.txt', "_$LogStart.txt")
			# define ideal log path
			$TranscriptPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Logs'
			# if ideal log path found...
			If (Test-Path -Path $TranscriptPath -PathType 'Container') {
				# update transcript path
				$TranscriptFile = $TranscriptFile.Replace($PSScriptRoot, $TranscriptPath)
			}
			# define parameters for Start-Transcript
			$StartTranscript = @{
				Path        = $TranscriptFile
				Force       = $true
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}
			# start transcript
			Try	{
				Start-Transcript @StartTranscript
			}
			Catch {
				# get program data path
				$TranscriptRoot = [System.Environment]::GetFolderPath('CommonApplicationData')
				# get basename of script
				$TranscriptBase = Get-Item -Path $PSCommandPath | Select-Object -ExpandProperty 'BaseName'
				# define path in program data
				$TranscriptPath = Join-Path -Path $TranscriptRoot -ChildPath $TranscriptBase
				# if path in program data not found...
				If ((Test-Path -Path $TranscriptPath -PathType 'Container') -eq $false) {
					Try {
						# create path in program data
						$null = New-Item -Path $TranscriptPath -ItemType 'Directory' -ErrorAction Stop
						# redirect transcript file from script directory to path in program data
						$TranscriptFile = $TranscriptFile.Replace($PSScriptRoot, $TranscriptPath)
					}
					Catch {
						# clear errors before starting script
						$Error.Clear()
						# redirect transcript file from script directory to root of program data
						$TranscriptFile = $TranscriptFile.Replace($PSScriptRoot, $TranscriptRoot)
					}
				}
				# update parameters for Start-Transcript
				$StartTranscript['Path'] = $TranscriptFile
				# start transcript
				Try {
					Start-Transcript @StartTranscript
				}
				Catch {
					Throw $_
				}
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
				Try {
					# define transcript file from script path and start transcript
					Start-Transcript -Path $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.txt') -Force

					# check entry count in configuration file
					If ($JsonData.Count -eq 0) {
						Write-Output "`nERROR: no entries found in configuration file: '$Json'"
						Return
					}

					# process configuration file
					ForEach ($json_datum in $JsonData) {
						If ([string]::IsNullOrEmpty($json_datum.VMName) -or [string]::IsNullOrEmpty($json_datum.Path) -or [string]::IsNullOrEmpty($json_datum.Destination)) {
							Write-Output "`nERROR: invalid entry found in configuration file: '$Json'"
						}
						Else {
							Copy-PathToPSDirect -VMName $json_datum.VMName -Path $json_datum.Path -Destination $json_datum.Destination -Purge:$json_datum.Purge
						}
					}
				}
				Finally {
					Write-Output ([string]::Empty)
					Stop-Transcript
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
			# get transcript path
			$PathForTranscript = Split-Path -Path $StartTranscript['Path'] -Parent
			# get transcript name
			$NameForTranscript = (Split-Path -Path $StartTranscript['Path'] -Leaf).Replace("_$LogStart.txt", $null)
			# get transcript files
			$TranscriptFiles = Get-ChildItem -Path $PathForTranscript | Where-Object { $_.BaseName.StartsWith($NameForTranscript, [System.StringComparison]::InvariantCultureIgnoreCase) -and $_.LastWriteTime -lt (Get-Date).AddDays(-$LogDays) }
			# get transcript files newer than cleanup date
			$NewFiles = $TranscriptFiles | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-$LogDays) }
			# if count of transcript files count is less than cleanup threshold...
			If ($LogCount -lt $NewFiles.Count ) {
				# declare and continue
				Write-Output "Skipping transcript file cleanup; count of transcript files ($($NewFiles.Count)) is below cleanup threshold ($LogCount)"
			}
			# if count of transcript files is not less than cleanup threshold...
			Else {
				# get log files older than cleanup date
				$OldFiles = $TranscriptFiles | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogDays) } | Sort-Object -Property FullName
				# remove old logs
				ForEach ($OldFile in $OldFiles) {
					Write-Output "Removing old transcript file: $($OldFile.FullName)"
					Try { 
						Remove-Item -Path $OldFile.FullName -Force -ErrorAction Stop
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
	}
}
