[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[string]$Identity,
	[switch]$RestoreFolders,
	[string[]]$FoldersToRestore
)

# define the default OneDrive excluded folders list
$FoldersToRestore_default = @()
$FoldersToRestore_default += 'Desktop'
$FoldersToRestore_default += 'Documents'
$FoldersToRestore_default += 'Downloads'
$FoldersToRestore_default += 'Music'
$FoldersToRestore_default += 'Pictures'
$FoldersToRestore_default += 'Videos'

# buffer output
Write-Output "`n"

# get the OneDrive path(s) so we can filter which path(s) to restore
$onedrive_directory = $null
switch ($Identity) {
	$null {
		Write-Output ('Searching for OneDrive directory...')
		$onedrive_directory = Get-ChildItem -Directory -Path $env:USERPROFILE | Where-Object { $_.Name -match 'OneDrive' }
	}
	Default {
		Write-Output ('Searching for OneDrive directory where name matches the Identity parameter...')
		$onedrive_directory = Get-ChildItem -Directory -Path $env:USERPROFILE | Where-Object { $_.Name -match 'OneDrive - ' -and $_.Name -match $Identity }	
	}
}

# test for 0 (can't junction) or 2+ (can't determine which to junction) OneDrive directories
switch (($onedrive_directory).Count) {
	1 { Write-Output ('...found the OneDrive directory: ' + $onedrive_directory.FullName) }
	0 { Write-Output ('...found no OneDrive directories; exiting!'); Return }
	Default {
		If ([string]::IsNullOrEmpty($Identity)) {
			Write-Output ('...found multiple OneDrive directories and no arguments were provided to limit scope to single directory, exiting!')
			Return
		}
		Else {
			Write-Output ('...found multiple OneDrive directories and the provided argument did not limit scope to single directory, exiting!')
			Return
		}
	}
}

# validate OneDrive directory *is* a directory
If ($onedrive_directory.PSIsContainer) {
	Write-Output '...validated the object found is a directory'
}
Else {
	Write-Output '...unable to determine if the object found is a directory, exiting!'
	Return
}

# buffer output
Write-Output "`n"

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

# loop through directories inside profile
Get-ChildItem -Path $env:USERPROFILE | Where-Object { $_.PSIsContainer -and $_.LinkType -eq 'Junction' -and $_.Target -match $onedrive_directory.Name } | ForEach-Object {
	# define variables and declare folder
	$folder_basename = ($_.BaseName)
	$folder_fullname = ($_.FullName)
	$folder_target = ($_.Target)
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