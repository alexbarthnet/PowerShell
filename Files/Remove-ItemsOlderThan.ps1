<#
.SYNOPSIS
Removes files and empty directories older than a defined point in time.

.DESCRIPTION
Removes files and empty directories where the last write time is older than the provided or computed datetime.

.PARAMETER Path
The path containing the files and empty directories.

.PARAMETER DateTime
The datetime used to compare with the last write time on files and directories. Cannot be combined with the TimeSpan, OlderThanUnits, or OlderThanType parameters.

.PARAMETER TimeSpan
The timespan used to create the computed datetime. A negative timespan will be inverted to correctly compute the datetime. Cannot be combined with the DateTime, OlderThanUnits, or OlderThanType parameters.

.PARAMETER OlderThanUnits
The number of datetime units to create the computed datetime. Cannot be combined with the DateTime or TimeSpan parameters.

.PARAMETER OlderThanType
The type of datetime units to create the computed datetime. Cannot be combined with the DateTime or TimeSpan parameters. Valid values are 'Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', and 'Years'

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Remove-ItemsOlderThan.ps1 -Path 'C:\Content\test' -OlderThanUnits 30 -OlderThanType 'Days'
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Computed')]
Param(
	# path for items to remove
	[Parameter(Mandatory = $True, Position = 0)][ValidateScript({ [System.IO.Directory]::Exists($_) })]
	[string]$Path,
	# previous datetime
	[Parameter(Mandatory = $True, Position = 1, ParameterSetName = 'DateTime')]
	[datetime]$DateTime,
	# timespan for computing previous datetime
	[Parameter(Mandatory = $True, Position = 1, ParameterSetName = 'TimeSpan')]
	[timespan]$TimeSpan,
	# units for computing previous datetime
	[Parameter(Mandatory = $True, Position = 1, ParameterSetName = 'Computed')][ValidateRange(1, 65535)]
	[uint16]$OlderThanUnits,
	# type for computing previous datetime
	[Parameter(Mandatory = $True, Position = 2, ParameterSetName = 'Computed')][ValidateSet('Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', 'Years')]
	[string]$OlderThanType
)

Begin {
	Function Get-PreviousDate {
		Param (
			[Parameter(Mandatory = $true, Position = 0)][ValidateRange(1, 65535)]
			[uint16]$OlderThanUnits,
			[Parameter(Mandatory = $true, Position = 1)][ValidateSet('Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', 'Years')]
			[string]$OlderThanType,
			[Parameter(Mandatory = $false)]
			[datetime]$DateTime = [datetime]::Now
		)
		Switch ($OlderThanType) {
			'Seconds' { Return $DateTime.AddSeconds(-1 * $OlderThanUnits) }
			'Minutes' { Return $DateTime.AddMinutes(-1 * $OlderThanUnits) }
			'Hours' { Return $DateTime.AddHours(-1 * $OlderThanUnits) }
			'Days' { Return $DateTime.AddDays(-1 * $OlderThanUnits) }
			'Weeks' { Return $DateTime.AddWeeks(-1 * $OlderThanUnits) }
			'Months' { Return $DateTime.AddMonths(-1 * $OlderThanUnits) }
			'Years' { Return $DateTime.AddYears(-1 * $OlderThanUnits) }
		}
	}
}

Process {
	# if timespan provided...
	If ($PSCmdLet.ParameterSetName -eq 'TimeSpan') {
		# ensure timespan is positive
		If ($TimeSpan -lt [timespan]::Zero) {
			$TimeSpan = $TimeSpan.Negate()
		}
	
		# get datetime from timespan
		$DateTime = [datetime]::Now.Subtract($TimeSpan)
	}

	# if components provided for computing previous datetime...
	If ($PSCmdLet.ParameterSetName -eq 'Computed') {
		# get previous date from input
		Try {
			$DateTime = Get-PreviousDate -OlderThanUnits $OlderThanUnits -OlderThanType $OlderThanType
		}
		Catch {
			Write-Warning -Message "could not create date from '$OlderThanUnits $OlderThanType'"
			Throw $_
		}
	}

	# define list for old files
	$Files = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

	# retrieve old files first
	Write-Host "Retrieving files written before '$DateTime' from '$Path'"
	Get-ChildItem -Path $Path -Recurse -Force -File | Where-Object { $_.LastWriteTime -lt $DateTime } | ForEach-Object {
		$Files.Add($_)
	}

	# remove old files first
	Write-Host "Removing '$($Files.Count)' file item(s) written before '$DateTime' from '$Path'"
	ForEach ($File in $Files) {
		If ($PSCmdlet.ShouldProcess($File.FullName, 'Remove File')) {
			# remove file
			Try {
				Remove-Item -Path $File.FullName -Force -ErrorAction 'Stop' -WarningAction 'Continue'
			}
			Catch {
				Write-Warning -Message "could not perform `"Remove File`" on target `"$($File.FullName)`": $($_.Exception.Message)"
			}

			# report file removed
			Write-Verbose -Message "removed '$($File.FullName)' file with '$($File.LastWriteTime)' LastWriteTime"
		}
	}

	# define list for old directories
	$Directories = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()

	# retrieve old directories
	Write-Host "Retrieving directories written before '$DateTime' from '$Path'"
	Get-ChildItem -Path $Path -Recurse -Force -Directory | Where-Object { $_.LastWriteTime -lt $DateTime } | Sort-Object -Property 'FullName' -Descending | ForEach-Object {
		# if old directory has files
		If ((Get-ChildItem -Path $_ -Recurse -Force)) {
			Write-Warning -Message "will not perform `"Remove Directory`" on target `"$($_.FullName)`": has child items last written after '$DateTime'"
		}
		Else {
			$Directories.Add($_)	
		}
	}

	# remove old directories last
	Write-Host "Removing '$($Directories.Count)' directory item(s) written before '$DateTime' from '$Path'"
	ForEach ($Directory in $Directories) {
		If ($PSCmdlet.ShouldProcess($Directory.FullName, 'Remove Directory')) {
			# remove directory
			Try {
				Remove-Item -Path $Directory.FullName -Force -ErrorAction 'Stop' -WarningAction 'Continue'
			}
			Catch {
				Write-Warning -Message "could not perform `"Remove Directory`" on target `"$($Directory.FullName)`": $($_.Exception.Message)"
			}

			# report directory removed
			Write-Verbose -Message "removed '$($Directory.FullName)' directory with '$($Directory.LastWriteTime)' LastWriteTime"
		}
	}
}
