<#
.SYNOPSIS
Synchronize files and directories in a source path with a destination path.

.DESCRIPTION 
Synchronize files and directories in a source path with a destination path based upon runtime parameters or settings from a JSON file. The JSON file enables the 

.PARAMETER Now
Synchronize files and directories per the parameters provided to the script.

.PARAMETER Sync
Synchronize files and directories per the configuration entries stored in the JSON file.

.PARAMETER Clear
Removes all configuration entries from the JSON file.

.PARAMETER Remove
Removes a configuration entry from the JSON file.

.PARAMETER Add
Adds a configuration entry to the JSON file.

.PARAMETER Path
Specifies the path of the source directory.

.PARAMETER Destination
Specifies the path of the destination directory.

.PARAMETER Preset
Specifies multiple parameters from a single value:
- 'Sync' sets Direction = 'Both', SkipDelete = $false, SkipExisting = $false
- 'Merge' sets Direction = 'Both', SkipDelete = $true, SkipExisting = $false
- 'Mirror' sets Direction = 'Forward', SkipDelete = $false, SkipExisting = $false
- 'Contribute' sets Direction = 'Forward', SkipDelete = $true, SkipExisting = $false
- 'Missing' sets Direction = 'Forward', SkipDelete = $true, SkipExisting = $true

.PARAMETER Direction
Specifics the direction of the synchronization:
- 'Forward' synchronizes items in the source to the destination.
- 'Reverse' synchronizes items in the destination to the path.
- 'Both' synchronizes items in both directions and is the default.

.PARAMETER Purge
Removes all files and directories in the Destination path before synchronization.

.PARAMETER Recurse
Specifies that files and directories in child directories of the path and destination should be synchronized.

.PARAMETER CheckHash
Specifies that files should be compared using Get-FileHash instead of the LastWriteTime attribute.

.PARAMETER SkipDelete
Specifies that existing files and directories should not be removed by synchronization.

.PARAMETER SkipExisting
Specifies that existing files and directories should not be compared by synchronization.

.PARAMETER SkipFiles
Specifies that files should not be synchronized.

.PARAMETER CreatePath
Specifies that the Path directory should be created if it does not already exist.

.PARAMETER CreateDestination
Specifies that the Destination directory should be created if it does not already exist.

.INPUTS
None. Sync-PathWithDestination does not accept pipeline input.

.OUTPUTS
None. The script merely reports on actions taken and does not provide any actionable output.

.EXAMPLE
To be added...
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Mandatory = $True, ParameterSetName = 'Now')]
	[switch]$Now,
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
	[Parameter(Mandatory = $True, ParameterSetName = 'Now')]
	[ValidatePattern('^[^\*]+$')]
	[string]$Path,
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Now')]
	[ValidatePattern('^[^\*]+$')]
	[string]$Destination,
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Now')]
	[ValidateSet('Sync', 'Contribute', 'Mirror', 'Merge')]
	[string]$Preset = 'Sync',
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Now')]
	[ValidateSet('Both', 'Forward', 'Reverse')]
	[string]$Direction = 'Both',
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Now')]
	[switch]$Purge,
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Now')]
	[switch]$Recurse,
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Now')]
	[switch]$CheckHash,
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Now')]
	[switch]$SkipDelete,
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Now')]
	[switch]$SkipExisting,
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Now')]
	[switch]$SkipFiles,
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Now')]
	[switch]$CreatePath,
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Now')]
	[switch]$CreateDestination,
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Now')]
	[uint64]$LastSyncTime,
	[Parameter()]
	[string]$Json,
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

Begin {
	# if JSON file not provided...
	If ([string]::IsNullOrEmpty($Json)) {
		# ...define default JSON file
		$Json = $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.json')
	}

	# if update mode...
	If ($Sync -or $Now) {
		# ...define transcript file from script path and start transcript
		Start-Transcript -Path $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, "_$Hostname.txt") -Force
	}

	Function Resolve-PresetToParameters {
		# resolve direction
		If ($null -eq $PSBoundParameters['Direction']) { 
			If ($script:Preset -eq 'Sync' -or $script:Preset -eq 'Merge') {
				$script:Direction = 'Both'
			}
			If ($script:Preset -eq 'Mirror' -or $script:Preset -eq 'Contribute' -or $script:Preset -eq 'Missing') {
				$script:Direction = 'Forward'
			}
		}

		# resolve SkipDelete
		If ($null -eq $PSBoundParameters['SkipDelete']) { 
			If ($script:Preset -eq 'Merge' -or $script:Preset -eq 'Contribute' -or $script:Preset -eq 'Missing') {
				$script:SkipDelete = $true
			}
			If ($script:Preset -eq 'Sync' -or $script:Preset -eq 'Mirror') {
				$script:SkipDelete = $false
			}
		}

		# resolve SkipExisting
		If ($null -eq $PSBoundParameters['SkipExisting']) { 
			If ($script:Preset -eq 'Missing') {
				$script:SkipExisting = $true
			}
			If ($script:Preset -eq 'Sync' -or $script:Preset -eq 'Merge' -or $script:Preset -eq 'Mirror' -or $script:Preset -eq 'Contribute') {
				$script:SkipExisting = $false
			}
		}
	}

	Function Sync-ItemsInPathWithDestination {
		[CmdletBinding()]
		param (
			[Parameter()]
			[string]$Path,
			[Parameter()]
			[string]$Destination,
			[ValidateSet('Both', 'Forward', 'Reverse')]
			[string]$Direction = 'Both',
			[Parameter()]
			[switch]$Purge,
			[Parameter()]
			[switch]$Recurse,
			[Parameter()]
			[switch]$CheckHash,
			[Parameter()]
			[switch]$SkipDelete,
			[Parameter()]
			[switch]$SkipExisting,
			[Parameter()]
			[switch]$SkipFiles,
			[Parameter()]
			[switch]$CreatePath,
			[Parameter()]
			[switch]$CreateDestination,
			[Parameter()]
			[uint64]$LastSyncTime = 0
		)

		# get current time
		$sync_time_ticks = (Get-Date).Ticks
		
		# trim inputs
		$Path = $Path.TrimEnd('\')
		$Destination = $Destination.TrimEnd('\')

		# verify source and target
		If ((Test-Path -Path $Path -PathType 'Container') -and (Test-Path -Path $Destination -PathType 'Container')) {
			Write-Output "Verified '$Path' and '$Destination' on host"
		}
		ElseIf (-not (Test-Path -Path $Path -PathType 'Container')) {
			If ($CreatePath) {
				Try {
					$null = New-Item -ItemType 'Directory' -Path $Path
				}
				Catch {
					Write-Output "Could not create Path folder '$Path' on host"; Return
				}
			}
			Else {
				Write-Output "Could not find Path folder '$Path' on host"; Return
			}
		}
		ElseIf (-not (Test-Path -Path $Destination -PathType 'Container')) {
			If ($CreateDestination) {
				Try {
					$null = New-Item -ItemType 'Directory' -Path $Destination
				}
				Catch {
					Write-Output "Could not create Destination folder '$Destination' on host"; Return
				}	
			}
			Else {
				Write-Output "Could not find Destination folder '$Destination' on host"; Return
			}
		}

		# set direction
		If ($Direction = 'Reverse') {
			$source_path = $Destination
			$target_path = $Path
		}
		Else {
			$source_path = $Path
			$target_path = $Destination
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
			$path_items_on_source = Get-ChildItem -Path $source_path -Recurse -Directory
			$path_items_on_target = Get-ChildItem -Path $target_path -Recurse -Directory

			# retrieve fullname of new paths
			$new_paths_on_source = $path_items_on_source | Where-Object { $_.LastWriteTime.Ticks -ge $LastSyncTime } | Select-Object -ExpandProperty 'FullName'
			$new_paths_on_target = $path_items_on_target | Where-Object { $_.LastWriteTime.Ticks -ge $LastSyncTime } | Select-Object -ExpandProperty 'FullName'

			# trim new paths to relative paths
			If ($new_paths_on_source.Count) { $new_paths_on_source_relative = $new_paths_on_source.Replace($source_path, $null) } Else { $new_paths_on_source_relative = @() }
			If ($new_paths_on_target.Count) { $new_paths_on_target_relative = $new_paths_on_target.Replace($target_path, $null) } Else { $new_paths_on_target_relative = @() }

			# create folders in Destination missing from Path
			If ($Direction -eq 'Forward' -or $Direction -eq 'Both') {
				# retrieve folders that are missing from Destination
				$paths_to_create_on_target += [array][System.Linq.Enumerable]::Except([string[]]$new_paths_on_source_relative, [string[]]$new_paths_on_target_relative)

				# create folders that are missing from Destination
				ForEach ($folder_to_create in $paths_to_create_on_target) {
					$folder_path_to_create = Join-Path -Path $target_path -ChildPath $folder_to_create
					Try {
						$null = New-Item -Path $folder_path_to_create -ItemType 'Directory' -Force -Verbose
					}
					Catch {
						Write-Output "ERROR: could not create folder '$folder_path_to_create'"
						Return
					}
				}
			}

			# create folders in Path missing from Destination
			If ($Direction -eq 'Both') {
				# retrieve folders that are missing from Path
				$paths_to_create_on_source += [array][System.Linq.Enumerable]::Except([string[]]$new_paths_on_target_relative, [string[]]$new_paths_on_source_relative)

				# create folders that are missing from Path
				ForEach ($folder_to_create in $paths_to_create_on_source) {
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

			# copy new files from Path to Destination
			If ($Direction -eq 'Forward' -or $Direction -eq 'Both') {
				# retrieve files that are missing from Destination
				$files_to_copy_to_target += [array][System.Linq.Enumerable]::Except([string[]]$new_files_on_source_relative, [string[]]$new_files_on_target_relative)

				# copy files that are missing from Destination
				ForEach ($file_to_copy in $files_to_copy_to_target) {
					$source_path_file_forward = Join-Path -Path $source_path -ChildPath $file_to_copy
					$target_path_file_forward = Join-Path -Path $target_path -ChildPath $file_to_copy
					Try {
						Copy-Item -Path $source_path_file_forward -Destination $target_path_file_forward -Force -Verbose
					}
					Catch {
						Write-Output "ERROR: could not copy file '$source_path_file_forward' to file '$target_path_file_forward'"
					}
				}
			}

			# copy new files from Destination to Path
			If ($Direction -eq 'Both') {
				# retrieve files that are missing from Path
				$files_to_copy_to_source += [array][System.Linq.Enumerable]::Except([string[]]$new_files_on_target_relative, [string[]]$new_files_on_source_relative)

				# copy files that are missing from Path
				ForEach ($file_to_copy in $files_to_copy_to_source) {
					$target_path_file_reverse = Join-Path -Path $target_path -ChildPath $file_to_copy
					$source_path_file_reverse = Join-Path -Path $source_path -ChildPath $file_to_copy
					Try {
						Copy-Item -Path $target_path_file_reverse -Destination $source_path_file_reverse -Force -Verbose
					}
					Catch {
						Write-Output "ERROR: could not copy file '$target_path_file_reverse' to file '$source_path_file_reverse'"
					}
				}
			}
		}

		# process files if SkipExisting and SkipFiles are false
		If (-not $SkipExisting -and -not $SkipFiles) {
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
				# define file path
				$file_path_on_source = Join-Path -Path $source_path -ChildPath $file_present
				$file_path_on_target = Join-Path -Path $target_path -ChildPath $file_present
				# compare files by hash if requested
				If ($CheckHash) {
					If ((Get-FileHash -Path $file_path_on_source).Hash -eq (Get-FileHash -Path $file_path_on_target).Hash) {
						Write-Verbose "Skipping '$file_path_on_source' as '$file_path_on_target' has same file hash"
						Continue
					}
				}
				# retrieve files
				$file_item_on_source = Get-Item -Path $file_path_on_source
				$file_item_on_target = Get-Item -Path $file_path_on_target
				# compare files by last 
				If (-not $CheckHash) {
					If ($file_item_on_source.LastWriteTime -eq $file_item_on_target.LastWriteTime) {
						Write-Verbose "Skipping '$file_path_on_source' as '$file_path_on_target' has same LastWriteTime"
						Continue
					}
				}
				# copy file from Path to Destination if newer or Direction is not 'Both'
				If ($file_item_on_source.LastWriteTime -gt $file_item_on_target.LastWriteTime -or $Direction -ne 'Both') {
					Try {
						Copy-Item -Path $file_path_on_source -Destination $file_path_on_target -Force -Verbose:$VerbosePreference
					}
					Catch {
						Write-Output "ERROR: could not copy file '$file_path_on_source' to file '$file_path_on_target'"
					}
				}
				# copy file from Destination to Path if newer and Direction is 'Both'
				ElseIf ($file_item_on_source.LastWriteTime -lt $file_item_on_target.LastWriteTime -and $Direction -eq 'Both') {
					Try {
						Copy-Item -Path $file_path_on_target -Destination $file_path_on_source -Force -Verbose:$VerbosePreference
					}
					Catch {
						Write-Output "ERROR: could not copy file '$file_path_on_target' to file '$file_path_on_source'"
					}
				}
			}
		}

		# remove old files if SkipDelete is false and SkipExisting or SkipFiles are false
		If (-not $SkipDelete -and (-not $SkipExisting -or -not $SkipFiles)) {
			# retrieve file objects
			$file_items_on_source = Get-ChildItem -Path $source_path -Recurse:$Recurse -File
			$file_items_on_target = Get-ChildItem -Path $target_path -Recurse:$Recurse -File

			# retrieve fullname of files
			$all_files_on_source = $file_items_on_source | Select-Object -ExpandProperty 'FullName'
			$all_files_on_target = $file_items_on_target | Select-Object -ExpandProperty 'FullName'
			$old_files_on_source = $file_items_on_source | Where-Object { $_.LastWriteTime.Ticks -lt $LastSyncTime } | Select-Object -ExpandProperty 'FullName'
			$old_files_on_target = $file_items_on_target | Where-Object { $_.LastWriteTime.Ticks -lt $LastSyncTime } | Select-Object -ExpandProperty 'FullName'

			# trim files to relative paths
			If ($all_files_on_source.Count) { $all_files_on_source_relative = $all_files_on_source.Replace($source_path, $null) } Else { $all_files_on_source_relative = @() }
			If ($all_files_on_target.Count) { $all_files_on_target_relative = $all_files_on_target.Replace($target_path, $null) } Else { $all_files_on_target_relative = @() }
			If ($old_files_on_source.Count) { $old_files_on_source_relative = $old_files_on_source.Replace($source_path, $null) } Else { $old_files_on_source_relative = @() }
			If ($old_files_on_target.Count) { $old_files_on_target_relative = $old_files_on_target.Replace($target_path, $null) } Else { $old_files_on_target_relative = @() }

			# retrieve files in both Path and Destination
			$files_in_both_paths += [array][System.Linq.Enumerable]::Intersect([string[]]$all_files_on_source_relative, [string[]]$all_files_on_target_relative)

			# remove old files from Destination
			If ($Direction -eq 'Forward' -or $Direction -eq 'Both') {
				# retrieve old files that are only in Destination
				$files_to_remove_from_target += [array][System.Linq.Enumerable]::Except([string[]]$old_files_on_target_relative, [string[]]$files_in_both_paths)

				# remove old files that are only in Destination
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

			# remove old files from Path
			If ($Direction -eq 'Reverse' -or $Direction -eq 'Both') {
				# retrieve old files that are only in Path
				$files_to_remove_from_source += [array][System.Linq.Enumerable]::Except([string[]]$old_files_on_source_relative, [string[]]$files_in_both_paths)

				# remove old files that are only in Path
				ForEach ($file_to_remove in $files_to_remove_from_source) {
					$file_path_to_remove = Join-Path -Path $source_path -ChildPath $file_to_remove
					Try {
						$null = Remove-Item -Path $file_path_to_remove -Force -Verbose
					}
					Catch {
						Write-Output "ERROR: could not remove file '$file_path_to_remove'"
					}
				}
			}
		}

		# remove old paths if SkipDelete and SkipExisting are false and Recurse is true
		If (-not $SkipDelete -and -not $SkipExisting -and $Recurse) {
			# retrieve path objects
			$path_items_on_source = Get-ChildItem -Path $source_path -Recurse:$Recurse -Directory
			$path_items_on_target = Get-ChildItem -Path $target_path -Recurse:$Recurse -Directory

			# retrieve fullname of paths
			$all_folders_on_source = $path_items_on_source | Select-Object -ExpandProperty 'FullName'
			$all_folders_on_target = $path_items_on_target | Select-Object -ExpandProperty 'FullName'
			$old_folders_on_source = $path_items_on_source | Where-Object { $_.LastWriteTime.Ticks -lt $LastSyncTime } | Select-Object -ExpandProperty 'FullName'
			$old_folders_on_target = $path_items_on_target | Where-Object { $_.LastWriteTime.Ticks -lt $LastSyncTime } | Select-Object -ExpandProperty 'FullName'

			# trim paths to relative paths
			If ($all_folders_on_source.Count) { $all_folders_on_source_relative = $all_folders_on_source.Replace($source_path, $null) } Else { $all_folders_on_source_relative = @() }
			If ($all_folders_on_target.Count) { $all_folders_on_target_relative = $all_folders_on_target.Replace($target_path, $null) } Else { $all_folders_on_target_relative = @() }
			If ($old_folders_on_source.Count) { $old_folders_on_source_relative = $old_folders_on_source.Replace($source_path, $null) } Else { $old_folders_on_source_relative = @() }
			If ($old_folders_on_target.Count) { $old_folders_on_target_relative = $old_folders_on_target.Replace($target_path, $null) } Else { $old_folders_on_target_relative = @() }

			# retrieve paths in both Path and Destination
			$folders_in_both_paths += [array][System.Linq.Enumerable]::Intersect([string[]]$all_folders_on_source_relative, [string[]]$all_folders_on_target_relative)

			# remove old paths from Destination
			If ($Direction -eq 'Forward' -or $Direction -eq 'Both') {
				# retrieve old paths only in Destination
				$paths_to_remove_from_target += [array][System.Linq.Enumerable]::Except([string[]]$old_folders_on_target_relative, [string[]]$folders_in_both_paths)

				# remove old paths only in Destination
				ForEach ($folder_to_remove in $paths_to_remove_from_target) {
					$folder_path_to_remove = Join-Path -Path $target_path -ChildPath $folder_to_remove
					Try {
						$null = Remove-Item -Path $folder_path_to_remove -Force -Verbose:$VerbosePreference
					}
					Catch {
						Write-Output "ERROR: could not remove path '$folder_path_to_remove'"
					}
				}
			}

			# remove old paths from Path
			If ($Direction -eq 'Reverse' -or $Direction -eq 'Both') {
				# retrieve old paths only in Path
				$paths_to_remove_from_source += [array][System.Linq.Enumerable]::Except([string[]]$old_folders_on_source_relative, [string[]]$folders_in_both_paths)

				# remove old paths only in Path
				ForEach ($folder_to_remove in $paths_to_remove_from_source) {
					$folder_path_to_remove = Join-Path -Path $source_path -ChildPath $folder_to_remove
					Try {
						$null = Remove-Item -Path $folder_path_to_remove -Force -Verbose:$VerbosePreference
					}
					Catch {
						Write-Output "ERROR: could not remove path '$folder_path_to_remove'"
					}
				}
			}
		}

		# update JSON file if LastSyncTime is not 0
		If ($Json -and $LastSyncTime -ne 0) {
			Try {
				$json_data = [array]($json_data | Where-Object { $_.Path -ne $source_path })
				$json_data += [pscustomobject]@{
					Path              = $source_path.TrimEnd('\')
					Destination       = $target_path.TrimEnd('\')
					Direction         = $Direction
					Purge             = $Purge.ToBool()
					Recurse           = $Recurse.ToBool()
					CheckHash         = $CheckHash.ToBool()
					SkipDelete        = $SkipDelete.ToBool()
					SkipExisting      = $SkipExisting.ToBool()
					SkipFiles         = $SkipFiles.ToBool()
					CreatePath        = $CreatePath.ToBool()
					CreateDestination = $CreateDestination.ToBool()
					LastSyncTime      = $sync_time_ticks
				}
				$json_data | ConvertTo-Json | Set-Content -Path $Json
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file after Sync: '$Json'"
			}
		}
	}
}

Process {
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
					$_.Path -ne $Path -and $_.Destination -ne $Destination
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
			# resolve preset to parameters
			Resolve-PresetToParameters
			# create custom object from parameters then add to object
			Try {
				$json_data += [pscustomobject]@{
					Path              = $Path.TrimEnd('\')
					Destination       = $Destination.TrimEnd('\')
					Direction         = $Direction
					Purge             = $Purge.ToBool()
					Recurse           = $Recurse.ToBool()
					CheckHash         = $CheckHash.ToBool()
					SkipDelete        = $SkipDelete.ToBool()
					SkipExisting      = $SkipExisting.ToBool()
					SkipFiles         = $SkipFiles.ToBool()
					CreatePath        = $CreatePath.ToBool()
					CreateDestination = $CreateDestination.ToBool()
					LastSyncTime      = 0
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
			# check entry count in configuration file
			If ($json_data.Count -eq 0) {
				Write-Output "`nERROR: no entries found in configuration file: $Json"
				Return
			}

			# process configuration file
			ForEach ($json_datum in $json_data) {
				If ([string]::IsNullOrEmpty($json_datum.Path) -or [string]::IsNullOrEmpty($json_datum.Destination) -or [string]::IsNullOrEmpty($json_datum.Direction)) {
					Write-Output "`nERROR: invalid entry found in configuration file: $Json"
				}
				Else {
					$json_hashtable = @{
						Path              = $json_datum.Path
						Destination       = $json_datum.Destination
						Direction         = $json_datum.Direction
						Purge             = $json_datum.Purge
						Recurse           = $json_datum.Recurse
						CheckHash         = $json_datum.CheckHash
						SkipDelete        = $json_datum.SkipDelete
						SkipExisting      = $json_datum.SkipExisting
						SkipFiles         = $json_datum.SkipFiles
						CreatePath        = $CreatePath.ToBool()
						CreateDestination = $CreateDestination.ToBool()
						LastSyncTime      = $json_datum.LastSyncTime
					}
					Sync-ItemsInPathWithDestination @json_hashtable
				}
			}
		}
		$Now {
			# resolve preset to parameters
			Resolve-PresetToParameters
			# verify required parameters are present
			If ([string]::IsNullOrEmpty($Direction)) {
				Write-Output "`nERROR: no Direction specified; provide a Direction or a Preset"
			}
			Else {
				$json_hashtable = @{
					Path              = $Path
					Destination       = $Destination
					Direction         = $Direction
					Purge             = $Purge.ToBool()
					Recurse           = $Recurse.ToBool()
					CheckHash         = $CheckHash.ToBool()
					SkipDelete        = $SkipDelete.ToBool()
					SkipExisting      = $SkipExisting.ToBool()
					SkipFiles         = $SkipFiles.ToBool()
					CreatePath        = $CreatePath.ToBool()
					CreateDestination = $CreateDestination.ToBool()
					LastSyncTime      = $LastSyncTime
				}
				Sync-ItemsInPathWithDestination @json_hashtable
			}
		}
		Default {
			Write-Output "`nDisplaying configuration file: '$Json'"
			$json_data | Format-Table
		}
	}
}

End {
	# if update mode...
	If ($Sync -or $Now) {
		# ...stop transcript
		Stop-Transcript
	}
}
