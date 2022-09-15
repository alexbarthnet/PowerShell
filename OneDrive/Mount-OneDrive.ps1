[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[string]$Identity,
	[switch]$ExcludeFolders,
	[string[]]$FoldersToExclude
)

# define the default OneDrive excluded folders list
$FoldersToExclude_default = @()
$FoldersToExclude_default += 'AppData'
$FoldersToExclude_default += 'Attachments'
$FoldersToExclude_default += 'Microsoft Teams Chat Files'
$FoldersToExclude_default += 'Microsoft Teams Data'
$FoldersToExclude_default += 'Notebooks'
$FoldersToExclude_default += 'Public'

# buffer output
Write-Output "`n"

# get the OneDrive path(s) so we can filter which path(s) to junction
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

# define OneDrive directories that will *NOT* be junctioned
If ($ExcludeFolders) {
	Write-Output ('Checking the excluded folders...')
	If ($FoldersToExclude.Count -ge 1) {
		ForEach ($FolderToExclude in $FoldersToExclude) {
			$FolderToExclude_path = Join-Path -Path $onedrive_directory -ChildPath $FolderToExclude
			If (Test-Path $FolderToExclude_path) {
				Write-Output ("`t Located: $FolderToExclude_path")
			}
			Else {
				Write-Output ("`t Missing: $FolderToExclude_path")
				Write-Output ('WARNING: the folder above was defined in the FoldersToExclude parameter but not found in OneDrive, exiting!')
				Return
			}
		}
	}
	Else {
		Write-Output ('NOTICE: no excluded folders were explicitly defined')
		Write-Output ('...the following default folders will be excluded from junctioning:')
		$FoldersToExclude = $FoldersToExclude_default
		ForEach ($FolderToExclude in $FoldersToExclude) {
			$FolderToExclude_path = Join-Path -Path $onedrive_directory -ChildPath $FolderToExclude
			Write-Output ("`t $FolderToExclude_path")
		}
		# insert warning here!
	}
}

# buffer output
Write-Output "`n"
Write-Output ('-----')

# loop through directories inside OneDrive directories
Get-ChildItem -Path $onedrive_directory.FullName | Where-Object { $_.PSIsContainer } | ForEach-Object {
	# define variables and declare folder
	$folder_hidden = $null
	$folder_ready = $false
	$folder_short = ($_.BaseName)
	$folder_cloud = ($_.FullName)
	$folder_local = ($env:USERPROFILE + '\' + $folder_short)
	Write-Output (' ')
	Write-Output ("Found OneDrive folder: '" + $folder_cloud + "'")
	
	# check if current folder matching the block list
	If ($FoldersToExclude -contains $folder_short) {
		Write-Output ("...'" + $folder_short + "' explicitly blocked, skipping!")
	}
	Else {
		If (Test-Path $folder_local) {
			Write-Output ("...'" + $folder_local + "' exists in user profile...")
			If ((Get-Item -Path $folder_local).LinkType -eq 'Junction') {
				Write-Output ("...'" + $folder_local + "' already junctioned, skipping!")
			}
			Else {
				Write-Output ("...'" + $folder_local + "' directory exists, migrating!")
				If ((Get-ChildItem -Path $folder_local -Recurse).Count -eq 0) {
					Write-Output ("...'" + $folder_local + "' directory is empty, checking for hidden items...")
					$folder_hidden = Get-ChildItem -Force -Path $folder_local
					If ($folder_hidden.Count -gt 0) {
						Write-Output ("...'" + $folder_local + "' hidden items found, resetting ACLs...")
						$folder_acl = Get-Acl $folder_local
						$folder_hidden | ForEach-Object { $_ | Set-Acl -AclObject $folder_acl }
						Write-Output ("...'" + $folder_local + "' hidden items updated, emptying directory!")
						Get-ChildItem -Force -Recurse -Path $folder_local | Remove-Item -Force -Recurse
					}
					$folder_ready = $true
				}
				Else {
					Write-Output ("...'" + $folder_local + "' directory is NOT empty, skipping!")
					Write-Output ('     NOTICE: a directory MUST be empty before it can be converted to a junction!')
				}
			}
		}
		Else {
			Write-Output ("...'" + $folder_local + "' does not exist, will create junction!")
			$folder_ready = $true
		}
		If ($folder_ready) {
			Write-Output ("...'" + $folder_local + "' creating junction!")
			New-Item -ItemType Junction -Path $folder_local -Target $folder_cloud | Out-Null
		}
	}
}

# close out
Write-Output (' ')
Write-Output ('-----')
Write-Output (' ')
Write-Output ('All permitted OneDrive directories are now locally junctioned!')