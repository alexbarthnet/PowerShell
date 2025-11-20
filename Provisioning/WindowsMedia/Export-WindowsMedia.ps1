<#
.SYNOPSIS
Exports Windows installation media in a staging path to an ISO image or USB drive.

.DESCRIPTION
Exports Windows installation media in a staging path to an ISO image or USB drive. This relies on peer scripts to import and update the media.

.PARAMETER ISO
Switch parameter to export Windows media to an ISO image. Cannot be combined with the USB parameter.

.PARAMETER USB
Switch parameter to export Windows media to an USB drive. Cannot be combined with the ISO parameter.

.PARAMETER ImagePath
Path for the updated Windows ISO image. Requires the ISO switch parameter.

.PARAMETER FilePath
Path to the required OS CD imaging program from the Windows ADK. Requires the ISO switch parameter. The default value is 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe' and is constructed using the path of the 'ProgramFilesx86' special folder.

.PARAMETER ShowProgramOutputInline
Switch parameter to display output from OS CD imaging program inline rather than in a new window. Requires the ISO switch parameter.

.PARAMETER DriveLetter
Character for the drive letter of an existing volume on the USB drive. Requires the USB switch parameter.

.PARAMETER Number
Integer for the disk number of the USB drive. Requires the USB switch parameter.

.PARAMETER FileSystem
String with file system to apply to USB drive. Requires the USB switch parameter. The default value is "NTFS" and the value must be "NTFS" or "FAT32".

.PARAMETER FileSystemLabelSuffix
String containing a suffix to apply to the file system label from the original Windows ISO image. The default value is 'UNATTENDED' and is separated from the original file system label by an underscore.

.PARAMETER Path
Path to the staging folder for the Windows installation media. This value is only required when updating media in an existing staging path and the staging path parameter has been cleared.

.PARAMETER SkipExclude
Switch parameter to skip creating Microsoft Defender path exclusion for the staging path.

.INPUTS
None.

.OUTPUTS
None. The function does not generate any output.

.LINK
https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/oscdimg-command-line-options?view=windows-11

#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
	[Parameter(ParameterSetName = 'ISO', Mandatory = $true)]
	[switch]$ISO,
	[Parameter(ParameterSetName = 'ISO', Mandatory = $true)]
	[string]$ImagePath,
	[Parameter(ParameterSetName = 'ISO', Mandatory = $false)]
	[string]$FilePath = '{0}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe' -f [System.Environment]::GetFolderPath('ProgramFilesx86'),
	[Parameter(ParameterSetName = 'ISO', Mandatory = $false)]
	[switch]$NoNewWindow,
	[Parameter(ParameterSetName = 'USB', Mandatory = $true)]
	[switch]$USB,
	[Parameter(ParameterSetName = 'USB', Mandatory = $false)]
	[string]$DriveLetter,
	[Parameter(ParameterSetName = 'USB', Mandatory = $false)]
	[uint32]$Number,
	[Parameter(ParameterSetName = 'USB', Mandatory = $false)][ValidateSet('NTFS', 'FAT32')]
	[string]$FileSystem = 'NTFS',
	[Parameter(Mandatory = $false)]
	[string]$FileSystemLabel = 'WindowsMedia',
	[Parameter(Mandatory = $false)]
	[string]$FileSystemLabelSuffix = 'UNATTENDED',
	[Parameter(Mandatory = $false)]
	[string]$Path,
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
			# warn and return
			Write-Warning -Message 'could not locate existing staging path: global WindowsMediaStagingPath variable is null or empty'
			Write-Warning -Message 'create a staging path with the Import-WindowsMedia.ps1 script or provide the Path parameter to define the staging path'
			return
		}
		# if global staging defined...
		else {
			# ...but not found...
			if (![System.IO.Directory]::Exists($global:WindowsMediaStagingPath)) {
				# warn and return
				Write-Warning -Message 'could not locate folder for existing staging path: value of global WindowsMediaStagingPath variable is not a folder'
				Write-Warning -Message 'create a staging path with the Import-WindowsMedia.ps1 script or provide the Path parameter to define the staging path'
				return
			}
			else {
				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Found existing staging path', $global:WindowsMediaStagingPath
			}
		}
	}

	# if Skip Exclude not requested...
	if ($SkipExclude.IsPresent -eq $false) {
		# add the staging path to the excluded paths in Windows Defender
		try {
			Add-MpPreference -ExclusionPath $global:WindowsMediaStagingPath -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not add Windows Defender path exclusion for staging path: $global:WindowsMediaStagingPath"
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# retrieve Windows Defender configuration
		try {
			$MpPreference = Get-MpPreference
		}
		catch {
			Write-Warning -Message 'could not retrieve Windows Defender preferences to check excluded paths'
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# if the staging path is not in the excluded paths in Windows Defender...
		if ($global:WindowsMediaStagingPath -notin $MpPreference.ExclusionPath) {
			# warn and inquire
			Write-Warning -Message "the Windows Defender excluded paths do not contain the global staging path: $global:WindowsMediaStagingPath"
			Write-Warning -Message 'continue to process the Windows Media without the staging path excluded from Windows Defender scanning' -WarningAction Inquire
		}
	}

	# retrieve base temporary path
	try {
		$TemporaryPath = Get-Item -Path $global:WindowsMediaStagingPath -ErrorAction 'Stop'
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# define temporary path for ISO contents
	try {
		$TemporaryPathForISO = Get-Item -Path (Join-Path -Path $TemporaryPath -ChildPath 'ISO') -Force -ErrorAction 'Stop'
	}
	catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}
}

process {
	# if file system label not provided...
	if (!$PSBoundParameters.ContainsKey('FileSystemLabel')) {
		# define saved file system label file
		$FileSystemLabelFile = Join-Path -Path $TemporaryPath -ChildPath 'label.txt'

		# if file system label file not found...
		if (![System.IO.File]::Exists($FileSystemLabelFile)) {
			Write-Warning -Message "could not locate file system label file: $FileSystemLabelFile"
			Write-Warning -Message "continue to use default 'WindowsMedia' as base for file system label" -WarningAction Inquire
		}

		# retrieve file system label
		try {
			$FileSystemLabel = Get-Content -Path $FileSystemLabelFile
		}
		catch {
			return $_
		}

		# if file system label is empty...
		if ([System.String]::IsNullOrEmpty($FileSystemLabel)) {
			Write-Warning -Message "found empty file system label file: $FileSystemLabelFile"
			Write-Warning -Message "continue to use default 'WindowsMedia' as base for file system label" -WarningAction Inquire
		}
	}

	# if file system label suffix exists...
	if (![System.String]::IsNullOrEmpty($FileSystemLabelSuffix)) {
		# append suffix to file system label
		$FileSystemLabel = '{0}_{1}' -f $FileSystemLabel, $FileSystemLabelSuffix
	}

	# if file system is FAT32...
	if ($FileSystem -eq 'FAT32') {
		# define file system label length for FAT32 file system
		$Length = 12
	}
	else {
		# define file system label length for NTFS and ISO file system
		$Length = 32
	}

	# if file system label is longer than permitted length...
	if ($FileSystemLabel.Length -gt $Length) {
		# trim file system label to permitted length
		$FileSystemLabel = $FileSystemLabel.Substring(0, $Length)
	}

	# report state
	"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Using file system label', $FileSystemLabel

	# switch on parameter set
	switch ($PSCmdlet.ParameterSetName) {
		'ISO' {
			########################################
			# validate program
			########################################

			# validate path to required program
			try {
				$null = Get-Item -Path $FilePath -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message "could not retrieve required program: $FilePath"
				throw $_
			}

			########################################
			# prepare ISO image path
			########################################

			# if ISO image exists...
			if ([System.IO.File]::Exists($ImagePath)) {
				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Removing previous ISO image', $ImagePath

				# retrieve existing ISO image
				try {
					$Item = Get-Item -Path $ImagePath -ErrorAction 'Stop'
				}
				catch {
					return $_
				}
			}
			# if ISO image exists...
			else {
				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Verifying ISO image path', $ImagePath

				# create temporary file for ISO image to create path
				try {
					$Item = New-Item -ItemType File -Path $ImagePath -Force -ErrorAction 'Stop'
				}
				catch {
					return $_
				}
			}

			# remove existing ISO image
			try {
				$Item | Remove-Item -Force -ErrorAction 'Stop'
			}
			catch {
				return $_
			}

			########################################
			# write prepared image to ISO image
			########################################

			# report state
			"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Creating ISO image', $ImagePath

			# define bootdata for ISO image
			$Bootdata = "2#p0,e,b$TemporaryPathForISO\boot\etfsboot.com#pEF,e,b$TemporaryPathForISO\efi\microsoft\boot\efisys_noprompt.bin"

			# define arguments
			# reference: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/oscdimg-command-line-options?view=windows-11
			$ArgumentList = "-l$FileSystemLabel -bootdata:$Bootdata -u2 -udfver102 -o $TemporaryPathForISO $ImagePath"

			# define parameters for Start-Process
			$StartProcess = @{
				FilePath     = $FilePath
				ArgumentList = $ArgumentList
				Wait         = $true
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# if NoNewWindow requested...
			if ($NoNewWindow.IsPresent) {
				$StartProcess['NoNewWindow'] = $NoNewWindow -as [bool]
			}
			else {
				$StartProcess['WindowStyle'] = [System.Diagnostics.ProcessWindowStyle]::Normal
			}

			# start process to write updated ISO in current window
			Start-Process @StartProcess
		}
		'USB' {
			########################################
			# locate USB drive
			########################################

			# retrieve removable volumes
			$Volumes = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' }

			# retrieve USB disks
			$Disks = Get-Disk | Where-Object { $_.BusType -eq 'USB' }

			# if drive letter provided...
			if ($DriveLetter) {
				# retrieve removable volumes
				$Volume = $Volumes | Where-Object { $_.DriveLetter -eq $DriveLetter }

				# if volume with drive letter not found...
				if ($null -eq $Volume) {
					Write-Warning -Message 'no removable volumes found with '$DriveLetter' drive letter, exiting!'
					return
				}

				# retrieve disk from volume
				$Disk = $Volume | Get-Partition | Get-Disk | Where-Object { $_.BusType -eq 'USB' }

				# if disk count is greater than 1...
				if ((Measure-Object -InputObject $Disk).Count -gt 1) {
					Write-Warning -Message 'multiple Removable USB disks found for provided DriveLetter, use DiskNumber parameter to define specific disk, exiting!'
					return
				}

				# if disk not found...
				if ($null -eq $Disk) {
					Write-Warning -Message 'no removable volumes on USB disks found with '$DriveLetter' drive letter, exiting!'
					return
				}
			}
			# if disk number provided...
			elseif ($Number) {
				# retrieve USB disk by disk number
				$Disk = $Disks | Where-Object { $_.BusType -eq 'USB' -and $_.Number -eq $Number }

				# if disk with disk number not found...
				if ($null -eq $Disk) {
					Write-Warning -Message 'no USB disks found with '$Number' disk number, exiting!'
					return
				}
			}
			# if drive letter and disk number not provided...
			else {
				# report state
				"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Locating first available USB drive'

				# retrieve removable volumes
				$Volume = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' }

				# if volume count is not zero...
				if ((Measure-Object -InputObject $Volume).Count -gt 0) {
					# retrieve volumes that are USB disks
					$Disk = $Volume | Get-Partition | Get-Disk | Where-Object { $_.BusType -eq 'USB' }

					# if disk count is greater than 1...
					if ((Measure-Object -InputObject $Disk).Count -gt 1) {
						Write-Warning -Message 'multiple removable volumes on USB disks found, use the DriveLetter or Number parameter to define a specific volume or disk, exiting!'
						return
					}

					# if disk count is less than 1...
					if ((Measure-Object -InputObject $Disk).Count -lt 1) {
						Write-Warning -Message 'no removable volumes on USB disks found, exiting!'
						return
					}
				}

				# if disk not found from volumes...
				if ($null -eq $Disk) {
					# retrieve USB disks
					$Disk = Get-Disk | Where-Object { $_.BusType -eq 'USB' }

					# if disk count is greater than 1...
					if ((Measure-Object -InputObject $Disk).Count -gt 1) {
						Write-Warning -Message 'multiple USB disks found, use the Number parameter from the Get-Disk command to define a specific disk, exiting!'
						return
					}

					# if disk count is less than 1...
					if ((Measure-Object -InputObject $Disk).Count -lt 1) {
						Write-Warning -Message 'no USB disks found, exiting!'
						return
					}
				}
			}

			# report state
			"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Will use USB drive with disk number', $Disk.Number

			########################################
			# prepare USB drive
			########################################

			# report state
			"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Clearing USB drive', $Disk.Number

			# clear disk
			$Disk = $Disk | Clear-Disk -RemoveData -Confirm:$false -PassThru

			# report state
			"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Partitioning USB drive', $Disk.Number

			# configure disk
			try {
				$Disk | Set-Disk -PartitionStyle GPT
			}
			catch {
				return $_
			}

			# define empty parameters for New-Partition
			$NewPartition = @{}

			# if disk is larger than 32GB...
			if ($Disk.Size -gt 32GB) {
				$NewPartition['Size'] = 32GB
			}
			else {
				$NewPartition['UseMaximumSize'] = $true
			}

			# if drive letter provided...
			if ($DriveLetter) {
				$NewPartition['DriveLetter'] = $DriveLetter
			}
			else {
				$NewPartition['AssignDriveLetter'] = $true
			}

			# create partition
			try {
				$Partition = $Disk | New-Partition @NewPartition
			}
			catch {
				return $_
			}

			# report state
			"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Formatting USB drive with file system', $FileSystem

			# partition and format disk
			try {
				$Volume = $Partition | Format-Volume -FileSystem $FileSystem -NewFileSystemLabel $FileSystemLabel
			}
			catch {
				return $_
			}

			########################################
			# write prepared image to USB drive
			########################################

			# report state
			"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Copying ISO contents to USB drive', $Volume.DriveLetter

			# copy ISO contents to USB drive
			try {
				Copy-Item -Path ('{0}\*' -f $TemporaryPathForISO) -Destination ('{0}:\' -f $Volume.DriveLetter) -Recurse -Force -ErrorAction 'Stop'
			}
			catch {
				return $_
			}
		}
		Default {
			Write-Warning -Message 'export format not defined'
		}
	}
}

end {
	# if Skip Exclude not requested...
	if (!$SkipExclude) {
		# remove the staging path from the excluded paths in Windows Defender
		try {
			Remove-MpPreference -ExclusionPath $global:WindowsMediaStagingPath -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not remove Windows Defender path exclusion for staging path: $global:WindowsMediaStagingPath"
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}
}