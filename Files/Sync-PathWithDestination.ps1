[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Mandatory = $True, ParameterSetName = 'Sync')]
	[switch]$Sync,
	[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[ValidatePattern('^[^\*]+$')]
	[string]$Path,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[ValidatePattern('^[^\*]+$')]
	[string]$Destination,
	[Parameter(ParameterSetName = 'Add')][ValidateSet('Sync', 'Contribute', 'Clone', 'Merge')]
	[string]$Mode = 'Sync',
	[Parameter(ParameterSetName = 'Add')]
	[switch]$Purge,
	[Parameter(ParameterSetName = 'Add')]
	[switch]$Recurse,
	[Parameter(ParameterSetName = 'Add')]
	[switch]$CheckHash,
	[Parameter(ParameterSetName = 'Add')]
	[switch]$SkipFiles,
	[Parameter(ParameterSetName = 'Add')]
	[switch]$SkipCreateTarget,
	[Parameter(ParameterSetName = 'Add')]
	[uint64]$LastSyncTime,
	[Parameter()]
	[string]$Json,
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

Function Sync-ItemsInPathWithDestination {
	[CmdletBinding()]
	param (
		[string]$Path,
		[string]$Destination,
		[string]$Mode,
		[switch]$Purge,
		[switch]$Recurse,
		[switch]$CheckHash,
		[switch]$SkipFiles,
		[switch]$SkipCreateTarget,
		[uint64]$LastSyncTime = 0
	)

	# get current time
	$sync_time_ticks = (Get-Date).Ticks

	# trim inputs if function called directly
	$source_path = $Path.TrimEnd('\')
	$target_path = $Destination.TrimEnd('\')

	# verify source and target
	If (-not (Test-Path -Path $source_path -PathType 'Container')) {
		Write-Output "Could not find source folder '$source_path' on host"; Return
	}
	ElseIf (-not (Test-Path -Path $target_path -PathType 'Container') -and $SkipCreateTarget) {
		Write-Output "Could not find target folder '$target_path' on host"; Return
	}
	ElseIf (-not (Test-Path -Path $target_path -PathType 'Container') -and -not $SkipCreateTarget) {
		Try {
			$null = New-Item -ItemType 'Directory' -Path $target_path
		}
		Catch {
			Write-Output "Could not create target folder '$target_path' on host"; Return
		}
	}
	Else {
		Write-Output "Verified '$source_path' and '$target_path' on host"
	}

	# remove all files and folders from target if Purge is set
	If ($Purge) {
		Write-Output "Clearing '$target_path' before copy"
		Try {
			Get-ChildItem -Path $target_path -Recurse -Force | Remove-Item -Force
		}
		Catch {
			"ERROR: Could not purge folder '$target_path'"
			Return
		}
	}

	# create new folders if Recurse is true
	If ($Recurse) {
		# retrieve path objects
		$folder_items_on_source = Get-ChildItem -Path $source_path -Recurse -Directory
		$folder_items_on_target = Get-ChildItem -Path $target_path -Recurse -Directory

		# retrieve fullname of new paths
		$new_folders_on_source = $folder_items_on_source | Where-Object { $_.LastWriteTime.Ticks -ge $LastSyncTime } | Select-Object -ExpandProperty 'FullName'
		$new_folders_on_target = $folder_items_on_target | Where-Object { $_.LastWriteTime.Ticks -ge $LastSyncTime } | Select-Object -ExpandProperty 'FullName'

		# trim new paths to relative paths
		If ($new_folders_on_source.Count) { $new_folders_on_source_relative = $new_folders_on_source.Replace($source_path, $null) } Else { $new_folders_on_source_relative = @() }
		If ($new_folders_on_target.Count) { $new_folders_on_target_relative = $new_folders_on_target.Replace($target_path, $null) } Else { $new_folders_on_target_relative = @() }

		# retrieve folders that are missing from Destination
		$folders_to_create_on_target += [array][System.Linq.Enumerable]::Except([string[]]$new_folders_on_source_relative, [string[]]$new_folders_on_target_relative)

		# create any missing folders in Destination
		ForEach ($folder_to_create in $folders_to_create_on_target) {
			$folder_path_to_create = Join-Path -Path $target_path -ChildPath $folder_to_create
			Try {
				$null = New-Item -Path $folder_path_to_create -ItemType 'Directory' -Force -Verbose
			}
			Catch {
				Write-Output "ERROR: could not create folder '$folder_path_to_create'"
				Return
			}
		}

		# repeat folder creation in reverse if Mode is Sync
		If ($Mode -eq 'Sync' -or $Mode -eq 'Merge') {
			# retrieve folders that are missing from Path
			$folders_to_create_on_source += [array][System.Linq.Enumerable]::Except([string[]]$new_folders_on_target_relative, [string[]]$new_folders_on_source_relative)

			# create any missing folders in Path
			ForEach ($folder_to_create in $folders_to_create_on_source) {
				$folder_path_to_create = Join-Path -Path $source_path -ChildPath $folder_to_create
				Try {
					$null = New-Item -Path $folder_path_to_create -ItemType 'Directory' -Force -Verbose
				}
				Catch {
					Write-Output "ERROR: could not create folder '$folder_path_to_create'"
					Return
				}
			}
		}
	}

	# copy new files if SkipFiles is false
	If (-not $SkipFiles) {
		# retrieve file objects
		$file_items_on_source = Get-ChildItem -Path $source_path -Recurse:$Recurse -File
		$file_items_on_target = Get-ChildItem -Path $target_path -Recurse:$Recurse -File

		# retrieve fullname of new files
		$new_files_on_source = $file_items_on_source | Where-Object { $_.LastWriteTime.Ticks -ge $LastSyncTime } | Select-Object -ExpandProperty 'FullName'
		$new_files_on_target = $file_items_on_target | Where-Object { $_.LastWriteTime.Ticks -ge $LastSyncTime } | Select-Object -ExpandProperty 'FullName'

		# trim new files to relative paths
		If ($new_files_on_source.Count) { $new_files_on_source_relative = $new_files_on_source.Replace($source_path, $null) } Else { $new_files_on_source_relative = @() }
		If ($new_files_on_target.Count) { $new_files_on_target_relative = $new_files_on_target.Replace($target_path, $null) } Else { $new_files_on_target_relative = @() }

		# retrieve files that are missing in Destination
		$files_to_copy_to_target += [array][System.Linq.Enumerable]::Except([string[]]$new_files_on_source_relative, [string[]]$new_files_on_target_relative)

		# copy any missing files to Destination
		ForEach ($file_to_copy in $files_to_copy_to_target) {
			$file_path_to_copy_to_source = Join-Path -Path $source_path -ChildPath $file_to_copy
			$file_path_to_copy_on_target = Join-Path -Path $target_path -ChildPath $file_to_copy
			Try {
				Copy-Item -Path $file_path_to_copy_to_source -Destination $file_path_to_copy_on_target -Force -Verbose
			}
			Catch {
				Write-Output "ERROR: could not copy file '$file_path_to_copy_to_source' to file '$file_path_to_copy_on_target'"
			}
		}

		# repeat file copy in reverse if Mode is Sync or Merge
		If ($Mode -eq 'Sync' -or $Mode -eq 'Merge') {
			# retrieve files that are missing in Path
			$files_to_copy_to_source += [array][System.Linq.Enumerable]::Except([string[]]$new_files_on_target_relative, [string[]]$new_files_on_source_relative)

			# copy any missing files to Path
			ForEach ($file_to_copy in $files_to_copy_to_source) {
				$file_path_to_copy_on_target = Join-Path -Path $target_path -ChildPath $file_to_copy
				$file_path_to_copy_to_source = Join-Path -Path $source_path -ChildPath $file_to_copy
				Try {
					Copy-Item -Path $file_path_to_copy_on_target -Destination $file_path_to_copy_to_source -Force -Verbose
				}
				Catch {
					Write-Output "ERROR: could not copy file '$file_path_to_copy_on_target' to file '$file_path_to_copy_to_source'"
				}
			}
		}
	}

	# process files if SkipFiles is false
	If (-not $SkipFiles) {
		# retrieve fullname of all files
		$all_files_on_source = $file_items_on_source | Select-Object -ExpandProperty 'FullName'
		$all_files_on_target = $file_items_on_target | Select-Object -ExpandProperty 'FullName'

		# trim all files to relative paths
		If ($all_files_on_source.Count) { $all_files_on_source_relative = $all_files_on_source.Replace($source_path, $null) } Else { $all_files_on_source_relative = @() }
		If ($all_files_on_target.Count) { $all_files_on_target_relative = $all_files_on_target.Replace($target_path, $null) } Else { $all_files_on_target_relative = @() }

		# retrieve files in both Path and Destination
		$files_present += [array][System.Linq.Enumerable]::Intersect([string[]]$all_files_on_source_relative, [string[]]$all_files_on_target_relative)

		# copy any present files when hash or lastwritetime are different
		ForEach ($file_present in $files_present) {
			$file_path_on_source = Join-Path -Path $source_path -ChildPath $file_present
			$file_path_on_target = Join-Path -Path $target_path -ChildPath $file_present
			$file_item_on_source = Get-Item -Path $file_path_on_source
			$file_item_on_target = Get-Item -Path $file_path_on_target
			# compare files
			If ($CheckHash) {
				If ((Get-FileHash -Path $file_path_on_source).Hash -eq (Get-FileHash -Path $file_path_on_target).Hash) {
					Write-Output "Skipping '$file_path_on_source' as '$file_path_on_target' has same file hash"
					Continue
				}
			}
			Else {
				If ($file_item_on_source.LastWriteTime -eq $file_item_on_target.LastWriteTime) {
					Write-Output "Skipping '$file_path_on_source' as '$file_path_on_target' has same LastWriteTime"
					Continue
				}
			}
			# copy file from Path to Destination
			If ($file_item_on_source.LastWriteTime -gt $file_item_on_target.LastWriteTime -or $Mode -eq 'Clone') {
				Try {
					Copy-Item -Path $file_path_on_source -Destination $file_path_on_target -Force -Verbose
				}
				Catch {
					Write-Output "ERROR: could not copy file '$file_path_on_source' to file '$file_path_on_target'"
				}
			}
			# copy file from Destination to Path
			ElseIf ($file_item_on_source.LastWriteTime -lt $file_item_on_target.LastWriteTime -and $Mode -eq 'Sync') {
				# copy the file
				Try {
					Copy-Item -Path $file_path_on_target -Destination $file_path_on_source -Force -Verbose
				}
				Catch {
					Write-Output "ERROR: could not copy file '$file_path_on_target' to file '$file_path_on_source'"
				}
			}
		}
	}

	# remove old files if SkipFiles is false and Mode is Sync
	If (-not $SkipFiles -and $Mode -eq 'Sync') {
		# retrieve file objects
		$file_items_on_source = Get-ChildItem -Path $source_path -Recurse:$Recurse -File
		$file_items_on_target = Get-ChildItem -Path $target_path -Recurse:$Recurse -File

		# retrieve fullname of files
		$old_files_on_source = $file_items_on_source | Where-Object { $_.LastWriteTime.Ticks -lt $LastSyncTime } | Select-Object -ExpandProperty 'FullName'
		$old_files_on_target = $file_items_on_target | Where-Object { $_.LastWriteTime.Ticks -lt $LastSyncTime } | Select-Object -ExpandProperty 'FullName'

		# trim files to relative paths
		If ($old_files_on_source.Count) { $old_files_on_source_relative = $old_files_on_source.Replace($source_path, $null) } Else { $old_files_on_source_relative = @() }
		If ($old_files_on_target.Count) { $old_files_on_target_relative = $old_files_on_target.Replace($target_path, $null) } Else { $old_files_on_target_relative = @() }

		# retrieve files in both Path and Destination
		$files_in_both_paths += [array][System.Linq.Enumerable]::Intersect([string[]]$all_files_on_source_relative, [string[]]$all_files_on_target_relative)

		# retrieve old files only in Path
		$files_to_remove_from_source += [array][System.Linq.Enumerable]::Except([string[]]$old_files_on_source_relative, [string[]]$files_in_both_paths)

		# remove old files only in Path
		ForEach ($file_to_remove in $files_to_remove_from_source) {
			$file_path_to_remove = Join-Path -Path $source_path -ChildPath $file_to_remove
			Try {
				$null = Remove-Item -Path $file_path_to_remove -Force -Verbose
			}
			Catch {
				Write-Output "ERROR: could not remove file '$file_path_to_remove'"
			}
		}

		# retrieve old files only in Destination
		$files_to_remove_from_target += [array][System.Linq.Enumerable]::Except([string[]]$old_files_on_target_relative, [string[]]$files_in_both_paths)

		# remove old files only in Destination
		ForEach ($file_to_remove in $files_to_remove_from_target) {
			$file_path_to_remove = Join-Path -Path $target_path -ChildPath $file_to_remove
			Try {
				$null = Remove-Item -Path $file_path_to_remove -Force -Verbose
			}
			Catch {
				Write-Output "ERROR: could not remove file '$file_path_to_remove'"
			}
		}
	}

	# remove old paths if Recurse is true and Mode is Sync
	If ($Recurse -and $Mode -eq 'Sync') {
		# retrieve path objects
		$folder_items_on_source = Get-ChildItem -Path $source_path -Recurse:$Recurse -Directory
		$folder_items_on_target = Get-ChildItem -Path $target_path -Recurse:$Recurse -Directory

		# retrieve fullname of paths
		$all_folders_on_source = $folder_items_on_source | Select-Object -ExpandProperty 'FullName'
		$all_folders_on_target = $folder_items_on_target | Select-Object -ExpandProperty 'FullName'
		$old_folders_on_source = $folder_items_on_source | Where-Object { $_.LastWriteTime.Ticks -lt $LastSyncTime } | Select-Object -ExpandProperty 'FullName'
		$old_folders_on_target = $folder_items_on_target | Where-Object { $_.LastWriteTime.Ticks -lt $LastSyncTime } | Select-Object -ExpandProperty 'FullName'

		# trim paths to relative paths
		If ($all_folders_on_source.Count) { $all_folders_on_source_relative = $all_folders_on_source.Replace($source_path, $null) } Else { $all_folders_on_source_relative = @() }
		If ($all_folders_on_target.Count) { $all_folders_on_target_relative = $all_folders_on_target.Replace($target_path, $null) } Else { $all_folders_on_target_relative = @() }
		If ($old_folders_on_source.Count) { $old_folders_on_source_relative = $old_folders_on_source.Replace($source_path, $null) } Else { $old_folders_on_source_relative = @() }
		If ($old_folders_on_target.Count) { $old_folders_on_target_relative = $old_folders_on_target.Replace($target_path, $null) } Else { $old_folders_on_target_relative = @() }

		# retrieve files in both Path and Destination
		$folders_in_both_paths += [array][System.Linq.Enumerable]::Intersect([string[]]$all_folders_on_source_relative, [string[]]$all_folders_on_target_relative)

		# retrieve old files only in Path
		$folders_to_remove_from_source += [array][System.Linq.Enumerable]::Except([string[]]$old_folders_on_source_relative, [string[]]$folders_in_both_paths)

		# remove old files only in Path
		ForEach ($folder_to_remove in $folders_to_remove_from_source) {
			$folder_path_to_remove = Join-Path -Path $source_path -ChildPath $folder_to_remove
			Try {
				$null = Remove-Item -Path $folder_path_to_remove -Force -Verbose
			}
			Catch {
				Write-Output "ERROR: could not remove path '$folder_path_to_remove'"
			}
		}

		# retrieve old files only in Destination
		$folders_to_remove_from_target += [array][System.Linq.Enumerable]::Except([string[]]$old_folders_on_target_relative, [string[]]$folders_in_both_paths)

		# remove old files only in Destination
		ForEach ($folder_to_remove in $folders_to_remove_from_target) {
			$folder_path_to_remove = Join-Path -Path $target_path -ChildPath $folder_to_remove
			Try {
				$null = Remove-Item -Path $folder_path_to_remove -Force -Verbose
			}
			Catch {
				Write-Output "ERROR: could not remove path '$folder_path_to_remove'"
			}
		}
	}

	# update JSON file
	$json_data = [array]($json_data | Where-Object { $_.Path -ne $source_path })
	$json_data += [pscustomobject]@{
		Path             = $source_path.TrimEnd('\')
		Destination      = $target_path.TrimEnd('\')
		Mode             = $Mode
		Purge            = $Purge.ToBool()
		Recurse          = $Recurse.ToBool()
		CheckHash        = $CheckHash.ToBool()
		SkipFiles        = $SkipFiles.ToBool()
		SkipCreateTarget = $SkipCreateTarget.ToBool()
		LastSyncTime     = $sync_time_ticks
	}
	$json_data | ConvertTo-Json | Set-Content -Path $Json
}

# define JSON file
If ([string]::IsNullOrEmpty($Json)) {
	$Json = $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.json')
}

# verify JSON file
If (-not (Test-Path -Path $Json)) {
	If ($Add) {
		Try {
			$null = New-Item -ItemType 'File' -Path $Json
		}
		Catch {
			Write-Output "`nERROR: could not create configuration file:"
			Write-Output "$Json`n"
			Return
		}
	}
	Else {
		Write-Output "`nERROR: could not find configuration file:"
		Write-Output "$Json`n"
		Return
	}
}

# import JSON data
$json_data = @()
$json_data += Get-Content -Path $Json | ConvertFrom-Json

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
			$json_data = $json_data | Where-Object {
				$_.Path -ne $Path
			}
			If ($null -eq $json_data) {
				[string]::Empty | Set-Content -Path $Json
				Write-Output "`nRemoved '$Path' from configuration file: '$Json'"
			}
			Else {
				$json_data | ConvertTo-Json | Set-Content -Path $Json
				Write-Output "`nRemoved '$Path' from configuration file: '$Json'"
			}
			$json_data | Format-Table
		}
		Catch {
			Write-Output "`nERROR: could not update configuration file: '$Json'"
		}
	}
	$Add {
		# create custom object from parameters then add to object
		Try {
			$json_data += [pscustomobject]@{
				Path             = $Path.TrimEnd('\')
				Destination      = $Destination.TrimEnd('\')
				Mode             = $Mode
				Purge            = $Purge.ToBool()
				Recurse          = $Recurse.ToBool()
				CheckHash        = $CheckHash.ToBool()
				SkipFiles        = $SkipFiles.ToBool()
				SkipCreateTarget = $SkipCreateTarget.ToBool()
				LastSyncTime     = 0
			}
			$json_data | ConvertTo-Json | Set-Content -Path $Json
			Write-Output "`nAdded '$Path' to configuration file: '$Json'"
			$json_data | Format-Table
		}
		Catch {
			Write-Output "`nERROR: could not update configuration file: '$Json'"
		}
	}
	$Sync {
		Try {
			# define transcript file from script path and start transcript
			Start-Transcript -Path $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, "_$HostName.txt") -Force

			# check entry count in configuration file
			If ($json_data.Count -eq 0) {
				Write-Output "`nERROR: no entries found in configuration file: $Json"
				Return
			}

			# process configuration file
			ForEach ($json_datum in $json_data) {
				If ([string]::IsNullOrEmpty($json_datum.Path) -or [string]::IsNullOrEmpty($json_datum.Destination) -or [string]::IsNullOrEmpty($json_datum.Mode)) {
					Write-Output "`nERROR: invalid entry found in configuration file: $Json"
				}
				Else {
					$json_hashtable = @{
						Path             = $json_datum.Path
						Destination      = $json_datum.Destination
						Mode             = $json_datum.Mode
						Purge            = $json_datum.Purge
						Recurse          = $json_datum.Recurse
						CheckHash        = $json_datum.CheckHash
						SkipFiles        = $json_datum.SkipFiles
						SkipCreateTarget = $json_datum.SkipCreateTarget
						LastSyncTime     = $json_datum.LastSyncTime
					}
					Sync-ItemsInPathWithDestination @json_hashtable
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
		$json_data | Format-Table
	}
}
