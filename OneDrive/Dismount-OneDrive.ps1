[CmdletBinding(SupportsShouldProcess)]
Param(
	[Parameter(DontShow)][ValidateSet('OneDrive', 'OneDriveConsumer', 'OneDriveCommerical')]
	[string]$Environment = 'OneDrive',
	[string]$Identity,
	[switch]$WaitForOneDrive,
	[switch]$RestoreFolders,
	[string[]]$FoldersToRestore
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

# define the default OneDrive excluded folders list
$FoldersToRestore_default = @()
$FoldersToRestore_default += 'Desktop'
$FoldersToRestore_default += 'Documents'
$FoldersToRestore_default += 'Downloads'
$FoldersToRestore_default += 'Music'
$FoldersToRestore_default += 'Pictures'
$FoldersToRestore_default += 'Videos'

# define OneDrive directories that will *NOT* be un-junctioned
If ($RestoreFolders) {
	Write-Output ('Checking the excluded folders...')
	If ($FoldersToRestore.Count -ge 1) {
		ForEach ($FolderToRestore in $FoldersToRestore) {
			$FolderToRestore_path = Join-Path -Path $onedrive_directory -ChildPath $FolderToRestore
			If (Test-Path $FolderToRestore_path) {
				Write-Output ("`t Located: $FolderToRestore_path")
			}
			Else {
				Write-Output ("`t Missing: $FolderToRestore_path")
				Write-Output ('WARNING: the folder above was defined in the FolderToExcludes parameter but not found in OneDrive, exiting!')
				Return
			}
		}
	}
	Else {
		Write-Output ('NOTICE: no restore folders were explicitly defined')
		Write-Output ('...the following default folders will be restored from junctions:')
		$FoldersToRestore = $FoldersToRestore_default
		ForEach ($FolderToRestore in $FoldersToRestore) {
			$FolderToRestore_path = Join-Path -Path $onedrive_directory -ChildPath $FolderToRestore
			Write-Output ("`t $FolderToRestore_path")
		}
		# insert warning here!
	}
}

# buffer output
Write-Output "`n"
Write-Output ('-----')

# retrieve junctions in profile directory
$folders_junctioned = Get-ChildItem -Path $env:USERPROFILE | Where-Object { $_.PSIsContainer -and $_.LinkType -eq 'Junction' -and $_.Target -match $onedrive_directory.Name }

# loop through directories inside profile
ForEach ($folder_junctioned in $folders_junctioned) {
	# define variables and declare folder
	$folder_basename = ($folder_junctioned.BaseName)
	$folder_fullname = ($folder_junctioned.FullName)
	$folder_target = ($folder_junctioned.Target)
	Write-Output (' ')
	Write-Output ("Found OneDrive folder: '" + $folder_fullname + "'")

	# remove junction
	Try {
		# $_.Delete()
		Invoke-Expression -Command "fsutil reparsepoint delete $folder_fullname"
		Write-Output ("...'" + $folder_basename + "' removing junction!")
	}
	Catch {
		Write-Output ('ERROR: the junction above could not be removed, exiting!')
		Return
	}

	# restore contents of junctions to original folders
	If ($RestoreFolders) {
		If ($FoldersToRestore -contains $folder_basename ) {
			Write-Output ("...'" + $folder_basename + "' restoring contents...")
			$path_items = Get-ChildItem -Path $folder_target -Recurse -Force
			$path_items | ForEach-Object {
				$path_old = $_.FullName
				$path_new = $_.FullName.Replace($folder_target, $folder_fullname)
				Try {
					Write-Output ("... - restoring '$path_new'...")
					Copy-Item -Path $path_old -Destination $path_new -Force
				}
				Catch {
					Write-Output ('ERROR: could restore previous file or folder, exiting!')
					Return
				}
			}
		}
	}
}

# close out
Write-Output (' ')
Write-Output ('-----')
Write-Output (' ')
Write-Output ('All permitted OneDrive directory junctions have been removed!')