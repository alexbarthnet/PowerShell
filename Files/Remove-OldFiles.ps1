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
The number of datetime units to create the computed datetime. Required when the Add and Json parameters are specified or the Path parameter is specified without the Json parameter.

.PARAMETER OlderThanType
The type of datetime units to create the computed datetime. Required when the Add and Json parameters are specified or the Path parameter is specified without the Json parameter. Valid values are 'Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', and 'Years'

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
# process all entries in the 'C:\Content\config.json' file and remove files and empty directories in the defined paths that are older than the datetime computed from the defined units and types
.\Remove-OldFiles.ps1 -Json C:\Content\config.json

.EXAMPLE
# show all entries in the 'C:\Content\config.json' file
.\Remove-OldFiles.ps1 -Json C:\Content\config.json -Show

.EXAMPLE
# remove all entries from the 'C:\Content\config.json' file
.\Remove-OldFiles.ps1 -Json C:\Content\config.json -Clear

.EXAMPLE
# remove any entries from the 'C:\Content\config.json' file that contain the 'C:\Content\test' path
.\Remove-OldFiles.ps1 -Json C:\Content\config.json -Remove -Path 'C:\Content\test'

.EXAMPLE
# add an entry to the 'C:\Content\config.json' file for removing files and empty directories in the 'C:\Content\test' path that are older than 30 days
.\Remove-OldFiles.ps1 -Json C:\Content\config.json -Add -Path 'C:\Content\test' -OlderThanUnits 30 -OlderThanType 'Days'

.EXAMPLE
# immediately remove files and empty directories in the 'C:\Content\test' path that are older than 30 days
.\Remove-OldFiles.ps1 -Path 'C:\Content\test' -OlderThanUnits 30 -OlderThanType 'Days'
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Run')]
Param(
	# switch parameter to show entries in json file
	[Parameter(Mandatory = $True, ParameterSetName = 'Show')]
	[switch]$Show,
	# switch parameter to clear entries in json file
	[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	# switch parameter to remove entries from json file
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	# switch parameter to add entries to json file
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	# path to json file
	[Parameter(Mandatory = $True, ParameterSetName = 'Show')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[string]$Json,
	# path for items to remove
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')][ValidatePattern('^[^\*]+$')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')][ValidatePattern('^[^\*]+$')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Run')][ValidatePattern('^[^\*]+$')]
	[string]$Path,
	# units for computing previous date
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')][ValidateRange(1, 65535)]
	[Parameter(Mandatory = $True, ParameterSetName = 'Run')][ValidateRange(1, 65535)]
	[uint16]$OlderThanUnits,
	# type for computing previous date
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')][ValidateSet('Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', 'Years')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Run')][ValidateSet('Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', 'Years')]
	[string]$OlderThanType,
	# legacy switch parameter to force run mode
	[Parameter(Mandatory = $False, ParameterSetName = 'Run')]
	[switch]$Run,
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
			[string]$OlderThanType,
			[Parameter(Mandatory = $false)]
			[datetime]$Date = [datetime]::Now
		)
		Switch ($OlderThanType) {
			'Seconds' { Return $Date.AddSeconds(-1 * $OlderThanUnits) }
			'Minutes' { Return $Date.AddMinutes(-1 * $OlderThanUnits) }
			'Hours' { Return $Date.AddHours(-1 * $OlderThanUnits) }
			'Days' { Return $Date.AddDays(-1 * $OlderThanUnits) }
			'Weeks' { Return $Date.AddWeeks(-1 * $OlderThanUnits) }
			'Months' { Return $Date.AddMonths(-1 * $OlderThanUnits) }
			'Years' { Return $Date.AddYears(-1 * $OlderThanUnits) }
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
		Write-Verbose -Verbose -Message  "Retrieving files written before '$Date' from '$Path'"
		Get-ChildItem -Path $Path -Recurse -Force -Attributes '!Directory' | Where-Object { $_.LastWriteTime -lt $Date } | ForEach-Object {
			$Files.Add($_.FullName)
		}

		# remove old files first
		Write-Verbose -Verbose -Message  "Removing files written before '$Date' from '$Path'"
		ForEach ($File in $Files) {
			If ($PSCmdlet.ShouldProcess($File, 'Remove File')) {
				Try {
					Remove-Item -Path $File -Force -Verbose -ErrorAction Stop
				}
				Catch {
					Write-Warning -Message "could not perform `"Remove File`" on target `"$File`": $($_.ToString())"
				}
			}
		}

		# define list for old directories
		$Directories = [System.Collections.Generic.List[System.Object]]::new()

		# retrieve old directories
		Write-Verbose -Verbose -Message  "Retrieving directories written before '$Date' from '$Path'"
		Get-ChildItem -Path $Path -Recurse -Force -Attributes 'Directory' | Where-Object { $_.LastWriteTime -lt $Date } | Sort-Object -Property FullName -Descending | ForEach-Object {
			$Directories.Add($_.FullName)
		}

		# define list for excluded directories
		$DirectoriesToExclude = [System.Collections.Generic.List[System.Object]]::new()

		# checking directories
		Write-Verbose -Verbose -Message  "Checking directories for child objects in '$Path'"
		ForEach ($Directory in $Directories) {
			If ($null -ne (Get-ChildItem -Path $Directory -Recurse -Force -Attributes '!Directory')) {
				Write-Warning -Message "will not perform `"Remove Directory`" on target `"$Directory`": has children that are not directories"
				$DirectoriesToExclude.Add($Directory)
			}
		}

		# remove directories to exclude from old directories
		ForEach ($Directory in $DirectoriesToExclude) {
			$Directories.Remove($Directory)
		}

		# remove old directories last
		Write-Verbose -Verbose -Message  "Removing directories written before '$Date' from '$Path'"
		ForEach ($Directory in $Directories) {
			If ($PSCmdlet.ShouldProcess($Directory, 'Remove Directory')) {
				Try {
					Remove-Item -Path $Directory -Force -Verbose:$VerbosePreference -ErrorAction 'Stop'
				}
				Catch {
					Write-Warning -Message "could not perform `"Remove Directory`" on target `"$Directory`": $($_.ToString())"
				}
			}
		}
	}
}

Process {
	# if script in direct run mode...
	If ($PSCmdLet.ParameterSetName -eq 'Run') {
		# get previous date from input
		Try {
			$Date = Get-PreviousDate -OlderThanUnits $OlderThanUnits -OlderThanType $OlderThanType
		}
		Catch {
			Write-Warning -Message "could not create date from '$OlderThanUnits $OlderThanType'"
			Throw $_
		}

		# define required parameters for Remove-ItemsFromPathBeforeDate
		$RemoveItemsFromPathBeforeDate = @{
			Path = [string]$Path
			Date = [datetime]$Date
		}

		# defined optional parameters for Remove-ItemsFromPathBeforeDate
		If ($VerbosePreference -eq 'Continue') {
			$RemoveItemsFromPathBeforeDate['Verbose'] = $true
		}

		# define optional parameters for Remove-ItemsFromPathBeforeDate
		If ($WhatIfPreference -eq $true) {
			$RemoveItemsFromPathBeforeDate['WhatIf'] = $true
		}

		# remove items from path before date
		Try {
			Remove-ItemsFromPathBeforeDate @RemoveItemsFromPathBeforeDate
		}
		Catch {
			Write-Warning -Message "could not remove items from path: $Path"
			Throw $_
		}

		# return after direct run
		Return
	}

	# if JSON file found...
	If (Test-Path -Path $Json) {
		# ...create JSON data object as array of PSCustomObjects from JSON file content
		Try {
			$JsonData = [array](Get-Content -Path $Json -ErrorAction Stop | ConvertFrom-Json)
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
				$null = New-Item -ItemType 'File' -Path $Json -ErrorAction Stop
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
			Write-Verbose -Verbose -Message  "Displaying '$Json'"
			$JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
		}
		# clear configuration file
		$Clear {
			Try {
				[string]::Empty | Set-Content -Path $Json
				Write-Verbose -Verbose -Message  "Cleared configuration file: '$Json'"
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
				$JsonData = [array]($JsonData.Where({ $_.Path -ne $Path }))
				# if JSON data empty...
				If ($JsonData.Count -eq 0) {
					# clear JSON data
					[string]::Empty | Set-Content -Path $Json
					Write-Verbose -Verbose -Message  "Removed '$Path' from configuration file: '$Json'"
				}
				Else {
					# export JSON data
					$JsonData | Sort-Object -Property 'Path' | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
					Write-Verbose -Verbose -Message  "Removed '$Path' from configuration file: '$Json'"
					$JsonData | Sort-Object -Property 'Path' | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
				}
				$JsonData | Format-List
			}
			Catch {
				Write-Warning -Message "could not update configuration file: '$Json'"
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
				If ($JsonData.Where({ $_.Path -eq $Path })) {
					# inquire before removing existing entry
					Write-Warning -Message "Will overwrite existing entry for '$Path' in configuration file: '$Json' `nAny previous configuration for this entry will **NOT** be preserved" -WarningAction Inquire
					# remove existing entry with same primary key(s)
					$JsonData = [array]($JsonData.Where({ $_.Path -ne $Path }))
				}

				# add entry to data
				$JsonData += $JsonEntry

				# export JSON data
				$JsonData | Sort-Object -Property 'Path' | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
				Write-Verbose -Verbose -Message  "Added '$Path' to configuration file: '$Json'"
				$JsonData | Sort-Object -Property 'Path' | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
			}
			Catch {
				Write-Warning -Message "could not update configuration file: '$Json'"
				Return $_
			}
		}
		# process entries in configuration file
		Default {
			# check entry count in configuration file
			If ($JsonData.Count -eq 0) {
				Write-Warning -Message "no entries found in configuration file: $Json"
				Return
			}

			# process entries in configuration file
			:NextJsonEntry ForEach ($JsonEntry in $JsonData) {
				# validate entries in JSON file
				Switch ($true) {
					([string]::IsNullOrEmpty($JsonEntry.Path)) {
						Write-Warning -Message "required entry (Path) not found in configuration file: $Json"
						Continue NextJsonEntry
					}
					([string]::IsNullOrEmpty($JsonEntry.OlderThanUnits)) {
						Write-Warning -Message "required entry (OlderThanUnits) not found in configuration file: $Json"
						Continue NextJsonEntry
					}
					([string]::IsNullOrEmpty($JsonEntry.OlderThanType)) {
						Write-Warning -Message "required entry (OlderThanType) not found in configuration file: $Json"
						Continue NextJsonEntry
					}
				}

				# get previous date from input
				Try {
					$Date = Get-PreviousDate -OlderThanUnits ($JsonEntry.OlderThanUnits) -OlderThanType ($JsonEntry.OlderThanType)
				}
				Catch {
					Write-Warning -Message "could not create date from '$($JsonEntry.OlderThanUnits) $($JsonEntry.OlderThanType)'"
					Continue NextJsonEntry
				}

				# define required parameters for Remove-ItemsFromPathBeforeDate
				$RemoveItemsFromPathBeforeDate = @{
					Path = [string]$JsonEntry.Path
					Date = [datetime]$Date
				}

				# defined optional parameters for Remove-ItemsFromPathBeforeDate
				If ($VerbosePreference -eq 'Continue') {
					$RemoveItemsFromPathBeforeDate['Verbose'] = $true
				}

				# define optional parameters for Remove-ItemsFromPathBeforeDate
				If ($WhatIfPreference -eq $true) {
					$RemoveItemsFromPathBeforeDate['WhatIf'] = $true
				}

				# remove items from path before date
				Try {
					Remove-ItemsFromPathBeforeDate @RemoveItemsFromPathBeforeDate
				}
				Catch {
					Write-Warning -Message "could not remove items from path: $($JsonEntry.Path)"
					Continue NextJsonEntry
				}
			}
		}
	}
}
