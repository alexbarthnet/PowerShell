[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Mandatory = $True, ParameterSetName = 'Copy')]
	[switch]$Copy,
	[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[ValidatePattern('^[^\*]+$')]
	[string]$Source,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[ValidatePattern('^[^\*]+$')]
	[string]$Target,
	[Parameter(ParameterSetName = 'Add')]
	[switch]$Purge,
	[Parameter()][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json
)

Function Copy-FilesFromSourceToTarget {
	[CmdletBinding()]
	param (
		[string]$Source,
		[string]$Target,
		[boolean]$Purge
	)

	# verify source
	If (Test-Path -Path $Source) {
		# retrieve files from source
		$file_list = $null
		$file_list = Get-ChildItem -Path $Source
		If ($file_list) {
			# verify target
			$target_check = $null
			$target_check = If ( Test-Path -Path $using:Target ) { Get-Item -Path $Target } Else { New-Item -ItemType 'Directory' -Path $Target }
			If ($target_check) {
				# determine if target should be cleaned before writing files
				If ($Purge) {
					Write-Output "Clearing '$Target' before copy"
					Get-ChildItem -Path $Target -Recurse -Force | Remove-Item -Force
				}
				# copy files from source to target
				ForEach ($file_name in $file_list.FullName) {
					Try {
						Copy-Item -Path $file_name -Destination $Target -Force -Verbose
					}
					Catch {
						Write-Output "ERROR: could not copy '$file_name' to '$Target'"
					}
				}
			}
			Else {
				Write-Output "Could not find or create '$Target' on host"
			}
		}
		Else {
			Write-Output "Could not retrieve files in '$Source' on host"
		}
	}
	Else {
		Write-Output "Could not find '$Source' on host"
	}
}

# define configuration file from script path then verify path
If ([string]::IsNullOrEmpty($json)) {
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
		$json_data = $json_data | Where-Object { $_.Source -ne $Source }
		$json_data | ConvertTo-Json | Set-Content -Path $json_path
		# declare changes then show current state
		Write-Output "`nUpdated '$json_name' to remove '$Source':"
		$json_data | Select-Object Source, Target, Purge
	}
	$Add {
		# create custom object from parameters then add to object
		$json_data += [pscustomobject]@{
			Source = $Source
			Target = $Target
			Purge  = $Purge.ToBool()
		}
		$json_data | ConvertTo-Json | Set-Content -Path $json_path
		# declare changes then show current state
		Write-Output "`nUpdated '$json_name' to add '$Source':"
		$json_data | Select-Object Source, Target, Purge
	}
	$Copy {
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
				If ([string]::IsNullOrEmpty($json_datum.Source) -or [string]::IsNullOrEmpty($json_datum.Target)) {
					Write-Host "ERROR: invalid entry found in configuration file: $json_name"
				}
				Else {
					Copy-FilesFromSourceToTarget -Source $json_datum.Source -Target $json_datum.Target -Purge $json_datum.Purge
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
		$json_data | Select-Object Source, Target, Purge
	}
}
