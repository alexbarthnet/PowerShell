<#
.SYNOPSIS
Create a Windows Server ISO image for virtual machine templates.

.DESCRIPTION
Create a Windows Server ISO image for virtual machine templates that will install and patch Windows Server then generalize (sysprep) the image.

.PARAMETER PathToOriginalIsoImage
Path to the original Windows Server ISO image.

.PARAMETER PathForUpdatedIsoImage
Path for the updated Windows Server ISO image.

.PARAMETER PathToUnattendFile
Path to unattend XML file to add to Windows Server ISO image. The file will be saved as 'Autounattend.xml' at the root of the ISO file system. This file must call the update script during the auditUser pass.

.PARAMETER PathToUpdateScript
Path to unattend PS1 file to add to Windows Server WIM image. The file will be saved as 'Update-Windows.ps1' under the Windows directory in the WIM image.

.PARAMETER PathToToolsFolder
Path to folder containing required oscdimg.exe program. Required when the deployment tools oscdimg has not been installed in the default location.

.PARAMETER NoNewWindow
Switch parameter to start the oscdimg program in the current window. Primarily used to debug any issues with creating the updated ISO image.

.PARAMETER SkipRemove
Switch parameter to skip removing the temporary files created by this script. Primarily used to debug any issues with the contents of the ISO image or the WIM file.

.PARAMETER StagingPath
Path to folder for staging the ISO file contents and mounting the WIM image. The default staging path is a randomly named folder in the system temp directory.

.PARAMETER ProductKey
String with product key for the Windows image. The default value is the KMS key for Windows Server 2025 Datacenter.

.PARAMETER Index
Integer for index of Windows image. The default value is 4 which maps to the Datacenter with Desktop Experience for Windows Server 2016 and later.

.INPUTS
None.

.OUTPUTS
None. The function does not generate any output.

.NOTES
This script creates and leverages an "applied updates" to avoid a potential loop during Windows setup to address the historical requirement to run Windows Update multiple times to completely update Windows.
This script returns the "The command is still in process" exit code when updates have been installed which enables Windows setup to restart the system and apply the updates and then re-run the script to apply any additional updates.
Windows Update MAY determine that a particular update is required during the search operation but not apply the update during the install operation which can result in an endless loop.
The "applied updates" file contains the ID of any update that was passed to the install function of the Windows Update COM object.
This script will return the "The command was successful. No reboot is required." return code when all updates found by the search operation have been passed to the install function in a previous run.

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

Param(
	[Parameter(Mandatory = $true)]
	[string]$PathToOriginalIsoImage,
	[Parameter(Mandatory = $true)]
	[string]$PathForUpdatedIsoImage,
	[Parameter(Mandatory = $true)]
	[string]$PathToUnattendFile,
	[Parameter(Mandatory = $true)]
	[string]$PathToUpdateScript,
	[string]$PathToToolsFolder,
	[switch]$NoNewWindow,
	[switch]$SkipRemove,
	[string]$StagingPath,
	[string]$ProductKey = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF',
	[uint16]$Index = 4
)

Begin {
	# if path to oscdimg folder not provided...
	If (!$PSBoundParameters.ContainsKey('PathToToolsFolder')) {
		# define default folder path
		$PathToToolsFolder = Join-Path -Path ([System.Environment]::GetFolderPath('ProgramFilesx86')) -ChildPath '\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg'
	}

	# define path to required program
	$FilePath = Join-Path -Path $PathToToolsFolder -ChildPath 'oscdimg.exe'

	# validate application path
	Try {
		$null = Get-Item -Path $FilePath
	}
	Catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# if staging path defined...
	If (!$PSBoundParameters.ContainsKey('StagingPath')) {
		$TemporaryPathRoot = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')
		$TemporaryPathBase = [System.IO.Path]::GetRandomFileName().Replace('.', [System.String]::Empty)
		$StagingPath = Join-Path -Path $TemporaryPathRoot -ChildPath $TemporaryPathBase
	}

	# create base temporary path
	Try {
		$TemporaryPath = New-Item -Force -ItemType Directory -Path $StagingPath
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

	# define relative items
	$WimPathOnISO = "$TemporaryPathForISO\sources\install.wim"
	$XmlPathOnISO = "$TemporaryPathForISO\Autounattend.xml"
	$Ps1PathOnWIM = "$TemporaryPathForWIM\Windows\Update-Windows.ps1"
}

Process {
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
	$DriveLetter = $Volume.DriveLetter
	$FileSystemLabel = $Volume.FileSystemLabel

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Copying ISO contents to path', $TemporaryPathForISO

	# copy ISO contents to temporary path
	Try {
		Copy-Item -Path ('{0}:\*' -f $DriveLetter) -Destination $TemporaryPathForISO -Recurse -Force
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

	# clear readonly flag on windows image
	Try {
		(Get-Item -Path $WimPathOnISO).IsReadOnly = $false
	}
	Catch {
		Return $_
	}

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Mounting WIM image', $WimPathOnISO

	# mount windows image
	Try {
		$null = Mount-WindowsImage -Path $TemporaryPathForWIM -ImagePath $WimPathOnISO -Index $Index
	}
	Catch {
		Return $_
	}

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Updating WIM with file', $Ps1PathOnWIM

	# add PS1 script to windows image
	Try {
		Copy-Item -Path $PathToUpdateScript -Destination $Ps1PathOnWIM
	}
	Catch {
		Return $_
	}

	# report state
	"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Dismounting WIM image...'

	# dismount windows image
	Try {
		$null = Dismount-WindowsImage -Path $TemporaryPathForWIM -Save
	}
	Catch {
		Return $_
	}

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Updating ISO contents with unattend file', $XmlPathOnISO

	# get contents of unattend file
	Try {
		$Content = Get-Content -Path $PathToUnattendFile -Raw
	}
	Catch {
		Return $_
	}

	# update content with index and product key
	$Content = $Content.Replace('%INDEX%', $Index)
	$Content = $Content.Replace('%PRODUCTKEY%', $ProductKey)

	# add unattend file to ISO
	Try {
		$Content | Set-Content -Path $XmlPathOnISO
	}
	Catch {
		Return $_
	}

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Creating ISO image', $PathForUpdatedIsoImage

	# define label for ISO image
	$Label = '{0}-{1}-Unattend' -f $FileSystemLabel, $Index

	# define timestamp for files in ISO image
	# $Timestamp = Get-Date -Format "MM/dd/yyyy,HH:mm:ss"

	# define bootdata for ISO image
	$Bootdata = "2#p0,e,b$TemporaryPathForISO\boot\etfsboot.com#pEF,e,b$TemporaryPathForISO\efi\microsoft\boot\efisys_noprompt.bin"

	# define arguments
	$ArgumentList = "-l$Label -bootdata:$Bootdata -u2 -udfver102 -o $TemporaryPathForISO $PathForUpdatedIsoImage"
	# $ArgumentList = "-l$Label -t$Timestamp -bootdata:$Bootdata -u2 -udfver102 -o $TemporaryPathForISO $PathForUpdatedIsoImage"

	# if no new window requested...
	If ($NoNewWindow) {
		# start process to write updated ISO in current window
		Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -NoNewWindow -ErrorAction Stop
	}
	Else {
		# start process to write updated ISO in new window
		Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -Window Normal -ErrorAction Stop
	}
}

End {
	# if skip remove not requested...
	If (!$SkipRemove) {
		# report state
		"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Removing temporary files...'

		# remove temporary items
		Get-Item -Path $TemporaryPath | Remove-Item -Recurse -Force
	}
}
