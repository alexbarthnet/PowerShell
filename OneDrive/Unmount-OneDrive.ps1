[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[string]$Identity,
	[switch]$SkipExcludedFoldersCheck,
	[switch]$ExcludeFolders,
	[string[]]$ExcludedFolders,
	[switch]$RestoreFolders,
	[string[]]$FoldersToRestore
)

# buffer output
Write-Output "`n"

# get the junctioned path(s)
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
If ($ExcludeFolders) {
	Write-Output ('Checking the excluded folders...')
	If ($ExcludedFolders.Count -ge 1) {
		If (-not $SkipExcludedFoldersCheck) {
			ForEach ($ExcludedFolder in $ExcludedFolders) {
				$ExcludedFolder_path = Join-Path -Path $onedrive_directory -ChildPath $ExcludedFolder
				If (Test-Path $ExcludedFolder_path) {
					Write-Output ("`t Located: $ExcludedFolder_path")
				}
				Else {
					Write-Output ("`t Missing: $ExcludedFolder_path")
					Write-Output ('WARNING: the folder above was defined in the ExcludedFolders parameter but not found in OneDrive, exiting!')
					Return
				}
			}
		}
	}
}

# buffer output
Write-Output "`n"
Write-Output ('-----')

# loop through directories inside profile
Get-ChildItem -Path $env:USERPROFILE | Where-Object { $_.PSIsContainer -and $_.LinkType -eq 'Junction' -and $_.Target -match $onedrive_directory.Name } | ForEach-Object {
	$folder_basename = ($_.BaseName)
	$folder_fullname = ($_.FullName)
	$folder_target = ($_.Target)
	Write-Output (' ')
	Write-Output ("Found OneDrive folder: '" + $folder_fullname + "'")
	# check if current folder matching the block list
	If ($ExcludedFolders -contains $folder_basename) {
		Write-Output ("...'" + $folder_basename + "' explicitly blocked, skipping!")
	}
	Else {
		# remove junction
		Try {
			# $_.Delete()
			Invoke-Expression "fsutil reparsepoint delete $folder_fullname"
			Write-Output ("...'" + $folder_basename + "' removing junction!")
		}
		Catch {
			Write-Output ('ERROR: the junction above could not be removed, exiting!')
		}
		# export junctioned contents into restored folders
		If ($RestoreFolders) {
			If ($FoldersToRestore -contains $folder_basename ) {
				Get-ChildItem -Path $folder_target -Recurse -Force | ForEach-Object {
					$path_old = $_.FullName
					$path_new = $_.FullName.Replace($folder_target,$folder_fullname)
					Move-Item -Path $path_old -Destination $path_new
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