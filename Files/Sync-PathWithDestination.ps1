<#
.SYNOPSIS
Synchronize files and directories in a source path with a destination path.

.DESCRIPTION
Synchronize files and directories in a source path with a destination path based upon runtime parameters.

.PARAMETER Path
The path of the source directory.

.PARAMETER Destination
The path of the target directory.

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
Switch to compare files using Get-FileHash instead of the LastWriteTimeUtc attribute.

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

.PARAMETER LastSyncTimeMethod
String parameter to define the method to retrieve and store the last sync time. The permitted values are 'Json' and 'Stream' with the latter as the default value.

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
	# purge target path before copying
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
	# define method to retrieve and store last sync time
	[ValidateSet('Json', 'Stream')]
	[string]$LastSyncTimeMethod = 'Stream',
	# path to JSON file containing last sync time
	[ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$JsonFilePath,
	# datetime minimum value in UTC
	[datetime]$DatetTimeMinValueUtc = [datetime]::new([UInt64]0,[System.DateTimeKind]::Utc),
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
	Function Get-DateTimeFromJson {
		Param(
			# path to JSON file
			[Parameter(Mandatory)]
			[string]$Json,

			# name of property in JSON string containing ticks for datetime
			[Parameter(Mandatory)]
			[string]$Property
		)

		# if JSON file not found...
		If (![System.IO.File]::Exists($Json)) {
			Write-Warning -Message "could not locate '$Json' JSON file: $($_.Exception.ToString())"
			Return $null
		}

		# retrieve content from JSON file
		Try {
			$JsonContent = Get-Content -Path $Json
		}
		Catch {
			Write-Warning -Message "could not retrieve content from '$Json' JSON file: $($_.Exception.ToString())"
			Return $null
		}

		# if content is null...
		If ($null -eq $JsonContent) {
			# return $null
			Return $null
		}

		# convert content from JSON
		Try {
			$JsonObject = ConvertFrom-Json -InputObject $JsonContent -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not convert content of '$Json' JSON file: $($_.Exception.ToString())"
			Return $null
		}

		# if object missing requested property...
		If (!$JsonObject.PSObject.Properties.Name.Contains($Property)) {
			# warn and return null
			Write-Warning -Message "could not locate '$Property' property on JSON object in '$Json' JSON file: $($_.Exception.ToString())"
			Return $null
		}

		# if requested property cannot be parsed as 64-bit unsigned integer...
		If (![uint64]::TryParse($JsonObject.$Property, [ref][uint64]::MinValue)) {
			Write-Warning -Message "could not parse '$($JsonObject.$Property)' value to uint64 in '$Property' property on JSON object in '$Json' JSON file: $($_.Exception.ToString())"
			Return $null
		}

		# create timespan from requested property
		Try {
			$TimeSpan = [timespan]::FromTicks($JsonObject.$Property)
		}
		Catch {
			Write-Warning -Message "could not create timespan from '$($JsonObject.$Property)' value in '$Property' property on JSON object in '$Json' JSON file: $($_.Exception.ToString())"
			Return $null
		}

		# create datetime from timespan
		Try {
			$DateTime = [datetime]::MinValue.Add($TimeSpan)
		}
		Catch {
			Write-Warning -Message "could not create datetime from '$($JsonObject.$Property)' value in '$Property' property on JSON object in '$Json' JSON file: $($_.Exception.ToString())"
			Return $null
		}

		# return datetime
		Return $DateTime
	}

	Function Get-DateTimeFromStream {
		Param(
			# path to file system object with stream
			[Parameter(Mandatory)]
			[string]$Path,

			# name of stream on file system object
			[Parameter(Mandatory)]
			[string]$Stream,

			# name of property in JSON string stored in stream
			[Parameter(Mandatory)]
			[string]$Property
		)

		# if path not found...
		If (![System.IO.Directory]::Exists($Path)) {
			# return $null
			Return $null
		}

		# get content from named stream on object
		[string]$JsonContent = Get-Content -Path $Path -Stream $Stream -ErrorAction 'Ignore'

		# if content is null...
		If ([string]::IsNullOrEmpty($JsonContent)) {
			# return null
			Write-Warning -Message "could not locate content in '$Stream' stream on '$Path' path"
			Return $null
		}

		# convert content from JSON
		Try {
			$JsonObject = ConvertFrom-Json -InputObject $JsonContent -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not convert content of '$Stream' stream on '$Path' path: $($_.Exception.ToString())"
			Return $null
		}

		# if object missing requested property...
		If (!$JsonObject.PSObject.Properties.Name.Contains($Property)) {
			# warn and return null
			Write-Warning -Message "could not locate '$Property' property on JSON object in '$Stream' stream on '$Path' path: $($_.Exception.ToString())"
			Return $null
		}

		# if requested property cannot be parsed as 64-bit unsigned integer...
		If (![uint64]::TryParse($JsonObject.$Property, [ref][uint64]::MinValue)) {
			Write-Warning -Message "could not parse '$($JsonObject.$Property)' value to uint64 in '$Property' property on JSON object in '$Stream' stream on '$Path' path: $($_.Exception.ToString())"
			Return $null
		}

		# create timespan from requested property
		Try {
			$TimeSpan = [timespan]::FromTicks($JsonObject.$Property)
		}
		Catch {
			Write-Warning -Message "could not create timespan from '$($JsonObject.$Property)' value in '$Property' property on JSON object in '$Stream' stream on '$Path' path: $($_.Exception.ToString())"
			Return $null
		}

		# create datetime from timespan
		Try {
			$DateTime = [datetime]::MinValue.Add($TimeSpan)
		}
		Catch {
			Write-Warning -Message "could not create datetime from '$($JsonObject.$Property)' value in '$Property' property on JSON object in '$Stream' stream on '$Path' path: $($_.Exception.ToString())"
			Return $null
		}

		# return datetime
		Return $DateTime
	}

	Function Write-DateTimeToJson {
		Param(
			# path to JSON file
			[Parameter(Mandatory)]
			[string]$Json,

			# name of property in JSON to store datetime as ticks
			[Parameter(Mandatory)]
			[string]$Property,

			# datetime to store in JSON
			[Parameter(Mandatory)]
			[datetime]$DateTime
		)

		# if JSON file not found...
		If (![System.IO.File]::Exists($Json)) {
			Try {
				$null = New-Item -ItemType File -Path $Json -Force -ErrorAction Stop
			}
			Catch {
				Write-Warning -Message "could not create '$Json' JSON file: $($_.Exception.ToString())"
				Throw $_
			}
		}

		# retrieve content from named stream on object
		Try {
			$JsonContent = Get-Content -Path $Json -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not retrieve content from '$Json' JSON file: $($_.Exception.ToString())"
			Return $null
		}

		# if content is null...
		If ([string]::IsNullOrEmpty($JsonContent)) {
			# create custom object
			$JsonObject = [pscustomobject]@{
				$Property = $DateTime.Ticks
			}
		}
		# if content is not null...
		Else {
			# convert content from JSON
			Try {
				$JsonObject = ConvertFrom-Json -InputObject $JsonContent -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not convert existing content of '$Json' JSON file: $($_.Exception.ToString())"
				Return
			}

			# update object with datetime value
			Try {
				Add-Member -InputObject $JsonObject -MemberType NoteProperty -Name $Property -Value $DateTime.Ticks -Force -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not update existing content of '$Json' JSON file: $($_.Exception.ToString())"
				Return
			}
		}

		# convert object to JSON
		Try {
			$Value = ConvertTo-Json -InputObject $JsonObject -Depth 100 -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not convert object to JSON for '$Json' JSON file: $($_.Exception.ToString())"
			Throw $_
		}

		# retrieve content from saved sync time path
		Try {
			Set-Content -Path $Json -Value $Value -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not store datetime in '$Property' property in '$Json' JSON file: $($_.Exception.ToString())"
			Throw $_
		}
	}

	Function Write-DateTimeToStream {
		Param(
			# path to file system object with stream
			[Parameter(Mandatory)]
			[string]$Path,

			# name of stream on file system object
			[Parameter(Mandatory)]
			[string]$Stream,

			# name of property in JSON string in stream
			[Parameter(Mandatory)]
			[string]$Property,

			# datetime to store in JSON string in stream
			[Parameter(Mandatory)]
			[datetime]$DateTime
		)

		# get content from named stream on object
		Try {
			$JsonContent = Get-Content -Path $Path -Stream $Stream -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not retrieve '$Stream' stream on '$Path' path: $($_.Exception.ToString())"
			Return $null
		}

		# if content is null...
		If ([string]::IsNullOrEmpty($JsonContent)) {
			# create custom object
			$JsonObject = [pscustomobject]@{
				$Property = $DateTime.Ticks
			}
		}
		# if content is not null...
		Else {
			# convert content from JSON
			Try {
				$JsonObject = ConvertFrom-Json -InputObject $JsonContent -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not convert content of '$Stream' stream on '$Path' path: $($_.Exception.ToString())"
				Return
			}

			# update object with datetime value
			Try {
				Add-Member -InputObject $JsonObject -MemberType NoteProperty -Name $Property -Value $DateTime.Ticks -Force -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not update content of '$Stream' stream on '$Path' path: $($_.Exception.ToString())"
				Return
			}
		}

		# convert object to JSON
		Try {
			$Value = ConvertTo-Json -InputObject $JsonObject -Depth 100 -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not convert object to JSON for '$Path' path: $($_.Exception.ToString())"
			Throw $_
		}

		# retrieve content from saved sync time path
		Try {
			Set-Content -Path $Path -Stream $Stream -Value $Value -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not store datetime in '$Stream' stream for '$Path' path: $($_.Exception.ToString())"
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
			[uint64]$LastSyncDateTime = [datetime]::MinValue.Ticks,
			[Parameter()]
			[uint64]$CurrentSyncDateTime = [datetime]::UtcNow.Ticks
		)

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
			$NewSourceFolders = $SourceFolders | Where-Object { $_.LastWriteTimeUtc.Ticks -ge $LastSyncDateTime.Ticks } | Select-Object -ExpandProperty 'FullName'
			$NewTargetFolders = $TargetFolders | Where-Object { $_.LastWriteTimeUtc.Ticks -ge $LastSyncDateTime.Ticks } | Select-Object -ExpandProperty 'FullName'

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
			$NewSourceFiles = $SourceItems | Where-Object { $_.LastWriteTimeUtc.Ticks -ge $LastSyncDateTime.Ticks } | Select-Object -ExpandProperty 'FullName'
			$NewTargetFiles = $TargetItems | Where-Object { $_.LastWriteTimeUtc.Ticks -ge $LastSyncDateTime.Ticks } | Select-Object -ExpandProperty 'FullName'

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
					If ($MatchedSourceItem.LastWriteTimeUtc -eq $MatchedTargetItem.LastWriteTimeUtc) {
						Write-Host "Skipping '$MatchedSourcePath' as '$MatchedTargetPath' has same LastWriteTimeUtc"
						Continue
					}
				}
				# copy file from Path to Destination if newer or Direction is not 'Both'
				If ($MatchedSourceItem.LastWriteTimeUtc -gt $MatchedTargetItem.LastWriteTimeUtc -or $Direction -ne 'Both') {
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
				ElseIf ($MatchedSourceItem.LastWriteTimeUtc -lt $MatchedTargetItem.LastWriteTimeUtc -and $Direction -eq 'Both') {
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
			$OldSourceFiles = $SourceItems | Where-Object { $_.LastWriteTimeUtc.Ticks -lt $LastSyncDateTime.Ticks } | Select-Object -ExpandProperty 'FullName'
			$OldTargetFiles = $TargetItems | Where-Object { $_.LastWriteTimeUtc.Ticks -lt $LastSyncDateTime.Ticks } | Select-Object -ExpandProperty 'FullName'

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
			$OldSourceFolders = $SourceFolders | Where-Object { $_.LastWriteTimeUtc.Ticks -lt $LastSyncDateTime.Ticks } | Select-Object -ExpandProperty 'FullName'
			$OldTargetFolders = $TargetFolders | Where-Object { $_.LastWriteTimeUtc.Ticks -lt $LastSyncDateTime.Ticks } | Select-Object -ExpandProperty 'FullName'

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

		# return current sync time
		Return $CurrentSyncDateTime
	}
}

Process {
	# resolve preset to parameters
	Try {
		Resolve-PresetToParameters
	}
	Catch {
		Write-Warning -Message "could not resolve '$Preset' preset to parameters: $($_.Exception.ToString())"
		Throw $_
	}

	# if Path is not an absolute path...
	If (![System.IO.Path]::IsPathRooted($Path)) {
		# get unresolved absolute path
		Try {
			$Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
		}
		Catch {
			Write-Warning -Message "could not create absolute path from the provided '$Path' Path: $($_.Exception.ToString())"
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
			Write-Warning -Message "could not trim Path: $($_.Exception.ToString())"
			Throw $_
		}
	}

	# if Destination is not an absolute path...
	If (![System.IO.Path]::IsPathRooted($Destination)) {
		# get unresolved absolute path
		Try {
			$Destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
		}
		Catch {
			Write-Warning -Message "could not create absolute path from the provided '$Destination' Destination: $($_.Exception.ToString())"
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
			Write-Warning -Message "could not trim Destination: $($_.Exception.ToString())"
			Throw $_
		}
	}

	# if SkipDelete not requested...
	If (!$SkipDelete) {
		# retrieve command name from call stack
		If ([string]::IsNullOrEmpty((Get-PSCallStack)[0].ScriptName)) {
			$CommandName = (Get-PSCallStack)[0].Command -replace '^<|>$'
		}
		Else {
			$CommandName = [System.IO.FileInfo]::new((Get-PSCallStack)[0].ScriptName).BaseName
		}

		# define instance name using Hostname, Path, and Destination parameters
		$InstanceName = '{0}:{1}=>{2}' -f $Hostname, $Path, $Destination

		# obscure instance name; get byte array of instance string as hex string then hash
		Try {
			$InstanceHash = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($InstanceName))).Replace('-', $null)
		}
		Catch {
			Write-Warning -Message "could not create hash of '$InstanceName' instance name: $($_.Exception.ToString())"
			Return $_
		}

		# if operating system is not Windows...
		If ([System.Environment]::OSVersion.Platform -ne 'Win32NT') {
			# if LastSyncTimeMethod defined and value set to Stream...
			If ($PSBoundParameters.ContainsKey('LastSyncTimeMethod') -and $LastSyncTimeMethod -eq 'Stream') {
				# warn user that LastSyncTimeMethod must be swapped to Json
				Write-Warning -Message "The 'Stream' LastSyncTimeMethod method is limited to Windows. Switch to 'Json' method for a non-Windows platform?" -WarningAction Inquire
			}
			# switch LastSyncTimeMethod to Json
			$LastSyncTimeMethod = 'Json'
		}

		# if JSON method for last sync time was requested...
		If ($LastSyncTimeMethod -eq 'Json') {
			# if JSON file path was not provided...
			If (!$PSBoundParameters.ContainsKey('JsonFilePath')) {
				# define folder for JSON file; default is common application data folder
				$JsonFolderPath = [System.Environment]::GetFolderPath('CommonApplicationData')

				# define path for JSON file; default is file named for script in the common application data folder
				$JsonFilePath = Join-Path -Path $JsonFolderPath -ChildPath "$CommandName.json"
			}

			# retrieve datetime from JSON file
			Try {
				$DateTimeFromJson = Get-DateTimeFromJson -Json $JsonFilePath -Property $InstanceHash
			}
			Catch {
				Return $_
			}

			# if datetime object not retrieved from JSON file...
			If (!$DateTimeFromJson) {
				# warn and set last sync time to zero
				Write-Warning -Message "could not locate datetime value in '$InstanceHash' property in '$JsonFilePath' JSON file; will sync without last sync time"
				$LastSyncDateTime = $DatetTimeMinValueUtc
			}
			# if datetime object retrieved from JSON file...
			Else {
				# set last sync time to ticks of datetime from JSON file...
				Write-Verbose -Message "found datetime value in '$InstanceHash' property in '$JsonFilePath' JSON file; will sync with last sync time: $($DateTimeFromJson.ToUniversalTime().ToString('o'))"
				$LastSyncDateTime = $DateTimeFromJson
			}
		}

		# if Stream method for last sync time was requested...
		If ($LastSyncTimeMethod -eq 'Stream') {
			# retrieve datetime from named stream on Path
			Try {
				$DateTimeFromPath = Get-DateTimeFromStream -Path $Path -Stream $CommandName -Property $InstanceHash
			}
			Catch {
				Return $_
			}

			# retrieve datetime from named stream on Destination
			Try {
				$DateTimeFromDestination = Get-DateTimeFromStream -Path $Destination -Stream $CommandName -Property $InstanceHash
			}
			Catch {
				Return $_
			}

			# if datetime objects not retrieved from Path or Destination...
			If (!$DateTimeFromPath -and !$DateTimeFromDestination) {
				# warn and set last sync time to zero
				Write-Warning -Message "could not locate datetime values in '$InstanceHash' property in '$CommandName' stream on provided Path and Destination; will initialize with current datetime after sync"
				$LastSyncDateTime = $DatetTimeMinValueUtc
			}
			# if datetime objects not retrieved from Path...
			ElseIf (!$DateTimeFromPath) {
				# warn and set last sync time to zero
				Write-Warning -Message "could not locate datetime value in '$InstanceHash' property in '$CommandName' stream on provided Path; will sync without last sync time"
				$LastSyncDateTime = $DatetTimeMinValueUtc
			}
			# if datetime objects not retrieved from Destination...
			ElseIf (!$DateTimeFromDestination) {
				# warn and set last sync time to zero
				Write-Warning -Message "could not locate datetime value in '$InstanceHash' property in '$CommandName' stream on provided Destination; will sync without last sync time"
				$LastSyncDateTime = $DatetTimeMinValueUtc
			}
			# if datetime objects do not match...
			ElseIf ($DateTimeFromPath -ne $DateTimeFromDestination) {
				# warn and set last sync time to zero
				Write-Warning -Message "found different datetime values in '$InstanceHash' property in '$CommandName' stream on provided Path and Destination; will sync without last sync time"
				$LastSyncDateTime = $DatetTimeMinValueUtc
			}
			# if datetime objects match...
			Else {
				# set last sync time to ticks of datetime from path
				Write-Verbose -Message "found matching datetime values in '$InstanceHash' property in '$CommandName' stream on provided Path and Destination; will sync with last sync time: $($DateTimeFromPath.ToUniversalTime().ToString('o'))"
				$LastSyncDateTime = $DateTimeFromPath
			}
		}
	}
	# if SkipDelete was requested...
	Else {
		# set last sync time to zero
		$LastSyncDateTime = $DatetTimeMinValueUtc
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
		LastSyncDateTime  = $LastSyncDateTime
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
		$DateTimeFromSync = Sync-ItemsInPathWithDestination @SyncItemsInPathWithDestination
	}
	Catch {
		Write-Warning -Message 'could not sync path with destination'
		Return $_
	}

	# if SkipDelete not requested...
	If (!$SkipDelete) {
		# if JSON method for last sync time was requested...
		If ($LastSyncTimeMethod -eq 'Json') {
			# write datetime to JSON file
			Try {
				Write-DateTimeToJson -Path $JsonFilePath -Property $InstanceHash -DateTime $DateTimeFromSync
			}
			Catch {
				Return $_
			}
		}

		# if Stream method for last sync time was requested...
		If ($LastSyncTimeMethod -eq 'Stream') {
			# save datetime to named stream on Path
			Try {
				Write-DateTimeToStream -Path $Path -Stream $CommandName -Property $InstanceHash -DateTime $DateTimeFromSync
			}
			Catch {
				Return $_
			}

			# save datetime to named stream on Destination
			Try {
				Write-DateTimeToStream -Path $Destination -Stream $CommandName -Property $InstanceHash -DateTime $DateTimeFromSync
			}
			Catch {
				Return $_
			}
		}
	}
}
