<#
.SYNOPSIS
Synchronize files and directories in a source path with a destination path.

.DESCRIPTION
Synchronize files and directories in a source path with a destination path based upon runtime parameters or settings from a JSON file.

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
Switch parameter to immediately synchronize files and directories per the parameters provided to the script. Cannot be combined with the Show, Clear, Remove, or Add parameters.

.PARAMETER Path
The path of the source directory. Required when the Remove, Add, or Run parameters are specified.

.PARAMETER Destination
The path of the destination directory. Required when the Remove, Add, or Run parameters are specified.

.PARAMETER Preset
String paramter to specify multiple parameters from a single value:
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
Switch to removes all files and directories in the Destination path before synchronization.

.PARAMETER Recurse
Switch to synchronize files and directories in child directories of the path and destination.

.PARAMETER CheckHash
Switch to compare files using Get-FileHash instead of the LastWriteTime attribute.

.PARAMETER SkipDelete
Switch to keep files and directories that would be removed by synchronization.

.PARAMETER SkipExisting
Switch to exclude existing files and directories from synchronization.

.PARAMETER SkipFiles
Switch to skip synchronizing files; only directories will be synchronized.

.PARAMETER CreatePath
Switch to create the Path directory if it does not already exist.

.PARAMETER CreateDestination
Switch to create the Destination directory if it does not already exist.

.INPUTS
None. Sync-PathWithDestination does not accept pipeline input.

.OUTPUTS
None. The script merely reports on actions taken and does not provide any actionable output.

.EXAMPLE
To be added...
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
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Remove')]
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Add')]
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Run')]
	[ValidatePattern('^[^\*]+$')]
	[string]$Path,
	[Parameter(Position = 2, Mandatory = $True, ParameterSetName = 'Remove')]
	[Parameter(Position = 2, Mandatory = $True, ParameterSetName = 'Add')]
	[Parameter(Position = 2, Mandatory = $True, ParameterSetName = 'Run')]
	[ValidatePattern('^[^\*]+$')]
	[string]$Destination,
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[ValidateSet('Sync', 'Contribute', 'Mirror', 'Merge')]
	[string]$Preset = 'Sync',
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[ValidateSet('Both', 'Forward', 'Reverse')]
	[string]$Direction = 'Both',
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[switch]$Purge,
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[switch]$Recurse,
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[switch]$CheckHash,
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[switch]$SkipDelete,
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[switch]$SkipExisting,
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[switch]$SkipFiles,
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[switch]$CreatePath,
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[switch]$CreateDestination,
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[uint64]$LastSyncTime,
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
				$paths_to_create_on_target = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except([string[]]$new_paths_on_source_relative, [string[]]$new_paths_on_target_relative))

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
				$paths_to_create_on_source = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except([string[]]$new_paths_on_target_relative, [string[]]$new_paths_on_source_relative))

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
				$files_to_copy_to_target = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except([string[]]$new_files_on_source_relative, [string[]]$new_files_on_target_relative))

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
				$files_to_copy_to_source = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except([string[]]$new_files_on_target_relative, [string[]]$new_files_on_source_relative))

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
			$files_present = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Intersect([string[]]$all_files_on_source_relative, [string[]]$all_files_on_target_relative))

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
			$files_in_both_paths = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Intersect([string[]]$all_files_on_source_relative, [string[]]$all_files_on_target_relative))

			# remove old files from Destination
			If ($Direction -eq 'Forward' -or $Direction -eq 'Both') {
				# retrieve old files that are only in Destination
				$files_to_remove_from_target = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except([string[]]$old_files_on_target_relative, $files_in_both_paths))

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
				$files_to_remove_from_source = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except([string[]]$old_files_on_source_relative, $files_in_both_paths))

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
			$folders_in_both_paths = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Intersect([string[]]$all_folders_on_source_relative, [string[]]$all_folders_on_target_relative))

			# remove old paths from Destination
			If ($Direction -eq 'Forward' -or $Direction -eq 'Both') {
				# retrieve old paths only in Destination
				$paths_to_remove_from_target = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except([string[]]$old_folders_on_target_relative, $folders_in_both_paths))

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
				$paths_to_remove_from_source = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except([string[]]$old_folders_on_source_relative, $folders_in_both_paths))

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
				$JsonData = [array]($JsonData | Where-Object { $_.Path -ne $source_path })
				$JsonData += [pscustomobject]@{
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
				$JsonData | ConvertTo-Json | Set-Content -Path $Json
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file after Sync: '$Json'"
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
	# if JSON file not provided...
	If ($PSBoundParameters.ContainsKey('Json') -eq $false) {
		# ...define default JSON file
		$Json = $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.json')
	}

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
				$JsonData = $JsonData | Where-Object {
					$_.Path -ne $Path -and $_.Destination -ne $Destination
				}
				If ($null -eq $JsonData) {
					[string]::Empty | Set-Content -Path $Json
					Write-Output "`nRemoved entry for '$Path' and '$Destination' from configuration file: '$Json'"
				}
				Else {
					$JsonData | Sort-Object -Property Path, Destination | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
					Write-Output "`nRemoved entry for '$Path' and '$Destination' from configuration file: '$Json'"
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
			# resolve preset to parameters
			Try {
				Resolve-PresetToParameters
			}
			Catch {
				Write-Output "`nERROR: could not resolve preset to parameters: '$Preset'"
				Throw $_
			}

			# trim any trailing backslash from Path
			Try {
				$Path = $Path.TrimEnd('\')
			}
			Catch {
				Write-Output "`nERROR: could not trim Path"
				Throw $_
			}

			# trim any trailing backslash from Destination
			Try {
				$Destination = $Destination.TrimEnd('\')
			}
			Catch {
				Write-Output "`nERROR: could not trim Destination"
				Throw $_
			}

			# create custom object from parameters then add to object
			Try {
				# create ordered dictionary for custom object
				$JsonParameters += [pscustomobject]@{
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
					LastSyncTime      = 0
				}

				# add current time as FileDateTimeUniversal
				$JsonParameters['Updated'] = Get-Date -Format FileDateTimeUniversal

				# create custom object from hashtable
				$JsonDatum = [pscustomobject]$JsonParameters

				# if existing entry has same primary key(s)...
				If ($JsonData | Where-Object { $_.Path -eq $_.Path -and $_.Destination -eq $_.Destination }) {
					# inquire before removing existing entry
					Write-Warning -Message "Will overwrite existing entry for '$Path' and '$Destination' in configuration file: '$Json' `nAny previous configuration for this entry will **NOT** be preserved" -WarningAction Inquire
					# remove existing entry with same primary key(s)
					$JsonData = $JsonData | Where-Object { $_.Path -ne $_.Path -and $_.Destination -ne $_.Destination }
				}

				# add datum to data
				$JsonData += $JsonDatum
				$JsonData | Sort-Object -Property Path, Destination | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
				Write-Output "`nAdded entry for '$Path' and '$Destination' to configuration file: '$Json'"
				$JsonData | Sort-Object -Property Path, Destination | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file: '$Json'"
			}
		}
		# run script with provided parameters
		$Run {
			# resolve preset to parameters
			Try {
				Resolve-PresetToParameters
			}
			Catch {
				Write-Output "`nERROR: could not resolve preset to parameters: '$Preset'"
				Throw $_
			}

			# trim any trailing backslash from Path
			Try {
				$Path = $Path.TrimEnd('\')
			}
			Catch {
				Write-Output "`nERROR: could not trim Path"
				Throw $_
			}

			# trim any trailing backslash from Destination
			Try {
				$Destination = $Destination.TrimEnd('\')
			}
			Catch {
				Write-Output "`nERROR: could not trim Destination"
				Throw $_
			}

			# define required parameters for Sync-ItemsInPathWithDestination
			$SyncItemsInPathWithDestination = @{
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

			# define optional parameters for Sync-ItemsInPathWithDestination
			If ($WhatIfPreference.IsPresent) {
				$SyncItemsInPathWithDestination['WhatIf'] = $true
			}

			# sync items in path with destination
			Sync-ItemsInPathWithDestination @SyncItemsInPathWithDestination
		}
		# process entries in configuration file
		Default {
			# check entry count in configuration file
			If ($JsonData.Count -eq 0) {
				Write-Output "`nERROR: no entries found in configuration file: $Json"
				Return
			}

			# process configuration file
			:JsonDatum ForEach ($JsonDatum in $JsonData) {
				switch ($true) {
					([string]::IsNullOrEmpty($JsonDatum.Path)) {
						Write-Host "ERROR: required entry (Path) not found in configuration file: $Json"; Continue :JsonDatum
					}
					([string]::IsNullOrEmpty($JsonDatum.Destination)) {
						Write-Host "ERROR: required entry (Destination) not found in configuration file: $Json"; Continue :JsonDatum
					}
					([string]::IsNullOrEmpty($JsonDatum.Direction)) {
						Write-Host "ERROR: required entry (Direction) not found in configuration file: $Json"; Continue :JsonDatum
					}
					Default {
						# define required parameters for Sync-ItemsInPathWithDestination
						$SyncItemsInPathWithDestination = @{
							Path              = $JsonDatum.Path
							Destination       = $JsonDatum.Destination
							Direction         = $JsonDatum.Direction
							Purge             = $JsonDatum.Purge
							Recurse           = $JsonDatum.Recurse
							CheckHash         = $JsonDatum.CheckHash
							SkipDelete        = $JsonDatum.SkipDelete
							SkipExisting      = $JsonDatum.SkipExisting
							SkipFiles         = $JsonDatum.SkipFiles
							CreatePath        = $CreatePath.ToBool()
							CreateDestination = $CreateDestination.ToBool()
							LastSyncTime      = $JsonDatum.LastSyncTime
						}

						# define optional parameters for Sync-ItemsInPathWithDestination
						If ($WhatIfPreference.IsPresent) {
							$SyncItemsInPathWithDestination['WhatIf'] = $true
						}

						# sync items in path with destination
						Sync-ItemsInPathWithDestination @SyncItemsInPathWithDestination
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
