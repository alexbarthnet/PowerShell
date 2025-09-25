[CmdletBinding(SupportsShouldProcess)]
param(
	[Parameter(DontShow)][ValidateSet('OneDrive', 'OneDriveConsumer', 'OneDriveCommerical')]
	[string]$Environment = 'OneDrive',
	[Parameter(Mandatory)][ValidateSet('Pin', 'Unpin', 'Reset')]
	[string]$Mode,
	[Parameter(Mandatory)]
	[string[]]$RelativePath,
	[switch]$WaitForOneDrive,
	[switch]$Force,
	[string]$Identity
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
	# warn and return
	Write-Warning -Message 'a mounted OneDrive container was not found in the user profile folder'
	return
}

# report OneDrive container:
Write-Host "...found mounted OneDrive container: $($OneDrive.FullName)"

# loop through folders in OneDrive container
:NextOneDriveFolder foreach ($ChildPath in $RelativePath) {
	# define OneDrive folder path
	$OneDriveFolderPath = Join-Path -Path $OneDrive.FullName -ChildPath $ChildPath

	# report state
	Write-Host "Checking OneDrive folder: $OneDriveFolderPath"

	# test OneDrive folder path
	$TestPath = Test-Path -Path $OneDriveFolderPath -PathType Container

	# if OneDrive folder path not found...
	if (!$TestPath) {
		# if wait for one drive requested...
		if ($WaitForOneDrive) {
			# report state
			Write-Host '...waiting for OneDrive folder'

			# while wait for OneDrive folder not found...
			while (!$TestPath) {
				# sleep
				Start-Sleep -Seconds 1

				# test OneDrive folder path
				$TestPath = Test-Path -Path $OneDriveFolderPath -PathType Container
			}
		}
	}

	# define list of paths
	$Paths = [System.Collections.Generic.List[string]]::new()

	# add OneDrive folder path to list
	$Paths.Add($OneDriveFolderPath)

	# add child items in OneDrive folder to list
	Get-ChildItem -Path $OneDriveFolderPath -Recurse | ForEach-Object { $Paths.Add($_.FullName) }

	# loop through paths
	:NextOneDriveItem foreach ($Path in $Paths) {
		# report state
		Write-Host "...checking OneDrive item: $Path"

		# retrieve folder
		$Item = Get-Item -Path $Path

		# switch on mode
		switch ($Mode) {
			'Pin' {
				# if file is already pinned...
				if ($Item.Attributes -band 0x80000 -and -not $Force.IsPresent) {
					Write-Host '...found the OneDrive item already pinned'
					continue NextOneDriveItem
				}
				else {
					Write-Host '...pinning the OneDrive item'
					$ArgumentList = '+p -u "{0}"' -f $Path
				}
			}
			'Unpin' {
				# if file is already unpinned...
				if ($Item.Attributes -band 0x100000 -and -not $Force.IsPresent) {
					Write-Host '...found the OneDrive item already unpinned'
					continue NextOneDriveItem
				}
				else {
					Write-Host '...unpinning the OneDrive item'
					$ArgumentList = '-p +u "{0}"' -f $Path
				}
			}
			'Reset' {
				Write-Host '...resetting the OneDrive item'
				$ArgumentList = '-p -u "{0}"' -f $Path
			}
			Default {
				continue NextOneDriveItem
			}
		}

		# apply attributes to folder
		Start-Process -Wait -NoNewWindow -FilePath 'attrib.exe' -ArgumentList $ArgumentList
	}
}
