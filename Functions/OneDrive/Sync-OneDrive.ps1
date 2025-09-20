function Sync-OneDrive {
	[CmdletBinding()]
	param(
		[string]$FilePath = (Join-Path -Path ([System.Environment]::GetFolderPath('System')) -ChildPath 'attrib.exe')
	)

	# define array for configured OneDrive user directories
	$ConfiguredOneDriveUserDirectories = @()

	# if consumer OneDrive defined...
	if (![string]::IsNullOrEmpty($env:OneDriveConsumer)) {
		# if consumer OneDrive mounted...
		if (Test-Path -PathType 'Container' -Path $env:OneDriveConsumer) {
			$ConfiguredOneDriveUserDirectories += $env:OneDriveConsumer
		}
	}

	# if commercial OneDrive defined...
	if (![string]::IsNullOrEmpty($env:OneDriveCommercial)) {
		# if commercial OneDrive mounted...
		if (Test-Path -PathType 'Container' -Path $env:OneDriveCommercial) {
			$ConfiguredOneDriveUserDirectories += $env:OneDriveCommercial
		}
	}

	# loop through mounted OneDrive user directories
	foreach ($FolderPath in $ConfiguredOneDriveUserDirectories) {
		# define item
		$Path = Join-Path -Path $FolderPath -ChildPath 'SyncOneDriveObject'

		# if item found...
		if ([System.IO.File]::Exists($Path)) {
			# retrieve item
			try {
				$Item = Get-Item -Path $Path
			}
			catch {
				return $_
			}
		}
		# if item not found...
		else {
			# create item
			try {
				$Item = New-Item -Path $Path -ItemType File
			}
			catch {
				return $_
			}
		}

		# define quoted path
		$PathForArgument = '"{0}"' -f $Path

		# set pinned attribute
		Start-Process -NoNewWindow -Wait -FilePath $FilePath -ArgumentList "+P $PathForArgument"

		# sleep for 1 seconds
		Start-Sleep -Seconds 1

		# remove pinned attribute
		Start-Process -NoNewWindow -Wait -FilePath $FilePath -ArgumentList "-P  $PathForArgument"

		# sleep for 1 seconds
		Start-Sleep -Seconds 1

		# set unpinned attribute
		Start-Process -NoNewWindow -Wait -FilePath $FilePath -ArgumentList "+U  $PathForArgument"

		# sleep for 1 seconds
		Start-Sleep -Seconds 1

		# remove item
		try {
			$Item | Remove-Item -Force
		}
		catch {
			return $_
		}
	}
}