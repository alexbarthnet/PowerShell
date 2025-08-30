<#
.SYNOPSIS
Run PowerShell scripts from removable media.

.DESCRIPTION
Run PowerShell scripts from removable media. The primary intent is enable arbitrary scripts to be run during Windows setup from one or more mounted ISO images without manipulation of the WIM image.

.INPUTS
None.

.OUTPUTS
None. The function does not generate any output.

.NOTES
This script will search for scripts in a 'Scripts' folder on mounted volumes of removable media. The scripts are run in alphabetical order from the volumes

.LINK
https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-deployment-runsynchronous-runsynchronouscommand-willreboot

#>

[CmdletBinding()]
param(
	[Parameter(DontShow)]
	[string]$SystemRoot = [System.Environment]::GetEnvironmentVariable('SystemRoot')
)

begin {
	# define error preference
	$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

	# define path for audit process
	$PathForAuditProcess = Join-Path -Path $SystemRoot -ChildPath 'System32\oobe\audit.exe'

	# retrieve processes
	$Processes = Get-Process

	# if audit process found...
	if ($Processes.Where({ $_.Path -eq $PathForAuditProcess })) {
		# set audit mode to true
		$AuditMode = $true
	}

	# define path for transcript
	$PathForTranscript = Join-Path -Path $SystemRoot -ChildPath 'Invoke-ScriptsFromRemovableMedia.log'

	# start transcript
	try {
		$null = Start-Transcript -Path $PathForTranscript -Append
	}
	catch {
		# if audit mode...
		if ($AuditMode) {
			# exit with a "The command failed" code
			exit 101
		}
		# if not audit mode...
		else {
			# return exception
			return $_
		}
	}

	# define script state XML file
	$ScriptStateXML = Join-Path -Path ([System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')) -ChildPath "$BaseName.xml"

	# if script state XML file found...
	if ([System.IO.File]::Exists($ScriptStateXML)) {
		# retrieve state
		try {
			$ScriptStates = Import-Clixml -Path $ScriptStateXML
		}
		catch {
			# if audit mode...
			if ($AuditMode) {
				# exit with a "The command failed" code
				exit 102
			}
			# if not audit mode...
			else {
				# return exception
				return $_
			}
		}
	}
	# if state file not found...
	else {
		# create empty array for script states
		$ScriptStates = @()
	}

	# retrieve volumes
	try {
		$Volumes = Get-Volume
	}
	catch {
		# if audit mode...
		if ($AuditMode) {
			# exit with a "The command failed" code
			exit 103
		}
		# if not audit mode...
		else {
			# return exception
			return $_
		}
	}
}

process {
	# get volumes with recognized file systems on non-fixed drives
	$RemoveableVolumes = $Volumes | Where-Object { $_.DriveType -ne 'Fixed' -and $_.OperationalStatus -eq 'OK' -and $_.Size -gt 0 } | Sort-Object -Property DriveLetter

	# if no optional drive volumes found...
	if ((Measure-Object -InputObject $RemoveableVolumes).Count -eq 0) {
		Write-Host 'No removeable volumes found'
		# if audit mode...
		if ($AuditMode) {
			# exit with a "The command completed" code
			exit 0
		}
		# if not audit mode...
		else {
			# return
			return
		}
	}

	# loop through volume
	:NextVolume foreach ($Volume in $RemoveableVolumes) {
		# define path from drive letter
		$Path = '{0}:\scripts' -f $Volume.DriveLetter

		# if path not found...
		if (![System.IO.Directory]::Exists($Path)) {
			# report and continue to next volume
			Write-Host "No 'scripts' path found on '$($Volume.DriveLetter)' drive with '$($Volume.FriendlyName)' label"
			continue NextVolume
		}

		# report state
		Write-Host "Checking for scripts in '$Path' path..."

		# retrieve scripts in path
		try {
			$Scripts = Get-ChildItem -Path $Path | Where-Object { $_.Extension -eq '.ps1' } | Select-Object -ExpandProperty FullName | Sort-Object
		}
		catch {
			Write-Warning -Message "could not retrieve scripts from '$Path' path: $($_.Exception.Message)"
			$ExitCodeFromScript = $_.Exception.HResult
		}

		# loop through scripts in path
		:NextScript foreach ($Script in $Scripts) {
			# retrieve script state from previous run
			$ScriptState = $ScriptStates | Where-Object { $_.Script -eq $Script }

			# process exit code from previous run
			if ($ScriptState.ExitCode -in 0, 1) {
				Write-Verbose -Message "Skipping completed '$Script' with existing exit code: $($ScriptState.ExitCode)"
				continue NextScript
			}

			# clear exit code
			$ExitCodeFromScript = $null

			# report state
			Write-Host "Running script: $Script"

			# run script
			try {
				& $Script
			}
			catch {
				Write-Warning -Message "could not run '$Script' script: $($_.Exception.Message)"
				$ExitCodeFromScript = $_.Exception.HResult
			}

			# record exit code from script
			if ($null -ne $ExitCodeFromScript) {
				$ExitCodeFromScript = $LASTEXITCODE
			}

			# if script state exists...
			if ($ScriptState.Script) {
				# update exit code for script state
				$ScriptState.ExitCode = $ExitCodeFromScript
			}
			# if script state does not exist...
			else {
				# add entry to script states
				$ScriptStates += [pscustomobject]@{
					Script   = $Script
					ExitCode = $ExitCodeFromScript
				}
			}

			# update script state file
			try {
				Export-Clixml -Path $ScriptStateXML -InputObject $ScriptStates
			}
			catch {
				Write-Warning -Message "could not write script state to '$ScriptStateXML' file: $($_.Exception.Message)"
				$ExitCodeFromScript = $_.Exception.HResult
			}

			# if audit mode and exit code from script is not "completed without error, no reboot required"...
			if ($AuditMode -and $ExitCodeFromScript -ne 0) {
				# immediately exit with exit code from script
				exit $ExitCodeFromScript
			}
		}
	}

	# stop transcript before exit
	$null = Stop-Transcript

	# if audit mode...
	if ($AuditMode) {
		# exit with the "The command was successful. No reboot is required." code
		exit 0
	}
	# if not audit mode...
	else {
		# return
		return
	}
}
