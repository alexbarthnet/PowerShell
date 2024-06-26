Function Get-PreviousDate {
	Param (
		[Parameter(Mandatory = $true, Position = 0)][ValidateRange(1, 65535)]
		[uint16]$OlderThanUnits,
		[Parameter(Mandatory = $true, Position = 1)][ValidateSet('Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', 'Years')]
		[string]$OlderThanType
	)
	Switch ($OlderThanType) {
		'Seconds' { Return (Get-Date).AddSeconds(-1 * $OlderThanUnits) }
		'Minutes' { Return (Get-Date).AddMinutes(-1 * $OlderThanUnits) }
		'Hours' { Return (Get-Date).AddHours(-1 * $OlderThanUnits) }
		'Days' { Return (Get-Date).AddDays(-1 * $OlderThanUnits) }
		'Weeks' { Return (Get-Date).AddWeeks(-1 * $OlderThanUnits) }
		'Months' { Return (Get-Date).AddMonths(-1 * $OlderThanUnits) }
		'Years' { Return (Get-Date).AddYears(-1 * $OlderThanUnits) }
	}
}

Function Write-LogToMany {
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[string]$LogText,
		[Parameter()]
		[string]$LogSubject,
		[Parameter()]
		[string]$LogFunction = ((Get-PSCallStack)[0].Command),
		[Parameter()]
		[string]$LogLevel = 'information',
		[Parameter()]
		[string]$LogUser,
		[Parameter()]
		[string]$LogHost,
		[Parameter()]
		[string]$LogTime = (Get-Date -Format FileDateTimeUniversal),
		[Parameter()][ValidateSet('ascii', 'bigendianunicode', 'unicode', 'utf7', 'utf8', 'utf32')]
		[string]$LogEncoding,
		[Parameter()]
		[string]$LogFile,
		[Parameter()]
		[string]$EventLog,
		[Parameter()]
		[string]$EventSource,
		[Parameter()]
		[int32]$EventId,
		[Parameter()]
		[boolean]$LogScreen = $true
	)

	# set any global defaults
	If ($global:LogToMany.Started) {
		If ([string]::IsNullOrEmpty($EventLog)) { $EventLog = $global:LogToMany.LogEvent }
		If ([string]::IsNullOrEmpty($EventSource)) { $EventSource = $global:LogToMany.LogSource }
		If ([string]::IsNullOrEmpty($LogFunction)) { $LogFunction = $global:LogToMany.LogSource }
		If ([string]::IsNullOrEmpty($LogEncoding)) { $LogEncoding = $global:LogToMany.LogEncoding }
		If ([string]::IsNullOrEmpty($LogFile)) { $LogFile = $global:LogToMany.LogFile }
		If ([string]::IsNullOrEmpty($LogHost)) { $LogHost = $global:LogToMany.LogHost }
		If ([string]::IsNullOrEmpty($LogUser)) { $LogUser = $global:LogToMany.LogUser }
	}

	# set any local defaults
	If ([string]::IsNullOrEmpty($LogHost)) { $LogHost = [System.Environment]::MachineName.ToLower() }
	If ([string]::IsNullOrEmpty($LogUser)) { $LogUser = [System.Environment]::UserName.ToLower() }
	If ([string]::IsNullOrEmpty($LogEncoding)) { $LogEncoding = 'ascii' }

	# create log text
	$text_withdate = @($LogTime, """$LogHost""", """$LogUser""", """$LogLevel""", """$LogFunction""", """$LogSubject""", """$LogText""") -join ','

	# write to file
	If ( [string]::IsNullOrEmpty($LogFile) -eq $false ) {
		Out-File -Force -Append -Encoding $LogEncoding -FilePath $LogFile -InputObject $text_withdate
	}

	# write to event log
	If ( [string]::IsNullOrEmpty($EventLog) -eq $false -and [string]::IsNullOrEmpty($EventSource) -eq $false ) {
		$WriteEvenLog = @{
			LogName   = $EventLog
			Source    = $EventSource
			Category  = 0
			EntryType = $LogLevel
			Message   = $LogText
		}
		switch ($LogLevel) {
			'warning' { If ($null -eq $EventId) { $EventId = [int32]2 }; Write-EventLog @WriteEvenLog -EventId $EventId }
			'error' { If ($null -eq $EventId) { $EventId = [int32]1 }; Write-EventLog @WriteEvenLog -EventId $EventId }
			Default { If ($null -eq $EventId) { $EventId = [int32]0 }; Write-EventLog @WriteEvenLog -EventId $EventId }
		}
	}

	# write to screen based upon level
	If ($LogScreen) {
		switch ($LogLevel) {
			'warning' { Write-Host -Object $text_withdate -ForegroundColor 'Yellow' -BackgroundColor 'Black' }
			'error' { Write-Host -Object $text_withdate -ForegroundColor 'Red' -BackgroundColor 'Black' }
			Default { Write-Host -Object $text_withdate }
		}
	}
}

Function Start-LogToMany {
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' })]
		[string]$ScriptPath,
		[Parameter(Position = 1)][ValidateScript({ Test-Path -Path $_ -PathType 'Container' })]
		[string]$LogFilePath = [System.Environment]::GetFolderPath('CommonApplicationData'),
		[Parameter(Position = 3)][ValidateSet('csv', 'json')]
		[string]$LogFileFormat = 'csv',
		[Parameter(Position = 2)][ValidateSet('ascii', 'bigendianunicode', 'unicode', 'utf7', 'utf8', 'utf32')]
		[string]$LogFileEncoding = 'ascii',
		[Parameter(Position = 3)][ValidateSet('FileDate', 'FileDateUniversal', 'FileDateTime', 'FileDateTimeUniversal')]
		[string]$TimeFormat = 'FileDateTimeUniversal',
		[Parameter(Position = 3)]
		[string]$EventLogName = 'Application',
		[Parameter(Position = 5)]
		[switch]$EventLog
	)

	# build required strings
	$log_base = (Get-Item -Path $ScriptPath).BaseName
	$log_date = (Get-Date -Format 'FileDateTimeUniversal')
	$log_host = [System.Environment]::MachineName.ToLower()
	$log_user = [System.Environment]::UserName.ToLower()
	$log_name = ($log_date, $log_base, $log_host -join '_') + '.txt'

	# build paths
	$log_parent = Join-Path -Path $LogFilePath -ChildPath 'LogToMany'
	$log_path = Join-Path -Path $log_parent -ChildPath $log_base
	$log_file = Join-Path -Path $log_path -ChildPath $log_name

	# verify log file
	If (Test-Path -Path $log_file) {
		Try {
			# verify existing log file
			$null = Get-Item -Path $log_file
			# report start to screen and existing log file
			Write-LogToMany -LogFile $log_file -LogText 'script-start-append'
		}
		Catch {
			# report error to screen
			Write-LogToMany -LogLevel 'error' -LogText 'script-start-append-ERROR'
			# return error to caller
			Return $_
		}
	}
	Else {
		Try {
			# create new log file
			$null = New-Item -Path $log_path -Name $log_name -ItemType 'File' -Force
			# write headers to log file
			$log_headers = 'time', 'hostname', 'user', 'level', 'function', 'subject', 'message' -join ','
			$log_headers | Out-File -Force -Append -Encoding $FileEncoding -FilePath $log_file
			# report start to screen and new log file
			Write-LogToMany -LogFile $log_file -LogText 'script-start-newfile'
		}
		Catch {
			# report error to screen
			Write-LogToMany -LogLevel 'error' -LogText 'script-start-newfile-ERROR'
			# return error to caller
			Return $_
		}
	}

	# verify event log source
	If ($EventLog) {
		Try {
			# verify event log exists
			$null = Get-WinEvent -ListLog $EventLogName
			# report start to screen and log file
			Write-LogToMany -LogFile $log_file -LogText 'event-log-found'
		}
		Catch {
			# report error to screen and log file
			Write-LogToMany -LogLevel 'error' -LogFile $log_file -LogText 'event-log-not-found'
			# return error to caller
			Return $_
		}
		Try {
			# verify event source exists
			If ([System.Diagnostics.EventLog]::SourceExists($log_base)) {
				Write-LogToMany -LogFile $log_file -LogText 'event-source-exists'
			}
			Else {
				# create event source
				New-EventLog -LogName $EventLogName -Source $log_base
				Write-LogToMany -LogFile $log_file -LogText 'event-source-created'
			}
		}
		Catch {
			# report error to screen and log file
			Write-LogToMany -LogLevel 'error' -LogFile $log_file -LogText 'event-source-ERROR'
			# return error to caller
			Return $_
		}
	}
	Else {
		$EventLogName = [string]::Empty
	}

	# set global variables
	New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'LogToMany' -Value (
		[pscustomobject]@{
			Started     = $true
			LogScreen   = $true
			LogHost     = $log_host
			LogUser     = $log_user
			LogFile     = $log_file
			LogEncoding = $FileEncoding
			LogEvent    = $EventLogName
			LogFormat   = $LogFileFormat
			LogSource   = $log_base
		}
	)
}

Function Remove-LogToMany {
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' })]
		[string]$ScriptPath,
		[Parameter(Position = 1)][ValidateScript({ Test-Path -Path $_ -PathType 'Container' })]
		[string]$LogFilePath = [System.Environment]::GetFolderPath('CommonApplicationData'),
		[Parameter(Position = 2)][ValidateSet('Minutes', 'Hours', 'Days', 'Weeks', 'Months', 'Years')]
		[string]$OlderThanType = 'Days',
		[Parameter(Position = 3)][ValidateRange(1, 32767)]
		[int16]$OlderThanUnits = 30
	)

	# build required strings
	$log_base = (Get-Item -Path $ScriptPath).BaseName

	# build paths
	$log_parent = Join-Path -Path $LogFilePath -ChildPath 'LogToMany'
	$log_path = Join-Path -Path $log_parent -ChildPath $log_base

	# build counters for removed files
	$log_removed_count = 0
	$log_removed_error = 0

	# start log file
	If ($null -eq $global:LogToMany) {
		Try {
			Start-LogToMany -ScriptPath $ScriptPath
		}
		Catch {
			Write-Host 'ERROR: could not start logging'
			Exit $LASTERRORCODE
		}
	}
	Else {
		Write-LogToMany -LogText "Appending open log file: $($global:LogToMany.Logfile)"
	}

	# verify log directory
	If (Test-Path -Path $log_path) {
		Write-LogToMany -LogText "Found log folder: $log_path"
	}
	Else {
		Write-LogToMany -LogText "ERROR: could not locate log folder: $log_path"
		Return
	}

	# get date from inputs
	$log_date_time = Get-PreviousDate -OlderThanUnits $OlderThanUnits -OlderThanType $OlderThanType
	Write-LogToMany -LogText "Checking for files older than $OlderThanUnits $OlderThanType ($($log_date_time.ToString()))"

	# get files from date
	$log_files_old = Get-ChildItem -Path $log_path | Where-Object { $_.LastWriteTime -lt $log_date_time }
	ForEach ($log_file in $log_files_old) {
		Try {
			Remove-Item -Path $log_file.FullName -Force
			$log_removed_count++
			Write-LogToMany -LogText "Removing log file: $($log_file.FullName)"
		}
		Catch {
			$log_removed_error++
			Write-LogToMany -LogText "ERROR: removing log file: $($log_file.FullName)" -LogLevel Error
		}
	}
	Write-LogToMany -LogText "Removed '$log_removed_count' file(s)"
	If ($log_removed_error -gt 0) {
		Write-LogToMany -LogText "Could not remove '$log_removed_error' file(s)"
	}
}

Function Initialize-LogToMany {
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' })]
		[string]$ScriptPath,
		[Parameter(Position = 1)][ValidateScript({ Test-Path -Path $_ -PathType 'Container' })]
		[string]$LogFilePath = [System.Environment]::GetFolderPath('CommonApplicationData'),
		[Parameter(Position = 2)]
		[string]$ScriptUser,
		[Parameter(Position = 3)]
		[switch]$EventLog,
		[Parameter(Position = 4)]
		[string]$LogEvent = 'Application'
	)

	# verify function run as admin
	If (-not ([Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
		Write-Host 'ERROR: this function must be run as an administrator, exiting!'
		Return
	}

	# build required strings
	$log_base = (Get-Item -Path $ScriptPath).BaseName

	# build paths
	$log_parent = Join-Path -Path $LogFilePath -ChildPath 'LogToMany'
	$log_path = Join-Path -Path $log_parent -ChildPath $log_base

	# verify log path
	Write-Host "Checking for log path: $log_path"
	If (Test-Path -Path $log_path) {
		Write-Host '...log path found'
	}
	Else {
		Try {
			# create log path
			$null = New-Item -Path $LogFilePath -Name $log_base -ItemType 'Directory' -Force
			Write-Host '...log path created'
		}
		Catch {
			# report log path not created
			Write-Host 'ERROR: log path NOT created, exiting!'
			Return
		}
	}

	# check for scriptuser
	If ($ScriptUser) {
		# get script user SID
		Try {
			$log_user_sid = (New-Object 'System.Security.Principal.NTAccount' $ScriptUser).Translate([System.Security.Principal.SecurityIdentifier])
		}
		Catch {
			Write-Host "ERROR: could not retrieve SID for the '$ScriptUser' username, exiting!"
			Return
		}

		# get script user full NT name
		Try {
			$log_user_name = (New-Object 'System.Security.Principal.SecurityIdentifier' $log_user_sid).Translate([System.Security.Principal.NTAccount])
		}
		Catch {
			Write-Host "ERROR: could not retrieve full NTAcount for the '$ScriptUser' SID, exiting!"
			Return
		}

		# check script user domain
		If ($log_user_name.Value -match '^NT AUTHORITY') {
			Write-Host "ERROR: provided username maps to an 'NT AUTHORITY' principal, exiting!"
			Return
		}

		# verify log path permissions
		Write-Host "Retrieved permissions on log path: $log_path"
		$log_path_acl = Get-Acl -Path $log_path
		$log_path_ace = $log_path_acl.Access | Where-Object {
			$_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -eq $log_user_sid -and
			$_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
			$_.InheritanceFlags -eq @([System.Security.AccessControl.InheritanceFlags]::ContainerInherit, [System.Security.AccessControl.InheritanceFlags]::ObjectInherit) -and
		($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Modify) -eq [System.Security.AccessControl.FileSystemRights]::Modify
		}
		# verify log path permissions
		Write-Host "Verifying permissions on log path: $log_path"
		If ($null -eq $log_path_ace) {
			Try {
				$log_path_ace = New-Object 'System.Security.AccessControl.FileSystemAccessRule' @($log_user_sid, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
				$log_path_acl.PurgeAccessRules($log_path_sid)
				$log_path_acl.AddAccessRule($log_path_ace)
				$log_path_acl | Set-Acl -Path $log_path
				Write-Host '...log path permissions corrected'
			}
			Catch {
				Write-Host 'ERROR: log path permissions NOT corrected, exiting '
				Return
			}
		}
		Else {
			Write-Host '...log path permissions verified'
		}
	}

	# verify event log source
	If ($EventLog) {
		Write-Host "Checking for event log source registered: $log_base"
		Try {
			If ([System.Diagnostics.EventLog]::SourceExists($log_base)) {
				Write-Host '...event log source found'
			}
			Else {
				Try {
					New-EventLog -LogName $LogEvent -Source $log_base
					Write-Host '...event log source created'
				}
				Catch {
					Write-Host 'ERROR: event log source NOT created, exiting!'
					Return
				}
			}
		}
		Catch {
			Write-Host 'ERROR: event log source could not be checked, exiting!'
			Return
		}
	}
}

# define functions to export
$FunctionsToExport = @(
	'Write-LogToMany'
	'Start-LogToMany'
	'Remove-LogToMany'
	'Initialize-LogToMany'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport