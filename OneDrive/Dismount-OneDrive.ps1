[CmdletBinding(SupportsShouldProcess)]
Param(
	[Parameter(DontShow)][ValidateSet('OneDrive', 'OneDriveConsumer', 'OneDriveCommerical')]
	[string]$Environment = 'OneDrive',
	[string]$Identity,
	[switch]$WaitForOneDrive,
	[switch]$RestoreFolders,
	[string[]]$FoldersToDismount,
	[string[]]$FoldersToRestore,
	[string[]]$FoldersToRetain
)

# check user environment variable for the OneDrive path
$OneDrivePath = [System.Environment]::GetEnvironmentVariable($Environment, 'User')

# if OneDrive path is null...
if ([System.String]::IsNullOrEmpty($OneDrivePath)) {
	# if wait for OneDrive requested...
	if ($WaitForOneDrive) {
		# report state
		Write-Host "Waiting for '$Environment' environment variable..."

		# while OneDrive path is null...
		while ([System.String]::IsNullOrEmpty($OneDrivePath)) {
			# retrieve user environment variable for the OneDrive path
			$OneDrivePath = [System.Environment]::GetEnvironmentVariable($Environment, 'User')

			# sleep
			Start-Sleep -Seconds 1
		}
	}
	else {
		# warn and return
		Write-Warning -Message "the '$Environment' environment variable is empty"
		return
	}
}

# if identity provided...
if ($PSBoundParameters.ContainsKey('Identity')) {
	# report state
	Write-Host 'Searching for mounted OneDrive container where name matches the Identity parameter...'

	# define filter script
	$FilterScript = { $_.Name -match '^OneDrive' -and $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint -and $_.Name -match $Identity }
}
else {
	# report state
	Write-Host 'Searching for mounted OneDrive container...'

	# define filter script
	$FilterScript = { $_.Name -match '^OneDrive' -and $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint }
}

# retrieve OneDrive container(s) matching filterscript
try {
	$OneDrive = Get-ChildItem -Directory -Path $env:USERPROFILE | Where-Object -FilterScript $FilterScript
}
catch {
	return $_
}

# if multiple OneDrive containers found with Identity...
if ($OneDrive.Count -gt 1 -and $PSBoundParameters.ContainsKey('Identity')) {
	# warn and return
	Write-Warning -Message 'multiple mounted OneDrive containers found in the user profile folder; the Identity parameter did not limit scope to single container'
	return
}

# if multiple OneDrive containers found without Identity...
if ($OneDrive.Count -gt 1) {
	# warn and return
	Write-Warning -Message 'multiple mounted OneDrive containers found in the user profile folder; the Identity parameter was not provided to limit scope to single container'
	return
}

# if no OneDrive containers found....
if ($OneDrive.Count -eq 0) {
	# if wait for OneDrive requested...
	if ($WaitForOneDrive) {
		# report state
		Write-Host 'Waiting for OneDrive container...'

		# while OneDrive containers not found
		while ($OneDrive.Count -eq 0) {
			# retrieve OneDrive container(s) matching filterscript
			try {
				$OneDrive = Get-ChildItem -Directory -Path $env:USERPROFILE | Where-Object -FilterScript $FilterScript
			}
			catch {
				return $_
			}

			# sleep
			Start-Sleep -Seconds 1
		}

		# loop through wait for OneDrive folders
		foreach ($WaitForOneDriveFolder in $WaitForOneDriveFolders) {
			# report state
			Write-Host "Waiting for OneDrive folder: $WaitForOneDriveFolder"

			# define full path to wait for OneDrive folder
			$OneDriveFolderPath = Join-Path -Path $OneDrive.FullName -ChildPath $WaitForOneDriveFolder

			# test path for wait for OneDrive folder
			$TestPath = Test-Path -Path $OneDriveFolderPath -PathType Container

			# while wait for OneDrive folder not found...
			while (!$TestPath) {
				# sleep
				Start-Sleep -Seconds 1

				# test path for wait for OneDrive folder
				$TestPath = Test-Path -Path $OneDriveFolderPath -PathType Container
			}
		}
	}
	else {
		# warn and return
		Write-Warning -Message 'a mounted OneDrive container was not found in the user profile folder'
		return
	}
}

# report OneDrive container
Write-Host "...found mounted OneDrive container: $($OneDrive.FullName)"

# report state
Write-Host 'Searching for folders junctioned to OneDrive container...'

# retrieve folders in profile directory junctioned to OneDrive container
$JunctionedFolders = Get-ChildItem -Path $env:USERPROFILE | Where-Object { $_.PSIsContainer -and $_.LinkType -eq 'Junction' -and $_.Target -match "^$($OneDrive.FullName)" }

# if no junctioned folders found....
if ($JunctionedFolders.Count -eq 0) {
	Write-Host "...no folders in user profile junctioned to OneDrive"
	return
}

# loop through junctioned folders
:NextOneDriveFolder foreach ($JunctionedFolder in $JunctionedFolders) {
	# define variables and declare folder
	$JunctionedFolderBaseName = $JunctionedFolder.BaseName
	$JunctionedFolderFullName = $JunctionedFolder.FullName
	$JunctionedTargetFullName = $JunctionedFolder.Target

	# report state
	Write-Host "Found junctioned folder: $JunctionedFolderBaseName"

	# check if junctioned folder name matches the retain list
	if ($JunctionedFolderBaseName -in $FoldersToRetain -or $JunctionedFolderFullName -in $FoldersToRetain -or $JunctionedTargetFullName -in $FoldersToRetain) {
		Write-Host "...skipped '$JunctionedFolderBaseName' folder; folder name is in FoldersToRetain"
		continue NextOneDriveFolder
	}

	# remove junction
	Try {
		Invoke-Expression -Command "fsutil reparsepoint delete $JunctionedFolderFullName"
		Write-Host "...removed junction of '$JunctionedFolderFullName' folder to $JunctionedTargetFullName' folder"
	}
	Catch {
		Write-Warning -Message "could not remove junction from '$JunctionedFolderFullName' folder"
		return $_
	}

	# check if junctioned folder name matches the dismount list
	if ($JunctionedFolderBaseName -in $FoldersToDismount -or $JunctionedFolderFullName -in $FoldersToDismount -or $JunctionedTargetFullName -in $FoldersToDismount) {
		Write-Host "...skipped restore of '$JunctionedFolderBaseName' folder; folder name is in FoldersToDismount"
		continue NextOneDriveFolder
	}

	# if folders to restore explicitly defined...
	if ($PSBoundParameters.ContainsKey('FoldersToRestore')) {
		# check if junctioned folder name matches the dismount list
		if ($JunctionedFolderBaseName -notin $FoldersToRestore -and $JunctionedFolderFullName -notin $FoldersToRestore -and $JunctionedTargetFullName -notin $FoldersToRestore) {
			Write-Host "...skipped restore of '$JunctionedFolderBaseName' folder; folder name is not in FoldersToRestore"
			continue NextOneDriveFolder
		}
	}

	# report state
	Write-Host "...restoring contents of '$JunctionedFolderFullName' folder from $JunctionedTargetFullName' folder"

	# retrieve folders in target folder
	try {
		$TargetFolders = Get-ChildItem -Path $JunctionedTargetFullName -Recurse -Force -Directory
	}
	catch {
		Write-Warning -Message "could not retrieve folders in '$JunctionedTargetFullName' folder"
		return $_
	}

	# loop through folders in target folder
	foreach ($TargetFolder in $TargetFolders) {
		# retrieve relative path for target folder
		$RelativeTargetFolderPath = $TargetFolder.FullName.Replace($JunctionedTargetFullName, $null)

		# create destination path for target folder
		$RestoredFolderPath = Join-Path -Path $JunctionedFolderFullName -ChildPath $RelativeTargetFolderPath

		# restore folder
		try {
			$null = New-Item -ItemType Directory -Path $RestoredFolderPath -Force
		}
		catch {
			Write-Warning -Message "could not restore '$RestoredFolderPath' folder"
			return $_
		}
	}

	# retrieve folders in target folder
	try {
		$TargetFiles = Get-ChildItem -Path $JunctionedTargetFullName -Recurse -Force -File
	}
	catch {
		Write-Warning -Message "could not retrieve files in '$JunctionedTargetFullName' folder"
		return $_
	}

	# loop through files in target folder
	foreach ($TargetFile in $TargetFiles) {
		# retrieve relative path for target file
		$RelativeTargetFilePath = $TargetFile.FullName.Replace($JunctionedTargetFullName, $null)

		# create destination path for target file
		$RestoredFilePath = Join-Path -Path $JunctionedFolderFullName -ChildPath $RelativeTargetFilePath

		# restore file
		try {
			Copy-Item -Path $TargetFile -Destination $RestoredFilePath -Force
		}
		catch {
			Write-Warning -Message "could not restore '$RestoredFilePath' file"
			return $_
		}
	}
}
