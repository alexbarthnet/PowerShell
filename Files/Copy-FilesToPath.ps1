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
	[Parameter()][ValidateScript({ Test-Path -Path (Split-Path -Path $_) })]
	[string]$Json
)

Function Copy-FilesFromSourceToTarget {
	[CmdletBinding()]
	param (
		[string]$Source,
		[string]$Target,
		[boolean]$Purge,
		[boolean]$CheckHash
	)

	# trim inputs
	$Source = $Source.TrimEnd('\')
	$Target = $Target.TrimEnd('\')

	# verify source and target
	switch ($true) {
		{ -not (Test-Path -Path $Source) } { Write-Output "Could not find '$Source' on host"; Return }
		{ -not (Test-Path -Path $Target) } { Write-Output "Could not find '$Target' on host"; Return }
		Default { Write-Output "Verified '$Source' and '$Target' on host" }
	}

	# get inputs
	$source_path = Get-Item -Path $Source
	$target_path = Get-Item -Path $Target

	# verify source and target are folders
	switch ($true) {
		{ -not $source_path.PSIsContainer } { Write-Output "ERROR: '$Source' is not a folder"; Return }
		{ -not $target_path.PSIsContainer } { Write-Output "ERROR: '$Target' is not a folder"; Return }
		Default { Write-Output "Verified '$Source' and '$Target' are folders" }
	}

	# remove all files and folders from target if Purge is set
	If ($Purge) {
		Write-Output "Clearing '$Target' before copy"
		Try {
			Get-ChildItem -Path $Target -Recurse -Force | Remove-Item -Force
		}
		Catch {
			"ERROR: Could not purge folder '$Target'"
			Return
		}
	}

	# retrieve folders from source
	$source_folders = Get-ChildItem -Path $Source -Recurse -Directory | Select-Object -ExpandProperty 'FullName'
	$target_folders = Get-ChildItem -Path $Target -Recurse -Directory | Select-Object -ExpandProperty 'FullName'

	# trim folders to relative paths
	If ($source_folders.Count) { $source_folders_relative = $source_folders.Replace($Source, $null) } Else { $source_folders_relative = @() }
	If ($target_folders.Count) { $target_folders_relative = $target_folders.Replace($Target, $null) } Else { $target_folders_relative = @() }

	# retrieve folders that are missing
	$folders_missing += [array][System.Linq.Enumerable]::Except([string[]]$source_folders_relative, [string[]]$target_folders_relative)

	# retrieve folders that are invalid
	$folders_invalid += [array][System.Linq.Enumerable]::Except([string[]]$target_folders_relative, [string[]]$source_folders_relative)

	# create any missing folders
	ForEach ($folder in $folders_missing) {
		$target_folder = Join-Path -Path $Target -ChildPath $folder
		Try {
			$null = New-Item -Path $target_folder -ItemType 'Directory' -Force -Verbose
		}
		Catch {
			Write-Output "ERROR: could not create folder '$target_folder'"
			Return
		}
	}

	# remove any invalid folders
	ForEach ($folder in $folders_invalid) {
		$target_folder = Join-Path -Path $Target -ChildPath $folder
		Try {
			$null = Remove-Item -Path $target_folder -Recurse -Force -Verbose
		}
		Catch {
			Write-Output "ERROR: could not remove folder '$target_folder'"
			Return
		}
	}

	# retrieve files from source
	$source_files = Get-ChildItem -Path $Source -Recurse -File | Select-Object -ExpandProperty 'FullName'
	$target_files = Get-ChildItem -Path $Target -Recurse -File | Select-Object -ExpandProperty 'FullName'

	# trim files to relative paths
	If ($source_files.Count) { $source_files_relative = $source_files.Replace($Source, $null) } Else { $source_files_relative = @() }
	If ($target_files.Count) { $target_files_relative = $target_files.Replace($Target, $null) } Else { $target_files_relative = @() }

	# retrieve files that are missing
	$files_missing += [array][System.Linq.Enumerable]::Except([string[]]$source_files_relative, [string[]]$target_files_relative)

	# retrieve files that are invalid
	$files_invalid += [array][System.Linq.Enumerable]::Except([string[]]$target_files_relative, [string[]]$source_files_relative)

	# copy any missing files
	ForEach ($file in $files_missing) {
		$source_file = Join-Path -Path $Source -ChildPath $file
		$target_file = Join-Path -Path $Target -ChildPath $file
		Try {
			Copy-Item -Path $source_file -Destination $target_file -Force -Verbose
		}
		Catch {
			Write-Output "ERROR: could not copy file '$source_file' to file '$target_file'"
		}
	}

	# remove any invalid files
	ForEach ($file in $files_invalid) {
		$target_file = Join-Path -Path $Target -ChildPath $file
		Try {
			$null = Remove-Item -Path $target_file -Force -Verbose
		}
		Catch {
			Write-Output "ERROR: could not remove file '$target_file'"
		}
	}

	# retrieve files that are present
	$files_present += [array][System.Linq.Enumerable]::Intersect([string[]]$source_files_relative, [string[]]$target_files_relative)

	# copy any present files when hash or lastwritetime are different
	ForEach ($file in $files_present) {
		$source_file = Join-Path -Path $Source -ChildPath $file
		$target_file = Join-Path -Path $Target -ChildPath $file
		# compare target file with source file
		If ($CheckHash) {
			If ((Get-FileHash -Path $source_file).Hash -eq (Get-FileHash -Path $target_file).Hash) {
				Write-Output "Skipping '$source_file' as '$target_file' has same file hash"
				Continue
			}
		}
		Else {
			If ((Get-Item -Path $source_file).LastWriteTime -eq (Get-Item -Path $target_file).LastWriteTime) {
				Write-Output "Skipping '$source_file' as '$target_file' has same LastWriteTime"
				Continue
			}
		}
		# copy the file
		Try {
			Copy-Item -Path $source_file -Destination $target_file -Force -Verbose
		}
		Catch {
			Write-Output "ERROR: could not copy file '$source_file' to file '$target_file'"
		}
	}
}

# define configuration file from script path then verify path
If ([string]::IsNullOrEmpty($Json)) {
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
