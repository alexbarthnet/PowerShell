<#
.SYNOPSIS
Create a bootable USB drive from a Windows ISO image.

.DESCRIPTION
Create a bootable USB drive from a Windows ISO image.

.PARAMETER PathToOriginalIsoImage
Path to the original Windows ISO image.

.PARAMETER DriveLetter
Character for the drive letter of an existing volume on the USB drive.

.PARAMETER Number
Integer for the disk number of the USB drive.

.PARAMETER PathToAutounattendFile
Path to autounattend XML file to add to Windows ISO image. The file will be saved as 'Autounattend.xml' at the root of the ISO file system. This file must enter the auditUser pass and call the update and invoke scripts during the auditUser pass.

.PARAMETER PathToUnattendFile
Path to unattend XML file to add to Windows ISO image. The file will be saved as 'Unattend.xml' at the root of the ISO file system. This file is called when the autounattend file does not shutdown after the auditUser pass.

.PARAMETER PathToUpdateScript
Path to required "update" PS1 file to add to Windows WIM image. The file will be saved as 'Update-Windows.ps1' under the Windows directory in the WIM image.

.PARAMETER PathToInvokeScript
Path to required "invoke" PS1 file to add to Windows WIM image. The file will be saved as 'Invoke-ScriptsFromRemovableMedia.ps1' under the Windows directory in the WIM image.

.PARAMETER PathToScriptFolder
Path to optional folder containing PS1 scripts to add to Windows ISO image.

.PARAMETER StagingPath
Path to folder for staging the ISO file contents and mounting the WIM image. The default staging path is a randomly named folder in the system temp directory.

.PARAMETER EmptyStagingPath
Switch parameter to remove any existing files and folders in the StagingPath folder.

.PARAMETER ReuseStagingPath
Switch parameter to use any existing files and folders in the StagingPath folder rather than copying new files from the original ISO image or script folders.

.PARAMETER SkipExclude
Switch parameter to skip creating Microsoft Defender path exclusion for the staging path.

.PARAMETER SkipWrite
Switch parameter to skip writing updated Windows ISO contents to the USB drive.

.PARAMETER FileSystem
String with file system to apply to USB drive. The default value is "NTFS" and the value must be "NTFS" or "FAT32".

.PARAMETER UnattendExpandStrings
Hashtable of expand strings and values for autounattend and unattend XML files

.INPUTS
None.

.OUTPUTS
None. The function does not generate any output.

#>

Param(
	[Parameter(Position = 0, Mandatory = $true)][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToOriginalIsoImage,
	[Parameter(Position = 1)]
	[string]$DriveLetter,
	[Parameter(Position = 2)]
	[uint32]$Number,
	[Parameter(Position = 3)][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToAutounattendFile,
	[Parameter(Position = 4)][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToUnattendFile,
	[Parameter(Position = 5)][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToUpdateScript,
	[Parameter(Position = 6)][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToInvokeScript,
	[Parameter(Position = 7)][ValidateScript({ [System.IO.Directory]::Exists($_) })]
	[string]$PathToScriptFolder,
	[Parameter(Position = 8)][ValidateScript({ [System.IO.Directory]::Exists($_) })]
	[string]$PathToBinaryFolder,
	[Parameter(Position = 9, ParameterSetName = 'StagingPath', Mandatory = $true)][ValidateScript({ [System.IO.Directory]::Exists($_) })]
	[string]$StagingPath,
	[Parameter(Position = 10, ParameterSetName = 'StagingPath')]
	[switch]$EmptyStagingPath,
	[Parameter(Position = 11, ParameterSetName = 'StagingPath')]
	[switch]$ReuseStagingPath,
	[Parameter(Position = 12, ParameterSetName = 'StagingPath')]
	[switch]$SkipWrite,
	[Parameter(Position = 13)]
	[switch]$SkipExclude,
	[Parameter(Position = 14)]
	[string]$FileSystem = 'NTFS',
	[Parameter(Position = 15)]
	[hashtable]$UnattendExpandStrings = @{
		'%INDEX%'      = 4
		'%PRODUCTKEY%' = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF'
	},
	[Parameter(DontShow)]
	[string[]]$ExpandStringsForUnattendFiles = @(
		'%INDEX%'
		'%PRODUCTKEY%'
		'%TIMEZONE%'
		'%COMPUTERNAME%'
		'%USERNAME%'
		'%PASSWORD%'
		'%DOMAINNAME%'
		'%ORGANIZATIONALUNIT%'
		'%ADMINISTRATORPASSWORD%'
	)
)

Begin {
	Function New-TemporaryFolder {
		Param(
			[switch]$ForMachine
		)

		# if temporary folder for machine requested...
		If ($ForMachine) {
			# retrieve TEMP environment variable for machine
			$PathForTEMP = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')
		}
		Else {
			# retrieve TEMP environment variable for user
			$PathForTEMP = [System.Environment]::GetEnvironmentVariable('TEMP', 'User')
		}

		# define path for temporary folder
		Do {
			# define temporary folder name
			$NameForTemporaryFolder = [System.IO.Path]::GetRandomFileName().Replace('.', [System.String]::Empty)
			# combine TEMP path and temporary folder name
			$PathForTemporaryFolder = Join-Path -Path $PathForTEMP -ChildPath $NameForTemporaryFolder
		}
		Until (![System.IO.Directory]::Exists($PathForTemporaryFolder))

		# create temporary folder
		Try {
			$TemporaryFolder = New-Item -Force -ItemType Directory -Path $PathForTemporaryFolder
		}
		Catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# return temporary folder
		Return $TemporaryFolder
	}

	# if staging path defined...
	If ($PSBoundParameters.ContainsKey('StagingPath')) {
		# if StagingPath is not an absolute path...
		If (![System.IO.Path]::IsPathRooted($StagingPath)) {
			# get unresolved absolute path
			Try {
				$StagingPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StagingPath)
			}
			Catch {
				Write-Warning -Message "could not create absolute path from the provided Path parameter: $StagingPath"
				$PSCmdlet.ThrowTerminatingError($_)
			}

			# report absolute path
			Write-Warning -Message "converted relative path in provided StagingPath parameter to absolute path: $StagingPath"
		}

		# if staging path not found...
		Try {
			$null = Get-Item -Path $StagingPath -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not locate directory for provided StagingPath: $StagingPath"
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# retrieve child items in StagingPath
		Try {
			$StagingPathItems = Get-ChildItem -Path $StagingPath -Force -Recurse
		}
		Catch {
			Write-Warning -Message 'could not check StagingPath for existing files and folders'
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# if child items found in StagingPath...
		If ($null -ne $StagingPathItems -and -not $ReuseStagingPath) {
			# if EmptyStagingPath not requested...
			If (!$EmptyStagingPath) {
				# warn and inquire
				Write-Warning -Message 'found existing files or folders in provided StagingPath. Continue to empty StagingPath.' -WarningAction Inquire
			}

			# remove child items in StagingPath
			Try {
				Get-ChildItem -Path $StagingPath -Force | Remove-Item -Force -Recurse -ErrorAction 'Stop'
			}
			Catch {
				$PSCmdlet.ThrowTerminatingError($_)
			}
		}
	}
	# if staging path not defined...
	Else {
		# create temporary folder
		Try {
			$TemporaryFolder = New-TemporaryFolder
		}
		Catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# define staging path from temporary folder full name
		$StagingPath = $TemporaryFolder.FullName
	}

	# create base temporary path
	Try {
		$TemporaryPath = New-Item -Force -ItemType Directory -Path $StagingPath
	}
	Catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# create temporary path for DISM scratch directory
	Try {
		$TemporaryPathForDSD = New-Item -Force -ItemType Directory -Path $TemporaryPath -Name 'DSD'
	}
	Catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# create temporary path for ISO contents
	Try {
		$TemporaryPathForISO = New-Item -Force -ItemType Directory -Path $TemporaryPath -Name 'ISO'
	}
	Catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# create temporary path for WIM file
	Try {
		$TemporaryPathForWIM = New-Item -Force -ItemType Directory -Path $TemporaryPath -Name 'WIM'
	}
	Catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# if Skip Exclude not requested...
	If (!$SkipExclude) {
		Try {
			Add-MpPreference -ExclusionPath $StagingPath -ErrorAction Stop
		}
		Catch {
			Write-Warning -Message "could not create exclusion for temporary path: $StagingPath"
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}

	# define relative items
	$AutounattendXmlOnISO = "$TemporaryPathForISO\Autounattend.xml"
	$UnattendXmlOnISO = "$TemporaryPathForISO\Unattend.xml"
	$ImagePathForWIM = "$TemporaryPathForISO\sources\install.wim"
	$ImagePathForSWM = "$TemporaryPathForISO\sources\install.swm"
	$UpdatePs1OnWIM = "$TemporaryPathForWIM\Windows\Update-Windows.ps1"
	$InvokePs1OnWIM = "$TemporaryPathForWIM\Windows\Invoke-ScriptsFromRemovableMedia.ps1"
}

Process {
	# retrieve removable volumes
	$Volumes = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' }

	# retrieve USB disks
	$Disks = Get-Disk | Where-Object { $_.BusType -eq 'USB' }

	# if drive letter provided...
	If ($DriveLetter) {
		# retrieve removable volumes
		$Volume = $Volumes | Where-Object { $_.DriveLetter -eq $DriveLetter }

		# if volume with drive letter not found...
		If ($null -eq $Volume) {
			Write-Warning -Message 'no removable volumes found with '$DriveLetter' drive letter, exiting!'
			Return
		}

		# retrieve disk from volume
		$Disk = $Volume | Get-Partition | Get-Disk | Where-Object { $_.BusType -eq 'USB' }

		# if disk count is greater than 1...
		If ((Measure-Object -InputObject $Disk).Count -gt 1) {
			Write-Warning -Message 'multiple Removable USB disks found for provided DriveLetter, use DiskNumber parameter to define specific disk, exiting!'
			Return
		}

		# if disk not found...
		If ($null -eq $Disk) {
			Write-Warning -Message 'no removable volumes on USB disks found with '$DriveLetter' drive letter, exiting!'
			Return
		}
	}
	# if disk number provided...
	ElseIf ($Number) {
		# retrieve USB disk by disk number
		$Disk = $Disks | Where-Object { $_.BusType -eq 'USB' -and $_.Number -eq $Number }

		# if disk with disk number not found...
		If ($null -eq $Disk) {
			Write-Warning -Message 'no USB disks found with '$Number' disk number, exiting!'
			Return
		}
	}
	# if drive letter and disk number not provided...
	Else {
		# retrieve removable volumes
		$Volume = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' }

		# if volume count is not zero...
		If ((Measure-Object -InputObject $Volume).Count -gt 0) {
			# retrieve volumes that are USB disks
			$Disk = $Volume | Get-Partition | Get-Disk | Where-Object { $_.BusType -eq 'USB' }

			# if disk count is greater than 1...
			If ((Measure-Object -InputObject $Disk).Count -gt 1) {
				Write-Warning -Message 'multiple removable volumes on USB disks found, use the DriveLetter or Number parameter to define a specific volume or disk, exiting!'
				Return
			}

			# if disk count is less than 1...
			If ((Measure-Object -InputObject $Disk).Count -lt 1) {
				Write-Warning -Message 'no removable volumes on USB disks found, exiting!'
				Return
			}
		}

		# if disk not found from volumes...
		If ($null -eq $Disk) {
			# retrieve USB disks
			$Disk = Get-Disk | Where-Object { $_.BusType -eq 'USB' }

			# if disk count is greater than 1...
			If ((Measure-Object -InputObject $Disk).Count -gt 1) {
				Write-Warning -Message 'multiple USB disks found, use the Number parameter from the Get-Disk command to define a specific disk, exiting!'
				Return
			}

			# if disk count is less than 1...
			If ((Measure-Object -InputObject $Disk).Count -lt 1) {
				Write-Warning -Message 'no USB disks found, exiting!'
				Return
			}
		}
	}

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Found USB disk', $Disk.Number

	# test disk for multiple volumes or partitions

	# if reuse staging path not set...
	If (!$ReuseStagingPath) {
		# report state
		"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Mounting ISO image', $PathToOriginalIsoImage

		# mount the original ISO image
		Try {
			$DiskImage = Mount-DiskImage -ImagePath $PathToOriginalIsoImage
		}
		Catch {
			Return $_
		}

		# retrieve volume for disk image
		Try {
			$Volume = Get-Volume -DiskImage $DiskImage
		}
		Catch {
			Return $_
		}

		# retrieve volume properties
		$ImageDriveLetter = $Volume.DriveLetter
		$FileSystemLabel = $Volume.FileSystemLabel

		# report state
		"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Copying ISO contents to path', $TemporaryPathForISO

		# copy ISO contents to temporary path
		Try {
			Copy-Item -Path ('{0}:\*' -f $ImageDriveLetter) -Destination $TemporaryPathForISO -Recurse -Force
		}
		Catch {
			Return $_
		}

		# report state
		"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Dismounting ISO image...'

		# dismount ISO image
		Try {
			$null = $DiskImage | Dismount-DiskImage
		}
		Catch {
			Return $_
		}

		# if scripts provided...
		If ($PathToInvokeScript -or $PathToUpdateScript) {
			# clear readonly flag on windows image
			Try {
				Set-ItemProperty -Path $ImagePathForWIM -Name 'IsReadOnly' -Value $false
			}
			Catch {
				Return $_
			}

			# report state
			"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Mounting WIM image', $ImagePathForWIM

			# mount windows image
			Try {
				$null = Mount-WindowsImage -Path $TemporaryPathForWIM -ImagePath $ImagePathForWIM -Index $Index -ScratchDirectory $TemporaryPathForDSD
			}
			Catch {
				Return $_
			}

			# if update script provided...
			If ($PSBoundParameters.ContainsKey('PathToUpdateScript')) {
				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Updating WIM with "update" script', $UpdatePs1OnWIM

				# add update script to windows image
				Try {
					Copy-Item -Path $PathToUpdateScript -Destination $UpdatePs1OnWIM
				}
				Catch {
					Return $_
				}
			}

			# if invoke script provided...
			If ($PSBoundParameters.ContainsKey('PathToInvokeScript')) {
				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Updating WIM with "invoke" script', $InvokePs1OnWIM

				# add invoke script to windows image
				Try {
					Copy-Item -Path $PathToInvokeScript -Destination $InvokePs1OnWIM
				}
				Catch {
					Return $_
				}
			}

			# report state
			"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Dismounting WIM image...'

			# dismount windows image
			Try {
				$null = Dismount-WindowsImage -Path $TemporaryPathForWIM -Save -CheckIntegrity -ScratchDirectory $TemporaryPathForDSD
			}
			Catch {
				Return $_
			}
		}

		# if file system is FAT32...
		If ($FileSystem -eq 'FAT32') {
			# report state
			"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Splitting WIM image...'

			# split images into 4GB chunks
			Try {
				$null = Split-WindowsImage -ImagePath $ImagePathForWIM -SplitImagePath $ImagePathForSWM -FileSize 4096 -ScratchDirectory $TemporaryPathForDSD
			}
			Catch {
				Return $_
			}

			# remove original WIM image
			Try {
				Remove-Item -Path $ImagePathForWIM -Force
			}
			Catch {
				Return $_
			}
		}

		# if autounattend file provided...
		If ($PSBoundParameters.ContainsKey('PathToAutounattendFile')) {
			# report state
			"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Updating ISO contents with unattend file for sysprep', $AutounattendXmlOnISO

			# get contents of unattend file
			Try {
				$Content = Get-Content -Path $PathToAutounattendFile -Raw
			}
			Catch {
				Return $_
			}

			# loop through unattend parameter strings
			ForEach ($ExpandString in $ExpandStringsForUnattendFiles) {
				# while content contains XML element with expand string as value...
				While ($Content -match "<\w*>$ExpandString</\w*>") {
					# retrieve original XML element
					$OriginalString = $Matches[0]
					# if expand string and value provided parameters...
					If ($UnattendExpandStrings.ContainsKey($ExpandString)) {
						# replace the expand string with the provided value
						$ModifiedString = $OriginalString -replace $ExpandString, $UnattendExpandStrings[$ExpandString]

						# report state
						"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Replaced expand string in unattend file for sysprep', $ExpandString
					}
					Else {
						# comment out the original XML element
						$ModifiedString = '<!-- {0} -->' -f ($OriginalString -replace '%')

						# report state
						"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Excluded expand string in unattend file for sysprep', $ExpandString
					}
					# replace original XML element with modified XML element
					$Content = $Content -replace $OriginalString, $ModifiedString
				}
			}

			# add unattend file to ISO
			Try {
				$Content | Set-Content -Path $AutounattendXmlOnISO
			}
			Catch {
				Return $_
			}
		}

		# if unattend file provided...
		If ($PSBoundParameters.ContainsKey('PathToUnattendFile')) {
			# report state
			"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Updating ISO contents with unattend file for install', $UnattendXmlOnISO

			# get contents of unattend file
			Try {
				$Content = Get-Content -Path $PathToUnattendFile -Raw
			}
			Catch {
				Return $_
			}

			# loop through unattend parameter strings
			ForEach ($ExpandString in $ExpandStringsForUnattendFiles) {
				# while content contains XML element with expand string as value...
				While ($Content -match "<\w*>$ExpandString</\w*>") {
					# retrieve original XML element
					$OriginalString = $Matches[0]
					# if expand string and value provided parameters...
					If ($UnattendExpandStrings.ContainsKey($ExpandString)) {
						# replace the expand string with the provided value
						$ModifiedString = $OriginalString -replace $ExpandString, $UnattendExpandStrings[$ExpandString]

						# report state
						"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Replaced expand string in unattend file for install', $ExpandString
					}
					Else {
						# comment out the original XML element
						$ModifiedString = '<!-- {0} -->' -f ($OriginalString -replace '%')

						# report state
						"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Excluded expand string in unattend file for install', $ExpandString
					}
					# replace original XML element with modified XML element
					$Content = $Content -replace $OriginalString, $ModifiedString
				}
			}

			# add unattend file to ISO
			Try {
				$Content | Set-Content -Path $UnattendXmlOnISO
			}
			Catch {
				Return $_
			}
		}
	}

	# if skip write requested...
	If ($SkipWrite) {
		"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Skipping write to USB drive'
		Return
	}

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Clearing USB drive', $Disk.Number

	# clear disk
	$Disk = $Disk | Clear-Disk -RemoveData -Confirm:$false -PassThru

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Partitioning USB drive', $Disk.Number

	# configure disk
	Try {
		$Disk | Set-Disk -PartitionStyle GPT
	}
	Catch {
		Return $_
	}

	# define empty parameters for New-Partition
	$NewPartition = @{}
	
	# if disk is larger than 32GB...
	If ($Disk.Size -gt 32GB) {
		$NewPartition['Size'] = 32GB
	}
	Else {
		$NewPartition['UseMaximumSize'] = $true
	}

	# if drive letter provided...
	If ($DriveLetter) {
		$NewPartition['DriveLetter'] = $DriveLetter
	}
	Else { 
		$NewPartition['AssignDriveLetter'] = $true
	}

	# create partition
	Try {
		$Partition = $Disk | New-Partition @NewPartition
	}
	Catch {
		Return $_
	}

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Formatting USB drive with file system', $FileSystem

	# partition and format disk
	Try {
		$Volume = $Partition | Format-Volume -FileSystem $FileSystem -NewFileSystemLabel $FileSystemLabel
	}
	Catch {
		Return $_
	}

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Copying ISO contents to USB drive', $Volume.DriveLetter

	# copy ISO contents to USB drive
	Try {
		Copy-Item -Path ('{0}\*' -f $TemporaryPathForISO) -Destination ('{0}:\' -f $Volume.DriveLetter) -Recurse -Force
	}
	Catch {
		Return $_
	}
}

End {
	# if Skip Exclude not requested...
	If (!$SkipExclude) {
		Try {
			Remove-MpPreference -ExclusionPath $StagingPath -ErrorAction Stop
		}
		Catch {
			Write-Warning -Message "could not remove exclusion for temporary path: $StagingPath"
		}
	}
	
	# if TemporaryFolder created...
	If ([System.IO.Directory]::Exists($script:TemporaryFolder)) {
		# remove temporary folder and all child items
		Try {
			Remove-Item -Path $TemporaryFolder -Recurse -Force
		}
		Catch {
			Return $_
		}
	}
}
