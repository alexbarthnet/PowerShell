<#
.SYNOPSIS
Create a Windows ISO image for virtual machine templates.

.DESCRIPTION
Create a Windows ISO image for virtual machine templates that will install and patch Windows then generalize (sysprep) the image.

.PARAMETER PathToOriginalIsoImage
Path to the original Windows ISO image.

.PARAMETER PathForUpdatedIsoImage
Path for the updated Windows ISO image.

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

.PARAMETER PathToBinaryFolder
Path to folder containing required oscdimg.exe program. Required when the deployment tools oscdimg has not been installed in the default location.

.PARAMETER NoNewWindow
Switch parameter to start the oscdimg program in the current window. Primarily used to debug any issues with creating the updated ISO image.

.PARAMETER StagingPath
Path to folder for staging the ISO file contents and mounting the WIM image. The default staging path is a randomly named folder in the system temp directory.

.PARAMETER EmptyStagingPath
Switch parameter to remove any existing files and folders in the StagingPath folder.

.PARAMETER ReuseStagingPath
Switch parameter to use any existing files and folders in the StagingPath folder rather than copying new files from the original ISO image or script folders.

.PARAMETER SkipExclude
Switch parameter to skip creating Microsoft Defender path exclusion for the staging path.

.PARAMETER ProductKey
String with product key for the Windows image. The default value is the KMS key for Windows Server 2025 Datacenter.

.PARAMETER Index
Integer for index of Windows image. The default value is 4 which maps to the Datacenter with Desktop Experience for Windows Server 2016 and later.

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

Param(
	[Parameter(Mandatory = $true)][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToOriginalIsoImage,
	[Parameter(Mandatory = $true)][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathForUpdatedIsoImage,
	[Parameter(Mandatory = $true)][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToAutounattendFile,
	[Parameter()][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToUnattendFile,
	[Parameter(Mandatory = $true)][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToUpdateScript,
	[Parameter()][ValidateScript({ [System.IO.File]::Exists($_) })]
	[string]$PathToInvokeScript,
	[Parameter()][ValidateScript({ [System.IO.Directory]::Exists($_) })]
	[string]$PathToScriptFolder,
	[Parameter()][ValidateScript({ [System.IO.Directory]::Exists($_) })]
	[string]$PathToBinaryFolder,
	[switch]$NoNewWindow,
	[Parameter()][ValidateScript({ [System.IO.Directory]::Exists($_) })]
	[string]$StagingPath,
	[switch]$EmptyStagingPath,
	[switch]$ReuseStagingPath,
	[switch]$SkipExclude,
	[string]$ProductKey = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF',
	[uint16]$Index = 4
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
		If (![System.IO.Directory]::Exists($StagingPath)) {
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
				Get-ChildItem -Path $StagingPath -Force -Recurse | Remove-Item -Force -Recurse
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

	# if path to oscdimg folder not provided...
	If (!$PSBoundParameters.ContainsKey('PathToBinaryFolder')) {
		# define default folder path
		$PathToBinaryFolder = Join-Path -Path ([System.Environment]::GetFolderPath('ProgramFilesx86')) -ChildPath '\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg'
	}
	
	# define path to required program
	$FilePath = Join-Path -Path $PathToBinaryFolder -ChildPath 'oscdimg.exe'
	
	# validate application path
	Try {
		$null = Get-Item -Path $FilePath
	}
	Catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# define relative items
	$AutounattendXmlOnISO = "$TemporaryPathForISO\Autounattend.xml"
	$UnattendXmlOnISO = "$TemporaryPathForISO\Unattend.xml"
	$ImagePathForWIM = "$TemporaryPathForISO\sources\install.wim"
	$UpdatePs1OnWIM = "$TemporaryPathForWIM\Windows\Update-Windows.ps1"
	$InvokePs1OnWIM = "$TemporaryPathForWIM\Windows\Invoke-ScriptsFromRemovableMedia.ps1"
}

Process {
	# if staging path provided and reuse staging path not set...
	If ($StagingPath -and -not $ReuseStagingPath) {
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
		(Get-Item -Path $ImagePathForWIM).IsReadOnly = $false
		}
		Catch {
			Return $_
		}

		# report state
		"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Mounting WIM image', $ImagePathForWIM

		# mount windows image
		Try {
			$null = Mount-WindowsImage -Path $TemporaryPathForWIM -ImagePath $ImagePathForWIM -Index $Index
		}
		Catch {
			Return $_
		}

		# report state
		"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Updating WIM with "update" script', $UpdatePs1OnWIM

		# add PS1 script to windows image
		Try {
			Copy-Item -Path $PathToUpdateScript -Destination $UpdatePs1OnWIM
		}
		Catch {
			Return $_
		}

		# if invoke script provided...
		If ($PSBoundParameters.ContainsKey('PathToInvokeScript')) {
			# report state
			"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Updating WIM with "invoke" script', $InvokePs1OnWIM

			# add PS1 script to windows image
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
			$null = Dismount-WindowsImage -Path $TemporaryPathForWIM -Save
		}
		Catch {
			Return $_
		}

		# report state
		"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Updating ISO contents with unattend file for sysprep', $AutounattendXmlOnISO

		# get contents of unattend file
		Try {
			$Content = Get-Content -Path $PathToAutounattendFile -Raw
		}
		Catch {
			Return $_
		}

		# update content with index and product key
		$Content = $Content.Replace('%INDEX%', $Index)
		$Content = $Content.Replace('%PRODUCTKEY%', $ProductKey)

		# add unattend file to ISO
		Try {
			$Content | Set-Content -Path $AutounattendXmlOnISO
		}
		Catch {
			Return $_
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

			# update content with index and product key
			$Content = $Content.Replace('%PRODUCTKEY%', $ProductKey)

			# add unattend file to ISO
			Try {
				$Content | Set-Content -Path $UnattendXmlOnISO
			}
			Catch {
				Return $_
			}
		}

		# if script folder provided...
		If ($PSBoundParameters.ContainsKey('PathToScriptFolder')) {
			# define scripts folder on ISO
			$ScriptFolderForISO = Join-Path -Path $TemporaryPathForISO -ChildPath 'scripts'

			# if script folder on ISO not found...
			If (![System.IO.Directory]::Exists($ScriptFolderForISO)) {
				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Creating ISO scripts folder', $ScriptFolderForISO

				# create folder
				Try {
					$null = New-Item -ItemType Directory -Path $ScriptFolderForISO
				}
				Catch {
					Return $_
				}
			}

			# retrieve files in script folder
			$Files = Get-ChildItem -Path $PathToScriptFolder -Filter '*.ps1'

			# loop through files
			ForEach ($File in $Files) {
				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Adding script to ISO scripts folder', $File.Name

				# copy item to folder
				Try {
					Copy-Item -Path $File -Destination $ScriptFolderForISO
				}
				Catch {
					Return $_
				}
			}
		}
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
