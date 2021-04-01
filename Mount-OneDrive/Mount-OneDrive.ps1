# buffer output
Write-Output (" ")

# get the OneDrive path(s)
switch ($args.Count) {
	0 {
		Write-Output ("Script started without arguments: searching for single OneDrive directory...")
		$onedrive_directory = Get-ChildItem -Directory -Path $env:USERPROFILE | Where-Object { $_.Name -match "OneDrive" }
	}
	1 {
		Write-Output ("Script started with single argument: searching for single OneDrive directory matching argument...")
		$onedrive_directory = Get-ChildItem -Directory -Path $env:USERPROFILE | Where-Object { $_.Name -match "OneDrive" -and $_.Name -match $args[0]}
	}
	default {
		Write-Output ("Script started with multiple arguments: only 0 or 1 arguments are supported, exiting!")
		Exit
	}
}

# test for 0 (can't junction) or 2+ (can't determine which to junction) OneDrive directories
switch (($onedrive_directory).Count) {
	1 {Write-Output ("...found the OneDrive directory: " + $onedrive_directory.FullName)}
	0 {Write-Output ("...found no OneDrive directories; exiting!"); Exit}
	Default {
		If ($args.Count -eq 0){
			Write-Output ("...found multiple OneDrive directories and no arguments were provided to limit scope to single directory, exiting!"); Exit
		}
		Else {
			Write-Output ("...found multiple OneDrive directories and the provided argument did not limit scope to single directory, exiting!"); Exit
		}
	}
}

# load directories that will *not* be junctioned
$onedrive_block_file = Get-ChildItem -Path . -Filter "Mount-OneDrive-Exceptions.txt"
$onedrive_block_list = Get-Content -Path $onedrive_block_file

# validate OneDrive directory *is* a directory
If ($onedrive_directory.PSIsContainer) {
	Write-Output "...validated the object found is a directory"
}
Else {
	Write-Output "...unable to determine if the object found is a directory, exiting!"
}

# buffer output
Write-Output (" ")
Write-Output ("-----")

# loop through directories inside OneDrive directories
Get-ChildItem -Path $onedrive_directory.FullName | Where-Object {$_.PSIsContainer} | ForEach-Object {
	$folder_hidden = $null
	$folder_ready = $false
	$folder_short = ($_.BaseName)
	$folder_cloud = ($_.FullName)
	$folder_local = ($env:USERPROFILE + "\" + $folder_short)
	Write-Output (" ")
	Write-Output ("Found OneDrive folder: '" + $folder_cloud + "'")
	# check if current folder matching the block list
	If ($onedrive_block_list -contains $folder_short) {
		Write-Output ("...'" + $folder_short + "' explicitly blocked, skipping!")
	}
	Else {
		If (Test-Path $folder_local) {
			Write-Output ("...'" + $folder_local + "' exists, continuing!")
			If ((Get-Item -Path $folder_local).LinkType -eq "Junction"){
				Write-Output ("...'" + $folder_local + "' junction exists, skipping!")
			}
			Else {
				Write-Output ("...'" + $folder_local + "' directory exists, migrating!")
				If ((Get-ChildItem -Path $folder_local -Recurse).Count -eq 0) {
					Write-Output ("...'" + $folder_local + "' directory is empty, checking for hidden items...")
					$folder_hidden = Get-ChildItem -Force -Path $folder_local
					If ($folder_hidden.Count -gt 0) {
						Write-Output ("...'" + $folder_local + "' hidden items found, resetting ACLs...")
						$folder_acl = Get-Acl $folder_local
						$folder_hidden | ForEach-Object {$_ | Set-Acl -AclObject $folder_acl}
						Write-Output ("...'" + $folder_local + "' hidden items removed, emptying directory!")
						Get-ChildItem -Force -Recurse -Path $folder_local | Remove-Item -Force -Recurse
					}
					$folder_ready = $true
				}
				Else {
					Write-Output ("...'" + $folder_local + "' directory is NOT empty, skipping!")
					Write-Output ("     NOTICE: a directory MUST be empty before it can be converted to a junction!")
				}
			}
		}
		Else {
			Write-Output ("...'" + $folder_local + "' does not exist, will create junction!")
			$folder_ready = $true
		}
		If ($folder_ready) {
			Write-Output ("...'" + $folder_local + "' creating junction!")
			New-Item -ItemType Junction -Path $folder_local -Target $folder_cloud
		}
	}
}

# close out
Write-Output (" ")
Write-Output ("-----")
Write-Output (" ")
Write-Output ("All permitted OneDrive directories are now locally junctioned!")