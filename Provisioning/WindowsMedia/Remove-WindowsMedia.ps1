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
	[Parameter(Mandatory = $false)]
	[string]$Path,
	[Parameter(Mandatory = $false)]
	[switch]$Force,
	[Parameter(Mandatory = $false)]
	[switch]$SkipExclude
)

begin {
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
			Write-Warning -Message 'could not locate existing staging path: global WindowsMediaStagingPath variable is null or empty'
			Write-Warning -Message 'create a staging path with the Import-WindowsMedia.ps1 script or provide the Path parameter to define the staging path'
			return
		}
		# if global staging defined...
		else {
			# ...but not found...
			if (![System.IO.Directory]::Exists($global:WindowsMediaStagingPath)) {
				Write-Warning -Message 'could not locate folder for existing staging path: value of global WindowsMediaStagingPath variable is not a folder'
				Write-Warning -Message 'create a staging path with the Import-WindowsMedia.ps1 script or provide the Path parameter to define the staging path'
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

	# create base temporary path
	try {
		$TemporaryPath = New-Item -ItemType Directory -Path $global:WindowsMediaStagingPath -Force -ErrorAction 'Stop'
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# create temporary path for DISM scratch directory
	try {
		$TemporaryPathForDSD = New-Item -ItemType Directory -Path $TemporaryPath -Name 'DSD' -Force -ErrorAction 'Stop'
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}
}

process {
	# if force set to false or not provided...
	If ($Force -eq $false -or -not $Force.IsPresent) {
		Write-Warning -Message "Continue to remove staging path: $global:WindowsMediaStagingPath" -WarningAction Inquire
	}

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Checking for mounted Windows images in staging path', $global:WindowsMediaStagingPath

	# retrieve mounted Windows images
	try {
		$MountedWindowsImages = Get-WindowsImage -Mounted -ErrorAction 'Stop'
	}
	catch {
		Write-Warning -Message 'could not retrieve mounted Windows images'
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# loop through mounted Windows images
	foreach ($MountedWindowsImage in $MountedWindowsImages) {
		# define booleans
		$MountPathInStagingPath = $MountedWindowsImage.Path.StartsWith($global:WindowsMediaStagingPath, [System.StringComparison]::InvariantCultureIgnoreCase)
		$ImagePathInStagingPath = $MountedWindowsImage.ImagePath.StartsWith($global:WindowsMediaStagingPath, [System.StringComparison]::InvariantCultureIgnoreCase)

		# if mount path or image path are in staging path...
		if ($MountPathInStagingPath -or $ImagePathInStagingPath) {
			# report state
			"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Dismounting Windows images in staging path', $MountedWindowsImage.Path

			# dismount windows image discarding changes
			try {
				Dismount-WindowsImage -Path $MountedWindowsImage.Path -Discard -ScratchDirectory $TemporaryPathForDSD -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message 'could not check staging path for existing files and folders'
				$PSCmdlet.ThrowTerminatingError($_)
			}

			# report state
			"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Dismounted Windows media in staging path'
		}
	}

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Checking for Windows media in staging path', $global:WindowsMediaStagingPath

	# retrieve child items in staging path
	try {
		$StagingPathItems = Get-ChildItem -Path $global:WindowsMediaStagingPath -Force -Recurse
	}
	catch {
		Write-Warning -Message 'could not check staging path for existing files and folders'
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# if child items found in staging path...
	if ($null -ne $StagingPathItems) {
		# report state
		"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Removing Windows media from staging path', $global:WindowsMediaStagingPath

		# remove child items in staging path
		try {
			Get-ChildItem -Path $global:WindowsMediaStagingPath -Force | Remove-Item -Force -Recurse -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message 'could not remove existing files or folders in staging path'
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# report state
		"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Removed Windows media from staging path'
	}

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Removing staging path', $global:WindowsMediaStagingPath

	# remove staging path
	try {
		Get-Item -Path $global:WindowsMediaStagingPath -Force | Remove-Item -Force -Recurse -ErrorAction 'Stop'
	}
	catch {
		Write-Warning -Message 'could not remove staging path'
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# report state
	"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Removed staging path'
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