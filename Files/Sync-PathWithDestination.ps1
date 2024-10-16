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

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Run')]
Param(
	# script parameters - json file
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Json')]
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Show')]
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Clear')]
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Remove')]
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Add')]
	[string]$Json,
	# script parameters - mode
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Show')]
	[switch]$Show,
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	# function parameters - source path
	[Parameter(Position = 2, Mandatory = $True, ParameterSetName = 'Remove')]
	[Parameter(Position = 2, Mandatory = $True, ParameterSetName = 'Add')]
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Run')]
	[ValidatePattern('^[^\*]+$')]
	[string]$Path,
	# function parameters - target path
	[Parameter(Position = 3, Mandatory = $True, ParameterSetName = 'Remove')]
	[Parameter(Position = 3, Mandatory = $True, ParameterSetName = 'Add')]
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Run')]
	[ValidatePattern('^[^\*]+$')]
	[string]$Destination,
	# function parameters - preset for Direction, SkipExisting, SkipDelete
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[ValidateSet('Sync', 'Contribute', 'Mirror', 'Merge')]
	[string]$Preset = 'Sync',
	# function parameters - sync direction
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[ValidateSet('Both', 'Forward', 'Reverse')]
	[string]$Direction = 'Both',
	# function parameters - purge destination
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[switch]$Purge,
	# function parameters - include child items
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[switch]$Recurse,
	# function parameters - compare files with Get-FileHash
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[switch]$CheckHash,
	# function parameters - do not delete mismatched files and folders
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[switch]$SkipDelete,
	# function parameters - do not compare existing files and folders
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[switch]$SkipExisting,
	# function parameters - do not compare files
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[switch]$SkipFiles,
	# function parameters - create source path if missing
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[switch]$CreatePath,
	# function parameters - create target path if missing
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Run')]
	[switch]$CreateDestination,
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
		# resolve Direction
		If ($null -eq $script:PSBoundParameters['Direction']) {
			If ($script:Preset -eq 'Sync' -or $script:Preset -eq 'Merge') {
				$script:Direction = 'Both'
			}
			If ($script:Preset -eq 'Mirror' -or $script:Preset -eq 'Contribute' -or $script:Preset -eq 'Missing') {
				$script:Direction = 'Forward'
			}
		}

		# resolve SkipDelete
		If ($null -eq $script:PSBoundParameters['SkipDelete']) {
			If ($script:Preset -eq 'Merge' -or $script:Preset -eq 'Contribute' -or $script:Preset -eq 'Missing') {
				$script:SkipDelete = $true
			}
			If ($script:Preset -eq 'Sync' -or $script:Preset -eq 'Mirror') {
				$script:SkipDelete = $false
			}
		}

		# resolve SkipExisting
		If ($null -eq $script:PSBoundParameters['SkipExisting']) {
			If ($script:Preset -eq 'Missing') {
				$script:SkipExisting = $true
			}
			If ($script:Preset -eq 'Sync' -or $script:Preset -eq 'Merge' -or $script:Preset -eq 'Mirror' -or $script:Preset -eq 'Contribute') {
				$script:SkipExisting = $false
			}
		}
	}

	Function Sync-ItemsInPathWithDestination {
		[CmdletBinding(SupportsShouldProcess)]
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
			[string]$Updated,
			[Parameter()]
			[uint64]$LastSyncTime = 0,
			[Parameter()]
			[uint64]$CurrentSyncTime = [datetime]::Now.Ticks
		)

		# get current time
		$CurrentSyncTime = (Get-Date).Ticks

		# trim inputs
		$Path = $Path.TrimEnd('\')
		$Destination = $Destination.TrimEnd('\')

		# if source found...
		If (Test-Path -Path $Path -PathType 'Container') {
			$Source = Get-Item -Path $Path | Select-Object -ExpandProperty 'FullName'
			Write-Host "Found '$Path' on host with full path: $Source"
		}
		# if source not found...
		Else {
			# if create path requested...
			If ($CreatePath) {
				Try {
					$Source = New-Item -ItemType 'Directory' -Path $Path -Verbose:$VerbosePreference | Select-Object -ExpandProperty 'FullName'
					Write-Host "Created '$Path' on host with full path: $Source"
				}
				Catch {
					Write-Warning -Message "Could not create Path folder '$Path' on host"
					Return $_
				}
			}
			# if create path not requested...
			Else {
				Write-Warning "Could not find Path folder '$Path' on host"
				Return
			}
		}

		# if target found...
		If (Test-Path -Path $Destination -PathType 'Container') {
			$Target = Get-Item -Path $Destination | Select-Object -ExpandProperty 'FullName'
			Write-Host "Found '$Destination' on host with full path: $Target"
		}
		# if target not found...
		Else {
			# if create destination requested...
			If ($CreateDestination) {
				Try {
					$Target = New-Item -ItemType 'Directory' -Path $Destination -Verbose:$VerbosePreference | Select-Object -ExpandProperty 'FullName'
					Write-Host "Created '$Destination' on host with full path: $Target"
				}
				Catch {
					Write-Warning "Could not create Destination folder '$Destination' on host"
					Return $_
				}
			}
			# if create destination not requested...
			Else {
				# report not found and return
				Write-Warning "Could not find Destination folder '$Destination' on host"
				Return
			}
		}

		# set direction
		If ($Direction -eq 'Reverse') {
			$SourcePath = $Target
			$TargetPath = $Source
		}
		Else {
			$SourcePath = $Source
			$TargetPath = $Target
		}

		# remove all files and folders from target if Purge is set
		If ($Purge) {
			Write-Warning "Clearing '$TargetPath' before copy"
			Try {
				Get-ChildItem -Path $TargetPath -Recurse -Force | Remove-Item -Force -Verbose:$VerbosePreference
			}
			Catch {
				Write-Warning -Message "Could not purge folder '$TargetPath'"
				Return $_
			}
		}

		# create new folders if Recurse is true
		If ($Recurse) {
			# retrieve path objects
			$SourceFolders = Get-ChildItem -Path $SourcePath -Recurse -Directory
			$TargetFolders = Get-ChildItem -Path $TargetPath -Recurse -Directory

			# retrieve fullname of new paths
			$NewSourceFolders = $SourceFolders | Where-Object { $_.LastWriteTime.Ticks -ge $LastSyncTime } | Select-Object -ExpandProperty 'FullName'
			$NewTargetFolders = $TargetFolders | Where-Object { $_.LastWriteTime.Ticks -ge $LastSyncTime } | Select-Object -ExpandProperty 'FullName'

			# trim new paths to relative paths
			If ($NewSourceFolders.Count) { $RelativeSourceFolders = $NewSourceFolders.Replace($SourcePath, $null) } Else { $RelativeSourceFolders = @() }
			If ($NewTargetFolders.Count) { $RelativeTargetFolders = $NewTargetFolders.Replace($TargetPath, $null) } Else { $RelativeTargetFolders = @() }

			# create folders in Destination missing from Path
			If ($Direction -eq 'Forward' -or $Direction -eq 'Both') {
				# retrieve folders that are missing from Destination
				$MissingTargetFolders = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except([string[]]$RelativeSourceFolders, [string[]]$RelativeTargetFolders))

				# create folders that are missing from Destination
				ForEach ($MissingTargetFolder in $MissingTargetFolders) {
					$MissingTargetFolder = Join-Path -Path $TargetPath -ChildPath $MissingTargetFolder
					If ($PSCmdlet.ShouldProcess($MissingTargetFolder, 'create folder')) {
						Try {
							$null = New-Item -Path $MissingTargetFolder -ItemType 'Directory' -Force -Verbose:$VerbosePreference
						}
						Catch {
							Write-Warning "could not create folder '$MissingTargetFolder'"
							Return $_
						}
					}
				}
			}

			# create folders in Path missing from Destination
			If ($Direction -eq 'Both') {
				# retrieve folders that are missing from Path
				$MissingSourceFolders = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except([string[]]$RelativeTargetFolders, [string[]]$RelativeSourceFolders))

				# create folders that are missing from Path
				ForEach ($MissingSourceFolder in $MissingSourceFolders) {
					$MissingSourceFolder = Join-Path -Path $SourcePath -ChildPath $MissingSourceFolder
					If ($PSCmdlet.ShouldProcess($MissingSourceFolder, 'create folder')) {
						Try {
							$null = New-Item -Path $MissingSourceFolder -ItemType 'Directory' -Force -Verbose:$VerbosePreference
						}
						Catch {
							Write-Warning "could not create folder '$MissingSourceFolder'"
							Return $_
						}
					}
				}
			}
		}

		# copy new files if SkipFiles is false
		If (-not $SkipFiles) {
			# retrieve file objects
			$SourceItems = Get-ChildItem -Path $SourcePath -Recurse:$Recurse -File
			$TargetItems = Get-ChildItem -Path $TargetPath -Recurse:$Recurse -File

			# retrieve fullname of new files
			$NewSourceFiles = $SourceItems | Where-Object { $_.LastWriteTime.Ticks -ge $LastSyncTime } | Select-Object -ExpandProperty 'FullName'
			$NewTargetFiles = $TargetItems | Where-Object { $_.LastWriteTime.Ticks -ge $LastSyncTime } | Select-Object -ExpandProperty 'FullName'

			# trim new files to relative paths
			If ($NewSourceFiles.Count) { $RelativeSourceFiles = $NewSourceFiles.Replace($SourcePath, $null) } Else { $RelativeSourceFiles = @() }
			If ($NewTargetFiles.Count) { $RelativeTargetFiles = $NewTargetFiles.Replace($TargetPath, $null) } Else { $RelativeTargetFiles = @() }

			# copy new files from Path to Destination
			If ($Direction -eq 'Forward' -or $Direction -eq 'Both') {
				# retrieve files that are missing from Destination
				$MissingTargetFiles = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except([string[]]$RelativeSourceFiles, [string[]]$RelativeTargetFiles))

				# copy files that are missing from Destination
				ForEach ($MissingTargetFile in $MissingTargetFiles) {
					$MissingTargetFileOnSource = Join-Path -Path $SourcePath -ChildPath $MissingTargetFile
					$MissingTargetFileExpected = Join-Path -Path $TargetPath -ChildPath $MissingTargetFile
					If ($PSCmdlet.ShouldProcess("source: $MissingTargetFileOnSource, target: $MissingTargetFileExpected", 'copy file')) {
						Try {
							Copy-Item -Path $MissingTargetFileOnSource -Destination $MissingTargetFileExpected -Force -Verbose:$VerbosePreference
						}
						Catch {
							Write-Warning "could not copy file '$MissingTargetFileOnSource' to file '$MissingTargetFileExpected'"
						}
					}
				}
			}

			# copy new files from Destination to Path
			If ($Direction -eq 'Both') {
				# retrieve files that are missing from Path
				$MissingSourceFiles = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except([string[]]$RelativeTargetFiles, [string[]]$RelativeSourceFiles))

				# copy files that are missing from Path
				ForEach ($MissingSourceFile in $MissingSourceFiles) {
					$MissingSourceFileOnTarget = Join-Path -Path $TargetPath -ChildPath $MissingSourceFile
					$MissingSourceFileExpected = Join-Path -Path $SourcePath -ChildPath $MissingSourceFile
					If ($PSCmdlet.ShouldProcess("source: $MissingSourceFileOnTarget, target: $MissingSourceFileExpected", 'copy file')) {
						Try {
							Copy-Item -Path $MissingSourceFileOnTarget -Destination $MissingSourceFileExpected -Force -Verbose:$VerbosePreference
						}
						Catch {
							Write-Warning "could not copy file '$MissingSourceFileOnTarget' to file '$MissingSourceFileExpected'"
						}
					}
				}
			}
		}

		# process files if SkipExisting and SkipFiles are false
		If (-not $SkipExisting -and -not $SkipFiles) {
			# retrieve fullname of all files
			$AllSourceFiles = $SourceItems | Select-Object -ExpandProperty 'FullName'
			$AllTargetFiles = $TargetItems | Select-Object -ExpandProperty 'FullName'

			# trim all files to relative paths
			If ($AllSourceFiles.Count) { $AllRelativeSourceFiles = $AllSourceFiles.Replace($SourcePath, $null) } Else { $AllRelativeSourceFiles = @() }
			If ($AllTargetFiles.Count) { $AllRelativeTargetFiles = $AllTargetFiles.Replace($TargetPath, $null) } Else { $AllRelativeTargetFiles = @() }

			# retrieve files in both Path and Destination
			$MatchedFiles = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Intersect([string[]]$AllRelativeSourceFiles, [string[]]$AllRelativeTargetFiles))

			# copy any present files when hash or lastwritetime are different
			:NextMatchedFile ForEach ($MatchedFile in $MatchedFiles) {
				# define file path
				$MatchedSourcePath = Join-Path -Path $SourcePath -ChildPath $MatchedFile
				$MatchedTargetPath = Join-Path -Path $TargetPath -ChildPath $MatchedFile
				# compare files by hash if requested
				If ($CheckHash) {
					If ((Get-FileHash -Path $MatchedSourcePath).Hash -eq (Get-FileHash -Path $MatchedTargetPath).Hash) {
						Write-Host "Skipping '$MatchedSourcePath' as '$MatchedTargetPath' has same file hash"
						Continue
					}
				}
				# retrieve files
				$MatchedSourceItem = $SourceItems.Where({ $_.FullName -eq $MatchedSourcePath })
				$MatchedTargetItem = $TargetItems.Where({ $_.FullName -eq $MatchedTargetPath })
				# compare files by last
				If (-not $CheckHash) {
					If ($MatchedSourceItem.LastWriteTime -eq $MatchedTargetItem.LastWriteTime) {
						Write-Host "Skipping '$MatchedSourcePath' as '$MatchedTargetPath' has same LastWriteTime"
						Continue
					}
				}
				# copy file from Path to Destination if newer or Direction is not 'Both'
				If ($MatchedSourceItem.LastWriteTime -gt $MatchedTargetItem.LastWriteTime -or $Direction -ne 'Both') {
					If ($PSCmdlet.ShouldProcess("source: $MatchedSourcePath, target: $MatchedTargetPath", 'copy file')) {
						Try {
							Copy-Item -Path $MatchedSourcePath -Destination $MatchedTargetPath -Force -Verbose:$VerbosePreference
						}
						Catch {
							Write-Warning "could not copy file '$MatchedSourcePath' to file '$MatchedTargetPath'"
						}
					}
				}
				# copy file from Destination to Path if newer and Direction is 'Both'
				ElseIf ($MatchedSourceItem.LastWriteTime -lt $MatchedTargetItem.LastWriteTime -and $Direction -eq 'Both') {
					If ($PSCmdlet.ShouldProcess("source: $MatchedTargetPath, target: $MatchedSourcePath", 'copy file')) {
						Try {
							Copy-Item -Path $MatchedTargetPath -Destination $MatchedSourcePath -Force -Verbose:$VerbosePreference
						}
						Catch {
							Write-Warning "could not copy file '$MatchedTargetPath' to file '$MatchedSourcePath'"
						}
					}
				}
			}
		}

		# remove old files if SkipDelete is false and SkipExisting or SkipFiles are false
		If (-not $SkipDelete -and (-not $SkipExisting -or -not $SkipFiles)) {
			# retrieve file objects
			$SourceItems = Get-ChildItem -Path $SourcePath -Recurse:$Recurse -File
			$TargetItems = Get-ChildItem -Path $TargetPath -Recurse:$Recurse -File

			# retrieve fullname of files
			$AllSourceFiles = $SourceItems | Select-Object -ExpandProperty 'FullName'
			$AllTargetFiles = $TargetItems | Select-Object -ExpandProperty 'FullName'
			$OldSourceFiles = $SourceItems | Where-Object { $_.LastWriteTime.Ticks -lt $LastSyncTime } | Select-Object -ExpandProperty 'FullName'
			$OldTargetFiles = $TargetItems | Where-Object { $_.LastWriteTime.Ticks -lt $LastSyncTime } | Select-Object -ExpandProperty 'FullName'

			# trim files to relative paths
			If ($AllSourceFiles.Count) { $AllRelativeSourceFiles = $AllSourceFiles.Replace($SourcePath, $null) } Else { $AllRelativeSourceFiles = @() }
			If ($AllTargetFiles.Count) { $AllRelativeTargetFiles = $AllTargetFiles.Replace($TargetPath, $null) } Else { $AllRelativeTargetFiles = @() }
			If ($OldSourceFiles.Count) { $OldRelativeSourceFiles = $OldSourceFiles.Replace($SourcePath, $null) } Else { $OldRelativeSourceFiles = @() }
			If ($OldTargetFiles.Count) { $OldRelativeTargetFiles = $OldTargetFiles.Replace($TargetPath, $null) } Else { $OldRelativeTargetFiles = @() }

			# retrieve files in both Path and Destination
			$MatchedFiles = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Intersect([string[]]$AllRelativeSourceFiles, [string[]]$AllRelativeTargetFiles))

			# remove old files from Destination
			If ($Direction -eq 'Forward' -or $Direction -eq 'Both') {
				# retrieve old files that are only in Destination
				$ExpiredTargetFiles = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except([string[]]$OldRelativeTargetFiles, $MatchedFiles))

				# remove old files that are only in Destination
				ForEach ($ExpiredTargetFile in $ExpiredTargetFiles) {
					$ExpiredTargetFilePath = Join-Path -Path $TargetPath -ChildPath $ExpiredTargetFile
					If ($PSCmdlet.ShouldProcess($ExpiredTargetFilePath, 'remove file')) {
						Try {
							$null = Remove-Item -Path $ExpiredTargetFilePath -Force -Verbose:$VerbosePreference
						}
						Catch {
							Write-Warning "could not remove file '$ExpiredTargetFilePath'"
						}
					}
				}
			}

			# remove old files from Path
			If ($Direction -eq 'Reverse' -or $Direction -eq 'Both') {
				# retrieve old files that are only in Path
				$ExpiredSourceFiles = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except([string[]]$OldRelativeSourceFiles, $MatchedFiles))

				# remove old files that are only in Path
				ForEach ($ExpiredSourceFile in $ExpiredSourceFiles) {
					$ExpiredSourceFilePath = Join-Path -Path $SourcePath -ChildPath $ExpiredSourceFile
					If ($PSCmdlet.ShouldProcess($ExpiredSourceFilePath, 'remove file')) {
						Try {
							$null = Remove-Item -Path $ExpiredSourceFilePath -Force -Verbose:$VerbosePreference
						}
						Catch {
							Write-Warning "could not remove file '$ExpiredSourceFilePath'"
						}
					}
				}
			}
		}

		# remove old paths if SkipDelete and SkipExisting are false and Recurse is true
		If (-not $SkipDelete -and -not $SkipExisting -and $Recurse) {
			# retrieve path objects
			$SourceFolders = Get-ChildItem -Path $SourcePath -Recurse:$Recurse -Directory
			$TargetFolders = Get-ChildItem -Path $TargetPath -Recurse:$Recurse -Directory

			# retrieve fullname of paths
			$AllSourceFolders = $SourceFolders | Select-Object -ExpandProperty 'FullName'
			$AllTargetFolders = $TargetFolders | Select-Object -ExpandProperty 'FullName'
			$OldSourceFolders = $SourceFolders | Where-Object { $_.LastWriteTime.Ticks -lt $LastSyncTime } | Select-Object -ExpandProperty 'FullName'
			$OldTargetFolders = $TargetFolders | Where-Object { $_.LastWriteTime.Ticks -lt $LastSyncTime } | Select-Object -ExpandProperty 'FullName'

			# trim paths to relative paths
			If ($AllSourceFolders.Count) { $AllRelativeSourceFolders = $AllSourceFolders.Replace($SourcePath, $null) } Else { $AllRelativeSourceFolders = @() }
			If ($AllTargetFolders.Count) { $AllRelativeTargetFolders = $AllTargetFolders.Replace($TargetPath, $null) } Else { $AllRelativeTargetFolders = @() }
			If ($OldSourceFolders.Count) { $OldRelativeSourceFolders = $OldSourceFolders.Replace($SourcePath, $null) } Else { $OldRelativeSourceFolders = @() }
			If ($OldTargetFolders.Count) { $OldRelativeTargetFolders = $OldTargetFolders.Replace($TargetPath, $null) } Else { $OldRelativeTargetFolders = @() }

			# retrieve paths in both Path and Destination
			$MatchedFolders = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Intersect([string[]]$AllRelativeSourceFolders, [string[]]$AllRelativeTargetFolders))

			# remove old paths from Destination
			If ($Direction -eq 'Forward' -or $Direction -eq 'Both') {
				# retrieve old paths only in Destination
				$ExpiredTargetFolders = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except([string[]]$OldRelativeTargetFolders, $MatchedFolders))

				# remove old paths only in Destination
				ForEach ($ExpiredTargetFolder in $ExpiredTargetFolders) {
					$ExpiredTargetFolderPath = Join-Path -Path $TargetPath -ChildPath $ExpiredTargetFolder
					If ($PSCmdlet.ShouldProcess($ExpiredTargetFolderPath, 'remove folder')) {
						Try {
							$null = Remove-Item -Path $ExpiredTargetFolderPath -Force -Verbose:$VerbosePreference
						}
						Catch {
							Write-Warning "could not remove path '$ExpiredTargetFolderPath'"
						}
					}
				}
			}

			# remove old paths from Path
			If ($Direction -eq 'Reverse' -or $Direction -eq 'Both') {
				# retrieve old paths only in Path
				$ExpiredSourceFolders = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except([string[]]$OldRelativeSourceFolders, $MatchedFolders))

				# remove old paths only in Path
				ForEach ($ExpiredSourceFolder in $ExpiredSourceFolders) {
					$ExpiredSourceFolderPath = Join-Path -Path $SourcePath -ChildPath $ExpiredSourceFolder
					If ($PSCmdlet.ShouldProcess($ExpiredSourceFolderPath, 'remove folder')) {
						Try {
							$null = Remove-Item -Path $ExpiredSourceFolderPath -Force -Verbose:$VerbosePreference
						}
						Catch {
							Write-Warning "could not remove path '$ExpiredSourceFolderPath'"
						}
					}
				}
			}
		}

		# update JSON file if LastSyncTime is not 0
		If ($Json -and $LastSyncTime -ne 0) {
			# create ordered dictionary for custom object
			$JsonParameters = [ordered]@{
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
				LastSyncTime      = $CurrentSyncTime
				Updated           = $Updated
			}

			# create custom object from ordered dictionary
			$JsonEntry = [pscustomobject]$JsonParameters

			# remove existing entry with same primary key(s)
			$JsonData = [array]($JsonData.Where({ $_.Path -ne $Path -and $_.Destination -ne $Destination }))

			# add entry to data
			$JsonData += $JsonEntry

			# convert JSON data to JSON string
			Try {
				$JsonValue = $JsonData | Sort-Object -Property 'Path', 'Destination' | ConvertTo-Json -Depth 100
			}
			Catch {
				Write-Warning 'could not convert object to JSON'
				Return $_
			}

			# update JSON file
			Try {
				$JsonValue | Set-Content -Path $Json
			}
			Catch {
				Write-Warning "could not update configuration file after Sync: '$Json'"
				Return $_
			}
		}
	}
}

Process {
	# if script in direct run mode...
	If ($PSCmdLet.ParameterSetName -eq 'Run') {
		# resolve preset to parameters
		Try {
			Resolve-PresetToParameters
		}
		Catch {
			Write-Warning -Message "could not resolve preset to parameters: '$Preset'"
			Throw $_
		}

		# trim any trailing backslash from Path
		Try {
			$Path = $Path.TrimEnd('\')
		}
		Catch {
			Write-Warning -Message 'could not trim Path'
			Throw $_
		}

		# trim any trailing backslash from Destination
		Try {
			$Destination = $Destination.TrimEnd('\')
		}
		Catch {
			Write-Warning -Message 'could not trim Destination'
			Throw $_
		}

		# create hashtable from parameters then splat to function
		Try {
			# define required parameters for Sync-ItemsInPathWithDestination
			$SyncItemsInPathWithDestination = [ordered]@{
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

			# defined optional parameters for Sync-ItemsInPathWithDestination
			If ($VerbosePreference -eq 'Continue') {
				$SyncItemsInPathWithDestination['Verbose'] = $true
			}

			# define optional parameters for Sync-ItemsInPathWithDestination
			If ($WhatIfPreference -eq $true) {
				$SyncItemsInPathWithDestination['WhatIf'] = $true
			}

			# sync items in path with destination
			Sync-ItemsInPathWithDestination @SyncItemsInPathWithDestination
		}
		Catch {
			Write-Warning -Message 'could not sync path with destination'
			Return $_
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
			Write-Host "Displaying '$Json'"
			$JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
		}
		# clear configuration file
		$Clear {
			# set empty string for JSON string
			$JsonValue = [string]::Empty

			# update JSON file
			Try {
				$JsonValue | Set-Content -Path $Json
			}
			Catch {
				Write-Warning "could not clear entries from configuration file: '$Json'"
				Return $_
			}

			# report entries cleared
			Write-Host "Cleared entries from configuration file: '$Json'"
		}
		# remove entry from configuration file
		$Remove {
			# remove existing entry by primary key(s)...
			$JsonData = [array]($JsonData.Where({ $_.Path -ne $Path -and $_.Destination -ne $Destination }))

			# if JSON data empty...
			If ($JsonData.Count -eq 0) {
				# set empty string for JSON string
				$JsonValue = [string]::Empty
			}
			# if JSON data is not empty...
			Else {
				# convert JSON data to JSON string
				Try {
					$JsonValue = $JsonData | Sort-Object -Property 'Path', 'Destination' | ConvertTo-Json -Depth 100
				}
				Catch {
					Write-Warning 'could not convert object to JSON'
					Return $_
				}
			}
			
			# update JSON file
			Try {
				$JsonValue | Set-Content -Path $Json
			}
			Catch {
				Write-Warning "could not remove entry from configuration file: '$Json'"
				Return $_
			}
			
			# report entry removed
			Write-Host "Removed '$Path' path with '$Destination' destination from configuration file: '$Json'"
			
			# display current entries if verbose
			If ($VerbosePreference -eq 'Continue') { $JsonValue | Format-List }
		}
		# add entry to configuration file
		$Add {
			# resolve preset to parameters
			Try {
				Resolve-PresetToParameters
			}
			Catch {
				Write-Warning -Message "could not resolve preset to parameters: '$Preset'"
				Throw $_
			}

			# trim any trailing backslash from Path
			Try {
				$Path = $Path.TrimEnd('\')
			}
			Catch {
				Write-Warning -Message "could not trim Path: '$Path'"
				Throw $_
			}

			# trim any trailing backslash from Destination
			Try {
				$Destination = $Destination.TrimEnd('\')
			}
			Catch {
				Write-Warning -Message "could not trim Destination: '$Destination'"
				Throw $_
			}

			# if existing entry has same primary key(s)...
			If ($JsonData.Where({ $_.Path -eq $Path -and $_.Destination -eq $Destination })) {
				# inquire before removing existing entry
				Write-Warning -Message "Will overwrite existing entry for '$Path' path and '$Destination' destination in configuration file: '$Json' `nAny previous configuration for this entry will **NOT** be preserved" -WarningAction Inquire
				# remove existing entry with same primary key(s)
				$JsonData = [array]($JsonData.Where({ $_.Path -ne $Path -and $_.Destination -ne $Destination }))
			}

			# create ordered dictionary for custom object
			$JsonParameters = [ordered]@{
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
			$JsonParameters['Updated'] = (Get-Date -Format FileDateTimeUniversal)

			# create custom object from ordered dictionary
			$JsonEntry = [pscustomobject]$JsonParameters

			# add entry to data
			$JsonData += $JsonEntry

			# convert data to JSON
			Try {
				$JsonValue = $JsonData | Sort-Object -Property 'Path', 'Destination' | ConvertTo-Json -Depth 100
			}
			Catch {
				Write-Warning 'could not convert object to JSON'
				Return $_
			}

			# update JSON file
			Try {
				$JsonValue | Set-Content -Path $Json
			}
			Catch {
				Write-Warning "could not add entry to configuration file: '$Json'"
				Return $_
			}

			# report entry added
			Write-Host "Added entry for '$Path' path and '$Destination' destination to configuration file: '$Json'"

			# display current entries if verbose
			If ($VerbosePreference -eq 'Continue') { $JsonValue | Format-List }
		}
		# process entries in configuration file
		Default {
			# check entry count in configuration file
			If ($JsonData.Count -eq 0) {
				Write-Warning -Message "no entries found in configuration file: '$Json'"
				Return
			}

			# process configuration file
			:NextJsonEntry ForEach ($JsonEntry in $JsonData) {
				# validate values present in JSON file
				Switch ($true) {
					([string]::IsNullOrEmpty($JsonEntry.Path)) {
						Write-Warning -Message "required entry (Path) not found in configuration file: $Json"
						Continue NextJsonEntry
					}
					([string]::IsNullOrEmpty($JsonEntry.Destination)) {
						Write-Warning -Message "required entry (Destination) not found in configuration file: $Json"
						Continue NextJsonEntry
					}
					([string]::IsNullOrEmpty($JsonEntry.Direction)) {
						Write-Warning -Message "required entry (Direction) not found in configuration file: $Json"
						Continue NextJsonEntry
					}
				}

				# define required parameters for Sync-ItemsInPathWithDestination
				$SyncItemsInPathWithDestination = @{
					Path              = $JsonEntry.Path
					Destination       = $JsonEntry.Destination
					Direction         = $JsonEntry.Direction
					Purge             = $JsonEntry.Purge
					Recurse           = $JsonEntry.Recurse
					CheckHash         = $JsonEntry.CheckHash
					SkipDelete        = $JsonEntry.SkipDelete
					SkipExisting      = $JsonEntry.SkipExisting
					SkipFiles         = $JsonEntry.SkipFiles
					CreatePath        = $JsonEntry.CreatePath
					CreateDestination = $JsonEntry.CreateDestination
					LastSyncTime      = $JsonEntry.LastSyncTime
					Updated           = $JsonEntry.Updated
				}

				# defined optional parameters for Sync-ItemsInPathWithDestination
				If ($VerbosePreference -eq 'Continue') {
					$SyncItemsInPathWithDestination['Verbose'] = $true
				}

				# define optional parameters for Sync-ItemsInPathWithDestination
				If ($WhatIfPreference -eq $true) {
					$SyncItemsInPathWithDestination['WhatIf'] = $true
				}

				# sync items in path with destination
				Try {
					Sync-ItemsInPathWithDestination @SyncItemsInPathWithDestination
				}
				Catch {
					Return $_
				}
			}
		}
	}
}
