<#
.SYNOPSIS
Run PowerShell scripts from a 'CD-ROM' drive.

.DESCRIPTION
Run PowerShell scripts from a 'CD-ROM' drive. The primary intent is enable arbitrary scripts to be run during Windows setup from one or more mounted ISO images without manipulation of the WIM image.

.INPUTS
None.

.OUTPUTS
None. The function does not generate any output.

.NOTES
This script will search for scripts in a 'Scripts' folder on mounted volumes with the 'CD-ROM' drive type. The scripts are run in alphabetical order from the volumes

.LINK
https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nn-wuapi-iinstallationresult

.LINK
https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdatesearcher-search

.LINK
https://learn.microsoft.com/en-us/windows/win32/api/wuapi/ne-wuapi-operationresultcode

.LINK
https://learn.microsoft.com/en-us/windows/win32/wua_sdk/searching--downloading--and-installing-updates

.LINK
https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-deployment-runsynchronous-runsynchronouscommand-willreboot

#>
# define transcript path
$BaseName = Get-Item -Path $PSCommandPath | Select-Object -ExpandProperty BaseName
$TranscriptPath = Join-Path -Path ([System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')) -ChildPath "$BaseName.txt"
$ScriptStateXML = Join-Path -Path ([System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')) -ChildPath "$BaseName.xml"

# start transcript
$null = Start-Transcript -Path $TranscriptPath -Force -Append

# if state file found...
If ([System.IO.File]::Exists($ScriptStateXML)) {
	# retrieve state
	Try {
		$ScriptStates = Import-Clixml -Path $ScriptStateXML
	}
	Catch {
		Exit 101
	}
}
# if state file not found...
Else {
	# create empty array for script states
	$ScriptStates = @()
}

# get optical drive volumes with mounted images
$Volumes = (Get-Volume).Where({ $_.DriveType -eq 'CD-ROM' -and $_.Size -gt 0 }) | Sort-Object -Property DriveLetter

# if no optional drive volumes found...
If ($Volumes.Count -eq 0) {
	Write-Host "No volumes found with drive type of 'CD-ROM'"
	Exit 0
}

# define overall exit code
[int]$ExitCode = 0

# loop through volume
:NextVolume ForEach ($Volume in $Volumes) {
	# define path from drive letter
	$Path = '{0}:\scripts' -f $Volume.DriveLetter

	# if path not found...
	If (![System.IO.Directory]::Exists($Path)) {
		# report and continue to next volume
		Write-Host "No 'scripts' path found on '$($Volume.DriveLetter)' drive with '$($Volume.FriendlyName)' label"
		Continue NextVolume
	}

	# retrieve scripts in path
	Try {
		$Scripts = Get-ChildItem -Path $Path | Where-Object { $_.Extension -eq '.ps1' } | Select-Object -ExpandProperty FullName | Sort-Object
	}
	Catch {
		Write-Warning -Message "could not retrieve scripts from '$Path' path: $($_.Exception.Message)"
		$ExitCodeFromScript = $_.Exception.HResult
	}

	# loop through scripts in path
	:NextScript ForEach ($Script in $Scripts.FullName) {
		# retrieve script state from previous run
		$ScriptState = $ScriptStates.Where({ $_.Script -eq $Script })

		# process exit code from previous run
		If ($ScriptState.ExitCode -in 0, 1) {
			Write-Verbose -Message "Skipping completed '$Script' with existing exit code: $($ScriptState.ExitCode)"
			Continue NextScript
		}

		# clear exit code
		$ExitCodeFromScript = $null

		# report state
		Write-Host "Running script: $Script"

		# run script
		Try {
			& $Script
		}
		Catch {
			Write-Warning -Message "could not run '$Script' script: $($_.Exception.Message)"
			$ExitCodeFromScript = $_.Exception.HResult
		}

		# record exit code from script
		If ($null -ne $ExitCodeFromScript) {
			$ExitCodeFromScript = $LASTEXITCODE
		}

		# if script state exists...
		If ($ScriptState.Script) {
			# update exit code for script state
			$ScriptState.ExitCode = $ExitCodeFromScript
		}
		# if script state does not exist...
		Else {
			# add entry to script states
			$ScriptStates += [pscustomobject]@{
				Script   = $Script
				ExitCode = $ExitCodeFromScript
			}
		}

		# update script state file
		Try {
			Export-Clixml -Path $ScriptStateXML -InputObject $ScriptStates
		}
		Catch {
			Write-Warning -Message "could not write script state to '$ScriptStateXML' file: $($_.Exception.Message)"
			$ExitCodeFromScript = $_.Exception.HResult
		}

		# if exit code from script is an error...
		If ($ExitCodeFromScript -ne 0) {
			# immediately exit with exit code from script
			Exit $ExitCodeFromScript
		}

		# if exit code from script is greater than overall exit code...
		If ($ExitCodeFromScript -gt $ExitCode) {
			# update overall exit code
			$ExitCode = $ExitCodeFromScript
		}
	}
}

# return overall exit code
Exit $ExitCode
