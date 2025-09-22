<#
.SYNOPSIS
Imports Windows installation media to a staging path.

.DESCRIPTION
Imports Windows installation media to a staging path. This enables peer scripts to update and export the media.

.PARAMETER ImagePath
Path to the ISO image containing Windows installation media.

.PARAMETER Path
Path to the staging folder for the Windows installation media. This value is only required when updating media in an existing staging path and the staging path parameter has been cleared.

.PARAMETER SkipExclude
Switch parameter to skip creating Microsoft Defender path exclusion for the staging path.

.INPUTS
None.

.OUTPUTS
None. The function does not generate any output.

.NOTES
This script creates or updates the global WindowsMediaStagingPath parameter

#>


[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
	[Parameter(Mandatory = $true)]
	[string]$ImagePath,
	[Parameter(Mandatory = $false)]
	[string]$Path,
	[Parameter(Mandatory = $false)]
	[switch]$SkipExclude
)

begin {
	function New-TemporaryFolder {
		param(
			[switch]$ForMachine
		)

		# if temporary folder for machine requested...
		if ($ForMachine) {
			# retrieve TEMP environment variable for machine
			$PathForTEMP = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')
		}
		else {
			# retrieve TEMP environment variable for user
			$PathForTEMP = [System.Environment]::GetEnvironmentVariable('TEMP', 'User')
		}

		# define path for temporary folder
		do {
			# define temporary folder name
			$NameForTemporaryFolder = [System.IO.Path]::GetRandomFileName().Replace('.', [System.String]::Empty)
			# combine TEMP path and temporary folder name
			$PathForTemporaryFolder = Join-Path -Path $PathForTEMP -ChildPath $NameForTemporaryFolder
		}
		until (![System.IO.Directory]::Exists($PathForTemporaryFolder))

		# create temporary folder
		try {
			$TemporaryFolder = New-Item -ItemType Directory -Path $PathForTemporaryFolder -Force -ErrorAction 'Stop'
		}
		catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# return temporary folder
		return $TemporaryFolder
	}

	# if parameter for staging path defined...
	if ($PSBoundParameters.ContainsKey('Path')) {
		# if staging path is not an absolute path...
		if (![System.IO.Path]::IsPathRooted($Path)) {
			# get unresolved absolute path
			try {
				$Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
			}
			catch {
				Write-Warning -Message "could not create absolute path from the provided Path parameter: $Path"
				$PSCmdlet.ThrowTerminatingError($_)
			}

			# report absolute path
			Write-Warning -Message "converted relative path from provided Path parameter to absolute path: $Path"
		}

		# if path not found as a directory...
		if (![System.IO.Directory]::Exists($Path)) {
			# create path WITHOUT the force parameter to create the path
			try {
				$null = New-Item -ItemType Directory -Path $Path -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message 'could not create staging path from provided Path parameter'
				$PSCmdlet.ThrowTerminatingError($_)
			}
		}

		# if global staging path exists is not provided path...
		if ($global:WindowsMediaStagingPath -and $global:WindowsMediaStagingPath -ne $Path) {
			Write-Warning -Message "found existing global staging path: $global:WindowsMediaStagingPath"
			Write-Warning -Message 'continue to overwrite with provided Path' -WarningAction Inquire
		}

		# store staging path in global variable
		try {
			New-Variable -Name 'WindowsMediaStagingPath' -Value $Path -Scope global -Force
		}
		catch {
			Write-Warning -Message 'could not store provided Path parameter as global WindowsMediaStagingPath variable'
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}
	# if parameter for staging path not defined...
	else {
		# if global staging path not defined...
		if ([System.String]::IsNullOrEmpty($global:WindowsMediaStagingPath)) {
			# create temporary folder
			try {
				$TemporaryFolder = New-TemporaryFolder
			}
			catch {
				Write-Warning -Message 'could not create temporary folder for staging path'
				$PSCmdlet.ThrowTerminatingError($_)
			}

			# store staging path in global variable
			try {
				New-Variable -Name 'WindowsMediaStagingPath' -Value $TemporaryFolder.FullName -Scope global -Force
			}
			catch {
				Write-Warning -Message 'could not store path to temporary folder as global WindowsMediaStagingPath variable'
				$PSCmdlet.ThrowTerminatingError($_)
			}
		}
		# if global staging defined...
		else {
			# ...but not found...
			if (![System.IO.Directory]::Exists($global:WindowsMediaStagingPath)) {
				# create path WITHOUT the force parameter to create the path
				try {
					$null = New-Item -ItemType Directory -Path $global:WindowsMediaStagingPath -ErrorAction 'Stop'
				}
				catch {
					Write-Warning -Message 'could not create staging path from global WindowsMediaStagingPath variable'
					$PSCmdlet.ThrowTerminatingError($_)
				}

				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Recreated previous staging path', $global:WindowsMediaStagingPath
			}
			else {
				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Found existing staging path', $global:WindowsMediaStagingPath
			}
		}
	}

	# if Skip Exclude not requested...
	if ($SkipExclude.IsPresent -eq $false) {
		try {
			Add-MpPreference -ExclusionPath $global:WindowsMediaStagingPath -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not create exclusion for staging path: $global:WindowsMediaStagingPath"
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}

	# retrieve child items in staging path
	try {
		$StagingPathItems = Get-ChildItem -Path $global:WindowsMediaStagingPath -Force -Recurse
	}
	catch {
		Write-Warning -Message 'could not check staging path for existing files and folders'
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# if child items found in staging path...
	if ($null -ne $StagingPathItems -and -not $ReuseStagingPath) {
		# if EmptyStagingPath not requested...
		if (!$EmptyStagingPath) {
			# warn and inquire
			Write-Warning -Message "found existing files or folders in staging path: $global:WindowsMediaStagingPath"
			Write-Warning -Message 'continue to empty StagingPath' -WarningAction Inquire
		}

		# remove child items in staging path
		try {
			Get-ChildItem -Path $global:WindowsMediaStagingPath -Force | Remove-Item -Force -Recurse -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message 'could not remove existing files or folders in staging path'
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}

	# retrieve base temporary path
	try {
		$TemporaryPath = Get-Item -Path $global:WindowsMediaStagingPath -ErrorAction 'Stop'
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# create temporary path for ISO contents
	try {
		$TemporaryPathForISO = New-Item -ItemType Directory -Path $TemporaryPath -Name 'ISO' -Force -ErrorAction 'Stop'
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}
}

process {
	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Mounting ISO image', $ImagePath

	# mount the original ISO image
	try {
		$DiskImage = Mount-DiskImage -ImagePath $ImagePath
	}
	catch {
		return $_
	}

	# retrieve volume for disk image
	try {
		$Volume = Get-Volume -DiskImage $DiskImage
	}
	catch {
		return $_
	}

	# define path for ISO label
	$PathForLabelFile = Join-Path -Path $TemporaryPath -ChildPath 'label.txt'

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Saving ISO label to file', $PathForLabelFile

	# save file system label
	try {
		Set-Content -Path $PathForLabelFile -Value $Volume.FileSystemLabel -Force -NoNewline
	}
	catch {
		return $_
	}

	# retrieve volume drive letter
	$ImageDriveLetter = $Volume.DriveLetter

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Copying ISO contents to path', $TemporaryPathForISO

	# copy ISO contents to temporary path
	try {
		Copy-Item -Path ('{0}:\*' -f $ImageDriveLetter) -Destination $TemporaryPathForISO -Recurse -Force -ErrorAction 'Stop'
	}
	catch {
		return $_
	}

	# report state
	"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Dismounting ISO image...'

	# dismount ISO image
	try {
		$null = $DiskImage | Dismount-DiskImage
	}
	catch {
		return $_
	}

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Windows media imported to staging path', $TemporaryPathForISO
}

end {
	# if Skip Exclude not requested...
	if (!$SkipExclude) {
		try {
			Remove-MpPreference -ExclusionPath $global:WindowsMediaStagingPath -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not remove exclusion for staging path: $global:WindowsMediaStagingPath"
		}
	}
}