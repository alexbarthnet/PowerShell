[CmdletBinding(SupportsShouldProcess)]
Param(
	[string]$Identity,
	[switch]$ClearHiddenItemsFromEmptyFolders,
	[switch]$CreateMissingFolders,
	[string[]]$ExcludeOneDriveFolders,
	[string[]]$IncludeOneDriveFolders
)

# if identity provided...
If ($PSBoundParameters.ContainsKey('Identity')) {
	# report state
	Write-Host 'Searching for mounted OneDrive container where name matches the Identity parameter...'

	# define filter script
	$FilterScript = { $_.Name -match '^OneDrive' -and $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint -and $_.Name -match $Identity }
}
Else {
	# report state
	Write-Host 'Searching for mounted OneDrive container...'

	# define filter script
	$FilterScript = { $_.Name -match '^OneDrive' -and $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint }
}

# retrieve OneDrice container(s) matching filterscript
Try {
	$OneDrive = Get-ChildItem -Directory -Path $env:USERPROFILE | Where-Object -FilterScript $FilterScript
}
Catch {
	Return $_
}

# if multiple OneDrive containers found with Identity...
If ($OneDrive.Count -gt 1 -and $PSBoundParameters.ContainsKey('Identity')) {
	Write-Warning -Message 'multiple OneDrive containers found in the user profile folder; the Identity parameter did not limit scope to single container'
	Return
}

# if multiple OneDrive containers found without Identity...
If ($OneDrive.Count -gt 1) {
	Write-Warning -Message 'multiple OneDrive containers found in the user profile folder; the Identity parameter was not provided to limit scope to single container'
	Return
}

# if no OneDrive containers found....
If ($OneDrive.Count -eq 0) {
	Write-Warning -Message 'a OneDrive container was not found in the user profile folder'
	Return
}

# report OneDrive container:
Write-Host "...found OneDrive container: $($OneDrive.FullName)"

# retrieve folders in OneDrive container
Try {
	$OneDriveFolders = $OneDrive | Get-ChildItem -Directory
}
Catch {
	Return $_
}

# loop through folders in OneDrive container
:NextOneDriveFolder ForEach ($OneDriveFolder in $OneDriveFolders) {
	# define variables and declare folder
	$OneDriveFolderBaseName = $OneDriveFolder.BaseName
	$OneDriveFolderFullName = $OneDriveFolder.FullName
	$ExistingFolderFullName = Join-Path -Path $env:USERPROFILE -ChildPath $OneDriveFolderBaseName

	# report state
	Write-Host "Found OneDrive folder: $OneDriveFolderBaseName"

	# if include folders provided...
	If ($PSBoundParameters.ContainsKey('IncludeOneDriveFolders')) {
		# check if OneDrive folder base name matches the include list
		If ($OneDriveFolderBaseName -notin $IncludeOneDriveFolders -and $OneDriveFolderFullName -notin $IncludeOneDriveFolders -and $ExistingFolderFullName -notin $IncludeOneDriveFolders) {
			Write-Host "...skipped '$OneDriveFolderBaseName' folder; folder name is not in IncludeOneDriveFolders"
			Continue NextOneDriveFolder
		}
	}

	# check if OneDrive folder base name matches the exclude list
	If ($OneDriveFolderBaseName -in $ExcludeOneDriveFolders -or $OneDriveFolderFullName -in $ExcludeOneDriveFolders -or $ExistingFolderFullName -in $ExcludeOneDriveFolders) {
		Write-Host "...skipped '$OneDriveFolderBaseName' folder; folder name is in ExcludeOneDriveFolders"
		Continue NextOneDriveFolder
	}

	# if existing folder not found...
	If (![System.IO.Directory]::Exists($ExistingFolderFullName)) {
		# if CreateMissingFolders requested...
		If ($CreateMissingFolders) {
			Write-Host  "...will create '$OneDriveFolderBaseName' folder; folder does not exist locally but CreateMissingFolders was set"
		}
		# if CreateMissingFolders not requested...
		Else {
			Write-Host  "...skipped '$OneDriveFolderBaseName' folder; folder does not exist locally and CreateMissingFolders was not set"
			Continue NextOneDriveFolder
		}
	}

	# if existing folder found...
	If ([System.IO.Directory]::Exists($ExistingFolderFullName)) {
		# retrieve existing folder
		Try {
			$ExistingFolder = Get-Item -Path $ExistingFolderFullName
		}
		Catch {
			Write-Warning -Message "...skipped '$OneDriveFolderBaseName' folder; could not retrieve existing folder: $($_.Exception.Message)"
			Continue NextOneDriveFolder
		}

		# check if current folder is already junctioned
		If ($ExistingFolder.LinkType -eq 'Junction') {
			Write-Host "...skipped '$OneDriveFolderBaseName' folder; existing folder already junctioned"
			Continue NextOneDriveFolder
		}

		# retrieve all child items
		Try {
			$ChildItems = Get-ChildItem -Path $ExistingFolderFullName -Force -Recurse
		}
		Catch {
			Write-Warning -Message "...skipped '$OneDriveFolderBaseName' folder; could not check existing folder for child items: $($_.Exception.Message)"
			Continue NextOneDriveFolder
		}

		# if existing folder contains files that are not hidden...
		If ($ChildItems.Where({ ($_.Attributes -band [System.IO.FileAttributes]::Hidden) -ne [System.IO.FileAttributes]::Hidden -and -not $_.PSIsContainer }).Count -gt 0) {
			Write-Host "...skipped '$OneDriveFolderBaseName' folder: existing folder contains existing files"
			Continue NextOneDriveFolder
		}

		# if existing folder contains files that are hidden...
		If ($ChildItems.Where({ ($_.Attributes -band [System.IO.FileAttributes]::Hidden) -eq [System.IO.FileAttributes]::Hidden -and -not $_.PSIsContainer }).Count -gt 0) {
			# if clear hidden items from empty folders not requested...
			If (!$ClearHiddenItemsFromEmptyFolders) {
				Write-Host "...skipped '$OneDriveFolderBaseName' folder: folder contains hidden files and ClearHiddenItemsFromEmptyFolders not set"
				Continue NextOneDriveFolder
			}

			# if what if not requested...
			If ($PSCmdlet.ShouldProcess($ExistingFolderFullName, 'Update ACL on child items')) {
				# retrieve ACL from existing folder
				$AclObject = Get-Acl -Path $ExistingFolder

				# reset ACL on each item
				ForEach ($ChildItem in $ChildItems) {
					# reset ACL
					Try {
						Set-Acl -Path $ChildItem.FullName -AclObject $AclObject -ErrorAction Stop
					}
					Catch {
						Write-Error "...skipped '$OneDriveFolderBaseName' folder; could not reset ACL on hidden item: $($ChildItem.FullName)"
						Continue NextOneDriveFolder
					}
				}

				# report state
				Write-Host "...updated hidden items in existing '$OneDriveFolderBaseName' folder, emptying existing folder..."
			}

			# if what if not requested...
			If ($PSCmdlet.ShouldProcess($ExistingFolderFullName, 'Remove child items')) {
				# remove items
				Try {
					Get-ChildItem -Path $ExistingFolderFullName -Force -Recurse | Remove-Item -Force -Recurse
				}
				Catch {
					Write-Error "...skipped '$OneDriveFolderBaseName' folder; could not remove hidden items"
					Continue NextOneDriveFolder
				}

				# report state
				Write-Host "...removed hidden items from existing '$OneDriveFolderBaseName' folder removed"
			}
		}
	}

	# create junction
	If ($PSCmdlet.ShouldProcess($ExistingFolderFullName, 'Junction folder')) {
		Try {
			$null = New-Item -ItemType Junction -Path $ExistingFolderFullName -Target $OneDriveFolderFullName
		}
		Catch {
			Write-Error "...skipped '$OneDriveFolderBaseName' folder; could not junction OneDrive folder to existing folder: $ExistingFolderFullName"
			Continue NextOneDriveFolder
		}

		# report state
		Write-Host "...junctioned '$OneDriveFolderBaseName' folder to '$ExistingFolderFullName' folder"
	}
}
