<#
.SYNOPSIS
Create a Windows ISO image with unattend files from a Windows ISO image.

.DESCRIPTION
Create a Windows ISO image with unattend files from a Windows ISO image.

.PARAMETER PathToOriginalIsoImage
Path to the original Windows ISO image.

.PARAMETER PathToFeaturesIsoImage
Path to the Features on Demand (FOD) ISO image.

.PARAMETER PathForUpdatedIsoImage
Path for the updated Windows ISO image.

.PARAMETER FilePathToRequiredProgram
Path to the required OS CD imaging program from the Windows ADK. The default value is 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe' and is constructed using the path of the 'ProgramFilesx86' special folder.

.PARAMETER ShowProgramOutputInline
Switch parameter to display output from OS CD imaging program inline rather than in a new window.

.PARAMETER FileSystemLabelSuffix
String containing a suffix to apply to the filesystem label from the original Windows ISO image. The default value is 'UNATTENDED' and is separated from the original file system label by an underscore.

.PARAMETER PathToAutounattendFile
Path to autounattend XML file to add to the ISO image. The file will be saved as 'Autounattend.xml' at the root of the USB file system and will be executed by Windows Setup after booting from the USB drive. The file should include the following passes and components:
 - windowsPE pass and Microsoft-Windows-International-Core-WinPE component with the language settings for setup
 - windowsPE pass Microsoft-Windows-Setup component with the UserData section to set the product key for setup and the DiskConfiguration section to partition and format the disks
 - specialize pass and Microsoft-Windows-International-Core component with the language settings for the Windows installation
 - specialize pass and Microsoft-Windows-Shell-Setup component with the product key for the Windows installation
 - oobeSystem pass and Microsoft-Windows-Deployment component with the Reseal settings to enter the auditUser pass
 - auditUser pass and Microsoft-Windows-Deployment component with the RunSynchronous settings to run the Update and Invoke scripts
 - auditUser pass and Microsoft-Windows-Deployment component with the Generalize settings to generalize the image at the end of Windows setup

.PARAMETER PathToUnattendFile
Path to unattend XML file to add to the ISO image. The file will be saved as 'Unattend.xml' at the root of the ISO file system and will be executed by Windows Setup after generalization is complete. The file should include the following passes and components:
 - oobeSystem pass and Microsoft-Windows-International-Core component with the language settings for the Windows installation
 - oobeSystem pass and Microsoft-Windows-Shell-Setup component with the administrator password settings

.PARAMETER PathToUpdateScript
Path to required "update" PS1 file to add to the Windows image(s). The file will be saved as 'Update-Windows.ps1' under the Windows directory in the Windows image(s).

.PARAMETER PathToInvokeScript
Path to required "invoke" PS1 file to add to the Windows image(s). The file will be saved as 'Invoke-ScriptsFromRemovableMedia.ps1' under the Windows directory in the Windows image(s).

.PARAMETER PathToScriptFolder
Path to optional folder containing PS1 scripts to add to the ISO image.

.PARAMETER PathToResourcesFolder
Path to optional folder containing file resources to add to the ISO image.

.PARAMETER RelativePathToFeaturesFolder
Relative path to folder containing FOD resources on the FOD ISO image. The default value is "LanguagesAndOptionalFeatures"

.PARAMETER StagingPath
Path to folder for staging the ISO file contents and mounting the Windows image(s). The default staging path is a randomly named folder in the system temp directory.

.PARAMETER EmptyStagingPath
Switch parameter to remove any existing files and folders in the StagingPath folder.

.PARAMETER ReuseStagingPath
Switch parameter to use any existing files and folders in the StagingPath folder rather than copying new files from the original ISO image or provided folders.

.PARAMETER StopAfterPreparingImage
Switch parameter to stop after preparing the contents for the ISO image. Requires StagingPath parameter.

.PARAMETER SkipExclude
Switch parameter to skip creating Microsoft Defender path exclusion for the staging path.

.PARAMETER UpdateAllWindowsImages
Switch parameter to update all Windows images in the WIM file regardless of Index value in the UnattendExpandStrings hashtable.

.PARAMETER OptionalFeaturesToDisable
String array containing the names of Windows Optional Features to disable in the Windows image(s).

.PARAMETER OptionalFeaturesToEnable
String array containing the names of Windows Optional Features to enable in the Windows image(s).

.PARAMETER CapabilitiesToRemove
String array containing the names of Windows Capabilities to remove from the Windows image(s).

.PARAMETER CapabilitiesToAdd
String array containing the names of Windows Capabilities to add to the Windows image(s).

.PARAMETER LocalAdminCredential
Credential containing the local administrator password to add to unattend XML files.

.PARAMETER DomainJoinCredential
Credential containing the domain join username and password to add to unattend XML files.

.PARAMETER UnattendExpandStrings
Hashtable of expand strings and values for autounattend and unattend XML files. The default values are as follows:
 - Index = 4 (default index for Datacenter with Desktop Experience since Windows Server 2016)
 - ProductKey = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF' (KMS activation key for Windows Server 2025 Datacenter)

.INPUTS
None.

.OUTPUTS
None. The function does not generate any output.

.LINK
https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/oscdimg-command-line-options?view=windows-11

#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
	[Parameter(Mandatory = $true)]
	[string]$PathForUpdatedIsoImage,
	[Parameter(Mandatory = $true)][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToOriginalIsoImage,
	[Parameter()][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToFeaturesIsoImage,
	[Parameter()]
	[string]$FilePathToRequiredProgram = '{0}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe' -f [System.Environment]::GetFolderPath('ProgramFilesx86'),
	[Parameter()]
	[switch]$ShowProgramOutputInline,
	[Parameter()]
	[string]$FileSystemLabelSuffix = 'UNATTENDED',
	[Parameter()][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToAutounattendFile,
	[Parameter()][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToUnattendFile,
	[Parameter()][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToUpdateScript,
	[Parameter()][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToInvokeScript,
	[Parameter()][ValidateScript({ [System.IO.Directory]::Exists($_) })]
	[string]$PathToScriptFolder,
	[Parameter()][ValidateScript({ [System.IO.Directory]::Exists($_) })]
	[string]$PathToResourcesFolder,
	[Parameter()]
	[string]$RelativePathToFeaturesFolder = 'LanguagesAndOptionalFeatures',
	[Parameter(ParameterSetName = 'StagingPath', Mandatory = $true)][ValidateScript({ [System.IO.Directory]::Exists($_) })]
	[string]$StagingPath,
	[Parameter(ParameterSetName = 'StagingPath')]
	[switch]$EmptyStagingPath,
	[Parameter(ParameterSetName = 'StagingPath')]
	[switch]$ReuseStagingPath,
	[Parameter(ParameterSetName = 'StagingPath')]
	[switch]$StopAfterPreparingImage,
	[Parameter()]
	[switch]$SkipExclude,
	[Parameter()]
	[switch]$UpdateAllWindowsImages,
	[Parameter()]
	[string[]]$OptionalFeaturesToDisable,
	[Parameter()]
	[string[]]$OptionalFeaturesToEnable,
	[Parameter()]
	[string[]]$CapabilitiesToRemove,
	[Parameter()]
	[string[]]$CapabilitiesToAdd,
	[Parameter()]
	[pscredential]$LocalAdminCredential,
	[Parameter()]
	[pscredential]$DomainJoinCredential,
	[Parameter()]
	[hashtable]$UnattendExpandStrings = @{
		DiskID     = 0
		Index      = 4
		ProductKey = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF'
	}
)

begin {
	function New-TemporaryFolder {
		param(
			[switch]$ForMachine
		)

		# if temporary folder for machine requested...
		if ($ForMachine) {
			# retrieve TEMP environment variable for machine
			$PathForTEMP = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')
		}
		else {
			# retrieve TEMP environment variable for user
			$PathForTEMP = [System.Environment]::GetEnvironmentVariable('TEMP', 'User')
		}

		# define path for temporary folder
		do {
			# define temporary folder name
			$NameForTemporaryFolder = [System.IO.Path]::GetRandomFileName().Replace('.', [System.String]::Empty)
			# combine TEMP path and temporary folder name
			$PathForTemporaryFolder = Join-Path -Path $PathForTEMP -ChildPath $NameForTemporaryFolder
		}
		until (![System.IO.Directory]::Exists($PathForTemporaryFolder))

		# create temporary folder
		try {
			$TemporaryFolder = New-Item -ItemType Directory -Path $PathForTemporaryFolder -Force -ErrorAction 'Stop'
		}
		catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# return temporary folder
		return $TemporaryFolder
	}

	# if administrator password provided...
	if ($PSBoundParameters.ContainsKey('LocalAdminCredential')) {
		# retrieve plaintext password from credential object
		try {
			$PlainText = $LocalAdminCredential.GetNetworkCredential().Password
		}
		catch {
			throw $_
		}

		# append required string to plaintext password
		$AppendedPlainText = '{0}?AdministratorPassword' -f $PlainText

		# encode appended password
		try {
			$EncodedAdministratorPassword = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($AppendedPlainText))
		}
		catch {
			throw $_
		}

		# add encoded plaintext password to expand strings hashtable
		$UnattendExpandStrings['AdministratorPassword'] = $EncodedAdministratorPassword
	}

	# if unattended join credential provided...
	if ($PSBoundParameters.ContainsKey('DomainJoinCredential')) {
		# add plaintext unattended join password to expand strings hashtable
		$UnattendExpandStrings['Username'] = $DomainJoinCredential.GetNetworkCredential().Username

		# add plaintext unattended join password to expand strings hashtable
		$UnattendExpandStrings['Password'] = $DomainJoinCredential.GetNetworkCredential().Password
	}

	# if staging path defined...
	if ($PSBoundParameters.ContainsKey('StagingPath')) {
		# if StagingPath is not an absolute path...
		if (![System.IO.Path]::IsPathRooted($StagingPath)) {
			# get unresolved absolute path
			try {
				$StagingPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StagingPath)
			}
			catch {
				Write-Warning -Message "could not create absolute path from the provided Path parameter: $StagingPath"
				$PSCmdlet.ThrowTerminatingError($_)
			}

			# report absolute path
			Write-Warning -Message "converted relative path in provided StagingPath parameter to absolute path: $StagingPath"
		}

		# if staging path not found...
		try {
			$null = Get-Item -Path $StagingPath -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not locate directory for provided StagingPath: $StagingPath"
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# retrieve child items in StagingPath
		try {
			$StagingPathItems = Get-ChildItem -Path $StagingPath -Force -Recurse
		}
		catch {
			Write-Warning -Message 'could not check StagingPath for existing files and folders'
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# if child items found in StagingPath...
		if ($null -ne $StagingPathItems -and -not $ReuseStagingPath) {
			# if EmptyStagingPath not requested...
			if (!$EmptyStagingPath) {
				# warn and inquire
				Write-Warning -Message 'found existing files or folders in provided StagingPath. Continue to empty StagingPath.' -WarningAction Inquire
			}

			# remove child items in StagingPath
			try {
				Get-ChildItem -Path $StagingPath -Force | Remove-Item -Force -Recurse -ErrorAction 'Stop'
			}
			catch {
				$PSCmdlet.ThrowTerminatingError($_)
			}
		}
	}
	# if staging path not defined...
	else {
		# create temporary folder
		try {
			$TemporaryFolder = New-TemporaryFolder
		}
		catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# define staging path from temporary folder full name
		$StagingPath = $TemporaryFolder.FullName
	}

	# create base temporary path
	try {
		$TemporaryPath = New-Item -ItemType Directory -Path $StagingPath -Force -ErrorAction 'Stop'
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# create temporary path for DISM scratch directory
	try {
		$TemporaryPathForDSD = New-Item -ItemType Directory -Path $TemporaryPath -Name 'DSD' -Force -ErrorAction 'Stop'
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# create temporary path for ISO contents
	try {
		$TemporaryPathForISO = New-Item -ItemType Directory -Path $TemporaryPath -Name 'ISO' -Force -ErrorAction 'Stop'
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# create temporary path for WIM file
	try {
		$TemporaryPathForWIM = New-Item -ItemType Directory -Path $TemporaryPath -Name 'WIM' -Force -ErrorAction 'Stop'
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# if Skip Exclude not requested...
	if ($SkipExclude.IsPresent -eq $false) {
		try {
			Add-MpPreference -ExclusionPath $StagingPath -ErrorAction 'Stop'
		}
		catch {
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

process {
	########################################
	# validate program
	########################################

	# validate path to required program
	try {
		$null = Get-Item -Path $FilePathToRequiredProgram -ErrorAction 'Stop'
	}
	catch {
		Write-Warning -Message "could not retrieve required program: $FilePathToRequiredProgram"
		throw $_
	}

	########################################
	# prepare image
	########################################

	# if reuse staging path requested...
	if ($ReuseStagingPath) {
		# mount the original ISO image
		try {
			$DiskImage = Mount-DiskImage -ImagePath $PathToOriginalIsoImage
		}
		catch {
			return $_
		}

		# retrieve volume for disk image
		try {
			$Volume = Get-Volume -DiskImage $DiskImage
		}
		catch {
			return $_
		}

		# retrieve file system label
		$FileSystemLabel = $Volume.FileSystemLabel

		# report state
		"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Dismounting ISO image...'

		# dismount ISO image
		try {
			$null = $DiskImage | Dismount-DiskImage
		}
		catch {
			return $_
		}
	}
	# if reuse staging path not set...
	else {
		# if capabilities to add provided but FOD image not provided...
		if ($PSBoundParameters.ContainsKey('CapabilitiesToAdd') -and -not $PSBoundParameters.ContainsKey('PathToFeaturesIsoImage')) {
			Write-Warning -Message "The 'CapabilitiesToAdd' parameter requires the 'PathToFeaturesIsoImage' parameter"
			return
		}

		# report state
		"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Mounting ISO image', $PathToOriginalIsoImage

		# mount the original ISO image
		try {
			$DiskImage = Mount-DiskImage -ImagePath $PathToOriginalIsoImage
		}
		catch {
			return $_
		}

		# retrieve volume for disk image
		try {
			$Volume = Get-Volume -DiskImage $DiskImage
		}
		catch {
			return $_
		}

		# retrieve file system label
		$FileSystemLabel = $Volume.FileSystemLabel

		# retrieve volume drive letter
		$ImageDriveLetter = $Volume.DriveLetter

		# report state
		"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Copying ISO contents to path', $TemporaryPathForISO

		# copy ISO contents to temporary path
		try {
			Copy-Item -Path ('{0}:\*' -f $ImageDriveLetter) -Destination $TemporaryPathForISO -Recurse -Force -ErrorAction 'Stop'
		}
		catch {
			return $_
		}

		# report state
		"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Dismounting ISO image...'

		# dismount ISO image
		try {
			$null = $DiskImage | Dismount-DiskImage
		}
		catch {
			return $_
		}

		# define boolean for updating the WIM
		$WIMUpdateRequired = $false

		# define parameters that require updating the WIM
		$WIMUpdatingParameters = @(
			'PathToUpdateScript'
			'PathToInvokeScript'
			'OptionalFeaturesToDisable'
			'OptionalFeaturesToEnable'
			'CapabilitiesToRemove'
			'CapabilitiesToAdd'
		)

		# loop through parameters that require updating the WIM
		foreach ($WIMUpdatingParameter in $WIMUpdatingParameters) {
			# if bound parameters contains a parameter that requires updating the WIM...
			if ($PSBoundParameters.ContainsKey($WIMUpdatingParameter)) {
				# update boolean
				$WIMUpdateRequired = $true
			}
		}

		# if WIM update required...
		if ($WIMUpdateRequired) {
			# if FOD image and capabilities to add provided...
			if ($PSBoundParameters.ContainsKey('PathToFeaturesIsoImage') -and $CapabilitiesToAdd.Count) {
				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Mounting FOD image', $PathToFeaturesIsoImage

				# mount the Feature on Demand ISO image
				try {
					$FeaturesDiskImage = Mount-DiskImage -ImagePath $PathToFeaturesIsoImage
				}
				catch {
					return $_
				}

				# retrieve volume for Feature on Demand disk image
				try {
					$FeaturesVolume = Get-Volume -DiskImage $FeaturesDiskImage
				}
				catch {
					return $_
				}

				# retrieve drive for Feature on Demand volume
				try {
					$FeaturesDrive = Get-PSDrive -PSProvider 'FileSystem' -Name $FeaturesVolume.DriveLetter
				}
				catch {
					return $_
				}
			}

			# clear readonly flag on windows image
			try {
				Set-ItemProperty -Path $ImagePathForWIM -Name 'IsReadOnly' -Value $false
			}
			catch {
				return $_
			}

			# retrieve windows image
			try {
				$WindowsImage = Get-WindowsImage -ImagePath $ImagePathForWIM
			}
			catch {
				return $_
			}

			# loop through indices
			:NextIndex foreach ($Index in $WindowsImage.ImageIndex) {
				# if index provided in unattend strings
				if ($UnattendExpandStrings.ContainsKey('Index') -and -not $UpdateAllWindowsImages) {
					# if current index does not provided index...
					if ($Index -ne $UnattendExpandStrings['Index']) {
						# report state
						"{0}`t{1}: {2}:{3}" -f [System.Datetime]::UtcNow.ToString('o'), 'Skipping WIM image and index', $ImagePathForWIM, $Index

						# continue to next index
						continue NextIndex
					}
				}

				# report state
				"{0}`t{1}: {2}:{3}" -f [System.Datetime]::UtcNow.ToString('o'), 'Mounting WIM image and index', $ImagePathForWIM, $Index

				# mount windows image
				try {
					$null = Mount-WindowsImage -Path $TemporaryPathForWIM -ImagePath $ImagePathForWIM -Index $Index -ScratchDirectory $TemporaryPathForDSD
				}
				catch {
					return $_
				}

				# if update script provided...
				if ($PSBoundParameters.ContainsKey('PathToUpdateScript')) {
					# report state
					"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Updating WIM with "update" script', $UpdatePs1OnWIM

					# add update script to windows image
					try {
						Copy-Item -Path $PathToUpdateScript -Destination $UpdatePs1OnWIM -Force -ErrorAction 'Stop'
					}
					catch {
						return $_
					}
				}

				# if invoke script provided...
				if ($PSBoundParameters.ContainsKey('PathToInvokeScript')) {
					# report state
					"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Updating WIM with "invoke" script', $InvokePs1OnWIM

					# add invoke script to windows image
					try {
						Copy-Item -Path $PathToInvokeScript -Destination $InvokePs1OnWIM -Force -ErrorAction 'Stop'
					}
					catch {
						return $_
					}
				}

				# if optional features to disable or enable provided...
				if ($OptionalFeaturesToDisable.Count -or $OptionalFeaturesToEnable.Count) {
					# retrieve optional features in windows image
					try {
						$WindowsOptionalFeatures = Get-WindowsOptionalFeature -Path $TemporaryPathForWIM -ErrorAction 'Stop'
					}
					catch {
						return $_
					}

					# if optional features to disable provided...
					if ($OptionalFeaturesToDisable.Count) {
						# loop through optional features
						:NextOptionalFeatureToDisable foreach ($FeatureName in $OptionalFeaturesToDisable) {
							# retrieve optional feature by name
							$WindowsOptionalFeature = $WindowsOptionalFeatures | Where-Object { $_.FeatureName -eq $FeatureName }

							# if optional feature not found...
							if (!$WindowsOptionalFeature) {
								# report state and continue to next optional feature
								"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Cannot disable unknown optional feature in WIM', $FeatureName
								continue NextOptionalFeatureToDisable
							}

							# if optional feature already disabled...
							if ($WindowsOptionalFeature.State -eq 'Disabled') {
								# report state and continue to next optional feature
								"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Found optional feature already disabled in WIM', $FeatureName
								continue NextOptionalFeatureToDisable
							}

							# report state
							"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Disabling optional feature in WIM', $FeatureName

							# disable optional feature in windows image
							try {
								$null = Disable-WindowsOptionalFeature -Path $TemporaryPathForWIM -FeatureName $FeatureName -ErrorAction 'Stop'
							}
							catch {
								Write-Warning -Message "could not disable '$FeatureName' feature in WIM: $($_.Exception.Message)"
							}
						}
					}

					# if optional features to enable provided...
					if ($OptionalFeaturesToEnable.Count) {
						# loop through optional features
						:NextOptionalFeatureToEnable foreach ($FeatureName in $OptionalFeaturesToEnable) {
							# retrieve optional feature by name
							$WindowsOptionalFeature = $WindowsOptionalFeatures | Where-Object { $_.FeatureName -eq $FeatureName }

							# if optional feature not found...
							if (!$WindowsOptionalFeature) {
								# report state and continue to next optional feature
								"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Cannot enable unknown optional feature in WIM', $FeatureName
								continue NextOptionalFeatureToEnable
							}

							# if optional feature already enabled...
							if ($WindowsOptionalFeature.State -eq 'Enabled') {
								# report state and continue to next optional feature
								"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Found optional feature already enabled in WIM', $FeatureName
								continue NextOptionalFeatureToEnable
							}

							# report state
							"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Enabling optional feature in WIM', $FeatureName

							# enable optional feature in windows image
							try {
								$null = Enable-WindowsOptionalFeature -Path $TemporaryPathForWIM -FeatureName $FeatureName -All -ErrorAction 'Stop'
							}
							catch {
								Write-Warning -Message "could not enable '$FeatureName' feature in WIM: $($_.Exception.Message)"
							}
						}
					}
				}

				# if capabilities to remove or add provided...
				if ($CapabilitiesToRemove.Count -or $CapabilitiesToAdd.Count) {
					# retrieve capabilities in windows image
					try {
						$WindowsCapabilities = Get-WindowsCapability -Path $TemporaryPathForWIM -ErrorAction 'Stop'
					}
					catch {
						return $_
					}

					# if capabilities to remove provided...
					if ($CapabilitiesToRemove.Count) {
						# loop through capabilities
						:NextCapabilityToRemove foreach ($CapabilityName in $CapabilitiesToRemove) {
							# retrieve capability by name
							$WindowsCapability = $WindowsCapabilities | Where-Object { $_.Name -eq $CapabilityName }

							# if capability not found...
							if (!$WindowsCapability) {
								# report state and continue to next capability
								"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Cannot remove unknown capability from WIM', $CapabilityName
								continue NextCapabilityToRemove
							}

							# if capability already enabled...
							if ($WindowsCapability.State -eq 'NotPresent') {
								# report state and continue to next capability
								"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Requested capability already removed from WIM', $CapabilityName
								continue NextCapabilityToRemove
							}

							# report state
							"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Removing capability from WIM', $CapabilityName

							# remove capability from windows image
							try {
								$null = Remove-WindowsCapability -Path $TemporaryPathForWIM -Name $CapabilityName -ErrorAction 'Stop'
							}
							catch {
								Write-Warning -Message "could not remove '$CapabilityName' capability from WIM: $($_.Exception.Message)"
							}
						}
					}

					# if capabilities to add provided...
					if ($CapabilitiesToAdd.Count) {
						# define source path
						$Source = Join-Path -Path $FeaturesDrive.Root -ChildPath $RelativePathToFeaturesFolder

						# loop through capabilities
						:NextCapabilityToAdd foreach ($CapabilityName in $CapabilitiesToAdd) {
							# retrieve capability by name
							$WindowsCapability = $WindowsCapabilities | Where-Object { $_.Name -eq $CapabilityName }

							# if capability not found...
							if (!$WindowsCapability) {
								# report state and continue to next capability
								"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Cannot add unknown capability to WIM', $CapabilityName
								continue NextCapabilityToAdd
							}

							# if capability already added...
							if ($WindowsCapability.State -eq 'Installed') {
								# report state and continue to next capability
								"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Requested capability already added to WIM', $CapabilityName
								continue NextCapabilityToAdd
							}

							# report state
							"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Adding capability to WIM', $CapabilityName

							# add capability to windows image
							try {
								$null = Add-WindowsCapability -Path $TemporaryPathForWIM -Name $CapabilityName -Source $Source -ErrorAction 'Stop'
							}
							catch {
								Write-Warning -Message "could not add '$CapabilityName' capability to WIM: $($_.Exception.Message)"
							}
						}
					}
				}

				# report state
				"{0}`t{1}: {2}:{3}" -f [System.Datetime]::UtcNow.ToString('o'), 'Dismounting WIM image and index', $ImagePathForWIM, $Index

				# dismount windows image
				try {
					$null = Dismount-WindowsImage -Path $TemporaryPathForWIM -Save -CheckIntegrity -ScratchDirectory $TemporaryPathForDSD
				}
				catch {
					return $_
				}
			}

			# if FOD image and capabilities to add provided...
			if ($PSBoundParameters.ContainsKey('PathToFeaturesIsoImage') -and $CapabilitiesToAdd.Count) {
				# report state
				"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Dismounting FOD image...'

				# dismount Feature on Demand ISO image
				try {
					$null = $FeaturesDiskImage | Dismount-DiskImage
				}
				catch {
					return $_
				}
			}
		}

		# if file system is FAT32...
		if ($FileSystem -eq 'FAT32') {
			# report state
			"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Splitting WIM image...'

			# split images into 4GB chunks
			try {
				$null = Split-WindowsImage -ImagePath $ImagePathForWIM -SplitImagePath $ImagePathForSWM -FileSize 4096 -ScratchDirectory $TemporaryPathForDSD
			}
			catch {
				return $_
			}

			# remove original WIM image
			try {
				Remove-Item -Path $ImagePathForWIM -Force
			}
			catch {
				return $_
			}
		}

		# if autounattend file provided...
		if ($PSBoundParameters.ContainsKey('PathToAutounattendFile')) {
			# report state
			"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Updating ISO contents with Autounattend file', $AutounattendXmlOnISO

			# get contents of autounattend file
			try {
				$Content = Get-Content -Path $PathToAutounattendFile -Raw -ErrorAction 'Stop'
			}
			catch {
				return $_
			}

			# if administrator password provided...
			if ($PSBoundParameters.ContainsKey('AdministratorPassword')) {
				$Content = $Content -replace '<!-- <AdministratorPassword>', '<AdministratorPassword>'
				$Content = $Content -replace '</AdministratorPassword> -->', '</AdministratorPassword>'
			}

			# while content contains XML element with expand string as value...
			while ($Content -match '<\w+>%(?<ExpandString>\w+)%</\w+>') {
				# retrieve original XML element
				$OriginalString = $Matches[0]
				# retrieve expand string
				$ExpandString = $Matches['ExpandString']
				# if value for expand string provided...
				if ($UnattendExpandStrings.ContainsKey($ExpandString)) {
					# replace the expand string with the provided value
					$ModifiedString = $OriginalString -replace "%$ExpandString%", $UnattendExpandStrings[$ExpandString]
				}
				else {
					# comment out the original XML element
					$ModifiedString = '<!-- {0} -->' -f ($OriginalString -replace '%')
				}
				# replace original XML element with modified XML element
				$Content = $Content -replace $OriginalString, $ModifiedString
			}

			# add autounattend file to ISO
			try {
				$Content | Set-Content -Path $AutounattendXmlOnISO -Force -ErrorAction 'Stop'
			}
			catch {
				return $_
			}
		}

		# if unattend file provided...
		if ($PSBoundParameters.ContainsKey('PathToUnattendFile')) {
			# report state
			"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Updating ISO contents with Unattend file', $UnattendXmlOnISO

			# get contents of unattend file
			try {
				$Content = Get-Content -Path $PathToUnattendFile -Raw -ErrorAction 'Stop'
			}
			catch {
				return $_
			}

			# if administrator password provided...
			if ($PSBoundParameters.ContainsKey('AdministratorPassword')) {
				$Content = $Content -replace '<!-- <AdministratorPassword>', '<AdministratorPassword>'
				$Content = $Content -replace '</AdministratorPassword> -->', '</AdministratorPassword>'
			}

			# while content contains XML element with expand string as value...
			while ($Content -match '<\w+>%(?<ExpandString>\w+)%</\w+>') {
				# retrieve original XML element
				$OriginalString = $Matches[0]
				# retrieve expand string
				$ExpandString = $Matches['ExpandString']
				# if value for expand string provided...
				if ($UnattendExpandStrings.ContainsKey($ExpandString)) {
					# replace the expand string with the provided value
					$ModifiedString = $OriginalString -replace "%$ExpandString%", $UnattendExpandStrings[$ExpandString]
				}
				else {
					# comment out the original XML element
					$ModifiedString = '<!-- {0} -->' -f ($OriginalString -replace '%')
				}
				# replace original XML element with modified XML element
				$Content = $Content -replace $OriginalString, $ModifiedString
			}

			# add unattend file to ISO
			try {
				$Content | Set-Content -Path $UnattendXmlOnISO -Force -ErrorAction 'Stop'
			}
			catch {
				return $_
			}
		}

		# if script folder provided...
		if ($PSBoundParameters.ContainsKey('PathToScriptFolder')) {
			# define scripts folder on ISO
			$ScriptFolderForISO = Join-Path -Path $TemporaryPathForISO -ChildPath 'scripts'

			# if script folder on ISO not found...
			if (![System.IO.Directory]::Exists($ScriptFolderForISO)) {
				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Creating ISO scripts folder', $ScriptFolderForISO

				# create folder
				try {
					$null = New-Item -ItemType Directory -Path $ScriptFolderForISO -Force -ErrorAction 'Stop'
				}
				catch {
					return $_
				}
			}

			# retrieve files in script folder
			$Files = Get-ChildItem -Path $PathToScriptFolder -Filter '*.ps1'

			# loop through files
			foreach ($File in $Files) {
				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Adding script to ISO scripts folder', $File.Name

				# create path for file on ISO
				$FileOnISO = Join-Path -Path $ScriptFolderForISO -ChildPath $File.Name

				# copy file to ISO
				try {
					Copy-Item -Path $File.FullName -Destination $FileOnISO -Force -ErrorAction 'Stop'
				}
				catch {
					return $_
				}
			}
		}

		# if resources folder provided...
		if ($PSBoundParameters.ContainsKey('PathToResourcesFolder')) {
			# define resources folder on ISO
			$ResourcesFolderForISO = Join-Path -Path $TemporaryPathForISO -ChildPath 'resources'

			# if resources folder on ISO not found...
			if (![System.IO.Directory]::Exists($FilesFolderForISO)) {
				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Creating ISO resources folder', $ResourcesFolderForISO

				# create folder
				try {
					$null = New-Item -ItemType Directory -Path $ResourcesFolderForISO -Force -ErrorAction 'Stop'
				}
				catch {
					return $_
				}
			}

			# retrieve resources folder
			try {
				$ResourcesFolder = Get-Item -Path $PathToResourcesFolder
			}
			catch {
				return $_
			}

			# retrieve folders in resources folder
			try {
				$Folders = Get-ChildItem -Recurse -Path $PathToResourcesFolder -Directory
			}
			catch {
				return $_
			}

			# loop through folders
			foreach ($Folder in $Folders) {
				# define relative folder path
				$RelativeFolderPath = $Folder.FullName.Replace($ResourcesFolder.FullName, '')

				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Adding folder to ISO resources folder', $RelativeFolderPath

				# file path in ISO
				$FolderPath = Join-Path -Path $ResourcesFolderForISO -ChildPath $RelativeFolderPath

				# copy item to folder
				try {
					$null = New-Item -Path $FolderPath -ItemType Directory -Force -ErrorAction 'Stop'
				}
				catch {
					return $_
				}
			}

			# retrieve files in resources folder
			try {
				$Files = Get-ChildItem -Recurse -Path $PathToResourcesFolder -File -ErrorAction 'Stop'
			}
			catch {
				return $_
			}

			# loop through files
			foreach ($File in $Files) {
				# define relative file path
				$RelativeFilePath = $File.FullName.Replace($ResourcesFolder.FullName, '')

				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Adding file to ISO resources folder', $RelativeFilePath

				# define destination file path in ISO
				$FileOnISO = Join-Path -Path $ResourcesFolderForISO -ChildPath $RelativeFilePath

				# copy file to ISO
				try {
					$null = Copy-Item -Path $File.FullName -Destination $FileOnISO -Force -ErrorAction 'Stop'
				}
				catch {
					return $_
				}
			}
		}
	}

	# if stop requested...
	if ($StopAfterPreparingImage) {
		"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Image prepared in staging path', $TemporaryPathForISO
		return
	}

	########################################
	# write prepared image to ISO image
	########################################

	# if ISO image exists...
	if ([System.IO.File]::Exists($PathForUpdatedIsoImage)) {
		# report state
		"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Removing ISO image', $PathForUpdatedIsoImage

		# retrieve existing ISO image
		try {
			$Item = Get-Item -Path $PathForUpdatedIsoImage -ErrorAction 'Stop'
		}
		catch {
			return $_
		}

		# remove existing ISO image
		try {
			$Item | Remove-Item -Force -ErrorAction 'Stop'
		}
		catch {
			return $_
		}
	}

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Creating ISO image', $PathForUpdatedIsoImage

	# if filesystem label suffix exists...
	if (![System.String]::IsNullOrEmpty($FileSystemLabelSuffix)) {
		# append suffix to filesystem label
		$FileSystemLabel = '{0}_{1}' -f $FileSystemLabel, $FileSystemLabelSuffix

		# define file system label length for ISO file system
		$Length = 32

		# if file system label is longer than permitted length...
		if ($FileSystemLabel.Length -gt $Length) {
			# trim file system label to permitted length
			$FileSystemLabel = $FileSystemLabel.Substring(0, $Length)
		}
	}

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Using file system label', $FileSystemLabel

	# define bootdata for ISO image
	$Bootdata = "2#p0,e,b$TemporaryPathForISO\boot\etfsboot.com#pEF,e,b$TemporaryPathForISO\efi\microsoft\boot\efisys_noprompt.bin"

	# define arguments
	# reference: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/oscdimg-command-line-options?view=windows-11
	$ArgumentList = "-l$FileSystemLabel -bootdata:$Bootdata -u2 -udfver102 -o $TemporaryPathForISO $PathForUpdatedIsoImage"

	# if program output should be shown...
	if ($ShowProgramOutputInline) {
		# start process to write updated ISO in current window
		Start-Process -FilePath $FilePathToRequiredProgram -ArgumentList $ArgumentList -Wait -NoNewWindow -ErrorAction Stop
	}
	else {
		# start process to write updated ISO in new window
		Start-Process -FilePath $FilePathToRequiredProgram -ArgumentList $ArgumentList -Wait -Window Normal -ErrorAction Stop
	}
}

end {
	# if Skip Exclude not requested...
	if (!$SkipExclude) {
		try {
			Remove-MpPreference -ExclusionPath $StagingPath -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not remove exclusion for temporary path: $StagingPath"
		}
	}

	# if TemporaryFolder created...
	if ([System.IO.Directory]::Exists($script:TemporaryFolder)) {
		# remove temporary folder and all child items
		try {
			Remove-Item -Path $TemporaryFolder -Recurse -Force -ErrorAction 'Stop'
		}
		catch {
			return $_
		}
	}
}
