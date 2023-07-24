#Requires -Modules LogToMultiple

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
	# if JSON file not provided...
	If ([string]::IsNullOrEmpty($Json)) {
		# ...define default JSON file
		$Json = $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.json')
	}

	# if running or testing...
	If ($Run -or $Test) {
		# ...define transcript file from script path and start transcript
		Start-Transcript -Path $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, "_$Hostname.txt") -Force
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
		If (-not (Test-Path -Path $Path -PathType Container)) {
			Write-LogToMultiple -LogSubject $Path -LogLevel 'Warning' -Text 'directory not found, skipping!'
		}

		# define list for old files
		$Files = [System.Collections.Generic.List[System.Object]]::new()

		# retrieve old files first
		Write-LogToMultiple -LogSubject $Path -Text "retrieving files written before: '$Date'"
		Get-ChildItem -Path $Path -Recurse -Force -Attributes '!Directory' | Where-Object { $_.LastWriteTime -lt $Date } | ForEach-Object {
			$Files.Add($_)
		}

		# remove old files first
		Write-LogToMultiple -LogSubject $Path -Text "removing files written before: '$Date'"
		ForEach ($File in $Files) {
			If ($Run) {
				Write-LogToMultiple -LogSubject $Path -Text "removing file: '$($File.FullName)'"
				Try {
					Remove-Item -Path $File.FullName -Force -ErrorAction Stop	
				}
				Catch {
					Write-LogToMultiple -LogSubject $Path -LogLevel 'Error' -Text "ERROR - removing file: '$($File.FullName)'"
				}
			}
			Else {
				Write-LogToMultiple -LogSubject $Path -Text "TESTING - would remove file: '$($File.FullName)'"
			}
		}

		# define list for old folders
		$Folders = [System.Collections.Generic.List[System.Object]]::new()

		# retrieve old folders
		Write-LogToMultiple -LogSubject $Path -Text "retrieving folders written before: '$Date'"
		Get-ChildItem -Path $Path -Recurse -Force -Attributes 'Directory' | Where-Object { $_.LastWriteTime -lt $Date } | Sort-Object -Property FullName -Descending | ForEach-Object {
			$Folders.Add($_)
		}

		# remove old folders last
		Write-LogToMultiple -LogSubject $Path -Text "removing folders written before: '$Date'"
		ForEach ($Folder in $Folders) {
			Write-LogToMultiple -LogSubject $Path -Text "checking folder: '$($Folder.FullName)'"
			If ($null -ne (Get-ChildItem -Path $Folder -Recurse -Force)) {
				Write-LogToMultiple -LogSubject $Path -Text 'folder not empty, skipping!'
				Continue
			}

			If ($Run) {
				Write-LogToMultiple -LogSubject $Path -Text 'folder is empty, removing!'
				Try {
					Remove-Item -Path $Folder.FullName -Force -ErrorAction Stop	
				}
				Catch {
					Write-LogToMultiple -LogSubject $Path -LogLevel 'Error' -Text "ERROR - removing folder: '$($Folder.FullName)'"
				}
			}
			Else {
				Write-LogToMultiple -LogSubject $Path -Text 'TESTING - folder is empty, would remove!'
			}
		}
	}
}

Process {
	# if JSON file was found...
	If (Test-Path -Path $Json) {
		# ...import JSON data
		Try {
			$JsonData = [array](Get-Content -Path $Json | ConvertFrom-Json)
		}
		Catch {
			Write-Host "`nERROR: could not read configuration file: '$Json'"
			Return $_
		}
	}
	# if JSON file was not found...
	Else {
		# if Add set...
		If ($Add) {
			# ...try to create the JSON file
			Try {
				$null = New-Item -ItemType 'File' -Path $Json -ErrorAction Stop
			}
			Catch {
				Write-Host "`nERROR: could not create configuration file: '$Json'"
				Return $_
			}
			# ...create empty JSON data object
			$JsonData = [PSCustomObject]@{}
		}
		# if Add not set...
		Else {
			# ...report and return
			Write-Host "`nERROR: could not find configuration file: '$Json'"
			Return
		}
	}

	# evaluate parameters
	switch ($true) {
		$Clear {
			# remove configuration file
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
		$Remove {
			# remove matching entries from object
			Try {
				$JsonData = $JsonData | Where-Object {
					$_.Path -ne $Path
				}
				If ($null -eq $JsonData) {
					[string]::Empty | Set-Content -Path $Json
					Write-Output "`nRemoved '$Path' from configuration file: '$Json'"
				}
				Else {
					$JsonData | ConvertTo-Json | Set-Content -Path $Json
					Write-Output "`nRemoved '$Path' from configuration file: '$Json'"
				}
				$JsonData | Select-Object Days, Path, Updated
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file: '$Json'"
			}
		}
		$Add {
			# create custom object from parameters then add to object
			Try {
				$JsonData += [pscustomobject]@{
					Path           = $Path
					OlderThanUnits = $OlderThanUnits
					OlderThanType  = $OlderThanType
					Updated        = (Get-Date -Format FileDateTimeUniversal)
				}
				$JsonData | ConvertTo-Json | Set-Content -Path $Json
				Write-Output "`nAdded '$Path' to configuration file: '$Json'"
				$JsonData | Select-Object Days, Path, Updated
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file: '$Json'"
			}
		}
		{ $Run -or $Test } {
			# start log file
			Try {
				Start-LogToMultiple -ScriptPath $PSCommandPath
			}
			Catch {
				Write-Host 'ERROR: could not start logging'
				Return $_
			}

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

			# start log cleanup
			Try {
				Remove-LogToMultiple -ScriptPath $PSCommandPath
			}
			Catch {
				Write-LogToMultiple -LogText 'Could not cleanup logs' -LogLevel 'error'
				Return $_
			}
		}
		Default {
			Write-Output "`nDisplaying configuration file: '$Json'"
			$JsonData | Select-Object Days, Path, Updated
		}
	}
}

End {
	# if running or testing...
	If ($Run -or $Test) {
		# ...stop transcript
		Stop-Transcript
	}
}