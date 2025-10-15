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
String parameter to specify multiple parameters from a single value:
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
	# define time started
	$TimeStarted = [System.DateTime]::Now

	# define counters
	$PathsCreatedInSource = [System.Collections.Generic.SortedSet[System.String]]::new()
	$PathsCreatedInTarget = [System.Collections.Generic.SortedSet[System.String]]::new()

	$PathsCheckedInSource = [System.Collections.Generic.SortedSet[System.String]]::new()
	$PathsCheckedInTarget = [System.Collections.Generic.SortedSet[System.String]]::new()

	$FilesCreatedInSource = [System.Collections.Generic.SortedSet[System.String]]::new()
	$FilesCreatedInTarget = [System.Collections.Generic.SortedSet[System.String]]::new()

	$FilesCheckedInSource = [System.Collections.Generic.SortedSet[System.String]]::new()
	$FilesCheckedInTarget = [System.Collections.Generic.SortedSet[System.String]]::new()

	$FilesUpdatedInSource = [System.Collections.Generic.SortedSet[System.String]]::new()
	$FilesUpdatedInTarget = [System.Collections.Generic.SortedSet[System.String]]::new()

	$FilesRemovedInSource = [System.Collections.Generic.SortedSet[System.String]]::new()
	$FilesRemovedInTarget = [System.Collections.Generic.SortedSet[System.String]]::new()

	$PathsRemovedInSource = [System.Collections.Generic.SortedSet[System.String]]::new()
	$PathsRemovedInTarget = [System.Collections.Generic.SortedSet[System.String]]::new()

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
			Write-Warning -Message "could not locate '$Json' JSON file: $($_.Exception.Message)"
			Return $null
		}

		# retrieve content from JSON file
		Try {
			$JsonContent = Get-Content -Path $Json
		}
		Catch {
			Write-Warning -Message "could not retrieve content from '$Json' JSON file: $($_.Exception.Message)"
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
			Write-Warning -Message "could not convert content of '$Json' JSON file: $($_.Exception.Message)"
			Return $null
		}

		# if object missing requested property...
		If (!$JsonObject.PSObject.Properties.Name.Contains($Property)) {
			# warn and return null
			Write-Warning -Message "could not locate '$Property' property on JSON object in '$Json' JSON file: $($_.Exception.Message)"
			Return $null
		}

		# if requested property cannot be parsed as 64-bit unsigned integer...
		If (![uint64]::TryParse($JsonObject.$Property, [ref][uint64]::MinValue)) {
			Write-Warning -Message "could not parse '$($JsonObject.$Property)' value to uint64 in '$Property' property on JSON object in '$Json' JSON file: $($_.Exception.Message)"
			Return $null
		}

		# create datetime from timespan
		Try {
			$DateTime = [datetime]::new([UInt64]$JsonObject.$Property,[System.DateTimeKind]::Utc)
		}
		Catch {
			Write-Warning -Message "could not create datetime from '$($JsonObject.$Property)' value in '$Property' property on JSON object in '$Json' JSON file: $($_.Exception.Message)"
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
			Write-Warning -Message "could not convert content of '$Stream' stream on '$Path' path: $($_.Exception.Message)"
			Return $null
		}

		# if object missing requested property...
		If (!$JsonObject.PSObject.Properties.Name.Contains($Property)) {
			# warn and return null
			Write-Warning -Message "could not locate '$Property' property on JSON object in '$Stream' stream on '$Path' path: $($_.Exception.Message)"
			Return $null
		}

		# if requested property cannot be parsed as 64-bit unsigned integer...
		If (![uint64]::TryParse($JsonObject.$Property, [ref][uint64]::MinValue)) {
			Write-Warning -Message "could not parse '$($JsonObject.$Property)' value to uint64 in '$Property' property on JSON object in '$Stream' stream on '$Path' path: $($_.Exception.Message)"
			Return $null
		}

		# create datetime from timespan
		Try {
			$DateTime = [datetime]::new([UInt64]$JsonObject.$Property,[System.DateTimeKind]::Utc)
		}
		Catch {
			Write-Warning -Message "could not create datetime from '$($JsonObject.$Property)' value in '$Property' property on JSON object in '$Stream' stream on '$Path' path: $($_.Exception.Message)"
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
				Write-Warning -Message "could not create '$Json' JSON file: $($_.Exception.Message)"
				Throw $_
			}
		}

		# retrieve content from named stream on object
		Try {
			$JsonContent = Get-Content -Path $Json -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not retrieve content from '$Json' JSON file: $($_.Exception.Message)"
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
				Write-Warning -Message "could not convert existing content of '$Json' JSON file: $($_.Exception.Message)"
				Return
			}

			# update object with datetime value
			Try {
				Add-Member -InputObject $JsonObject -MemberType NoteProperty -Name $Property -Value $DateTime.Ticks -Force -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not update existing content of '$Json' JSON file: $($_.Exception.Message)"
				Return
			}
		}

		# convert object to JSON
		Try {
			$Value = ConvertTo-Json -InputObject $JsonObject -Depth 100 -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not convert object to JSON for '$Json' JSON file: $($_.Exception.Message)"
			Throw $_
		}

		# retrieve content from saved sync time path
		Try {
			Set-Content -Path $Json -Value $Value -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not store datetime in '$Property' property in '$Json' JSON file: $($_.Exception.Message)"
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
		[string]$JsonContent = Get-Content -Path $Path -Stream $Stream -ErrorAction 'Ignore'

		# if content is null...
		If ([string]::IsNullOrEmpty($JsonContent)) {
			# create custom object
			$JsonObject = [pscustomobject]@{ $Property = $DateTime.Ticks }
		}
		# if content is not null...
		Else {
			# convert content from JSON
			Try {
				$JsonObject = ConvertFrom-Json -InputObject $JsonContent -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not convert content of '$Stream' stream on '$Path' path: $($_.Exception.Message)"
				Return
			}

			# update object with datetime value
			Try {
				Add-Member -InputObject $JsonObject -MemberType NoteProperty -Name $Property -Value $DateTime.Ticks -Force -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not update content of '$Stream' stream on '$Path' path: $($_.Exception.Message)"
				Return
			}
		}

		# convert object to JSON
		Try {
			$Value = ConvertTo-Json -InputObject $JsonObject -Depth 100 -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not convert object to JSON for '$Path' path: $($_.Exception.Message)"
			Throw $_
		}

		# retrieve content from saved sync time path
		Try {
			Set-Content -Path $Path -Stream $Stream -Value $Value -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not store datetime in '$Stream' stream for '$Path' path: $($_.Exception.Message)"
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
			[datetime]$LastSyncDateTime = [datetime]::new([UInt64]0,[System.DateTimeKind]::Utc),
			[Parameter()]
			[datetime]$CurrentSyncDateTime = [datetime]::UtcNow
		)

		# report datetime values
		Write-Host "Datetime of this sync: $($CurrentSyncDateTime.ToString('o'))"
		Write-Host "Datetime of last sync: $($LastSyncDateTime.ToString('o'))"

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
				# create missing source folder
				If ($PSCmdlet.ShouldProcess($Path, 'create folder')) {
					Try {
						$Source = New-Item -ItemType 'Directory' -Path $Path -Verbose:$VerbosePreference | Select-Object -ExpandProperty 'FullName'
					}
					Catch {
						Write-Warning -Message "Could not create Path folder '$Path' on host"
						Return $_
					}

					# report state
					Write-Host "Created '$Path' on host with full path: $Source"
				}
				Else {
					# assign path to source for WhatIf 
					$Source = $Path
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
				# create missing source folder
				If ($PSCmdlet.ShouldProcess($Path, 'create folder')) {
					Try {
						$Target = New-Item -ItemType 'Directory' -Path $Destination -Verbose:$VerbosePreference | Select-Object -ExpandProperty 'FullName'
					}
					Catch {
						Write-Warning -Message "could not create Destination folder '$Destination' on host"
						Return $_
					}

					# report state
					Write-Host "Created '$Destination' on host with full path: $Target"
				}
				Else {
					# assign destination to target for WhatIf 
					$Target = $Destination
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
			# define sorted sets for relative paths
			$AllRelativeSourceFolders = [System.Collections.Generic.SortedSet[System.String]]::new()
			$AllRelativeTargetFolders = [System.Collections.Generic.SortedSet[System.String]]::new()
			$NewRelativeSourceFolders = [System.Collections.Generic.SortedSet[System.String]]::new()
			$NewRelativeTargetFolders = [System.Collections.Generic.SortedSet[System.String]]::new()
			$OldRelativeSourceFolders = [System.Collections.Generic.SortedSet[System.String]]::new()
			$OldRelativeTargetFolders = [System.Collections.Generic.SortedSet[System.String]]::new()

			# if source path found...
			If (Test-Path -Path $SourcePath -PathType Container) {
				# populate sorted set with relative path of new directory objects under source path
				try {
					Get-ChildItem -Path $SourcePath -Recurse -Directory | ForEach-Object { 
						# define relative path
						$RelativePath = $_.FullName.Replace($SourcePath, [System.String]::Empty)

						# add relative path to all set only
						$null = $AllRelativeSourceFolders.Add($RelativePath)

						# if last write time newer than last sync...
						If ($_.LastWriteTimeUtc.Ticks -ge $LastSyncDateTime.Ticks) {
							# add relative path to new set
							$null = $NewRelativeSourceFolders.Add($RelativePath)
						}
						# if last write time not newer than last sync...
						else {
							# add relative path to old set
							$null = $OldRelativeSourceFolders.Add($RelativePath)
						}
					}
				}
				catch {
					Write-Warning -Message "could not retrieve folders from path: '$SourcePath'"
					Return $_
				}
			}

			# if target path found...
			If (Test-Path -Path $TargetPath -PathType Container) {
				# populate sorted set with relative path of new directory objects under target path
				try {
					Get-ChildItem -Path $TargetPath -Recurse -Directory | ForEach-Object {
						# define relative path
						$RelativePath = $_.FullName.Replace($TargetPath, [System.String]::Empty)

						# add relative path to all set only
						$null = $AllRelativeSourceFolders.Add($RelativePath)

						# if last write time newer than last sync...
						If ($_.LastWriteTimeUtc.Ticks -ge $LastSyncDateTime.Ticks) {
							# add relative path to new set
							$null = $NewRelativeSourceFolders.Add($RelativePath)
						}
						# if last write time not newer than last sync...
						else {
							# add relative path to old set
							$null = $OldRelativeSourceFolders.Add($RelativePath)
						}
					}
				}
				catch {
					Write-Warning -Message "could not retrieve folders from path: '$TargetPath'"
					Return $_
				}
			}

			# retrieve folders in both Path and Destination
			$MatchedFolders = [System.Collections.Generic.SortedSet[System.String]]::new([System.Linq.Enumerable]::Intersect($AllRelativeSourceFolders, $AllRelativeTargetFolders))
			
			# create folders in Destination that are missing from Path
			If ($Direction -eq 'Forward' -or $Direction -eq 'Both') {
				# retrieve folders in Destination that are missing from Path
				$MissingRelativeTargetFolders = [System.Collections.Generic.SortedSet[System.String]]::new([System.Linq.Enumerable]::Except($NewRelativeSourceFolders, $MatchedFolders))

				# report count
				Write-Host "Found '$($MissingRelativeTargetFolders.Count)' folder(s) to create in path: '$TargetPath'"

				# loop through missing relative target folders
				ForEach ($MissingRelativeTargetFolder in $MissingRelativeTargetFolders) {
					# define missing target folder
					$MissingTargetFolder = Join-Path -Path $TargetPath -ChildPath $MissingRelativeTargetFolder

					# create missing target folder
					If ($PSCmdlet.ShouldProcess($MissingTargetFolder, 'create folder')) {
						Try {
							$null = New-Item -Path $MissingTargetFolder -ItemType 'Directory' -Force
						}
						Catch {
							Write-Warning "could not create folder '$MissingTargetFolder'"
							Return $_
						}
					}

					# add path to set
					$null = $PathsCreatedInTarget.Add($MissingRelativeTargetFolder)
				}
			}

			# create folders in Path that are missing from Destination
			If ($Direction -eq 'Both') {
				# retrieve folders in Path that are missing from Destination
				$MissingRelativeSourceFolders = [System.Collections.Generic.SortedSet[System.String]]::new([System.Linq.Enumerable]::Except($NewRelativeTargetFolders, $MatchedFolders))

				# report count
				Write-Host "Found '$($MissingRelativeSourceFolders.Count)' folder(s) to create in path: '$SourcePath'"

				# loop through missing relative source folders
				ForEach ($MissingRelativeSourceFolder in $MissingRelativeSourceFolders) {
					# define missing source folder
					$MissingSourceFolder = Join-Path -Path $SourcePath -ChildPath $MissingRelativeSourceFolder

					# create missing source folder
					If ($PSCmdlet.ShouldProcess($MissingSourceFolder, 'create folder')) {
						Try {
							$null = New-Item -Path $MissingSourceFolder -ItemType 'Directory' -Force
						}
						Catch {
							Write-Warning "could not create folder '$MissingSourceFolder'"
							Return $_
						}
					}

					# add path to set
					$null = $PathsCreatedInSource.Add($MissingRelativeSourceFolder)
				}
			}
		}

		# copy new files if SkipFiles is false
		If (-not $SkipFiles) {
			# define sorted sets for relative paths
			$AllRelativeSourceFiles = [System.Collections.Generic.SortedSet[System.String]]::new()
			$AllRelativeTargetFiles = [System.Collections.Generic.SortedSet[System.String]]::new()
			$NewRelativeSourceFiles = [System.Collections.Generic.SortedSet[System.String]]::new()
			$NewRelativeTargetFiles = [System.Collections.Generic.SortedSet[System.String]]::new()
			$OldRelativeSourceFiles = [System.Collections.Generic.SortedSet[System.String]]::new()
			$OldRelativeTargetFiles = [System.Collections.Generic.SortedSet[System.String]]::new()

			# define sorted lists for datetimes
			$DateTimeForSourceFiles = [System.Collections.Generic.SortedList[System.String, System.DateTime]]::new()
			$DateTimeForTargetFiles = [System.Collections.Generic.SortedList[System.String, System.DateTime]]::new()

			# if source path found...
			If (Test-Path -Path $SourcePath -PathType Container) {
				# populate sorted set with relative path of file objects under source path
				try {
					Get-ChildItem -Path $SourcePath -Recurse:$Recurse -File | ForEach-Object { 
						# define relative path
						$RelativePath = $_.FullName.Replace($SourcePath, [System.String]::Empty)

						# add relative path and datetime to list
						$DateTimeForSourceFiles.Add($RelativePath, $_.LastWriteTimeUtc)

						# add relative path to all set only
						$null = $AllRelativeSourceFiles.Add($RelativePath)

						# if last write time newer than last sync...
						If ($_.LastWriteTimeUtc.Ticks -ge $LastSyncDateTime.Ticks) {
							# add relative path to new set
							$null = $NewRelativeSourceFiles.Add($RelativePath)
						}
						# if last write time not newer than last sync...
						else {
							# add relative path to old
							$null = $OldRelativeSourceFiles.Add($RelativePath)
						}
					}
				}
				catch {
					Write-Warning -Message "could not retrieve files from path: '$SourcePath'"
					Return $_
				}
			}

			# if target path found...
			If (Test-Path -Path $TargetPath -PathType Container) {
				# populate sorted set with relative path of file objects under target path
				try {
					Get-ChildItem -Path $TargetPath -Recurse:$Recurse -File | ForEach-Object { 
						# define relative path
						$RelativePath = $_.FullName.Replace($TargetPath, [System.String]::Empty)

						# add relative path and datetime to list
						$DateTimeForTargetFiles.Add($RelativePath, $_.LastWriteTimeUtc)

						# add relative path to all set only
						$null = $AllRelativeTargetFiles.Add($RelativePath)

						# if last write time newer than last sync...
						If ($_.LastWriteTimeUtc.Ticks -ge $LastSyncDateTime.Ticks) {
							# add relative path to new set
							$null = $NewRelativeTargetFiles.Add($RelativePath)
						}
						# if last write time not newer than last sync...
						else {
							# add relative path to old
							$null = $OldRelativeTargetFiles.Add($RelativePath)
						}
					}
				}
				catch {
					Write-Warning -Message "could not retrieve files from path: '$TargetPath'"
					Return $_
				}
			}

			# retrieve files in both Path and Destination
			$MatchedFiles = [System.Collections.Generic.SortedSet[System.String]]::new([System.Linq.Enumerable]::Intersect($AllRelativeSourceFiles, $AllRelativeTargetFiles))
			
			# copy files in Path that are missing from Destination
			If ($Direction -eq 'Forward' -or $Direction -eq 'Both') {
				# retrieve files in Path that are missing from Destination
				$MissingRelativeTargetFiles = [System.Collections.Generic.SortedSet[System.String]]::new([System.Linq.Enumerable]::Except($NewRelativeSourceFiles, $MatchedFiles))

				# report count
				Write-Host "Found '$($MissingRelativeTargetFiles.Count)' files(s) to copy to path: '$TargetPath'"

				# loop through missing relative target folders
				ForEach ($MissingRelativeTargetFile in $MissingRelativeTargetFiles) {
					# define missing target file and present source file
					$MissingTargetFile = Join-Path -Path $TargetPath -ChildPath $MissingRelativeTargetFile
					$PresentSourceFile = Join-Path -Path $SourcePath -ChildPath $MissingRelativeTargetFile

					# create missing target file
					If ($PSCmdlet.ShouldProcess("source: $PresentSourceFile, target: $MissingTargetFile", 'copy file')) {
						Try {
							Copy-Item -Path $PresentSourceFile -Destination $MissingTargetFile -Force
						}
						Catch {
							Write-Warning "could not copy file '$PresentSourceFile' to file '$MissingTargetFile'"
							Return $_
						}
					}

					# add file to set
					$null = $FilesCreatedInTarget.Add($MissingRelativeTargetFile)
				}
			}

			# copy new files from Destination to Path
			If ($Direction -eq 'Both') {
				# retrieve files that are missing from Path
				$MissingRelativeSourceFiles = [System.Collections.Generic.SortedSet[System.String]]::new([System.Linq.Enumerable]::Except($NewRelativeTargetFiles, $MatchedFiles))

				# report count
				Write-Host "Found '$($MissingRelativeSourceFiles.Count)' files(s) to copy to path: '$SourcePath'"

				# loop through missing relative source files
				ForEach ($MissingRelativeSourceFile in $MissingRelativeSourceFiles) {
					# define missing source file and present target file
					$MissingSourceFile = Join-Path -Path $SourcePath -ChildPath $MissingRelativeSourceFile
					$PresentTargetFile = Join-Path -Path $TargetPath -ChildPath $MissingRelativeSourceFile

					# create missing source file
					If ($PSCmdlet.ShouldProcess("source: $PresentTargetFile, target: $MissingSourceFile", 'copy file')) {
						Try {
							Copy-Item -Path $PresentTargetFile -Destination $MissingSourceFile -Force
						}
						Catch {
							Write-Warning "could not copy file '$PresentTargetFile' to file '$MissingSourceFile'"
							Return $_
						}
					}

					# add file to set
					$null = $FilesCreatedInSource.Add($MissingRelativeSourceFile)
				}
			}
		}

		# process files if files are in scope (SkipExisting and SkipFiles are false)
		If (-not $SkipExisting -and -not $SkipFiles) {
			# report count
			Write-Host "Found '$($MatchedFiles.Count)' files(s) to compare"

			# copy any present files when hash or lastwritetime are different
			:NextMatchedFile ForEach ($MatchedFile in $MatchedFiles) {
				# define file path
				$MatchedSourcePath = Join-Path -Path $SourcePath -ChildPath $MatchedFile
				$MatchedTargetPath = Join-Path -Path $TargetPath -ChildPath $MatchedFile

				# if compare files by hash requested
				If ($CheckHash) {
					# if file in Path and Direction have same file hash
					If ((Get-FileHash -Path $MatchedSourcePath).Hash -eq (Get-FileHash -Path $MatchedTargetPath).Hash) {
						# report state
						Write-Verbose -Verbose:$VerbosePreference -Message "Skipping '$MatchedSourcePath' as '$MatchedTargetPath' has same file hash"

						# add file to sets
						$null = $FilesCheckedInSource.Add($MatchedFile)
						$null = $FilesCheckedInTarget.Add($MatchedFile)

						# continue to next matched file
						Continue NextMatchedFile
					}
				}
				# if compare files by hash not requested
				else {
					# if file in Path and Direction have same LastWriteTimeUtc
					If ($DateTimeForSourceFiles[$MatchedFile] -eq $DateTimeForTargetFiles[$MatchedFile]) {
						# report state
						Write-Verbose -Verbose:$VerbosePreference -Message "Skipping '$MatchedSourcePath' as '$MatchedTargetPath' has same LastWriteTimeUtc"

						# add file to sets
						$null = $FilesCheckedInSource.Add($MatchedFile)
						$null = $FilesCheckedInTarget.Add($MatchedFile)

						# continue to next matched file
						Continue NextMatchedFile
					}
				}

				# if file in Destination is newer and Direction is 'Both'
				If ($DateTimeForTargetFiles[$MatchedFile] -gt $DateTimeForSourceFiles[$MatchedFile] -and $Direction -eq 'Both') {
					# copy file from Destination to Path
					If ($PSCmdlet.ShouldProcess("source: $MatchedTargetPath, target: $MatchedSourcePath", 'copy file')) {
						Try {
							Copy-Item -Path $MatchedTargetPath -Destination $MatchedSourcePath -Force
						}
						Catch {
							Write-Warning "could not copy file '$MatchedTargetPath' to file '$MatchedSourcePath'"
							Continue NextMatchedFile
						}
					}

					# add file to sets
					$null = $FilesUpdatedInSource.Add($MatchedFile)
					$null = $FilesCheckedInTarget.Add($MatchedFile)
				}
				# if file in Destination is older and Direction is not 'Both'
				else {
					# copy file from Path to Destination
					If ($PSCmdlet.ShouldProcess("source: $MatchedSourcePath, target: $MatchedTargetPath", 'copy file')) {
						Try {
							Copy-Item -Path $MatchedSourcePath -Destination $MatchedTargetPath -Force
						}
						Catch {
							Write-Warning "could not copy file '$MatchedSourcePath' to file '$MatchedTargetPath'"
							Continue NextMatchedFile
						}
					}

					# add file to sets
					$null = $FilesCheckedInSource.Add($MatchedFile)
					$null = $FilesUpdatedInTarget.Add($MatchedFile)
				}
			}
		}

		# remove old files if SkipDelete is false and files are in scope (SkipExisting and SkipFiles are false)
		If (-not $SkipDelete -and (-not $SkipExisting -and -not $SkipFiles)) {
			# remove old files from Destination
			If ($Direction -eq 'Forward' -or $Direction -eq 'Both') {
				# retrieve old files that are only in Destination
				$ExpiredRelativeTargetFiles = [System.Collections.Generic.SortedSet[System.String]]::new([System.Linq.Enumerable]::Except($OldRelativeTargetFiles, $MatchedFiles))

				# loop through expired relative target files
				ForEach ($ExpiredRelativeTargetFile in $ExpiredRelativeTargetFiles.Reverse()) {
					# define expired target file
					$ExpiredTargetFile = Join-Path -Path $TargetPath -ChildPath $ExpiredRelativeTargetFile

					# remove expired target file
					If ($PSCmdlet.ShouldProcess($ExpiredTargetFile, 'remove file')) {
						Try {
							$null = Remove-Item -Path $ExpiredTargetFile -Force
						}
						Catch {
							Write-Warning "could not remove file '$ExpiredTargetFile'"
							Return $_
						}
					}

					# add path to set
					$null = $PathsRemovedInTarget.Add($ExpiredRelativeTargetFile)
				}
			}

			# remove old files from Path
			If ($Direction -eq 'Reverse' -or $Direction -eq 'Both') {
				# retrieve old files that are only in Path
				$ExpiredRelativeSourceFiles = [System.Collections.Generic.SortedSet[System.String]]::new([System.Linq.Enumerable]::Except($OldRelativeSourceFiles, $MatchedFiles))

				# loop through expired relative source files in reverse
				ForEach ($ExpiredRelativeSourceFile in $ExpiredRelativeSourceFiles.Reverse()) {
					# define expired source file
					$ExpiredSourceFile = Join-Path -Path $SourcePath -ChildPath $ExpiredRelativeSourceFile

					# remove expired source file
					If ($PSCmdlet.ShouldProcess($ExpiredSourceFile, 'remove file')) {
						Try {
							$null = Remove-Item -Path $ExpiredSourceFile -Force
						}
						Catch {
							Write-Warning "could not remove file '$ExpiredSourceFile'"
							Return $_
						}
					}

					# add file to set
					$null = $FilesRemovedInSource.Add($ExpiredRelativeSourceFile)
				}
			}
		}

		# remove old paths if SkipDelete is files and folders are in scope (SkipExisting is false and Recurse is true)
		If (-not $SkipDelete -and -not $SkipExisting -and $Recurse) {
			# remove old paths from Destination
			If ($Direction -eq 'Forward' -or $Direction -eq 'Both') {
				# retrieve old paths only in Destination
				$ExpiredRelativeTargetFolders = [System.Collections.Generic.SortedSet[System.String]]::new([System.Linq.Enumerable]::Except($OldRelativeTargetFolders, $MatchedFolders))

				# loop through old target folders in reverse
				ForEach ($ExpiredRelativeTargetFolder in $ExpiredRelativeTargetFolders.Reverse()) {
					# define expired target folder
					$ExpiredTargetFolder = Join-Path -Path $TargetPath -ChildPath $ExpiredRelativeTargetFolder

					# remove expired target folder
					If ($PSCmdlet.ShouldProcess($ExpiredTargetFolder, 'remove folder')) {
						Try {
							$null = Remove-Item -Path $ExpiredTargetFolder -Force
						}
						Catch {
							Write-Warning "could not remove folder '$ExpiredTargetFolder'"
							Return $_
						}
					}

					# add path to set
					$null = $PathsRemovedInTarget.Add($ExpiredRelativeTargetFolder)
				}
			}

			# remove old paths from Path
			If ($Direction -eq 'Reverse' -or $Direction -eq 'Both') {
				# retrieve old paths only in Path
				$ExpiredRelativeSourceFolders = [System.Collections.Generic.SortedSet[System.String]]::new([System.Linq.Enumerable]::Except($OldRelativeSourceFolders, $MatchedFolders))

				# loop through expired relative source folders in reverse
				ForEach ($ExpiredRelativeSourceFolder in $ExpiredRelativeSourceFolders.Reverse()) {
					# define expired source folder
					$ExpiredSourceFolder = Join-Path -Path $SourcePath -ChildPath $ExpiredRelativeSourceFolder

					# remove expired source folder
					If ($PSCmdlet.ShouldProcess($ExpiredSourceFolder, 'remove folder')) {
						Try {
							$null = Remove-Item -Path $ExpiredSourceFolder -Force
						}
						Catch {
							Write-Warning "could not remove folder '$ExpiredSourceFolder'"
							Return $_
						}
					}

					# add path to set
					$null = $PathsRemovedInSource.Add($ExpiredRelativeSourceFolder)
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
		Write-Warning -Message "could not resolve '$Preset' preset to parameters: $($_.Exception.Message)"
		Throw $_
	}

	# if Path is not an absolute path...
	If (![System.IO.Path]::IsPathRooted($Path)) {
		# get unresolved absolute path
		Try {
			$Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
		}
		Catch {
			Write-Warning -Message "could not create absolute path from the provided '$Path' Path: $($_.Exception.Message)"
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
			Write-Warning -Message "could not trim Path: $($_.Exception.Message)"
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
			Write-Warning -Message "could not create absolute path from the provided '$Destination' Destination: $($_.Exception.Message)"
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
			Write-Warning -Message "could not trim Destination: $($_.Exception.Message)"
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
			Write-Warning -Message "could not create hash of '$InstanceName' instance name: $($_.Exception.Message)"
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

	# if date time returned by function and SkipDelete not requested...
	If ($DateTimeFromSync -and !$SkipDelete) {
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

End {
	# define time stopped
	$TimeStopped = [System.DateTime]::Now

	# report state
	"Time started: {0}" -f $TimeStarted.ToString('o')
	"Time stopped: {0}" -f $TimeStopped.ToString('o')

	If ($PathsCreatedInSource.Count) { "Paths created in source: {0}" -f $PathsCreatedInSource.Count }
	If ($PathsCreatedInTarget.Count) { "Paths created in target: {0}" -f $PathsCreatedInTarget.Count }

	If ($PathsCheckedInSource.Count) { "Paths checked in source: {0}" -f $PathsCheckedInSource.Count }
	If ($PathsCheckedInTarget.Count) { "Paths checked in target: {0}" -f $PathsCheckedInTarget.Count }

	If ($FilesCreatedInSource.Count) { "Files created in source: {0}" -f $FilesCreatedInSource.Count }
	If ($FilesCreatedInTarget.Count) { "Files created in target: {0}" -f $FilesCreatedInTarget.Count }

	If ($FilesCheckedInSource.Count) { "Files checked in source: {0}" -f $FilesCheckedInSource.Count }
	If ($FilesCheckedInTarget.Count) { "Files checked in target: {0}" -f $FilesCheckedInTarget.Count }

	If ($FilesUpdatedInSource.Count) { "Files updated in source: {0}" -f $FilesUpdatedInSource.Count }
	If ($FilesUpdatedInTarget.Count) { "Files updated in target: {0}" -f $FilesUpdatedInTarget.Count }

	If ($FilesRemovedInSource.Count) { "Files removed in source: {0}" -f $FilesRemovedInSource.Count }
	If ($FilesRemovedInTarget.Count) { "Files removed in target: {0}" -f $FilesRemovedInTarget.Count }

	If ($PathsRemovedInSource.Count) { "Paths removed in source: {0}" -f $PathsRemovedInSource.Count }
	If ($PathsRemovedInTarget.Count) { "Paths removed in target: {0}" -f $PathsRemovedInTarget.Count }
}