[CmdletBinding(SupportsShouldProcess)]
param(
	[Parameter(DontShow)][ValidateSet('OneDrive', 'OneDriveConsumer', 'OneDriveCommerical')]
	[string]$Environment = 'OneDrive',
	[string]$Identity,
	[switch]$WaitForOneDrive,
	[switch]$ClearHiddenItemsFromEmptyFolders,
	[switch]$CreateMissingFolders,
	[string[]]$ProhibitedLocalFolders = 'AppData',
	[string[]]$ExcludeOneDriveFolders,
	[string[]]$IncludeOneDriveFolders,
	[string[]]$WaitForOneDriveFolders
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

# report OneDrive container:
Write-Host "...found mounted OneDrive container: $($OneDrive.FullName)"

# retrieve folders in OneDrive container
try {
	$OneDriveFolders = $OneDrive | Get-ChildItem -Directory
}
catch {
	return $_
}

# loop through folders in OneDrive container
:NextOneDriveFolder foreach ($OneDriveFolder in $OneDriveFolders) {
	# define variables and declare folder
	$OneDriveFolderBaseName = $OneDriveFolder.BaseName
	$OneDriveFolderFullName = $OneDriveFolder.FullName
	$ExistingFolderFullName = Join-Path -Path $env:USERPROFILE -ChildPath $OneDriveFolderBaseName

	# report state
	Write-Host "Found OneDrive folder: $OneDriveFolderBaseName"

	# if include folders provided...
	if ($PSBoundParameters.ContainsKey('IncludeOneDriveFolders')) {
		# check if OneDrive folder base name matches the include list
		if ($OneDriveFolderBaseName -notin $IncludeOneDriveFolders -and $OneDriveFolderFullName -notin $IncludeOneDriveFolders -and $ExistingFolderFullName -notin $IncludeOneDriveFolders) {
			Write-Host "...skipped '$OneDriveFolderBaseName' folder; folder name is not in IncludeOneDriveFolders"
			continue NextOneDriveFolder
		}
	}

	# check if OneDrive folder base name matches the prohibited list
	if ($OneDriveFolderBaseName -in $ProhibitedLocalFolders -or $OneDriveFolderFullName -in $ProhibitedLocalFolders -or $ExistingFolderFullName -in $ProhibitedLocalFolders) {
		Write-Host "...skipped '$OneDriveFolderBaseName' folder; folder name is in ProhibitedLocalFolders"
		continue NextOneDriveFolder
	}

	# check if OneDrive folder base name matches the exclude list
	if ($OneDriveFolderBaseName -in $ExcludeOneDriveFolders -or $OneDriveFolderFullName -in $ExcludeOneDriveFolders -or $ExistingFolderFullName -in $ExcludeOneDriveFolders) {
		Write-Host "...skipped '$OneDriveFolderBaseName' folder; folder name is in ExcludeOneDriveFolders"
		continue NextOneDriveFolder
	}

	# if existing folder not found...
	if (![System.IO.Directory]::Exists($ExistingFolderFullName)) {
		# if CreateMissingFolders requested...
		if ($CreateMissingFolders) {
			Write-Host "...will create '$OneDriveFolderBaseName' folder; folder does not exist locally but CreateMissingFolders was set"
		}
		# if CreateMissingFolders not requested...
		else {
			Write-Host "...skipped '$OneDriveFolderBaseName' folder; folder does not exist locally and CreateMissingFolders was not set"
			continue NextOneDriveFolder
		}
	}

	# if existing folder found...
	if ([System.IO.Directory]::Exists($ExistingFolderFullName)) {
		# retrieve existing folder
		try {
			$ExistingFolder = Get-Item -Path $ExistingFolderFullName
		}
		catch {
			Write-Warning -Message "...skipped '$OneDriveFolderBaseName' folder; could not retrieve existing folder: $($_.Exception.Message)"
			continue NextOneDriveFolder
		}

		# check if current folder is already junctioned
		if ($ExistingFolder.LinkType -eq 'Junction') {
			Write-Host "...skipped '$OneDriveFolderBaseName' folder; existing folder already junctioned"
			continue NextOneDriveFolder
		}

		# retrieve all child items
		try {
			$ChildItems = Get-ChildItem -Path $ExistingFolderFullName -Force -Recurse
		}
		catch {
			Write-Warning -Message "...skipped '$OneDriveFolderBaseName' folder; could not check existing folder for child items: $($_.Exception.Message)"
			continue NextOneDriveFolder
		}

		# if existing folder contains files that are not hidden...
		if ($ChildItems.Where({ ($_.Attributes -band [System.IO.FileAttributes]::Hidden) -ne [System.IO.FileAttributes]::Hidden -and -not $_.PSIsContainer }).Count -gt 0) {
			Write-Host "...skipped '$OneDriveFolderBaseName' folder: existing folder contains existing files"
			continue NextOneDriveFolder
		}

		# if existing folder contains files that are hidden...
		if ($ChildItems.Where({ ($_.Attributes -band [System.IO.FileAttributes]::Hidden) -eq [System.IO.FileAttributes]::Hidden -and -not $_.PSIsContainer }).Count -gt 0) {
			# if clear hidden items from empty folders not requested...
			if (!$ClearHiddenItemsFromEmptyFolders) {
				Write-Host "...skipped '$OneDriveFolderBaseName' folder: folder contains hidden files and ClearHiddenItemsFromEmptyFolders not set"
				continue NextOneDriveFolder
			}

			# if what if not requested...
			if ($PSCmdlet.ShouldProcess($ExistingFolderFullName, 'Update ACL on child items')) {
				# retrieve ACL from existing folder
				$AclObject = Get-Acl -Path $ExistingFolder

				# reset ACL on each item
				foreach ($ChildItem in $ChildItems) {
					# reset ACL
					try {
						Set-Acl -Path $ChildItem.FullName -AclObject $AclObject -ErrorAction Stop
					}
					catch {
						Write-Error "...skipped '$OneDriveFolderBaseName' folder; could not reset ACL on hidden item: $($ChildItem.FullName)"
						continue NextOneDriveFolder
					}
				}

				# report state
				Write-Host "...updated hidden items in existing '$OneDriveFolderBaseName' folder, emptying existing folder..."
			}

			# if what if not requested...
			if ($PSCmdlet.ShouldProcess($ExistingFolderFullName, 'Remove child items')) {
				# remove items
				try {
					Get-ChildItem -Path $ExistingFolderFullName -Force -Recurse | Remove-Item -Force -Recurse
				}
				catch {
					Write-Error "...skipped '$OneDriveFolderBaseName' folder; could not remove hidden items"
					continue NextOneDriveFolder
				}

				# report state
				Write-Host "...removed hidden items from existing '$OneDriveFolderBaseName' folder removed"
			}
		}
	}

	# create junction
	if ($PSCmdlet.ShouldProcess($ExistingFolderFullName, 'Junction folder')) {
		# clear item object
		$Item = $null

		# create junction with silently continue
		$Item = New-Item -ItemType Junction -Path $ExistingFolderFullName -Target $OneDriveFolderFullName -Force -ErrorAction 'SilentlyContinue'

		# if item link type is not junction...
		if ($Item.LinkType -ne 'Junction') {
			Write-Error "...skipped '$OneDriveFolderBaseName' folder; could not junction OneDrive folder to existing folder: $ExistingFolderFullName"
			continue NextOneDriveFolder
		}

		# report state
		Write-Host "...junctioned '$OneDriveFolderBaseName' folder to '$ExistingFolderFullName' folder"
	}
}
