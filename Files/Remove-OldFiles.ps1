<#
.SYNOPSIS
Removes files and empty directories based upon values in a JSON configuration file.

.DESCRIPTION
Removes files and empty directories based upon values in a JSON configuration file. Files and empty directories are removed from the define path when the last write time is older than the computed datetime from the defined values.

.PARAMETER Json
The path to a JSON file containing the configuration for this script.

.PARAMETER Show
Switch parameter to show all entries from the JSON configuration file. Cannot be combined with the Clear, Remove, Add, or Run parameters.

.PARAMETER Clear
Switch parameter to clear all entries from the JSON configuration file. Cannot be combined with the Show, Remove, Add, or Run parameters.

.PARAMETER Remove
Switch parameter to remove an entry from the JSON configuration file. Cannot be combined with the Show, Clear, Add, or Run parameters.

.PARAMETER Add
Switch parameter to add an entry from the JSON configuration file. Cannot be combined with the Show, Clear, Remove, or Run parameters.

.PARAMETER Run
Switch parameter to remove files and empty directories based upoon the parameters provided to the script. Cannot be combined with the Show, Clear, Remove, or Add parameters.

.PARAMETER Path
The path containing files and empty directories that will be removed if older than the computed datetime. Required when the Remove, Add or Run parameters are specified.

.PARAMETER OlderThanUnits
The number of datetime units to create the computed datetime. Required when the Add or Run parameters are specified.

.PARAMETER OlderThanType
The type of datetime units to create the computed datetime. Required when the Add or Run parameters are specified. Valid values are 'Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', and 'Years'

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Remove-OldFiles.ps1 -Json C:\Content\config.json

.EXAMPLE
.\Remove-OldFiles.ps1 -Json C:\Content\config.json -Show

.EXAMPLE
.\Remove-OldFiles.ps1 -Json C:\Content\config.json -Clear

.EXAMPLE
.\Remove-OldFiles.ps1 -Json C:\Content\config.json -Remove -Path 'C:\Content\test'

.EXAMPLE
.\Remove-OldFiles.ps1 -Json C:\Content\config.json -Add -Path 'C:\Content\test' -OlderThanUnits 30 -OlderThanType 'Days'

.EXAMPLE
.\Remove-OldFiles.ps1 -Run -Path 'C:\Content\test' -OlderThanUnits 30 -OlderThanType 'Days'
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Show')]
	[switch]$Show,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Run')]
	[switch]$Run,
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Remove')][ValidatePattern('^[^\*]+$')]
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Add')][ValidatePattern('^[^\*]+$')]
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Run')][ValidatePattern('^[^\*]+$')]
	[string]$Path,
	[Parameter(Position = 2, Mandatory = $True, ParameterSetName = 'Add')][ValidateRange(1, 65535)]
	[Parameter(Position = 2, Mandatory = $True, ParameterSetName = 'Run')][ValidateRange(1, 65535)]
	[uint16]$OlderThanUnits,
	[Parameter(Position = 3, Mandatory = $True, ParameterSetName = 'Add')][ValidateSet('Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', 'Years')]
	[Parameter(Position = 3, Mandatory = $True, ParameterSetName = 'Run')][ValidateSet('Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', 'Years')]
	[string]$OlderThanType,
	[Parameter()]
	[string]$Json,
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipTranscript,
	# name in transcript files
	[Parameter(DontShow)]
	[string]$TranscriptName,
	# path to transcript files
	[Parameter(DontShow)]
	[string]$TranscriptPath,
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
	Function Get-PreviousDate {
		Param (
			[Parameter(Mandatory = $true, Position = 0)][ValidateRange(1, 65535)]
			[uint16]$OlderThanUnits,
			[Parameter(Mandatory = $true, Position = 1)][ValidateSet('Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', 'Years')]
			[string]$OlderThanType
		)
		Switch ($OlderThanType) {
			'Seconds' { Return (Get-Date).AddSeconds(-1 * $OlderThanUnits) }
			'Minutes' { Return (Get-Date).AddMinutes(-1 * $OlderThanUnits) }
			'Hours' { Return (Get-Date).AddHours(-1 * $OlderThanUnits) }
			'Days' { Return (Get-Date).AddDays(-1 * $OlderThanUnits) }
			'Weeks' { Return (Get-Date).AddWeeks(-1 * $OlderThanUnits) }
			'Months' { Return (Get-Date).AddMonths(-1 * $OlderThanUnits) }
			'Years' { Return (Get-Date).AddYears(-1 * $OlderThanUnits) }
		}
	}

	Function Remove-ItemsFromPathBeforeDate {
		[CmdletBinding(SupportsShouldProcess)]
		Param(
			[Parameter(Mandatory = $true, Position = 0)]
			[string]$Path,
			[Parameter(Mandatory = $true, Position = 1)]
			[datetime]$Date
		)

		# verify path
		Try {
			$null = Get-Item -Path $Path -ErrorAction Stop
		}
		Catch {
			Write-Warning "Could not locate path: '$Path'"
			Return
		}

		# define list for old files
		$Files = [System.Collections.Generic.List[System.Object]]::new()

		# retrieve old files first
		Write-Output "Retrieving files written before '$Date' from '$Path'"
		Get-ChildItem -Path $Path -Recurse -Force -Attributes '!Directory' | Where-Object { $_.LastWriteTime -lt $Date } | ForEach-Object {
			$Files.Add($_.FullName)
		}

		# remove old files first
		Write-Output "Removing files written before '$Date' from '$Path'"
		ForEach ($File in $Files) {
			If ($PSCmdlet.ShouldProcess($File, 'Remove File')) {
				Try {
					Remove-Item -Path $File -Force -Verbose -ErrorAction Stop
				}
				Catch {
					Write-Warning "Could not perform `"Remove File`" on target `"$File`": $($_.ToString())"
				}
			}
		}

		# define list for old directories
		$Directories = [System.Collections.Generic.List[System.Object]]::new()

		# retrieve old directories
		Write-Output "Retrieving directories written before '$Date' from '$Path'"
		Get-ChildItem -Path $Path -Recurse -Force -Attributes 'Directory' | Where-Object { $_.LastWriteTime -lt $Date } | Sort-Object -Property FullName -Descending | ForEach-Object {
			$Directories.Add($_.FullName)
		}

		# define list for excluded directories
		$DirectoriesToExclude = [System.Collections.Generic.List[System.Object]]::new()

		# checking directories
		Write-Output "Checking directories for child objects in '$Path'"
		ForEach ($Directory in $Directories) {
			If ($null -ne (Get-ChildItem -Path $Directory -Recurse -Force -Attributes '!Directory')) {
				Write-Warning "Will not perform `"Remove Directory`" on target `"$Directory`": has children that are not directories"
				$DirectoriesToExclude.Add($Directory)
			}
		}

		# remove directories to exclude from old directories
		ForEach ($Directory in $DirectoriesToExclude) {
			$Directories.Remove($Directory)
		}

		# remove old directories last
		Write-Output "Removing directories written before '$Date' from '$Path'"
		ForEach ($Directory in $Directories) {
			If ($PSCmdlet.ShouldProcess($Directory, 'Remove Directory')) {
				Try {
					Remove-Item -Path $Directory -Force -Verbose -ErrorAction Stop
				}
				Catch {
					Write-Warning "Could not perform `"Remove Directory`" on target `"$Directory`": $($_.ToString())"
				}
			}
		}
	}

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
			$TranscriptName = (Get-PSCallStack)[1].Command -replace '\.ps1$'
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
			$TranscriptName = (Get-PSCallStack)[1].Command -replace '\.ps1$'
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
			# remove old transcript files
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

	# if running...
	If ($PSCmdlet.ParameterSetName -in 'Default', 'Run') {
		# define hashtable for transcript functions
		$TranscriptWithHostAndDate = @{}
		# define parameters for transcript functions
		If ($PSBoundParameters.ContainsKey('TranscriptName')) { $TranscriptWithHostAndDate['TranscriptName'] = $PSBoundParameters['TranscriptName'] }
		If ($PSBoundParameters.ContainsKey('TranscriptPath')) { $TranscriptWithHostAndDate['TranscriptPath'] = $PSBoundParameters['TranscriptPath'] }
		# start transcript with parameters
		Try {
			Start-TranscriptWithHostAndDate @TranscriptWithHostAndDate
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
			$JsonData = [array](Get-Content -Path $Json -ErrorAction Stop | ConvertFrom-Json)
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
				Write-Output "`nERROR: could not clear configuration file: '$Json'"
				Return $_
			}
		}
		# remove entry from configuration file
		$Remove {
			Try {
				# remove existing entry by primary key(s)...
				$JsonData = $JsonData | Where-Object { $_.Path -ne $Path }
				# if JSON data empty...
				If ($null -eq $JsonData) {
					# clear JSON data
					[string]::Empty | Set-Content -Path $Json
					Write-Output "`nRemoved '$Path' from configuration file: '$Json'"
				}
				Else {
					# export JSON data
					$JsonData | Sort-Object -Property Path | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
					Write-Output "`nRemoved '$Path' from configuration file: '$Json'"
					$JsonData | Sort-Object -Property Path | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
				}
				$JsonData | Format-List
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file: '$Json'"
				Return $_
			}
		}
		# add entry to configuration file
		$Add {
			Try {
				# create ordered dictionary for custom object
				$JsonParameters = [ordered]@{
					Path           = $Path
					OlderThanUnits = $OlderThanUnits
					OlderThanType  = $OlderThanType
				}

				# add current time as FileDateTimeUniversal
				$JsonParameters['Updated'] = Get-Date -Format FileDateTimeUniversal

				# create custom object from hashtable
				$JsonEntry = [pscustomobject]$JsonParameters

				# if existing entry has same primary key(s)...
				If ($JsonData | Where-Object { $_.Path -eq $Path }) {
					# inquire before removing existing entry
					Write-Warning -Message "Will overwrite existing entry for '$Path' in configuration file: '$Json' `nAny previous configuration for this entry will **NOT** be preserved" -WarningAction Inquire
					# remove existing entry with same primary key(s)
					$JsonData = $JsonData | Where-Object { $_.Path -ne $Path }
				}

				# add entry to data
				$JsonData += $JsonEntry

				# export JSON data
				$JsonData | Sort-Object -Property Path | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
				Write-Output "`nAdded '$Path' to configuration file: '$Json'"
				$JsonData | Sort-Object -Property Path | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file: '$Json'"
				Return $_
			}
		}
		# run script with provided parameters
		$Run {
			# get previous date from input
			Try {
				$Date = Get-PreviousDate -OlderThanUnits $OlderThanUnits -OlderThanType $OlderThanType
			}
			Catch {
				Write-Host "ERROR: could not create date from '$OlderThanUnits $OlderThanType'"
				Throw $_
			}
			
			# define required parameters for Remove-ItemsFromPathBeforeDate
			$RemoveItemsFromPathBeforeDate = @{
				Path = [string]$Path
				Date = [datetime]$Date
			}
			
			# define optional parameters for Remove-ItemsFromPathBeforeDate
			If ($WhatIfPreference.IsPresent) {
				$RemoveItemsFromPathBeforeDate['WhatIf'] = $true
			}
			
			# remove items from path before date
			Try {
				Remove-ItemsFromPathBeforeDate @RemoveItemsFromPathBeforeDate
			}
			Catch {
				Write-Host 'ERROR: could not remove items'
				Throw $_
			}
		}
		# process entries in configuration file
		Default {
			# check entry count in configuration file
			If ($JsonData.Count -eq 0) {
				Write-Host "ERROR: no entries found in configuration file: $Json"
				Return
			}

			# process entries in configuration file
			:JsonEntry ForEach ($JsonEntry in $JsonData) {
				switch ($true) {
					([string]::IsNullOrEmpty($JsonEntry.Path)) {
						Write-Host "ERROR: required entry (Path) not found in configuration file: $Json"; Continue :JsonEntry
					}
					([string]::IsNullOrEmpty($JsonEntry.OlderThanUnits)) {
						Write-Host "ERROR: required entry (OlderThanUnits) not found in configuration file: $Json"; Continue :JsonEntry
					}
					([string]::IsNullOrEmpty($JsonEntry.OlderThanType)) {
						Write-Host "ERROR: required entry (OlderThanType) not found in configuration file: $Json"; Continue :JsonEntry
					}
					Default {
						# get previous date from input
						Try {
							$Date = Get-PreviousDate -OlderThanUnits ($JsonEntry.OlderThanUnits) -OlderThanType ($JsonEntry.OlderThanType)
						}
						Catch {
							Write-Host "ERROR: could not create date from '$($JsonEntry.OlderThanUnits) $($JsonEntry.OlderThanType)'"
							Continue :JsonEntry
						}

						# define required parameters for Remove-ItemsFromPathBeforeDate
						$RemoveItemsFromPathBeforeDate = @{
							Path = [string]$JsonEntry.Path
							Date = [datetime]$Date
						}

						# define optional parameters for Remove-ItemsFromPathBeforeDate
						If ($WhatIfPreference.IsPresent) {
							$RemoveItemsFromPathBeforeDate['WhatIf'] = $true
						}

						# remove items from path before date
						Try {
							Remove-ItemsFromPathBeforeDate @RemoveItemsFromPathBeforeDate
						}
						Catch {
							Write-Host 'ERROR: could not remove items'
							Continue :JsonEntry
						}
					}
				}
			}
		}
	}
}

End {
	# if running...
	If ($PSCmdlet.ParameterSetName -in 'Default', 'Run') {
		# stop transcript with parameters
		Try {
			Stop-TranscriptWithHostAndDate @TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}
