<#
.SYNOPSIS
Removes files and empty directories based upon values in a JSON configuration file.

.DESCRIPTION
Removes files and empty directories based upon values in a JSON configuration file.

.PARAMETER Json
The path to a JSON file containing the configuration for this script.

.PARAMETER Clear
Switch parameter to clear all entries from the JSON configuration file. Cannot be combined with the Remove, Add, or Run parameters.

.PARAMETER Remove
Switch parameter to remove an entry from the JSON configuration file. Cannot be combined with the Clear, Add, or Run parameters.

.PARAMETER Add
Switch parameter to add an entry from the JSON configuration file. Cannot be combined with the Clear, Remove, or Run parameters.

.PARAMETER Run
Switch parameter to process all entries from the JSON configuration file. Cannot be combined with the Clear, Remove, or Add parameters.

.PARAMETER Path
The path containing files and empty directories that will be removed if older than the computed datetime. Required when the Add or Remove parameters are specified.

.PARAMETER OlderThanUnits
The number of datetime units to create the computed datetime. Required when the Add parameter is specified.

.PARAMETER OlderThanType
The type of datetime units to create the computed datetime. Required when the Add parameter is specified. Valid values are 'Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', and 'Years'

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Remove-OldFiles.ps1 -Json C:\Content\config.json -Add -Path 'C:\Content\test' -OlderThanUnits 30 -OlderThanType 'Days'

.EXAMPLE
.\Remove-OldFiles.ps1 -Json C:\Content\config.json -Remove -Path 'C:\Content\test'

.EXAMPLE
.\Remove-OldFiles.ps1 -Json C:\Content\config.json -Clear

.EXAMPLE
.\Remove-OldFiles.ps1 -Json C:\Content\config.json -Run
#>

[CmdletBinding(SupportsShouldProcess,DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Run')]
	[switch]$Run,
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Remove')][ValidatePattern('^[^\*]+$')]
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Add')][ValidatePattern('^[^\*]+$')][ValidateScript({ Test-Path -Path $_ })]
	[string]$Path,
	[Parameter(Position = 2, Mandatory = $True, ParameterSetName = 'Add')][ValidateRange(1, 65535)]
	[uint16]$OlderThanUnits,
	[Parameter(Position = 3, Mandatory = $True, ParameterSetName = 'Add')][ValidateSet('Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', 'Years')]
	[string]$OlderThanType,
	[Parameter()]
	[string]$Json,
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
					[string]::Empty | Set-Content -Path $Json
					Write-Output "`nCleared configuration file: '$Json'"
				}
				Catch {
					Write-Output "`nERROR: could not clear configuration file: '$Json'"
					Return $_
				}
			}
		}
		# remove entry from configuration file
		$Remove {
			Try {
				$JsonData = $JsonData | Where-Object { $_.Path -ne $Path }
				If ($null -eq $JsonData) {
					[string]::Empty | Set-Content -Path $Json
					Write-Output "`nRemoved '$Path' from configuration file: '$Json'"
				}
				Else {
					$JsonData | ConvertTo-Json | Set-Content -Path $Json
					Write-Output "`nRemoved '$Path' from configuration file: '$Json'"
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
				$json_hashtable = [ordered]@{
					Path           = $Path
					OlderThanUnits = $OlderThanUnits
					OlderThanType  = $OlderThanType
				}

				# add current time as FileDateTimeUniversal
				$json_hashtable['Updated'] = $LogStart

				# create custom object from hashtable
				$JsonDatum = [pscustomobject]$json_hashtable

				# remove existing entry with same name
				If ($JsonData.Path -contains $Path) {
					Write-Warning -Message "Will overwrite existing entry for '$Path' configuration file: '$Json' `nAny previous configuration for this entry will **NOT** be preserved" -WarningAction Inquire
					$JsonData = $JsonData | Where-Object { $_.Path -ne $Path }
				}

				# add datum to data
				$JsonData += $JsonDatum
				$JsonData | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
				Write-Output "`nAdded '$Path' to configuration file: '$Json'"
				$JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file: '$Json'"
				Return $_
			}
		}
		# run through entries in configuration file
		$Run {
			# check entry count in configuration file
			If ($JsonData.Count -eq 0) {
				Write-Host "ERROR: no entries found in configuration file: $Json"
				Return
			}

			# process entries in configuration file
			ForEach ($JsonDatum in $JsonData) {
				switch ($true) {
					([string]::IsNullOrEmpty($JsonDatum.Path)) {
						Write-Host "ERROR: invalid entry found in configuration file: $Json"
						Continue
					}
					([string]::IsNullOrEmpty($JsonDatum.OlderThanUnits)) {
						Write-Host "ERROR: invalid entry found in configuration file: $Json"
						Continue
					}
					([string]::IsNullOrEmpty($JsonDatum.OlderThanType)) {
						Write-Host "ERROR: invalid entry found in configuration file: $Json"
						Continue
					}
					Default {
						# get previous date from input
						Try {
							$Date = Get-PreviousDate -OlderThanUnits ($JsonDatum.OlderThanUnits) -OlderThanType ($JsonDatum.OlderThanType)
						}
						Catch {
							Write-Host "ERROR: could not create date from '$($JsonDatum.OlderThanUnits) $($JsonDatum.OlderThanType)'"
							Continue
						}
						
						# define parameters for Remove-ItemsFromPathBeforeDate
						$RemoveItemsFromPathBeforeDate = @{
							Path   = $JsonDatum.Path
							Date   = $Date
							WhatIf = $WhatIf.ToBool()
						}

						# remove items from path before date
						Try {
							Remove-ItemsFromPathBeforeDate @RemoveItemsFromPathBeforeDate
						}
						Catch {
							Write-Host 'ERROR: could not remove items'
							Continue
						}
					}
				}
			}
		}
		Default {
			Write-Output "`nDisplaying '$Json'"
			$JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
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
