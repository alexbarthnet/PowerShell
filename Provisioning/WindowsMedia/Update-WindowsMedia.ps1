<#
.SYNOPSIS
Updates Windows installation media in a staging path.

.DESCRIPTION
Updates Windows installation media in a staging path. This relies on peer scripts to import and export the media.

.PARAMETER PathToFeaturesIsoImage
Path to the Features on Demand (FOD) ISO image.

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
Path to required "update" PowerShell file to add to the Windows image(s). The file will be saved as 'Update-Windows.ps1' under the Windows directory in the Windows image(s).

.PARAMETER PathToInvokeScript
Path to required "invoke" PowerShell file to add to the Windows image(s). The file will be saved as 'Invoke-ScriptsFromRemovableMedia.ps1' under the Windows directory in the Windows image(s).

.PARAMETER PathToDriverFolder
Path to optional folder containing drivers to add to the Windows image(s).

.PARAMETER PathToScriptFolder
Path to optional folder containing PS1 scripts to add to the ISO image.

.PARAMETER PathToResourcesFolder
Path to optional folder containing file resources to add to the ISO image.

.PARAMETER RelativePathToFeaturesFolder
Relative path to folder containing FOD resources on the FOD ISO image. The default value is "LanguagesAndOptionalFeatures"

.PARAMETER UpdateAllWindowsImages
Switch parameter to update all Windows images in the WIM file regardless of Index value in the ExpandStrings hashtable.

.PARAMETER AddVerboseStatusToSetup
Switch parameter to add the Verbose Status to the offline registry in the Windows image(s)

.PARAMETER OptionalFeaturesToDisable
String array containing the names of Windows Optional Features to disable in the Windows image(s).

.PARAMETER OptionalFeaturesToEnable
String array containing the names of Windows Optional Features to enable in the Windows image(s).

.PARAMETER CapabilitiesToRemove
String array containing the names of Windows Capabilities to remove from the Windows image(s).

.PARAMETER CapabilitiesToAdd
String array containing the names of Windows Capabilities to add to the Windows image(s). Requires the PathToFeaturesIsoImage parameter.

.PARAMETER AppxPackagesToRemove
String array containing the names of AppX Packages to remove from the Windows image(s).

.PARAMETER AppxPackagesToAdd
Hashtable containing the names and paths of AppX Packages to add to the Windows image(s). Each entry in the hashtable must be populated as follows:
 - Key: the displayname of the AppX package
 - Value: a hashtable of the parameters required for the Add-AppxProvisionedPackage command to install the AppX package but excluding the Path parameter

.PARAMETER PackagesToRemove
String array containing the names of Windows Packages to remove from the Windows image(s).

.PARAMETER PackagesToAdd
Hashtable containing the names and paths of Windows Packages to add to the Windows image(s). Each entry in the hashtable must be populated as follows:
 - Key: the name of the Windows package
 - Value: a hashtable of the parameters required for the Add-WindowsPackage command to install the Windows package but excluding the Path parameter

.PARAMETER LocalAdminCredential
Credential containing the local administrator password to add to unattend XML files.

.PARAMETER DomainJoinCredential
Credential containing the domain join username and password to add to unattend XML files.

.PARAMETER ExpandStrings
Hashtable of expand strings and values for autounattend and unattend XML files. The default values are as follows:
 - DiskID = 0 (default disk ID for systems with a single disk)
 - Index = 4 (default index for Datacenter with Desktop Experience since Windows Server 2016)
 - ProductKey = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF' (KMS activation key for Windows Server 2025 Datacenter)

.PARAMETER Path
Path to the staging folder for the Windows installation media. This value is only required when updating media in an existing staging path and the staging path parameter has been cleared.

.PARAMETER SkipExclude
Switch parameter to skip creating Microsoft Defender path exclusion for the staging path.

.INPUTS
None.

.OUTPUTS
None. The function does not generate any output.

#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
	[Parameter()][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToFeaturesIsoImage,
	[Parameter()][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToAutounattendFile,
	[Parameter()][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToUnattendFile,
	[Parameter()][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToUpdateScript,
	[Parameter()][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToInvokeScript,
	[Parameter()][ValidateScript({ [System.IO.Directory]::Exists($_) })]
	[string]$PathToDriverFolder,
	[Parameter()][ValidateScript({ [System.IO.Directory]::Exists($_) })]
	[string]$PathToScriptFolder,
	[Parameter()][ValidateScript({ [System.IO.Directory]::Exists($_) })]
	[string]$PathToResourcesFolder,
	[Parameter()]
	[string]$RelativePathToFeaturesFolder = 'LanguagesAndOptionalFeatures',
	[Parameter()]
	[switch]$UpdateAllWindowsImages,
	[Parameter()]
	[switch]$AddVerboseStatusToSetup,
	[Parameter()]
	[string[]]$OptionalFeaturesToDisable,
	[Parameter()]
	[string[]]$OptionalFeaturesToEnable,
	[Parameter()]
	[string[]]$CapabilitiesToRemove,
	[Parameter()]
	[string[]]$CapabilitiesToAdd,
	[Parameter()]
	[string[]]$AppxPackagesToRemove,
	[Parameter()]
	[hashtable]$AppxPackagesToAdd,
	[Parameter()]
	[string[]]$PackagesToRemove,
	[Parameter()]
	[hashtable]$PackagesToAdd,
	[Parameter()]
	[pscredential]$LocalAdminCredential,
	[Parameter()]
	[pscredential]$DomainJoinCredential,
	[Parameter()]
	[hashtable]$ExpandStrings = @{
		DiskID     = 0
		Index      = 4
		ProductKey = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF'
	},
	[Parameter(Mandatory = $false)]
	[switch]$SplitImage,
	[Parameter(Mandatory = $false)]
	[string]$Path,
	[Parameter(Mandatory = $false)]
	[switch]$SkipExclude
)

begin {
	function Resolve-ExpandStringsInXML {
		param(
			[Parameter(Mandatory)]
			[string]$String,
			[Parameter(Mandatory)]
			[hashtable]$ExpandStrings
		)

		# if administrator password provided...
		if ($ExpandStrings.ContainsKey('AdministratorPassword')) {
			# uncomment administrator password section in unattend file
			$String = $String.Replace('<!-- <AdministratorPassword>', '<AdministratorPassword>')
			$String = $String.Replace('</AdministratorPassword> -->', '</AdministratorPassword>')
		}
		# if administrator password not provided...
		else {
			# hide administrator password expand string from the expand strings loop
			$String = $String -replace '%ADMINISTRATORPASSWORD%', '<%>ADMINISTRATORPASSWORD<%>'
		}

		# if domain join username and password provided...
		if ($ExpandStrings.ContainsKey('Username') -and $ExpandStrings.ContainsKey('Password')) {
			# uncomment domain join section in unattend file
			$String = $String.Replace('<!-- <identification>', '<identification>')
			$String = $String.Replace('</identification> -->', '</identification>')
			# uncomment domain accounts section in unattend file
			$String = $String.Replace('<!-- <DomainAccounts>', '<DomainAccounts>')
			$String = $String.Replace('</DomainAccounts> -->', '</DomainAccounts>')
		}
		# if domain join username and password not provided...
		else {
			# hide domain join expand strings from the expand strings loop
			$String = $String.Replace('%USERNAME%', '<%>USERNAME<%>')
			$String = $String.Replace('%PASSWORD%', '<%>PASSWORD<%>')
			$String = $String.Replace('%DOMAINNAME%', '<%>DOMAINNAME<%>')
			$String = $String.Replace('%ORGANIZATIONALUNIT%', '<%>ORGANIZATIONALUNIT<%>')
		}

		# while content contains XML element with expand string as value...
		while ($String -match '<\w+>%(?<ExpandString>\w+)%</\w+>') {
			# retrieve original XML element
			$OriginalString = $Matches[0]
			# retrieve expand string
			$ExpandString = $Matches['ExpandString']
			# if value for expand string provided...
			if ($ExpandStrings.ContainsKey($ExpandString)) {
				# replace the expand string with the provided value
				$ModifiedString = $OriginalString -replace "%$ExpandString%", $ExpandStrings[$ExpandString]
			}
			else {
				# comment out the original XML element
				$ModifiedString = '<!-- {0} -->' -f ($OriginalString -replace '%', '<%>')
			}
			# replace original XML element with modified XML element
			$String = $String -replace $OriginalString, $ModifiedString
		}

		# return updated string
		return $String
	}

	# if parameter for staging path defined...
	if ($PSBoundParameters.ContainsKey('Path')) {
		# if staging path is not an absolute path...
		if (![System.IO.Path]::IsPathRooted($Path)) {
			# get unresolved absolute path
			try {
				$Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
			}
			catch {
				Write-Warning -Message "could not create absolute path from the provided Path parameter: $Path"
				$PSCmdlet.ThrowTerminatingError($_)
			}

			# report absolute path
			Write-Warning -Message "converted relative path from provided Path parameter to absolute path: $Path"
		}

		# if global staging path exists is not provided path...
		if ($global:WindowsMediaStagingPath -and $global:WindowsMediaStagingPath -ne $Path) {
			Write-Warning -Message "found existing global staging path: $global:WindowsMediaStagingPath"
			Write-Warning -Message 'continue to overwrite with provided Path' -WarningAction Inquire
		}

		# store staging path in global variable
		try {
			New-Variable -Name 'WindowsMediaStagingPath' -Value $Path -Scope global -Force
		}
		catch {
			Write-Warning -Message 'could not store provided Path parameter as global WindowsMediaStagingPath variable'
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}
	# if parameter for staging path not defined...
	else {
		# if global staging path not defined...
		if ([System.String]::IsNullOrEmpty($global:WindowsMediaStagingPath)) {
			# warn and return
			Write-Warning -Message 'could not locate existing staging path: global WindowsMediaStagingPath variable is null or empty'
			Write-Warning -Message 'create a staging path with the Import-WindowsMedia.ps1 script or provide the Path parameter to define the staging path'
			return
		}
		# if global staging defined...
		else {
			# ...but not found...
			if (![System.IO.Directory]::Exists($global:WindowsMediaStagingPath)) {
				# warn and return
				Write-Warning -Message 'could not locate folder for existing staging path: value of global WindowsMediaStagingPath variable is not a folder'
				Write-Warning -Message 'create a staging path with the Import-WindowsMedia.ps1 script or provide the Path parameter to define the staging path'
				return
			}
			else {
				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Found existing staging path', $global:WindowsMediaStagingPath
			}
		}
	}

	# if Skip Exclude not requested...
	if ($SkipExclude.IsPresent -eq $false) {
		# add the staging path to the excluded paths in Windows Defender
		try {
			Add-MpPreference -ExclusionPath $global:WindowsMediaStagingPath -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not add Windows Defender path exclusion for staging path: $global:WindowsMediaStagingPath"
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# retrieve Windows Defender configuration
		try {
			$MpPreference = Get-MpPreference
		}
		catch {
			Write-Warning -Message 'could not retrieve Windows Defender preferences to check excluded paths'
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# if the staging path is not in the excluded paths in Windows Defender...
		if ($global:WindowsMediaStagingPath -notin $MpPreference.ExclusionPath) {
			# warn and inquire
			Write-Warning -Message "the Windows Defender excluded paths do not contain the global staging path: $global:WindowsMediaStagingPath"
			Write-Warning -Message 'continue to process the Windows Media without the staging path excluded from Windows Defender scanning' -WarningAction Inquire
		}
	}

	# create base temporary path
	try {
		$TemporaryPath = New-Item -ItemType Directory -Path $global:WindowsMediaStagingPath -Force -ErrorAction 'Stop'
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

	# create temporary path for WIM file
	try {
		$TemporaryPathForWIM = New-Item -ItemType Directory -Path $TemporaryPath -Name 'WIM' -Force -ErrorAction 'Stop'
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($_)
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
		$ExpandStrings['AdministratorPassword'] = $EncodedAdministratorPassword
	}

	# if unattended join credential provided...
	if ($PSBoundParameters.ContainsKey('DomainJoinCredential')) {
		# add plaintext unattended join password to expand strings hashtable
		$ExpandStrings['Username'] = $DomainJoinCredential.GetNetworkCredential().Username

		# add plaintext unattended join password to expand strings hashtable
		$ExpandStrings['Password'] = $DomainJoinCredential.GetNetworkCredential().Password
	}

	# define relative items
	$AutounattendXmlOnISO = "$TemporaryPathForISO\Autounattend.xml"
	$UnattendXmlOnISO = "$TemporaryPathForISO\Unattend.xml"
	$ImagePathForWIM = "$TemporaryPathForISO\sources\install.wim"
	$ImagePathForSWM = "$TemporaryPathForISO\sources\install.swm"
	$UpdatePs1OnWIM = "$TemporaryPathForWIM\Windows\Update-Windows.ps1"
	$InvokePs1OnWIM = "$TemporaryPathForWIM\Windows\Invoke-ScriptsFromRemovableMedia.ps1"
	$SoftwareHiveOnWIM = "$TemporaryPathForWIM\Windows\System32\Config\Software"
}

process {
	# if WIM not found...
	if (![System.IO.File]::Exists($ImagePathForWIM)) {
		# warn and return
		Write-Warning -Message "could not locate WIM file at expected location in staging path: $ImagePathForWIM"
		return
	}

	# define boolean for updating the WIM
	$WIMUpdateRequired = $false

	# define parameters that require updating the WIM
	$WIMUpdatingParameters = @(
		'PathToUpdateScript'
		'PathToInvokeScript'
		'PathToDriverFolder'
		'AddVerboseStatusToSetup'
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
		# if capabilities to add provided...
		if ($PSBoundParameters.ContainsKey('CapabilitiesToAdd') -and $CapabilitiesToAdd.Count) {
			# if FOD image not provided...
			if (!$PSBoundParameters.ContainsKey('PathToFeaturesIsoImage')) {
				# warn and return
				Write-Warning -Message "The 'CapabilitiesToAdd' parameter requires the 'PathToFeaturesIsoImage' parameter"
				return
			}

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
			Write-Warning -Message "could not clear read only flag on WIM file in staging page: $ImagePathForWIM"
			return $_
		}

		# retrieve windows image
		try {
			$WindowsImage = Get-WindowsImage -ImagePath $ImagePathForWIM
		}
		catch {
			Write-Warning -Message "could not retrieve WIM file in staging page: $ImagePathForWIM"
			return $_
		}

		# loop through indices
		:NextIndex foreach ($Index in $WindowsImage.ImageIndex) {
			# if index provided in unattend strings
			if ($ExpandStrings.ContainsKey('Index') -and -not $UpdateAllWindowsImages) {
				# if current index does not provided index...
				if ($Index -ne $ExpandStrings['Index']) {
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

			# if drivers folder provided...
			if ($PSBoundParameters.ContainsKey('PathToDriverFolder')) {
				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Updating WIM with drivers from folder', $PathToDriverFolder

				# retrieve INF files in drivers folder
				try {
					$InfFiles = Get-ChildItem -Path $PathToDriverFolder -Filter '*.inf' -Recurse
				}
				catch {
					return $_
				}

				# loop through INF files
				foreach ($InfFile in $InfFiles) {
					# report state
					"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Updating WIM with driver', $InfFile.Name

					# add driver to windows image
					try {
						$null = Add-WindowsDriver -Path $TemporaryPathForWIM -Driver $InfFile.FullName
					}
					catch {
						return $_
					}
				}
			}

			# if optional features to disable or enable provided...
			if ($OptionalFeaturesToDisable.Count -or $OptionalFeaturesToEnable.Count) {
				# report state
				"{0}`t{1}: {2}:{3}" -f [System.Datetime]::UtcNow.ToString('o'), 'Retrieving optional features in WIM', $ImagePathForWIM, $Index

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

			# if capabilities to remove provided...
			if ($CapabilitiesToRemove.Count) {
				# report state
				"{0}`t{1}: {2}:{3}" -f [System.Datetime]::UtcNow.ToString('o'), 'Retrieving Windows capabilities in WIM before remove', $ImagePathForWIM, $Index

				# retrieve capabilities in windows image
				try {
					$WindowsCapabilities = Get-WindowsCapability -Path $TemporaryPathForWIM -ErrorAction 'Stop'
				}
				catch {
					return $_
				}

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
				# report state
				"{0}`t{1}: {2}:{3}" -f [System.Datetime]::UtcNow.ToString('o'), 'Retrieving Windows capabilities in WIM before add', $ImagePathForWIM, $Index

				# retrieve capabilities in windows image
				try {
					$WindowsCapabilities = Get-WindowsCapability -Path $TemporaryPathForWIM -ErrorAction 'Stop'
				}
				catch {
					return $_
				}

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

			# if appx packages to remove provided...
			if ($AppxPackagesToRemove.Count) {
				# report state
				"{0}`t{1}: {2}:{3}" -f [System.Datetime]::UtcNow.ToString('o'), 'Retrieving AppX packages in WIM before remove', $ImagePathForWIM, $Index

				# retrieve appx packages in windows image
				try {
					$AppxPackages = Get-AppxProvisionedPackage -Path $TemporaryPathForWIM -ScratchDirectory $TemporaryPathForDSD -ErrorAction 'Stop'
				}
				catch {
					return $_
				}

				# loop through appx packages
				:NextAppxPackageToRemove foreach ($DisplayName in $AppxPackagesToRemove) {
					# retrieve appx package by name
					$AppxPackage = $AppxPackages | Where-Object { $_.DisplayName -eq $DisplayName }

					# if appx package not found...
					if (!$AppxPackage) {
						# report state and continue to next package
						"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Cannot remove unknown AppX package from WIM', $DisplayName
						continue NextAppxPackageToRemove
					}

					# report state
					"{0}`t{1}: {2} ({3})" -f [System.Datetime]::UtcNow.ToString('o'), 'Removing AppX package from WIM', $DisplayName, $AppxPackage.PackageName

					# remove appx package from windows image
					try {
						$null = Remove-AppxProvisionedPackage -Path $TemporaryPathForWIM -PackageName $AppxPackage.PackageName -ScratchDirectory $TemporaryPathForDSD -ErrorAction 'Stop'
					}
					catch {
						Write-Warning -Message "could not remove '$PackageName' AppX package from WIM: $($_.Exception.Message)"
					}
				}
			}

			# if appx packages to add provided...
			if ($AppxPackagesToAdd.Keys.Count) {
				# report state
				"{0}`t{1}: {2}:{3}" -f [System.Datetime]::UtcNow.ToString('o'), 'Retrieving AppX packages in WIM before add', $ImagePathForWIM, $Index

				# retrieve appx packages in windows image
				try {
					$AppxPackages = Get-AppxProvisionedPackage -Path $TemporaryPathForWIM -ScratchDirectory $TemporaryPathForDSD -ErrorAction 'Stop'
				}
				catch {
					return $_
				}

				# loop through appx packages
				:NextAppxPackageToAdd foreach ($DisplayName in $AppxPackagesToAdd.Keys) {
					# retrieve appx package by name
					$AppxPackage = $AppxPackages | Where-Object { $_.DisplayName -eq $DisplayName }

					# if appx package already added...
					if ($AppxPackage) {
						# report state and continue to next appx package
						"{0}`t{1}: {2}, {3}" -f [System.Datetime]::UtcNow.ToString('o'), 'Requested AppX package already added to WIM', $DisplayName, $AppxPackage.PackageName
						continue NextAppxPackageToAdd
					}

					# report state
					"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Adding AppX package to WIM', $DisplayName

					# define parameters hashtable from provided parameters
					$AddAppxProvisionedPackage = $AppxPackagesToAdd[$DisplayName]

					# update parameters hashtable with script values
					$AddAppxProvisionedPackage['Path'] = $TemporaryPathForWIM
					$AddAppxProvisionedPackage['ScratchDirectory'] = $TemporaryPathForDSD
					$AddAppxProvisionedPackage['ErrorAction'] = [System.Management.Automation.ActionPreference]::Stop

					# add appx package to windows image
					try {
						$null = Add-AppxProvisionedPackage @AddAppxProvisionedPackage
					}
					catch {
						Write-Warning -Message "could not add '$DisplayName' AppX package to WIM: $($_.Exception.Message)"
					}
				}
			}

			# if packages to remove provided...
			if ($PackagesToRemove.Count) {
				# report state
				"{0}`t{1}: {2}:{3}" -f [System.Datetime]::UtcNow.ToString('o'), 'Retrieving Windows packages in WIM before remove', $ImagePathForWIM, $Index

				# retrieve packages in windows image
				try {
					$WindowsPackages = Get-WindowsPackage -Path $TemporaryPathForWIM -ErrorAction 'Stop'
				}
				catch {
					return $_
				}

				# loop through packages
				:NextPackageToRemove foreach ($PackageName in $PackagesToRemove) {
					# retrieve package by name
					$WindowsPackage = $WindowsPackages | Where-Object { $_.PackageName -eq $PackageName }

					# if package not found...
					if (!$WindowsPackage) {
						# report state and continue to next package
						"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Cannot remove unknown package from WIM', $PackageName
						continue NextPackageToRemove
					}

					# if package already enabled...
					if ($WindowsPackage.PackageState -eq 'NotPresent') {
						# report state and continue to next package
						"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Requested package already removed from WIM', $PackageName
						continue NextPackageToRemove
					}

					# report state
					"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Removing package from WIM', $PackageName

					# remove package from windows image
					try {
						$null = Remove-WindowsPackage -Path $TemporaryPathForWIM -PackageName $PackageName -ErrorAction 'Stop'
					}
					catch {
						Write-Warning -Message "could not remove '$PackageName' package from WIM: $($_.Exception.Message)"
					}
				}
			}

			# if packages to add provided...
			if ($PackagesToAdd.Keys.Count) {
				# report state
				"{0}`t{1}: {2}:{3}" -f [System.Datetime]::UtcNow.ToString('o'), 'Retrieving Windows packages in WIM before add', $ImagePathForWIM, $Index

				# retrieve packages in windows image
				try {
					$WindowsPackages = Get-WindowsPackage -Path $TemporaryPathForWIM -ErrorAction 'Stop'
				}
				catch {
					return $_
				}

				# loop through packages
				:NextPackageToAdd foreach ($PackageName in $PackagesToAdd.Keys) {
					# retrieve package by name
					$WindowsPackage = $WindowsPackages | Where-Object { $_.PackageName -eq $PackageName }

					# if package not found...
					if (!$WindowsPackage) {
						# report state and continue to next package
						"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Cannot add unknown package to WIM', $PackageName
						continue NextPackageToAdd
					}

					# if package already added...
					if ($WindowsPackage.PackageState -eq 'Installed') {
						# report state and continue to next package
						"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Requested package already added to WIM', $PackageName
						continue NextPackageToAdd
					}

					# report state
					"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Adding package to WIM', $PackageName

					# define parameters hashtable from provided parameters
					$AddWindowsPackage = $PackagesToAdd[$PackageName]

					# update parameters hashtable with script values
					$AddWindowsPackage['Path'] = $TemporaryPathForWIM
					$AddWindowsPackage['ScratchDirectory'] = $TemporaryPathForDSD
					$AddWindowsPackage['ErrorAction'] = [System.Management.Automation.ActionPreference]::Stop

					# add package to windows image
					try {
						$null = Add-WindowsPackage @AddWindowsPackage
					}
					catch {
						Write-Warning -Message "could not add '$PackageName' package to WIM: $($_.Exception.Message)"
					}
				}
			}

			# if verbose status in setup requested...
			if ($AddVerboseStatusToSetup) {
				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Loading SOFTWARE registry hive in WIM', $SoftwareHiveOnWIM

				# load software hive
				try {
					$Process = Start-Process -PassThru -Wait -WindowStyle Hidden -FilePath 'reg.exe' -ArgumentList "load HKLM\OFFLINE $SoftwareHiveOnWIM"
				}
				catch {
					return $_
				}

				# if process exit is not 0...
				if ($Process.ExitCode -ne 0) {
					Write-Warning -Message "could not load SOFTWARE registry hive in WIM: $SoftwareHiveOnWIM"
					return
				}

				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Updating SOFTWARE registry hive in WIM', $SoftwareHiveOnWIM

				# load software hive
				try {
					$Process = Start-Process -PassThru -Wait -WindowStyle Hidden -FilePath 'reg.exe' -ArgumentList 'add HKLM\OFFLINE\Microsoft\Windows\CurrentVersion\Policies\System /v VerboseStatus /t REG_DWORD /d 1 /f'
				}
				catch {
					return $_
				}

				# if process exit is not 0...
				if ($Process.ExitCode -ne 0) {
					Write-Warning -Message "could not update SOFTWARE registry hive in WIM: $SoftwareHiveOnWIM"
					return
				}

				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Unloading SOFTWARE registry hive in WIM', $SoftwareHiveOnWIM

				# load software hive
				try {
					$Process = Start-Process -PassThru -Wait -WindowStyle Hidden -FilePath 'reg.exe' -ArgumentList 'unload HKLM\OFFLINE'
				}
				catch {
					return $_
				}

				# if process exit is not 0...
				if ($Process.ExitCode -ne 0) {
					Write-Warning -Message "could not unload SOFTWARE registry hive in WIM: $SoftwareHiveOnWIM"
					return
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

		# if Feature on Demand ISO image mounted...
		if ($FeaturesDiskImage) {
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

	# if split image requested...
	if ($SplitImage) {
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

		# resolve expand strings in autounattend file
		try {
			$Content = Resolve-ExpandStringsInXML -String $Content -ExpandStrings $ExpandStrings
		}
		catch {
			return $_
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

		# resolve expand strings in autounattend file
		try {
			$Content = Resolve-ExpandStringsInXML -String $Content -ExpandStrings $ExpandStrings
		}
		catch {
			return $_
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
		if (![System.IO.Directory]::Exists($ResourcesFolderForISO)) {
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

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Windows media prepared in staging path', $TemporaryPathForISO
}

end {
	# if Skip Exclude not requested...
	if (!$SkipExclude) {
		# remove the staging path from the excluded paths in Windows Defender
		try {
			Remove-MpPreference -ExclusionPath $global:WindowsMediaStagingPath -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not remove Windows Defender path exclusion for staging path: $global:WindowsMediaStagingPath"
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}
}