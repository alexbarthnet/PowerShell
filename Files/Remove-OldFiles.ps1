<#
.SYNOPSIS
Removes files and empty folders based upon values in a JSON configuration file.

.DESCRIPTION
Removes files and empty folders based upon values in a JSON configuration file.

.PARAMETER Json
The path to a JSON file containing the configuration for this script.

.PARAMETER Run
Switch parameter to process all entries from the JSON configuration file. Cannot be combined with the Clear, Remove, or Add parameters.

.PARAMETER Clear
Switch parameter to clear all entries from the JSON configuration file. Cannot be combined with the Run, Remove, or Add parameters.

.PARAMETER Remove
Switch parameter to remove an entry from the JSON configuration file. Cannot be combined with the Run, Clear, or Add parameters.

.PARAMETER Add
Switch parameter to add an entry from the JSON configuration file. Cannot be combined with the Run, Clear, or Remove parameters.

.PARAMETER Path
The path of containing files and empty folders that will be removed if older than the computed datetime. Required when the Add or Remove parameters are specified.

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


[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Run')]
	[switch]$Run,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Test')]
	[switch]$Test,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Remove')][ValidatePattern('^[^\*]+$')]
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Add')][ValidatePattern('^[^\*]+$')][ValidateScript({ Test-Path -Path $_ })]
	[string]$Path,
	[Parameter(Position = 2, Mandatory = $True, ParameterSetName = 'Add')][ValidateRange(1, 65535)]
	[uint16]$OlderThanUnits,
	[Parameter(Position = 3, Mandatory = $True, ParameterSetName = 'Add')][ValidateSet('Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', 'Years')]
	[string]$OlderThanType,
	[Parameter()]
	[string]$Json,
	# local hostname
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

Begin {
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
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true, Position = 0)]
			[string]$Path,
			[Parameter(Mandatory = $true, Position = 1)]
			[datetime]$Date
		)

		# declare start
		If (Test-Path -Path $Path -PathType Container) {
			Write-Output "retrieving files written before '$Date' from '$Path'"
		}
		Else {
			Write-Warning "Could not locate folder, skipping path: '$Path'"
			Return
		}

		# define list for old files
		$Files = [System.Collections.Generic.List[System.Object]]::new()

		# retrieve old files first
		Get-ChildItem -Path $Path -Recurse -Force -Attributes '!Directory' | Where-Object { $_.LastWriteTime -lt $Date } | ForEach-Object {
			$Files.Add($_.FullName)
		}

		# remove old files first
		Write-Output "removing files written before '$Date' from '$Path'"
		ForEach ($File in $Files) {
			If ($Run) {
				Try {
					Remove-Item -Path $File.FullName -Force -Verbose -ErrorAction Stop	
				}
				Catch {
					Write-Warning "Could not perform `"Remove File`" on target `"$File`": $($_.ToString())"
				}
			}
			Else {
				Write-Output "TESTING - would remove file: '$File'"
			}
		}

		# define list for old folders
		$Folders = [System.Collections.Generic.List[System.Object]]::new()

		# retrieve old folders
		Write-Output "retrieving folders written before '$Date' from '$Path'"
		Get-ChildItem -Path $Path -Recurse -Force -Attributes 'Directory' | Where-Object { $_.LastWriteTime -lt $Date } | Sort-Object -Property FullName -Descending | ForEach-Object {
			$Folders.Add($_.FullName)
		}

		# remove old folders last
		Write-Output "removing folders written before '$Date' from '$Path'"
		ForEach ($Folder in $Folders) {
			Write-Output "checking folder: '$Folder'"
			If ($null -ne (Get-ChildItem -Path $Folder -Recurse -Force)) {
				Write-Warning "Will not perform `"Remove Directory`" while child items exist in target `"$Folder`""
				Continue
			}

			If ($Run) {
				Try {
					Remove-Item -Path $Folder -Force -Verbose -ErrorAction Stop	
				}
				Catch {
					Write-Warning "Could not perform `"Remove Directory`" on target `"$Folder`": $($_.ToString())"
				}
			}
			Else {
				Write-Output "TESTING - would remove directory: '$Folder'"
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
		{ $Run -or $Test } {
			# check entry count in configuration file
			If ($JsonData.Count -eq 0) {
				Write-Host "ERROR: no entries found in configuration file: $Json"
				Return
			}

			# process configuration file
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
						Try {
							$Date = Get-PreviousDate -OlderThanUnits ($JsonDatum.OlderThanUnits) -OlderThanType ($JsonDatum.OlderThanType)
						}
						Catch {
							Write-Host "ERROR: could not create date from '$($JsonDatum.OlderThanUnits) $($JsonDatum.OlderThanType)'"
							Continue
						}
						
						Try {
							Remove-ItemsFromPathBeforeDate -Path $JsonDatum.Path -Date $Date
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
	# if running or testing...
	If ($Run -or $Test) {
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