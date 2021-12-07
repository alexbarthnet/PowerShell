[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Mandatory = $True, ParameterSetName = 'Mount')]
	[switch]$Mount,
	[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')][ValidatePattern('^[^\*]+$')]
	[string]$Subject,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')][ValidatePattern('^[^\*]+$')][ValidateScript({ Test-Path -Path $_ })]
	[string]$Storage
)


Param(  
	[string]$OneDriveString,
	[string]$ExcludedFolders
)

# define the default OneDrive excluded folders list
$onedrive_block_list = @()
$onedrive_block_list += 'AppData'
$onedrive_block_list += 'Attachments'
$onedrive_block_list += 'Email Attachments'
$onedrive_block_list += 'Microsoft Teams Chat Files'
$onedrive_block_list += 'Microsoft Teams Data'
$onedrive_block_list += 'Notebooks'
$onedrive_block_list += 'Public'	

# buffer output
Write-Output (' ')

# get the OneDrive path(s)
$onedrive_directory = $null
switch ($OneDriveString) {
	{ 'OneDrive' -or 'Personal' } {
		Write-Output ('Searching for OneDrive directory...')
		$onedrive_directory = Get-ChildItem -Directory -Path $env:USERPROFILE | Where-Object { $_.Name -eq 'OneDrive' }
	}
	$null {
		Write-Output ('Searching for OneDrive directory...')
		$onedrive_directory = Get-ChildItem -Directory -Path $env:USERPROFILE | Where-Object { $_.Name -match 'OneDrive' }
	}
	Default {
		Write-Output ('Searching for OneDrive directory where name matches the OneDriveString parameter...')
		$onedrive_directory = Get-ChildItem -Directory -Path $env:USERPROFILE | Where-Object { $_.Name -match 'OneDrive - ' -and $_.Name -match $OneDriveString }	
	}
}

# test for 0 (can't junction) or 2+ (can't determine which to junction) OneDrive directories
switch (($onedrive_directory).Count) {
	1 { Write-Output ('...found the OneDrive directory: ' + $onedrive_directory.FullName) }
	0 { Write-Output ('...found no OneDrive directories; exiting!'); Exit }
	Default {
		If ([string]::IsNullOrEmpty($OneDriveString)) {
			Write-Output ('...found multiple OneDrive directories and no arguments were provided to limit scope to single directory, exiting!')
			Exit
		}
		Else {
			Write-Output ('...found multiple OneDrive directories and the provided argument did not limit scope to single directory, exiting!')
			Exit
		}
	}
}

# validate OneDrive directory *is* a directory
If ($onedrive_directory.PSIsContainer) {
	Write-Output '...validated the object found is a directory'
}
Else {
	Write-Output '...unable to determine if the object found is a directory, exiting!'
	Exit
}

# buffer output
Write-Output (' ')

# define OneDrive directories that will *NOT* be junctioned
Write-Output ('Checking for folders to exclude from junctioning...')
$onedrive_block_list = @()
If ($ExcludedFolders) {
	Write-Output ('Checking the file in the ExcludedFolders parameter...')
	If (Test-Path $ExcludedFolders) {
		$onedrive_block_list = @()
		Get-Content -Path $ExcludedFolders | ForEach-Object { $onedrive_block_list += $_ }
		Write-Output ('...setting the excluded folders to the following from the file:')
	}
	Else {
		Write-Output ('...file in the ExcludedFolders parameter was not found, exiting!')
		Exit
	}
}
Else {
	Write-Output ('...setting the excluded folders to the following defaults:')
}

# declare the excluded folders
$onedrive_block_list

# buffer output
Write-Output (' ')
Write-Output ('-----')

# loop through directories inside OneDrive directories
Get-ChildItem -Path $onedrive_directory.FullName | Where-Object { $_.PSIsContainer } | ForEach-Object {
	$folder_hidden = $null
	$folder_ready = $false
	$folder_short = ($_.BaseName)
	$folder_cloud = ($_.FullName)
	$folder_local = ($env:USERPROFILE + '\' + $folder_short)
	Write-Output (' ')
	Write-Output ("Found OneDrive folder: '" + $folder_cloud + "'")
	# check if current folder matching the block list
	If ($onedrive_block_list -contains $folder_short) {
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