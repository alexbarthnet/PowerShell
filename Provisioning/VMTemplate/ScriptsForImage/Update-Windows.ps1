<#
.SYNOPSIS
Run Windows Update from PowerShell.

.DESCRIPTION
Run Windows Update from PowerShell with support for running via an unattended installation file during the auditUser pass of Windows setup.

.PARAMETER Reboot
Switch parameter to restart the computer after applying updates. This parameter is ignored during the auditUser pass of Windows setup.

.PARAMETER IncludePreview
Switch parameter to include preview updates when searching for updates. Preview updates are not included in the default search criteria.

.PARAMETER IncludeDrivers
Switch parameter to include drivers when searching for updates. Driver updates are not included in the default search criteria.

.INPUTS
None.

.OUTPUTS
None. The function does not generate any output.

.NOTES
This script creates and leverages an "applied updates" to avoid a potential loop during Windows setup to address the historical requirement to run Windows Update multiple times to completely update Windows.
This script returns the "The command is still in process" exit code when updates have been installed which enables Windows setup to restart the system and apply the updates and then re-run the script to apply any additional updates.
Windows Update MAY determine that a particular update is required during the search operation but not apply the update during the install operation which can result in an endless loop.
The "applied updates" file contains the ID of any update that was passed to the install function of the Windows Update COM object.
This script will return the "The command was successful. No reboot is required." return code when all updates found by the search operation have been passed to the install function in a previous run.

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

[CmdletBinding()]
Param(
	[Parameter(Position = 0)]
	[switch]$Reboot,
	[Parameter(Position = 1)]
	[switch]$IncludePreview,
	[Parameter(Position = 2)]
	[switch]$IncludeDrivers,
	[Parameter(DontShow)]
	[string]$SystemRoot = [System.Environment]::GetEnvironmentVariable('SystemRoot')
)

Begin {
	# define error preference
	$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

	# define path for audit process
	$PathForAuditProcess = Join-Path -Path $SystemRoot -ChildPath 'System32\oobe\audit.exe'

	# retrieve processes
	$Processes = Get-Process

	# if audit process found...
	If ($Processes.Where({ $_.Path -eq $PathForAuditProcess })) {
		# set audit mode to true
		$AuditMode = $true
	}

	# define path for transcript
	$PathForTranscript = Join-Path -Path $SystemRoot -ChildPath 'Update-Windows.log'

	# start transcript
	Try {
		$null = Start-Transcript -Path $PathForTranscript -Append
	}
	Catch {
		# if audit mode...
		If ($AuditMode) {
			# exit with a "The command failed" code
			Exit 101
		}
		# if not audit mode...
		Else {
			# return exception
			Return $_
		}
	}

	# define path for applied updates file
	$PathForAppliedUpdatesFile = Join-Path -Path $SystemRoot -ChildPath 'Update-Windows.txt'

	# if applied updates file not found...
	If (![System.IO.File]::Exists($PathForAppliedUpdatesFile)) {
		# create applied
		Try {
			$null = New-Item -ItemType File -Path $PathForAppliedUpdatesFile
		}
		Catch {
			# if audit mode...
			If ($AuditMode) {
				# exit with a "The command failed" code
				Exit 102
			}
			# if not audit mode...
			Else {
				# throw exception
				$PSCmdlet.ThrowTerminatingError($_)
			}
		}
	}

	# retrieve contents of applied updates file
	Try {
		$UpdatesApplied = Get-Content -Path $PathForAppliedUpdatesFile
	}
	Catch {
		# if audit mode...
		If ($AuditMode) {
			# exit with a "The command failed" code
			Exit 103
		}
		# if not audit mode...
		Else {
			# throw exception
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}
}

Process {
	# report state
	"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Finding updates...'

	# define searcher object
	Try {
		$Searcher = New-Object -ComObject Microsoft.Update.Searcher
	}
	Catch {
		# if audit mode...
		If ($AuditMode) {
			# exit with a "The command failed" code
			Exit 201
		}
		# if not audit mode...
		Else {
			# return exception
			Return $_
		}
	}

	# define base criteria
	$Criteria = 'IsInstalled = 0 AND IsHidden = 0'

	# if preview updates not requested...
	If (!$IncludePreview) {
		# update criteria to exclude preview updates
		$Criteria = "$Criteria AND AutoSelectOnWebSites = 1"
	}

	# if driver updates not requested...
	If (!$IncludeDrivers) {
		# update criteria to exclude drivers
		$Criteria = "$Criteria AND Type='software'"
	}

	# search for updates
	Try {
		$SearcherResults = $Searcher.Search($Criteria)
	}
	Catch {
		# if audit mode...
		If ($AuditMode) {
			# exit with a "The command failed" code
			Exit 202
		}
		# if not audit mode...
		Else {
			# return exception
			Return $_
		}
	}

	# if no updates found...
	If ($SearcherResults.Updates.Count -eq 0) {
		# report state
		"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'No updates found'
		# stop transcript before exit
		$null = Stop-Transcript
		# if audit mode...
		If ($AuditMode) {
			# exit with the "The command was successful. No reboot is required." code
			Exit 0
		}
		# if not audit mode...
		Else {
			# return
			Return
		}
	}
	# if updates found...
	Else {
		# report state
		"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Found updates:'
		# loop through updates and report each update
		ForEach ($Update in $SearcherResults.Updates) {
			"`t{0}`t{1}" -f $Update.Identity.UpdateID, $Update.Title
		}
	}

	# define update collection object
	Try {
		$Updates = New-Object -ComObject Microsoft.Update.UpdateColl
	}
	Catch {
		# if audit mode...
		If ($AuditMode) {
			# exit with a "The command failed" code
			Exit 203
		}
		# if not audit mode...
		Else {
			# return exception
			Return $_
		}
	}

	# define updates required boolean
	$UpdatesRequired = $false

	# loop through updates
	ForEach ($Update in $SearcherResults.Updates) {
		# if updated already applied...
		If ($Update.Identity.UpdateID -notin $UpdatesApplied) {
			# set updates required boolean
			$UpdatesRequired = $true
		}
		# add update to collection
		$null = $Updates.Add($Update)
	}

	# if audit mode and no updates required...
	If ($AuditMode -and -not $UpdatesRequired) {
		# report state
		"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'All updates have been previously applied; exiting early'
		# stop transcript before exit
		$null = Stop-Transcript
		# exit with the "The command was successful. No reboot is required." code
		Exit 0
	}

	# report state
	"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Downloading updates...'

	# define session object
	Try {
		$Session = New-Object -ComObject Microsoft.Update.Session
	}
	Catch {
		# if audit mode...
		If ($AuditMode) {
			# exit with a "The command failed" code
			Exit 204
		}
		# if not audit mode...
		Else {
			# return exception
			Return $_
		}
	}

	# create update downloader object
	Try {
		$Downloader = $Session.CreateUpdateDownloader()
	}
	Catch {
		# if audit mode...
		If ($AuditMode) {
			# exit with a "The command failed" code
			Exit 205
		}
		# if not audit mode...
		Else {
			# return exception
			Return $_
		}
	}

	# add update collection to downloader object
	Try {
		$Downloader.Updates = $Updates
	}
	Catch {
		# if audit mode...
		If ($AuditMode) {
			# exit with a "The command failed" code
			Exit 206
		}
		# if not audit mode...
		Else {
			# return exception
			Return $_
		}
	}

	# download updates
	Try {
		$DownloaderResults = $Downloader.Download()
	}
	Catch {
		# if audit mode...
		If ($AuditMode) {
			# exit with a "The command failed" code
			Exit 207
		}
		# if not audit mode...
		Else {
			# return exception
			Return $_
		}
	}

	# report state
	"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Downloaded updates'

	# if download result code is not "completed successfully"...
	If ($DownloaderResults.ResultCode -ne 2) {
		# report state
		"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Error downloading updates', $DownloaderResults.HResult
		# stop transcript before exit
		$null = Stop-Transcript
		# if audit mode...
		If ($AuditMode) {
			# exit with a "The command failed" code
			Exit 208
		}
		# if not audit mode...
		Else {
			# return exception
			Return $_
		}
	}

	# report state
	"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Installing updates...'

	# create update installer object
	Try {
		$Installer = New-Object -ComObject Microsoft.Update.Installer
	}
	Catch {
		# if audit mode...
		If ($AuditMode) {
			# exit with a "The command failed" code
			Exit 209
		}
		# if not audit mode...
		Else {
			# return exception
			Return $_
		}
	}

	# add update collection to installer object
	Try {
		$Installer.Updates = $Updates
	}
	Catch {
		# if audit mode...
		If ($AuditMode) {
			# exit with a "The command failed" code
			Exit 210
		}
		# if not audit mode...
		Else {
			# return exception
			Return $_
		}
	}

	# install updates
	Try {
		$InstallerResults = $Installer.Install()
	}
	Catch {
		# if audit mode...
		If ($AuditMode) {
			# exit with a "The command failed" code
			Exit 211
		}
		# if not audit mode...
		Else {
			# return exception
			Return $_
		}
	}

	# report state
	"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Installed updates'

	# if install result code is not "completed successfully"...
	If ($InstallerResults.ResultCode -ne 2) {
		# report state
		"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Error installing updates', $InstallerResults.HResult
		# stop transcript before exit
		$null = Stop-Transcript
		# if audit mode...
		If ($AuditMode) {
			# exit with a "The command failed" code
			Exit 212
		}
		# if not audit mode...
		Else {
			# return exception
			Return $_
		}
	}

	# loop through updates and...
	ForEach ($Update in $Updates) {
		# if update not listed in applied updates...
		If ($Update.Identity.UpdateID -notin $UpdatesApplied) {
			# add update to applied updates file
			Try {
				Add-Content -Path $PathForAppliedUpdatesFile -Value $Update.Identity.UpdateID
			}
			Catch {
				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Error updating applied updates file', $_.Exception.Message
				# stop transcript before exit
				$null = Stop-Transcript
				# if audit mode...
				If ($AuditMode) {
					# exit with a "The command failed" code
					Exit 213
				}
				# if not audit mode...
				Else {
					# return exception
					Return $_
				}
			}
		}
	}

	# if install results includes reboot required...
	If ($InstallerResults.RebootRequired) {
		# report state
		"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Reboot required after installing updates'
		# if reboot requested and not in audit mode...
		If ($PSBoundParameters['Reboot'] -and -not $AuditMode) {
			# restart the computer
			Try {
				Restart-Computer -Force
			}
			Catch {
				# return exception
				Return $_
			}
		}
	}

	# stop transcript before exit
	$null = Stop-Transcript

	# if audit mode...
	If ($AuditMode) {
		# exit with "The command is still in process" code to force another pass
		Exit 2
	}
	# if not audit mode...
	Else {
		# return
		Return
	}
}
