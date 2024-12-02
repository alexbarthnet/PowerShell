<#
.SYNOPSIS
Synchronize files and directories in a source path with a destination path.

.DESCRIPTION
Synchronize files and directories in a source path with a destination path based upon runtime parameters or settings from a JSON file.

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
Specifies the direction of the synchronization:
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

.PARAMETER UseSavedSyncTime
Switch parameter to use a saved sync time file.

.INPUTS
None. Sync-PathWithDestination does not accept pipeline input.

.OUTPUTS
None. The script merely reports on actions taken and does not provide any actionable output.

.EXAMPLE
To be added...
#>

[CmdletBinding(SupportsShouldProcess)]
Param(
	# source path
	[Parameter(Position = 0, Mandatory = $True)]
	[ValidatePattern('^[^\*]+$')]
	[string]$Path,
	# target path
	[Parameter(Position = 1, Mandatory = $True)]
	[ValidatePattern('^[^\*]+$')]
	[string]$Destination,
	# preset for Direction, SkipExisting, SkipDelete
	[ValidateSet('Sync', 'Contribute', 'Mirror', 'Merge')]
	[string]$Preset = 'Sync',
	# sync direction
	[ValidateSet('Both', 'Forward', 'Reverse')]
	[string]$Direction = 'Both',
	# purge destination
	[switch]$Purge,
	# include child items
	[switch]$Recurse,
	# compare files with Get-FileHash
	[switch]$CheckHash,
	# do not delete mismatched files and folders
	[switch]$SkipDelete,
	# do not compare existing files and folders
	[switch]$SkipExisting,
	# do not compare files
	[switch]$SkipFiles,
	# create source path if missing
	[switch]$CreatePath,
	# create target path if missing
	[switch]$CreateDestination,
	# script parameter - use saved sync time files
	[switch]$UseSavedSyncTime,
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
	Function Get-SavedSyncTime {
		Param(
			# source path for sync
			[Parameter(Mandatory)]
			[string]$Path,
			
			# target path for sync
			[Parameter(Mandatory)]
			[string]$Destination,

			# define instance name from Path and Destination parameters
			[string]$SavedSyncTimeSet = [string]::Join('=>', $Path, $Destination),

			# get hash of byte array of instance string as hex string
			[string]$SavedSyncTimeName = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($SavedSyncTimeSet))).Replace('-', $null),

			# root folder for text output folders; default is common application data folder
			[string]$SavedSyncTimeRoot = [System.Environment]::GetFolderPath('CommonApplicationData'),

			# leaf folder for text output folders; default is 'PowerShell_SavedSyncTime'
			[string]$SavedSyncTimeLeaf = ((Get-PSCallStack)[0].Command -replace '^<|\.ps1$|>$'),

			# base folder for text output folders; default is text output leaf folder in common application data folder
			[string]$SavedSyncTimeBase = (Join-Path -Path $SavedSyncTimeRoot -ChildPath $SavedSyncTimeLeaf),

			# path for text output files; default is named folder under 'PowerShell_SavedSyncTime' folder in common application data folder
			[string]$SavedSyncTimePath = (Join-Path -Path $SavedSyncTimeBase -ChildPath $SavedSyncTimeName)
		)

		# if saved sync time base not found...
		If (![System.IO.Directory]::Exists($SavedSyncTimeBase)) {
			Try {
				$null = New-Item -ItemType Directory -Path $SavedSyncTimeBase -ErrorAction Stop
			}
			Catch {
				Write-Warning -Message "could not create saved sync time folder: $SavedSyncTimeBase"
				Throw $_
			}
		}

		# if saved sync time path not found...
		If (![System.IO.File]::Exists($SavedSyncTimePath)) {
			Try {
				$null = New-Item -ItemType File -Path $SavedSyncTimePath -ErrorAction Stop
			}
			Catch {
				Write-Warning -Message "could not create saved sync time file: $SavedSyncTimePath"
				Throw $_
			}
		}

		# retrieve content from saved sync time path
		Try {
			$SavedSyncTimeText = Get-Content -Path $SavedSyncTimePath
		}
		Catch {
			Write-Warning -Message "could not retrieve saved sync time from file: $SavedSyncTimePath"
			Throw $_
		}

		# if content is null...
		If ([string]::IsNullOrEmpty($SavedSyncTimeText)) {
			# return 0
			Return [uint64]::MinValue
		}
		
		# if content cannot be parsed as uint64...
		If (![uint64]::TryParse($SavedSyncTimeText, [ref][uint64]::MinValue)) {
			# warn and throw
			Write-Warning -Message "could not create unsigned 64-bit integer from saved sync time value: $SavedSyncTimeText"
			Throw $_
		}

		# parse content and return
		Return [uint64]::Parse($SavedSyncTimeText)
	}

	Function Set-SavedSyncTime {
		Param(
			# file ticks of last sync time
			[Parameter(Mandatory)]
			[uint64]$SyncTime,

			# source path for sync
			[Parameter(Mandatory)]
			[string]$Path,
			
			# target path for sync
			[Parameter(Mandatory)]
			[string]$Destination,

			# define instance name from Path and Destination parameters
			[string]$SavedSyncTimeSet = [string]::Join('=>', $Path, $Destination),

			# get hash of byte array of instance string as hex string
			[string]$SavedSyncTimeName = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($SavedSyncTimeSet))).Replace('-', $null),

			# root folder for text output folders; default is common application data folder
			[string]$SavedSyncTimeRoot = [System.Environment]::GetFolderPath('CommonApplicationData'),

			# leaf folder for text output folders; default is 'PowerShell_SavedSyncTime'
			[string]$SavedSyncTimeLeaf = ((Get-PSCallStack)[0].Command -replace '^<|\.ps1$|>$'),

			# base folder for text output folders; default is text output leaf folder in common application data folder
			[string]$SavedSyncTimeBase = (Join-Path -Path $SavedSyncTimeRoot -ChildPath $SavedSyncTimeLeaf),

			# path for text output files; default is named folder under 'PowerShell_SavedSyncTime' folder in common application data folder
			[string]$SavedSyncTimePath = (Join-Path -Path $SavedSyncTimeBase -ChildPath $SavedSyncTimeName)
		)

		# if saved sync time base not found...
		If (![System.IO.Directory]::Exists($SavedSyncTimeBase)) {
			Try {
				$null = New-Item -ItemType Directory -Path $SavedSyncTimeBase -ErrorAction Stop
			}
			Catch {
				Write-Warning -Message "could not create saved sync time folder: $SavedSyncTimeBase"
				Throw $_
			}
		}

		# if saved sync time path not found...
		If (![System.IO.File]::Exists($SavedSyncTimePath)) {
			Try {
				$null = New-Item -ItemType File -Path $SavedSyncTimePath -ErrorAction Stop
			}
			Catch {
				Write-Warning -Message "could not create saved sync time file: $SavedSyncTimePath"
				Throw $_
			}
		}

		# retrieve content from saved sync time path
		Try {
			Set-Content -Path $SavedSyncTimePath -Value $SyncTime
		}
		Catch {
			Write-Warning -Message "could not store sync time in file: $SavedSyncTimePath"
			Throw $_
		}
	}

	Function Resolve-PresetToParameters {
		# resolve Direction
		If (!$script:PSBoundParameters.ContainsKey('Direction')) {
			If ($script:Preset -eq 'Sync' -or $script:Preset -eq 'Merge') {
				$script:Direction = 'Both'
			}
			If ($script:Preset -eq 'Mirror' -or $script:Preset -eq 'Contribute' -or $script:Preset -eq 'Missing') {
				$script:Direction = 'Forward'
			}
		}

		# resolve SkipDelete
		If (!$script:PSBoundParameters.ContainsKey('SkipDelete')) {
			If ($script:Preset -eq 'Merge' -or $script:Preset -eq 'Contribute' -or $script:Preset -eq 'Missing') {
				$script:SkipDelete = $true
			}
			If ($script:Preset -eq 'Sync' -or $script:Preset -eq 'Mirror') {
				$script:SkipDelete = $false
			}
		}

		# resolve SkipExisting
		If (!$script:PSBoundParameters.ContainsKey('SkipExisting')) {
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

		# if last sync time had value...
		If ($LastSyncTime -gt 0) {
			# return current sync time
			Return $CurrentSyncTime
		}
	}
}

Process {
	# resolve preset to parameters
	Try {
		Resolve-PresetToParameters
	}
	Catch {
		Write-Warning -Message "could not resolve preset to parameters: '$Preset'"
		Throw $_
	}

	# if Path is not an absolute path...
	If (![System.IO.Path]::IsPathRooted($Path)) {
		# get unresolved absolute path
		Try {
			$Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
		}
		Catch {
			Write-Warning -Message "could not create absolute path from the provided Path parameter: $Path"
			Throw $_
		}

		# report absolute path
		Write-Warning -Message "converted relative path in provided Path parameter to absolute path: $Path"
	}

	# if Path ends with a backslash...
	If ($Path.EndsWith('\')) {
		# trim any trailing backslash from Path
		Try {
			$Path = $Path.TrimEnd('\')
		}
		Catch {
			Write-Warning -Message 'could not trim Path'
			Throw $_
		}
	}

	# if Destination is not an absolute path...
	If (![System.IO.Path]::IsPathRooted($Destination)) {
		# get unresolved absolute path
		Try {
			$Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
		}
		Catch {
			Write-Warning -Message "could not create absolute path from the provided Destination parameter: $Destination"
			Throw $_
		}

		# report absolute path
		Write-Warning -Message "converted relative path in provided Destination parameter to absolute path: $Destination"
	}

	# if Destination ends with a backslash...
	If ($Destination.EndsWith('\')) {
		# trim any trailing backslash from Destination
		Try {
			$Destination = $Destination.TrimEnd('\')
		}
		Catch {
			Write-Warning -Message 'could not trim Destination'
			Throw $_
		}
	}

	# if UseSavedSyncTime was requested...
	If ($UseSavedSyncTime) {
		# retrieve last sync time
		Try {
			$LastSyncTime = Get-SavedSyncTime -Path $Path -Destination $Destination
		}
		Catch {
			Write-Warning -Message "could not retrieve saved sync time for '$Path' path and '$Destination' destination"
			Return $_
		}
	}
	# if UseSavedSyncTime was not requested...
	Else {
		# set last sync time to zero
		$LastSyncTime = 0
	}

	# define required parameters for Sync-ItemsInPathWithDestination
	$SyncItemsInPathWithDestination = [ordered]@{
		Path              = $Path
		Destination       = $Destination
		Direction         = $Direction
		Purge             = $Purge -as [System.Boolean]
		Recurse           = $Recurse -as [System.Boolean]
		CheckHash         = $CheckHash -as [System.Boolean]
		SkipDelete        = $SkipDelete -as [System.Boolean]
		SkipExisting      = $SkipExisting -as [System.Boolean]
		SkipFiles         = $SkipFiles -as [System.Boolean]
		CreatePath        = $CreatePath -as [System.Boolean]
		CreateDestination = $CreateDestination -as [System.Boolean]
		LastSyncTime      = $LastSyncTime
	}

	# define optional parameters for Sync-ItemsInPathWithDestination
	If ($VerbosePreference -eq 'Continue') {
		$SyncItemsInPathWithDestination['Verbose'] = $true
	}

	# define optional parameters for Sync-ItemsInPathWithDestination
	If ($WhatIfPreference -eq $true) {
		$SyncItemsInPathWithDestination['WhatIf'] = $true
	}

	# sync items in path with destination
	Try {
		$SyncTime = Sync-ItemsInPathWithDestination @SyncItemsInPathWithDestination
	}
	Catch {
		Write-Warning -Message 'could not sync path with destination'
		Return $_
	}

	# if UseSavedSyncTime was requested...
	If ($UseSavedSyncTime) {
		# update last sync time
		Try {
			Set-SavedSyncTime -Path $Path -Destination $Destination -SyncTime $SyncTime
		}
		Catch {
			Write-Warning -Message "could not retrieve saved sync time for '$Path' path and '$Destination' destination"
			Return $_
		}
	}
}
