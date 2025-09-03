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
	[parameter(DontShow)]
	[switch]$SkipAuditModeCheck,
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
		# warn before setting exit code and throwing exception
		Write-Warning -Message "could not create '$PathForTranscript' transcript file: $($_.Exception.Message)"

		# set exit code to a "The command failed" code before throwing exception
		$ExitCode = 101

		# throw exception
		throw $_
	}

	# define script states file
	$PathForScriptStates = Join-Path -Path $SystemRoot -ChildPath 'Invoke-ScriptsFromRemovableMedia.xml'

	# if script states file found...
	if ([System.IO.File]::Exists($PathForScriptStates)) {
		# import script states object from file
		try {
			$ScriptStates = Import-Clixml -Path $PathForScriptStates
		}
		catch {
			# warn before setting exit code and throwing exception
			Write-Warning -Message "could not read '$PathForScriptStates' script states file: $($_.Exception.Message)"

			# set exit code to a "The command failed" code before throwing exception
			$ExitCode = 102

			# throw exception
			throw $_
		}
	}
	# if state file not found...
	else {
		# create initial script states object as empty array
		$ScriptStates = @()

		# export initial script states object to file
		try {
			$ScriptStates | Export-Clixml -Path $PathForScriptStates -Force
		}
		catch {
			# warn before setting exit code and throwing exception
			Write-Warning -Message "could not create '$PathForScriptStates' script states file: $($_.Exception.Message)"

			# set exit code to a "The command failed" code before throwing exception
			$ExitCode = 103

			# throw exception
			throw $_
		}
	}

	# retrieve volumes
	try {
		$Volumes = Get-Volume
	}
	catch {
		# warn before setting exit code and throwing exception
		Write-Warning -Message "could not read volumes on system: $($_.Exception.Message)"

		# set exit code to a "The command failed" code before throwing exception
		$ExitCode = 104

		# throw exception
		throw $_
	}
}

process {
	# define char array of drive letters
	$DriveLetters = [char]'A'..[char]'Z'

	# get volumes on removable (not fixed) drives that are not empty and have a valid drive letters
	$RemoveableVolumes = $Volumes | Where-Object { $_.DriveType -ne 'Fixed' -and $_.Size -gt 0 -and $_.DriveLetter -in $DriveLetters } | Sort-Object -Property DriveLetter

	# if no optional drive volumes found...
	if ((Measure-Object -InputObject $RemoveableVolumes).Count -eq 0) {
		# report state before setting exit code and throwing exception
		Write-Host 'No removeable volumes found'

		# set exit code to the "The command was successful. No reboot is required." code before returning
		$ExitCode = 0

		# return
		return
	}

	# loop through volume
	:NextVolume foreach ($Volume in $RemoveableVolumes) {
		# define path from drive letter
		$Path = '{0}:\scripts' -f $Volume.DriveLetter

		# if path not found...
		if (![System.IO.Directory]::Exists($Path)) {
			# report state before continuing to next volume
			Write-Host "No 'scripts' path found on '$($Volume.DriveLetter)' drive with '$($Volume.FriendlyName)' label"

			# continue to next volume
			continue NextVolume
		}

		# report state
		Write-Host "Checking for scripts in '$Path' path..."

		# retrieve scripts in path
		try {
			$Scripts = Get-ChildItem -Path $Path | Where-Object { $_.Extension -eq '.ps1' } | Sort-Object -Property 'FullName'
		}
		catch {
			# warn before setting exit code and returning exception
			Write-Warning -Message "could not retrieve scripts from '$Path' path: $($_.Exception.Message)"

			# set exit code to a "The command failed" code before returning
			$ExitCode = 201

			# return exception
			return $_
		}

		# if no scripts found in path...
		if ((Measure-Object -InputObject $Scripts).Count -eq 0) {
			# report state before continuing to next volume
			Write-Host 'No scripts found in '$Path' path'

			# continue to next volume
			continue NextVolume
		}

		# loop through scripts in path
		:NextScript foreach ($Script in $Scripts) {
			# retrieve name and full name from script object
			$ScriptName = $Script.Name
			$ScriptPath = $Script.FullName

			# retrieve any script state from previous run by script name
			$ScriptState = $ScriptStates | Where-Object { $_.ScriptName -eq $ScriptName }

			# if script state found...
			if ($ScriptState) {
				# if audit mode and exit code is 2...
				if ($AuditMode -and $ScriptState.ExitCode -eq 2) {
					# report state before running script again
					Write-Host "Running '$ScriptPath' script in audit mode again; found existing exit code from previous run: $($ScriptState.ExitCode)"
				}
				# if not audit mode and exit code is not 2...
				else {
					# if audit mode...
					if ($AuditMode) {
						# report state before continuing to next script
						Write-Host "Skipping '$ScriptPath' script in audit mode; found existing exit code from previous run: $($ScriptState.ExitCode)"
					}
					# if not audit mode...
					else {
						# report state before continuing to next script
						Write-Host "Skipping '$ScriptPath' script in normal mode; found existing exit code from previous run: $($ScriptState.ExitCode)"
					}

					# continue to next script
					continue NextScript
				}
			}

			# if audit mode...
			if ($AuditMode) {
				# report state
				Write-Host "Running script in audit mode: $ScriptPath"
			}
			# if not audit mode...
			else {
				# report state
				Write-Host "Running script in normal mode: $ScriptPath"
			}

			# define parameters for Start-Process
			$StartProcess = @{
				PassThru     = $true # returns process object with the exit code
				Wait         = $true # wait so the script returns the exit code
				FilePath     = Join-Path -Path $SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
				ArgumentList = '-NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath
			}

			# run script
			try {
				$Process = Start-Process @StartProcess
			}
			catch {
				# warn before setting exit code and throwing exception
				Write-Warning -Message "could not run '$ScriptPath' script: $($_.Exception.Message)"

				# set exit code to a "The command failed" code before returning
				$ExitCode = 202

				# return exception
				return $_
			}

			# set exit code to exit code from process object
			$ExitCode = $Process.ExitCode

			# if audit mode...
			if ($AuditMode) {
				# report state
				Write-Host "Completed running '$ScriptPath' script in audit mode and received exit code: $ExitCode"
			}
			# if not audit mode...
			else {
				# report state
				Write-Host "Completed running '$ScriptPath' script in normal mode and received exit code: $ExitCode"
			}

			# if script state found...
			if ($ScriptState) {
				# update script state with exit code
				$ScriptState.ExitCode = $ExitCode
			}
			else {
				# add script state to script states
				$ScriptStates += [pscustomobject]@{
					ScriptName = $ScriptName
					ExitCode   = $ExitCode
				}
			}

			# update script states file
			try {
				$ScriptStates | Export-Clixml -Path $PathForScriptStates -Force
			}
			catch {
				# warn before setting exit code and returning exception
				Write-Warning -Message "could not write script state to '$PathForScriptStates' file: $($_.Exception.Message)"

				# set exit code to a "The command failed" code before returning
				$ExitCode = 203

				# return exception
				return $_
			}

			# if exit code is not "The command was successful. No reboot is required." exit code...
			if ($ExitCode -ne 0) {
				# if audit mode and exit code is "The command was successful. An immediate reboot is required." or "The command is still in process. An immediate reboot is required." for specialize pass and in audit mode...
				if ($AuditMode -and $ExitCode -in 1,2) {
					# report state before returning
					Write-Host "Rebooting after running '$ScriptName' script in audit mode and receiving '$ExitCode' exit code"

					# set exit code to "The command is still in process. An immediate reboot is required." to force another pass of this script after a reboot
					$ExitCode = 2
				}

				# return
				return
			}
		}
	}
}

end {
	# stop transcript before exit
	$null = Stop-Transcript

	# exit with exit code
	if ($AuditMode) {
		exit $ExitCode
	}
}
