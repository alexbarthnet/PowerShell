#Requires -Modules WDS

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Position = 0, Mandatory = $True, ValueFromPipeline = $true)]
	[object[]]$WdsInstallImage,
	[Parameter(Position = 1)][ValidateScript({ (Test-Path -PathType 'Container' -Path $_) -and ((Get-ChildItem -Path $_).Count -eq 0) } )]
	[string]$TempPath = ([System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')),
	[Parameter(Position = 1)][ValidateScript({ Test-Path -PathType 'Container' -Path $_ } )]
	[string]$UpdatePath = '.\Updates',
	[Parameter(Position = 1)]
	[switch]$AddFeatures,
	[Parameter(Position = 2)]
	[string[]]$Features = @(
		'TelnetClient'
		'WirelessNetworking'
	),
	[Parameter(Position = 3)]
	[switch]$RemoveAppXPackages,
	[Parameter(Position = 4)]
	[string[]]$AppXPackages = @(
		'Microsoft.BingWeather',
		'Microsoft.GetHelp',
		'Microsoft.Getstarted',
		'Microsoft.Messaging',
		'Microsoft.Microsoft3DViewer',
		'Microsoft.MicrosoftOfficeHub',
		'Microsoft.MicrosoftSolitaireCollection',
		'Microsoft.MicrosoftStickyNotes',
		'Microsoft.MixedReality.Portal',
		'Microsoft.Office.OneNote',
		'Microsoft.OneConnect',
		'Microsoft.People',
		'Microsoft.Print3D',
		'Microsoft.SkypeApp',
		'Microsoft.Wallet',
		'Microsoft.WindowsAlarms',
		'Microsoft.WindowsCamera',
		'microsoft.windowscommunicationsapps',
		'Microsoft.WindowsSoundRecorder',
		'Microsoft.Xbox.TCUI',
		'Microsoft.XboxApp',
		'Microsoft.XboxGameOverlay',
		'Microsoft.XboxGamingOverlay',
		'Microsoft.XboxIdentityProvider',
		'Microsoft.XboxSpeechToTextOverlay',
		'Microsoft.YourPhone',
		'Microsoft.ZuneMusic',
		'Microsoft.ZuneVideo'
	)
)

# get start time
$time_start = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

# process each WDS image
ForEach ($Image in $WdsInstallImage) {
	# get image and image group from WDS
	Try {
		$wds_image_order = $WdsInstallImage.DisplayOrder
		$wds_image_group = $WdsInstallImage.ImageGroup
		$wds_image_name = $WdsInstallImage.ImageName
		$wds_image_file = $WdsInstallImage.FileName
		$wds_image_base = $WdsInstallImage.FileName.Replace('.wim', $null)
	}
	Catch {
		Write-Error 'Could not retrieve one or more required values from the WDS Install Image'
		$_
		Return
	}

	# create temp folders
	Try {
		# create temp file and root folder
		$wds_temp_file = New-TemporaryFile
		$wds_temp_file | Remove-Item -Force
		$wds_temp_root = New-Item -ItemType 'Directory' -Path $TempPath -Name "wds_$($wds_temp_file.BaseName)"
		$wds_temp_path = New-Item -ItemType 'Directory' -Path $wds_temp_root -Name $wds_image_group

		# create temp folders
		$wds_temp_files = New-Item -ItemType 'Directory' -Path $wds_temp_path -Name 'files'
		$wds_temp_mount = New-Item -ItemType 'Directory' -Path $wds_temp_path -Name 'mount'
	}
	Catch {
		Write-Error 'Could not create one or more required temporary folders'
		$_
		Return
	}

	# define files based upon folders
	$wim_file_old = Join-Path -Path $wds_temp_files -ChildPath "$wds_image_base-old.wim"
	$wim_file_new = Join-Path -Path $wds_temp_files -ChildPath "$wds_image_base-new.wim"

	# get image from WDS
	Write-Host '================================'
	Write-Host 'Exporting original image...'
	Write-Host (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
	Write-Host ''
	Try {
		$null = Export-WdsInstallImage -ImageGroup $wds_image_group -ImageName $wds_image_name -Destination $wim_file_old
	}
	Catch {
		Write-Error 'Could not export the original image'
		$_
		Return
	}

	# mount WIM
	Write-Host '================================'
	Write-Host 'Mounting original image...'
	Write-Host (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
	Write-Host ''
	Try {
		$null = Mount-WindowsImage -Path $wds_temp_mount -ImagePath $wim_file_old -Index 1 -CheckIntegrity -Verbose
	}
	Catch {
		Write-Error 'Could not mount the image'
		$_
		Return
	}

	# patch WIM
	Write-Host '================================'
	Write-Host 'Adding patches to image...'
	Write-Host (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
	Write-Host ''
	Try {
		$null = Add-WindowsPackage -Path $wds_temp_mount -PackagePath $UpdatePath
	}
	Catch {
		Write-Error 'Could not patch the image'
		$_
		Return
	}

	# enable features in WIM
	If ($AddFeatures) {
		Write-Host '================================'
		Write-Host 'Adding features to image...'
		Write-Host (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
		Write-Host ''
		Try {
			$null = Get-WindowsOptionalFeature -Path $wds_temp_mount | Where-Object { $_.FeatureName -in $Features -and $_.State -eq 'Disabled' } | Enable-WindowsOptionalFeature
		}
		Catch {
			Write-Error 'Could not add features to the image'
			$_
			Return
		}
	}

	# remove AppX packages from WIM
	If ($RemoveAppXPackages) {
		Write-Host '================================'
		Write-Host 'Removing packages from image...'
		Write-Host (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
		Write-Host ''
		Try {
			$null = Get-AppxProvisionedPackage -Path $wds_temp_mount | Where-Object { $_.DisplayName -in $AppXPackages } | Remove-AppxProvisionedPackage
		}
		Catch {
			Write-Error 'Could not remove packages from the image'
			$_
			Return
		}
	}

	# clean up superseded components in image
	Write-Host '================================'
	Write-Host 'Removing superseded components from image...'
	Write-Host (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
	Write-Host ''
	Try {
		$null = Repair-WindowsImage -Verbose -Path $wds_temp_mount -StartComponentCleanup -ResetBase
	}
	Catch {
		Write-Error 'Could not cleanup the image'
		$_
		Return
	}

	# dismount image and re-export to shrink file
	Write-Host '================================'
	Write-Host 'Unmounting updated image...'
	Write-Host (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
	Write-Host ''
	Try {
		$null = Dismount-WindowsImage -Path $wds_temp_mount -Save -CheckIntegrity
	}
	Catch {
		Write-Error 'Could not dismount the image'
		$_
		Return
	}

	# export to shrink file
	Write-Host '================================'
	Write-Host 'Exporting updated image...'
	Write-Host (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
	Write-Host ''
	Try {
		$null = Export-WindowsImage -Verbose -SourceImagePath $wim_file_old -SourceIndex 1 -CheckIntegrity -DestinationImagePath $wim_file_new
	}
	Catch {
		Write-Error 'Could not export the patched image'
		$_
		Return
	}

	# save uninstall file
	If ($WdsInstallImage.UnattendFilePresent) {
		# define path for unattend file
		$wds_share_path = Join-Path -Path (Get-SmbShare | Where-Object { $_.Name -match 'REMINST' }).Path -ChildPath 'Images'
		$wds_group_path = Join-Path -Path $wds_share_path -ChildPath $wds_image_group
		$wds_image_path = Join-Path -Path $wds_group_path -ChildPath $wds_image_base
		$wds_files_path = Join-Path -Path $wds_image_path -ChildPath 'Unattend'

		# get unattend file
		$wds_files_xml = Get-ChildItem -Path $wds_files_path -Filter '*.xml' | Copy-Item -Destination $wds_temp_files -PassThru
	}

	# remove wds image
	Write-Host '================================'
	Write-Host 'Removing original image...'
	Write-Host (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
	Write-Host ''
	Try {
		$null = Remove-WdsInstallImage -ImageGroup $wds_image_group -ImageName $wds_image_name
	}
	Catch {
		Write-Error 'Could not remove the image from WDS'
		$_
		Return
	}

	# import new image into WDS
	Write-Host '================================'
	Write-Host 'Importing updated image...'
	Write-Host (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
	Write-Host ''
	Try {
		$null = Import-WdsInstallImage -ImageGroup $wds_image_group -ImageName $wds_image_name -Path $wim_file_new -NewFileName $wds_image_file -DisplayOrder $wds_image_order
	}
	Catch {
		Write-Error 'Could not import the image into WDS'
		$_
		Return
	}

	# restore unattend XML file
	If ($WdsInstallImage.UnattendFilePresent) {
		New-Item -Path $wds_files_path -ItemType 'Directory' -Force
		Move-Item -Path $wds_files_xml -Destination $wds_files_path
	}

	# remove WIM files and get finish time
	Remove-Item -Path $wds_temp_root -Force
	$time_stop = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
}

# close out with report of time taken
Write-Host 'Started   :' $time_start
Write-Host 'Completed :' $time_stop
Write-Host ''
