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
	function Assert-NetConnectionToWindowsUpdate {
		[CmdletBinding()]
		param (
			[string]$ComputerName = 'windowsupdate.microsoft.com'
		)

		# set progress preference
		$ProgressPreference = 'SilentlyContinue'

		# report state
		"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Verifying connectivity to Windows Update...'

		# test connection to Windows Update
		try {
			$TcpTestSucceeded = Test-NetConnection -ComputerName $ComputerName -CommonTCPPort HTTP -WarningAction SilentlyContinue | Select-Object -ExpandProperty 'TcpTestSucceeded'
		}
		catch {
			# warn before throwing exception
			Write-Warning -Message 'could not test connection to Windows Update'

			# throw exception
			throw $_
		}

		# define integers for while loop and reporting
		$Limit = [int32]8
		$Seconds = [int32]5
		$WaitTime = [int32]0
		$Multiplier = [int32]0

		# wait limit not reached and connection to Windows Update not successful...
		while ($Multiplier -lt $Limit -and -not $TcpTestSucceeded) {
			# increment multiplier
			$Multiplier++

			# record total time
			$WaitTime += ($Seconds * $Multiplier)

			# wait for collection update to complete
			Write-Host "...waiting an additional '$($Seconds * $Multiplier)' seconds"
			Start-Sleep -Seconds ($Seconds * $Multiplier)

			# retrieve device by name
			try {
				$TcpTestSucceeded = Test-NetConnection -ComputerName $ComputerName -CommonTCPPort HTTP -WarningAction SilentlyContinue | Select-Object -ExpandProperty 'TcpTestSucceeded'
			}
			catch {
				# warn before throwing exception
				Write-Warning -Message 'could not test connection to Windows Update'

				# throw exception
				throw $_
			}
		}

		# if connection to Windows Update successful...
		if ($TcpTestSucceeded) {
			# ...and wait time incurred...
			if ($WaitTime -gt 0) {
				# ...declare connectivity and wait time
				"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), "...verified connectivity to Windows Update after '$WaitTime' seconds"
			}
			# ...and wait time not incurred...
			else {
				# ...declare connectivity
				"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), "...verified connectivity to Windows Update"

			}
		}
		# if connection to Windows Update not successful...
		else {
			# ...declare wait time before throwing exception
			Write-Warning -Message "could not verify connectivity to Windows Update after '$WaitTime' seconds"

			# throw exception
			throw
		}
	}

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
		# warn before setting exit code and throwing exception
		Write-Warning -Message "could not create '$PathForTranscript' transcript file: $($_.Exception.Message)"

		# set exit code to a "The command failed" code before throwing exception
		$ExitCode = 101

		# throw exception
		throw $_
	}

	# define path for applied updates file
	$PathForAppliedUpdatesFile = Join-Path -Path $SystemRoot -ChildPath 'Update-Windows.txt'

	# if applied updates file exists...
	if ([System.IO.File]::Exists($PathForAppliedUpdatesFile)) {
		# retrieve contents of applied updates file
		try {
			$UpdatesApplied = Get-Content -Path $PathForAppliedUpdatesFile
		}
		catch {
			# warn before setting exit code and throwing exception
			Write-Warning -Message "could not read '$PathForAppliedUpdates' applied updates file: $($_.Exception.Message)"

			# set exit code to a "The command failed" code before throwing exception
			$ExitCode = 102

			# throw exception
			throw $_
		}
	}
	# if applied updates file not found...
	else {
		# create applied updates file
		try {
			$null = New-Item -ItemType File -Path $PathForAppliedUpdatesFile
		}
		catch {
			# warn before setting exit code and throwing exception
			Write-Warning -Message "could not create '$PathForAppliedUpdates' applied updates file: $($_.Exception.Message)"

			# set exit code to a "The command failed" code before returning
			$ExitCode = 103

			# throw exception
			throw $_
		}
	}
}

process {
	# assert network connectivity
	try {
		Assert-NetConnectionToWindowsUpdate
	}
	catch {
		# warn before setting exit code and return exception
		Write-Warning -Message 'could not assert network connectivity to Windows Update'

		# set exit code to a "The command failed" code before returning
		$ExitCode = 201

		# return exception
		return $_
	}

	# report state
	"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Finding updates...'

	# define searcher object
	try {
		$Searcher = New-Object -ComObject 'Microsoft.Update.Searcher'
	}
	catch {
		# warn before setting exit code and throwing exception
		Write-Warning -Message "could not create Microsoft.Update.Searcher object: $($_.Exception.Message)"

		# set exit code to a "The command failed" code before returning
		$ExitCode = 202

		# return exception
		return $_
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
		# warn before setting exit code and throwing exception
		Write-Warning -Message "could not call Search method with '$Criteria' criteria: $($_.Exception.Message)"

		# set exit code to a "The command failed" code before returning
		$ExitCode = 203

		# return exception
		return $_
	}

	# if no updates found...
	if ($SearcherResults.Updates.Count -eq 0) {
		# report state
		"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'No updates found'

		# set exit code to a "The command was successful. No reboot is required." code before returning
		$ExitCode = 0

		# return to end script
		return
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
		# warn before setting exit code and throwing exception
		Write-Warning -Message "could not create Microsoft.Update.UpdateColl object: $($_.Exception.Message)"

		# set exit code to a "The command failed" code before returning
		$ExitCode = 204

		# return exception
		return $_
	}

	# loop through updates
	foreach ($Update in $SearcherResults.Updates) {
		# if updated already applied...
		if ($Update.Identity.UpdateID -in $UpdatesApplied) {
			# report already applied
			"{0}`t{1} {2}" -f [System.Datetime]::UtcNow.ToString('o'), 'Skipping update already applied:', $Update.Identity.UpdateID
		}
		else {
			# add update to collection
			$null = $Updates.Add($Update)
		}
	}

	# if no updates required...
	if ($Updates.Count -eq 0) {
		# report state
		"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'All updates have been previously applied; exiting early'

		# exit with the "The command was successful. No reboot is required." code
		$ExitCode = 0

		# return to end script
		return
	}

	# report state
	"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Downloading updates...'

	# define session object
	try {
		$Session = New-Object -ComObject 'Microsoft.Update.Session'
	}
	catch {
		# warn before setting exit code and throwing exception
		Write-Warning -Message "could not create Microsoft.Update.Session object: $($_.Exception.Message)"

		# set exit code to a "The command failed" code before returning
		$ExitCode = 205

		# return exception
		return $_
	}

	# create update downloader object
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdatesession-createupdatedownloader
	try {
		$Downloader = $Session.CreateUpdateDownloader()
	}
	catch {
		# warn before setting exit code and throwing exception
		Write-Warning -Message "could not call CreateUpdateDownloader method: $($_.Exception.Message)"

		# set exit code to a "The command failed" code before returning
		$ExitCode = 206

		# return exception
		return $_
	}

	# add update collection to downloader object
	try {
		$Downloader.Updates = $Updates
	}
	catch {
		# warn before setting exit code and throwing exception
		Write-Warning -Message "could not add update collection to Downloader object: $($_.Exception.Message)"

		# set exit code to a "The command failed" code before returning
		$ExitCode = 207

		# return exception for transcript
		return $_
	}

	# download updates
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdatedownloader-download
	try {
		$DownloaderResults = $Downloader.Download()
	}
	catch {
		# warn before setting exit code and throwing exception
		Write-Warning -Message "could not call Download() method: $($_.Exception.Message)"

		# set exit code to a "The command failed" code before returning
		$ExitCode = 208

		# return exception for transcript
		return $_
	}

	# report state
	"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Downloaded updates'

	# if download result code is not "completed successfully"...
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-idownloadresult-get_resultcode
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/wuapi/ne-wuapi-operationresultcode
	if ($DownloaderResults.ResultCode -ne 2) {
		# define error message
		$Message = "calling Download method returned '{1}' result code and HRESULT: 0x{0:x} ({0})" -f $DownloaderResults.HResult, $DownloaderResults.ResultCode

		# warn before setting exit code and throwing exception
		Write-Warning -Message "could not download updates: $Message"

		# set exit code to a "The command failed" code before returning
		$ExitCode = 209

		# return message as exception for transcript
		return [System.Exception]::new($Message)
	}

	# report state
	"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Installing updates...'

	# create update installer object
	try {
		$Installer = New-Object -ComObject 'Microsoft.Update.Installer'
	}
	catch {
		# warn before setting exit code and throwing exception
		Write-Warning -Message "could not create Microsoft.Update.Installer object: $($_.Exception.Message)"

		# set exit code to a "The command failed" code before returning
		$ExitCode = 210

		# return exception for transcript
		return $_
	}

	# add update collection to installer object
	try {
		$Installer.Updates = $Updates
	}
	catch {
		# warn before setting exit code and throwing exception
		Write-Warning -Message "could not add update collection to Installer object: $($_.Exception.Message)"

		# set exit code to a "The command failed" code before returning
		$ExitCode = 211

		# return exception for transcript
		return $_
	}

	# install updates
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdateinstaller-install
	try {
		$InstallerResults = $Installer.Install()
	}
	catch {
		# warn before setting exit code and throwing exception
		Write-Warning -Message "could not call Install() method: $($_.Exception.Message)"

		# set exit code to a "The command failed" code before returning
		$ExitCode = 212

		# return exception for transcript
		return $_
	}

	# report state
	"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Installed updates'

	# if install result code is not "completed successfully"...
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iinstallationresult-get_resultcode
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/wuapi/ne-wuapi-operationresultcode
	if ($InstallerResults.ResultCode -ne 2) {
		# define error message
		$Message = "calling Install method returned '{1}' result code and HRESULT: 0x{0:x} ({0})" -f $InstallerResults.HResult, $InstallerResults.ResultCode

		# warn before setting exit code and throwing exception
		Write-Warning -Message "could not install updates: $Message"

		# set exit code to a "The command failed" code before returning
		$ExitCode = 213

		# return message as exception for transcript
		return [System.Exception]::new($Message)
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
				# warn before setting exit code and throwing exception
				Write-Warning -Message "could not update '$PathForAppliedUpdates' applied updates file: $($_.Exception.Message)"

				# set exit code to a "The command failed" code before returning
				$ExitCode = 214

				# return exception for transcript
				return $_
			}
		}
	}

	# if install results includes reboot required...
	# reference: https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nn-wuapi-iinstallationresult
	if ($InstallerResults.RebootRequired) {
		# report state
		"{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), 'Reboot required after installing updates'

		# if reboot requested and not audit mode...
		if ($PSBoundParameters['Reboot'] -and -not $AuditMode) {
			# restart the computer
			try {
				Restart-Computer -Force
			}
			catch {
				# warn before setting exit code and throwing exception
				Write-Warning -Message "could not restart computer after installing updates: $($_.Exception.Message)"

				# return exception
				return $_
			}
		}

		# set exit code to "The command complete and must be run again after a reboot" to force another pass before returning
		$ExitCode = 2

		# return
		return
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
