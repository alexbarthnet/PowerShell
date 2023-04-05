[CmdletBinding(SupportsShouldProcess)]
Param(
	[string]$Identity,
	[switch]$ClearHiddenItemsFromEmptyFolders,
	[switch]$CreateMissingFolders,
	[string[]]$ExcludeOneDriveFolders
)

# buffer output
Write-Output "`n"

# get the OneDrive path(s) so we can filter which path(s) to junction
$onedrive_directory = $null
If ([string]::IsNullOrEmpty($Identity)) {
	Write-Output ('Searching for OneDrive directory...')
	$onedrive_directory = Get-ChildItem -Directory -Path $env:USERPROFILE | Where-Object { $_.Name -match 'OneDrive' }
}
Else {
	Write-Output ('Searching for OneDrive directory where name matches the Identity parameter...')
	$onedrive_directory = Get-ChildItem -Directory -Path $env:USERPROFILE | Where-Object { $_.Name -match 'OneDrive - ' -and $_.Name -match $Identity }
}

# test for 0 (can't junction) or 2+ (can't determine which to junction) OneDrive directories
switch (($onedrive_directory).Count) {
	1 { Write-Output ('...found the OneDrive directory: ' + $onedrive_directory.FullName) }
	0 { Write-Output ('...found no OneDrive directories; exiting!'); Return }
	Default {
		If ([string]::IsNullOrEmpty($Identity)) {
			Write-Output ('...found multiple OneDrive directories; the Identity parameter was not provided to limit scope to single directory, exiting!')
			Return
		}
		Else {
			Write-Output ('...found multiple OneDrive directories; the Identity parameter did not limit scope to single directory, exiting!')
			Return
		}
	}
}

# buffer output
Write-Output "`n"
Write-Output ('-----')

# retrieve directories in OneDrive directory
$folders_onedrive = Get-ChildItem -Path $onedrive_directory.FullName | Where-Object { $_.PSIsContainer }

# loop through directories inside OneDrive directory
:folder ForEach ($folder_onedrive in $folders_onedrive) {
	# define variables and declare folder
	$folder_hidden = @()
	$folder_short = ($folder_onedrive.BaseName)
	$folder_cloud = ($folder_onedrive.FullName)
	$folder_local = ($env:USERPROFILE + '\' + $folder_short)
	Write-Output (' ')
	Write-Output ("Found OneDrive folder: '" + $folder_cloud + "'")

	# check if folder short name matches the block list
	If ($folder_short -in $ExcludeOneDriveFolders) {
		Write-Output ("...'" + $folder_short + "' skipped; folder name is blocked")
		Continue :folder
	}

	# check if folder path in OneDrive matches the block list
	If ($folder_cloud -in $ExcludeOneDriveFolders) {
		Write-Output ("...'" + $folder_cloud + "' skipped; folder name is blocked")
		Continue :folder
	}

	# check if folder path on machine matches the block list
	If ($folder_local -in $ExcludeOneDriveFolders) {
		Write-Output ("...'" + $folder_local + "' skipped; folder name is blocked")
		Continue :folder
	}

	# if OneDrive folder exists locally...
	If (Test-Path $folder_local) {
		# check if current folder is already junctioned
		If ((Get-Item -Path $folder_local).LinkType -eq 'Junction') {
			Write-Output ("...'$folder_local' skipped; folder already junctioned")
			Continue :folder
		}

		# check if current folder is empty
		If ((Get-ChildItem -Path $folder_local -Recurse).Count -eq 0) {
			# check if current folder contains hidden items
			$folder_hidden = Get-ChildItem -Force -Path $folder_local
			If ($folder_hidden.Count -gt 0 -and -not $ClearHiddenItemsFromEmptyFolders) {
				Write-Output ("...'$folder_local' skipped; folder is empty but contains hidden items")
				$HiddenItemsFound = $true
				Continue
			}
			If ($folder_hidden.Count -gt 0) {
				Write-Output ("...'$folder_local' is empty but contains hidden items, updating ACLs on hidden items...")
				# retrieve current folder ACL
				$folder_acl = Get-Acl $folder_local
				# update ACLs on all hidden items in current folder
				if ($PSCmdlet.ShouldProcess($folder_local, 'Remove hidden items')) {
					ForEach ($item_hidden in $folder_hidden) {
						# reset ACL
						Try {
							$item_hidden | Set-Acl -AclObject $folder_acl
						}
						Catch {
							Write-Error "...'$folder_local' skipped; could not reset ACL on hidden item: $($item_hidden.FullName)"
							Continue :folder
						}
					}
					Write-Output ("...'$folder_local' hidden items updated, emptying directory...")
					# remove item
					Try {
						Get-ChildItem -Force -Recurse -Path $folder_local | Remove-Item -Force -Recurse
					}
					Catch {
						Write-Error "...'$folder_local' skipped; could not remove hidden items"
						Continue :folder
					}
					Write-Output ("...'$folder_local' hidden items removed")
				}
			}
		}
		Else {
			Write-Warning "...'$folder_local' directory is NOT empty, skipping!"
			Continue :folder
		}
	}
	# if OneDrive folder missing locally...
	Else {
		If ($CreateMissingFolders) {
			Write-Output "...'$folder_local' will be created; folder does not exist locally but CreateMissingFolders was set"
		}
		Else {
			Write-Output "...'$folder_local' skipped; folder does not exist locally and CreateMissingFolders was not set"
			Continue :folder
		}
	}

	# create junction
	Try {
		if ($PSCmdlet.ShouldProcess($folder_local, 'Junction folder')) {
			$null = New-Item -ItemType Junction -Path $folder_local -Target $folder_cloud
			Write-Output ("...'$folder_local' junctioned!")
		}
	}
	Catch {
		Write-Error "...'$folder_local' skipped; could not junction"
	}
}

# inform user how to handle hidden items if encountered
If ($HiddenItemsFound) {
	Write-Output (' ')
	Write-Output ('-----')
	Write-Output (' ')
	Write-Output ('One or more folders contain hidden items and could not be junctioned; use the -ClearHiddenItemsFromEmptyFoldersItemsFromEmptyFolders switch to permit the script to remove hidden items from otherwise empty folders')
}

# close out
Write-Output (' ')
Write-Output ('-----')
Write-Output (' ')
Write-Output ('All permitted OneDrive directories are now locally junctioned!')