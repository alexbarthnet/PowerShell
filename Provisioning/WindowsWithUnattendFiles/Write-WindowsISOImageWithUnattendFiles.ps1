<#
.SYNOPSIS
Create a Windows ISO image with unattend files from a Windows ISO image.

.DESCRIPTION
Create a Windows ISO image with unattend files from a Windows ISO image.

.PARAMETER PathToOriginalIsoImage
Path to the original Windows ISO image.

.PARAMETER PathForUpdatedIsoImage
Path for the updated Windows ISO image.

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
Path to required "update" PS1 file to add to WIM file. The file will be saved as 'Update-Windows.ps1' under the Windows directory in the WIM image.

.PARAMETER PathToInvokeScript
Path to required "invoke" PS1 file to add to WIM file. The file will be saved as 'Invoke-ScriptsFromRemovableMedia.ps1' under the Windows directory in the WIM image.

.PARAMETER PathToScriptFolder
Path to optional folder containing PS1 scripts to add to the ISO image.

.PARAMETER PathToResourcesFolder
Path to optional folder containing file resources to add to the ISO image.

.PARAMETER StagingPath
Path to folder for staging the ISO file contents and mounting the WIM image. The default staging path is a randomly named folder in the system temp directory.

.PARAMETER EmptyStagingPath
Switch parameter to remove any existing files and folders in the StagingPath folder.

.PARAMETER ReuseStagingPath
Switch parameter to use any existing files and folders in the StagingPath folder rather than copying new files from the original ISO image or provided folders.

.PARAMETER StopAfterPreparingImage
Switch parameter to stop after preparing the contents for the ISO image. Requires StagingPath parameter.

.PARAMETER SkipExclude
Switch parameter to skip creating Microsoft Defender path exclusion for the staging path.

.PARAMETER UpdateAllWindowsImages
Switch parameter to update all images in the WIM file regardless of Index value in the UnattendExpandStrings hashtable.

.PARAMETER AdministratorPassword
Credential containing the administrator password to add to unattend XML files.

.PARAMETER UnattendedJoinCredential
Credential containing the unattended domain join username and password to add to unattend XML files.

.PARAMETER UnattendExpandStrings
Hashtable of expand strings and values for autounattend and unattend XML files. The default values are as follows:
 - Index = 4 (default index for Datacenter with Desktop Experience since Windows Server 2016)
 - ProductKey = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF' (KMS activation key for Windows Server 2025 Datacenter)

.INPUTS
None.

.OUTPUTS
None. The function does not generate any output.

.LINK
https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nn-wuapi-iinstallationresult

.LINK
https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdatesearcher-search

.LINK
https://learn.microsoft.com/en-us/windows/win32/api/wuapi/ne-wuapi-operationresultcode

.LINK
https://learn.microsoft.com/en-us/windows/win32/wua_sdk/searching--downloading--and-installing-updates

.LINK
https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-deployment-runsynchronous-runsynchronouscommand-willreboot

.LINK
https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys

.LINK
https://learn.microsoft.com/en-us/windows-server/get-started/automatic-vm-activation

#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
	[Parameter(Position = 0, Mandatory = $true)][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToOriginalIsoImage,
	[Parameter(Position = 1, Mandatory = $true)]
	[string]$PathForUpdatedIsoImage,
	[Parameter(Position = 2)]
	[string]$PathToBinaryFile = 'oscdimg.exe',
	[Parameter(Position = 3)][ValidateScript({ [System.IO.Directory]::Exists($_) })]
	[string]$PathToBinaryFolder = (Join-Path -Path ([System.Environment]::GetFolderPath('ProgramFilesx86')) -ChildPath '\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg'),
	[Parameter(Position = 4)][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToAutounattendFile,
	[Parameter(Position = 5)][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToUnattendFile,
	[Parameter(Position = 6)][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToUpdateScript,
	[Parameter(Position = 7)][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToInvokeScript,
	[Parameter(Position = 8)][ValidateScript({ [System.IO.Directory]::Exists($_) })]
	[string]$PathToScriptFolder,
	[Parameter(Position = 9)][ValidateScript({ [System.IO.Directory]::Exists($_) })]
	[string]$PathToResourcesFolder,
	[Parameter(Position = 10, ParameterSetName = 'StagingPath', Mandatory = $true)][ValidateScript({ [System.IO.Directory]::Exists($_) })]
	[string]$StagingPath,
	[Parameter(Position = 11, ParameterSetName = 'StagingPath')]
	[switch]$EmptyStagingPath,
	[Parameter(Position = 12, ParameterSetName = 'StagingPath')]
	[switch]$ReuseStagingPath,
	[Parameter(Position = 13, ParameterSetName = 'StagingPath')]
	[switch]$StopAfterPreparingImage,
	[Parameter(Position = 14)]
	[switch]$SkipExclude,
	[Parameter(Position = 15)]
	[pscredential]$AdministratorPassword,
	[Parameter(Position = 16)]
	[pscredential]$UnattendedJoinCredential,
	[Parameter(Position = 17)]
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
			$TemporaryFolder = New-Item -Force -ItemType Directory -Path $PathForTemporaryFolder
		}
		catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# return temporary folder
		return $TemporaryFolder
	}

	# define path to required program
	$FilePath = Join-Path -Path $PathToBinaryFolder -ChildPath $PathToBinaryFile

	# validate application path
	try {
		$null = Get-Item -Path $FilePath
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# if administrator password provided...
	if ($PSBoundParameters.ContainsKey('AdministratorPassword')) {
		# retrieve plaintext password from credential object
		try {
			$PlainText = $AdministratorPassword.GetNetworkCredential().Password
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
	if ($PSBoundParameters.ContainsKey('UnattendedJoinCredential')) {
		# add plaintext unattended join password to expand strings hashtable
		$UnattendExpandStrings['Username'] = $UnattendedJoinCredential.GetNetworkCredential().Username

		# add plaintext unattended join password to expand strings hashtable
		$UnattendExpandStrings['Password'] = $UnattendedJoinCredential.GetNetworkCredential().Password
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
		$TemporaryPath = New-Item -Force -ItemType Directory -Path $StagingPath
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# create temporary path for DISM scratch directory
	try {
		$TemporaryPathForDSD = New-Item -Force -ItemType Directory -Path $TemporaryPath -Name 'DSD'
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# create temporary path for ISO contents
	try {
		$TemporaryPathForISO = New-Item -Force -ItemType Directory -Path $TemporaryPath -Name 'ISO'
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# create temporary path for WIM file
	try {
		$TemporaryPathForWIM = New-Item -Force -ItemType Directory -Path $TemporaryPath -Name 'WIM'
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# if Skip Exclude not requested...
	if (!$SkipExclude) {
		try {
			Add-MpPreference -ExclusionPath $StagingPath -ErrorAction Stop
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
	# prepare image
	########################################

	# if staging path provided and reuse staging path not set...
	if ($StagingPath -and -not $ReuseStagingPath) {
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

		# retrieve volume properties
		$ImageDriveLetter = $Volume.DriveLetter
		$FileSystemLabel = $Volume.FileSystemLabel

		# report state
		"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Copying ISO contents to path', $TemporaryPathForISO

		# copy ISO contents to temporary path
		try {
			Copy-Item -Path ('{0}:\*' -f $ImageDriveLetter) -Destination $TemporaryPathForISO -Recurse -Force
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

		# if scripts provided...
		if ($PathToInvokeScript -or $PathToUpdateScript) {
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
						Copy-Item -Path $PathToUpdateScript -Destination $UpdatePs1OnWIM
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
						Copy-Item -Path $PathToInvokeScript -Destination $InvokePs1OnWIM
					}
					catch {
						return $_
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
				$Content = Get-Content -Path $PathToAutounattendFile -Raw
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
				$Content | Set-Content -Path $AutounattendXmlOnISO
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
				$Content = Get-Content -Path $PathToUnattendFile -Raw
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
				$Content | Set-Content -Path $UnattendXmlOnISO
			}
			catch {
				return $_
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

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Creating ISO image', $PathForUpdatedIsoImage

	# define label for ISO image
	$Label = '{0}-Unattend' -f $FileSystemLabel

	# define timestamp for files in ISO image
	# $Timestamp = Get-Date -Format "MM/dd/yyyy,HH:mm:ss"

	# define bootdata for ISO image
	$Bootdata = "2#p0,e,b$TemporaryPathForISO\boot\etfsboot.com#pEF,e,b$TemporaryPathForISO\efi\microsoft\boot\efisys_noprompt.bin"

	# define arguments
	$ArgumentList = "-l$Label -bootdata:$Bootdata -u2 -udfver102 -o $TemporaryPathForISO $PathForUpdatedIsoImage"
	# $ArgumentList = "-l$Label -t$Timestamp -bootdata:$Bootdata -u2 -udfver102 -o $TemporaryPathForISO $PathForUpdatedIsoImage"

	# if no new window requested...
	if ($NoNewWindow) {
		# start process to write updated ISO in current window
		Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -NoNewWindow -ErrorAction Stop
	}
	else {
		# start process to write updated ISO in new window
		Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -Window Normal -ErrorAction Stop
	}
}

end {
	# if Skip Exclude not requested...
	if (!$SkipExclude) {
		try {
			Remove-MpPreference -ExclusionPath $StagingPath -ErrorAction Stop
		}
		catch {
			Write-Warning -Message "could not remove exclusion for temporary path: $StagingPath"
		}
	}
	
	# if TemporaryFolder created...
	if ([System.IO.Directory]::Exists($script:TemporaryFolder)) {
		# remove temporary folder and all child items
		try {
			Remove-Item -Path $TemporaryFolder -Recurse -Force
		}
		catch {
			return $_
		}
	}
}
