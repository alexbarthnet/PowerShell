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
param(
	[Parameter(Position = 0)]
	[switch]$Reboot,
	[Parameter(Position = 1)]
	[switch]$IncludePreview,
	[Parameter(Position = 2)]
	[switch]$IncludeDrivers,
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
	$PathForTranscript = Join-Path -Path $SystemRoot -ChildPath 'Update-Windows.log'

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

	# define path for applied updates file
	$PathForAppliedUpdatesFile = Join-Path -Path $SystemRoot -ChildPath 'Update-Windows.txt'

	# if applied updates file not found...
	if (![System.IO.File]::Exists($PathForAppliedUpdatesFile)) {
		# create applied
		try {
			$null = New-Item -ItemType File -Path $PathForAppliedUpdatesFile
		}
		catch {
			# if audit mode...
			if ($AuditMode) {
				# exit with a "The command failed" code
				exit 102
			}
			# if not audit mode...
			else {
				# throw exception
				$PSCmdlet.ThrowTerminatingError($_)
			}
		}
	}

	# retrieve contents of applied updates file
	try {
		$UpdatesApplied = Get-Content -Path $PathForAppliedUpdatesFile
	}
	catch {
		# if audit mode...
		if ($AuditMode) {
			# exit with a "The command failed" code
			exit 103
		}
		# if not audit mode...
		else {
			# throw exception
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}
}

process {
	# report state
	"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Finding updates...'

	# define searcher object
	try {
		$Searcher = New-Object -ComObject 'Microsoft.Update.Searcher'
	}
	catch {
		# if audit mode...
		if ($AuditMode) {
			# exit with a "The command failed" code
			exit 201
		}
		# if not audit mode...
		else {
			# return exception
			return $_
		}
	}

	# define base criteria
	$Criteria = 'IsInstalled = 0 AND IsHidden = 0'

	# if preview updates not requested...
	if (!$IncludePreview) {
		# update criteria to exclude preview updates
		$Criteria = "$Criteria AND AutoSelectOnWebSites = 1"
	}

	# if driver updates not requested...
	if (!$IncludeDrivers) {
		# update criteria to exclude drivers
		$Criteria = "$Criteria AND Type='software'"
	}

	# search for updates
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdatesearcher-search
	try {
		$SearcherResults = $Searcher.Search($Criteria)
	}
	catch {
		# if audit mode...
		if ($AuditMode) {
			# exit with a "The command failed" code
			exit 202
		}
		# if not audit mode...
		else {
			# return exception
			return $_
		}
	}

	# if no updates found...
	if ($SearcherResults.Updates.Count -eq 0) {
		# report state
		"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'No updates found'
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
	# if updates found...
	else {
		# report state
		"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Found updates:'
		# loop through updates and report each update
		foreach ($Update in $SearcherResults.Updates) {
			"`t{0}`t{1}" -f $Update.Identity.UpdateID, $Update.Title
		}
	}

	# define update collection object
	try {
		$Updates = New-Object -ComObject 'Microsoft.Update.UpdateColl'
	}
	catch {
		# if audit mode...
		if ($AuditMode) {
			# exit with a "The command failed" code
			exit 203
		}
		# if not audit mode...
		else {
			# return exception
			return $_
		}
	}

	# define updates required boolean
	$UpdatesRequired = $false

	# loop through updates
	foreach ($Update in $SearcherResults.Updates) {
		# if updated already applied...
		if ($Update.Identity.UpdateID -notin $UpdatesApplied) {
			# set updates required boolean
			$UpdatesRequired = $true
		}
		# add update to collection
		$null = $Updates.Add($Update)
	}

	# if no updates required...
	if ($UpdatesRequired) {
		# report state
		"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'All updates have been previously applied; exiting early'
		# stop transcript before exit
		$null = Stop-Transcript
		# if audit mode...
		if ($AuditMode) {
			# exit with the "The command was successful. No reboot is required." code
			exit 0
		}
		# if not audit mode...
		else {
			# return exception
			return
		}
	}

	# report state
	"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Downloading updates...'

	# define session object
	try {
		$Session = New-Object -ComObject 'Microsoft.Update.Session'
	}
	catch {
		# if audit mode...
		if ($AuditMode) {
			# exit with a "The command failed" code
			exit 204
		}
		# if not audit mode...
		else {
			# return exception
			return $_
		}
	}

	# create update downloader object
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdatesession-createupdatedownloader
	try {
		$Downloader = $Session.CreateUpdateDownloader()
	}
	catch {
		# if audit mode...
		if ($AuditMode) {
			# exit with a "The command failed" code
			exit 205
		}
		# if not audit mode...
		else {
			# return exception
			return $_
		}
	}

	# add update collection to downloader object
	try {
		$Downloader.Updates = $Updates
	}
	catch {
		# if audit mode...
		if ($AuditMode) {
			# exit with a "The command failed" code
			exit 206
		}
		# if not audit mode...
		else {
			# return exception
			return $_
		}
	}

	# download updates
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdatedownloader-download
	try {
		$DownloaderResults = $Downloader.Download()
	}
	catch {
		# if audit mode...
		if ($AuditMode) {
			# exit with a "The command failed" code
			exit 207
		}
		# if not audit mode...
		else {
			# return exception
			return $_
		}
	}

	# report state
	"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Downloaded updates'

	# if download result code is not "completed successfully"...
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-idownloadresult-get_resultcode
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/wuapi/ne-wuapi-operationresultcode
	if ($DownloaderResults.ResultCode -ne 2) {
		# report state
		"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Error downloading updates', $DownloaderResults.HResult
		# stop transcript before exit
		$null = Stop-Transcript
		# if audit mode...
		if ($AuditMode) {
			# exit with a "The command failed" code
			exit 208
		}
		# if not audit mode...
		else {
			# return exception
			return $_
		}
	}

	# report state
	"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Installing updates...'

	# create update installer object
	try {
		$Installer = New-Object -ComObject 'Microsoft.Update.Installer'
	}
	catch {
		# if audit mode...
		if ($AuditMode) {
			# exit with a "The command failed" code
			exit 209
		}
		# if not audit mode...
		else {
			# return exception
			return $_
		}
	}

	# add update collection to installer object
	try {
		$Installer.Updates = $Updates
	}
	catch {
		# if audit mode...
		if ($AuditMode) {
			# exit with a "The command failed" code
			exit 210
		}
		# if not audit mode...
		else {
			# return exception
			return $_
		}
	}

	# install updates
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdateinstaller-install
	try {
		$InstallerResults = $Installer.Install()
	}
	catch {
		# if audit mode...
		if ($AuditMode) {
			# exit with a "The command failed" code
			exit 211
		}
		# if not audit mode...
		else {
			# return exception
			return $_
		}
	}

	# report state
	"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Installed updates'

	# if install result code is not "completed successfully"...
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iinstallationresult-get_resultcode
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/wuapi/ne-wuapi-operationresultcode
	if ($InstallerResults.ResultCode -ne 2) {
		# report state
		"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Error installing updates', $InstallerResults.HResult
		# stop transcript before exit
		$null = Stop-Transcript
		# if audit mode...
		if ($AuditMode) {
			# exit with a "The command failed" code
			exit 212
		}
		# if not audit mode...
		else {
			# return exception
			return $_
		}
	}

	# loop through updates and...
	foreach ($Update in $Updates) {
		# if update not listed in applied updates...
		if ($Update.Identity.UpdateID -notin $UpdatesApplied) {
			# add update to applied updates file
			try {
				Add-Content -Path $PathForAppliedUpdatesFile -Value $Update.Identity.UpdateID
			}
			catch {
				# report state
				"{0}`t{1}: {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Error updating applied updates file', $_.Exception.Message
				# stop transcript before exit
				$null = Stop-Transcript
				# if audit mode...
				if ($AuditMode) {
					# exit with a "The command failed" code
					exit 213
				}
				# if not audit mode...
				else {
					# return exception
					return $_
				}
			}
		}
	}

	# if install results includes reboot required...
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nn-wuapi-iupdateinstallationresult
	if ($InstallerResults.RebootRequired) {
		# report state
		"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Reboot required after installing updates'
		# if reboot requested and not in audit mode...
		if ($PSBoundParameters['Reboot'] -and -not $AuditMode) {
			# restart the computer
			try {
				Restart-Computer -Force
			}
			catch {
				# return exception
				return $_
			}
		}
	}

	# stop transcript before exit
	$null = Stop-Transcript

	# if audit mode...
	if ($AuditMode) {
		# exit with "The command is still in process" code to force another pass
		exit 2
	}
	# if not audit mode...
	else {
		# return
		return
	}
}
