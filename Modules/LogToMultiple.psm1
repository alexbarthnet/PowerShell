Function Write-LogToMultiple {
    [CmdletBinding()]
    Param (
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        [string]$LogText,
        [Parameter()]
        [string]$LogSubject,
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
        [uint16]$EventId = 0,
        [Parameter()]
        [boolean]$LogScreen = $true
    )

    # set any global defaults
    If ($global:LogToScreenAndFile.Started) {
        If ([string]::IsNullOrEmpty($EventLog)) { $EventLog = $global:LogToScreenAndFile.LogEvent }
        If ([string]::IsNullOrEmpty($EventSource)) { $EventSource = $global:LogToScreenAndFile.LogSource }
        If ([string]::IsNullOrEmpty($LogEncoding)) { $LogEncoding = $global:LogToScreenAndFile.LogEncoding }
        If ([string]::IsNullOrEmpty($LogFile)) { $LogFile = $global:LogToScreenAndFile.LogFile }
        If ([string]::IsNullOrEmpty($LogHost)) { $LogHost = $global:LogToScreenAndFile.LogHost }
        If ([string]::IsNullOrEmpty($LogUser)) { $LogUser = $global:LogToScreenAndFile.LogUser }
    }

    # set any local defaults
    If ([string]::IsNullOrEmpty($LogHost)) { $LogHost = [System.Environment]::MachineName.ToLower() }
    If ([string]::IsNullOrEmpty($LogUser)) { $LogUser = [System.Environment]::UserName.ToLower() }
    If ([string]::IsNullOrEmpty($LogEncoding)) { $LogEncoding = 'ascii' }

    # combine strings
    $text_withdate = @($LogTime, $LogHost, $LogUser, $LogLevel, $LogSubject, $LogText) -join ','

    # write to file
    If ( [string]::IsNullOrEmpty($LogFile) -eq $false ) {
        Out-File -Force -Append -Encoding $LogEncoding -FilePath $LogFile -InputObject $text_withdate
    }

    # write to event log
    If ( [string]::IsNullOrEmpty($EventLog) -eq $false -and [string]::IsNullOrEmpty($EventSource) -eq $false ) {
        Write-EventLog -LogName $EventLog -Source $EventSource -Category 0 -EventId $EventId -EntryType $LogLevel -Message $LogText
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

Function Start-LogToMultiple {
    [CmdletBinding()]
    Param (
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ Test-Path -Path $_ })]
        [string]$ScriptPath,
        [Parameter(Position = 1)]
        [string]$LogsPath = 'C:\Content\logs',
        [Parameter(Position = 2)][ValidateSet('ascii', 'bigendianunicode', 'unicode', 'utf7', 'utf8', 'utf32')]
        [string]$FileEncoding = 'ascii',
        [Parameter(Position = 4)][ValidateSet('FileDate', 'FileDateUniversal', 'FileDateTime', 'FileDateTimeUniversal')]
        [string]$TimeFormat = 'FileDateTimeUniversal',
        [Parameter(Position = 3)]
        [string]$EventLogName = 'Application',
        [Parameter(Position = 4)]
        [switch]$EventLog
    )

    # build required strings for log path and file
    $log_base = (Get-Item -Path $ScriptPath).BaseName
    $log_date = (Get-Date -Format 'FileDateTimeUniversal')
    $log_host = [System.Environment]::MachineName.ToLower()
    $log_user = [System.Environment]::UserName.ToLower()
    $log_name = ($log_date, $log_base, $log_host -join '_') + '.txt'

    # build log path and file
    $log_path = Join-Path -Path $LogsPath -ChildPath $log_base
    $log_file = Join-Path -Path $log_path -ChildPath $log_name

    # verify log file
    If (Test-Path -Path $log_file) {
        Try {
            # verify existing log file
            $null = Get-Item -Path $log_file
            # report start to screen and existing log file
            Write-LogToMultiple -LogFile $log_file -LogText 'script-start-append'
        }
        Catch {
            # report error to screen
            Write-LogToMultiple -LogLevel 'error' -LogText 'script-start-append-ERROR'
            # return error to caller
            Return $_
        }
    }
    Else {
        Try {
            # create new log file
            $null = New-Item -Path $log_path -Name $log_name -ItemType 'File' -Force
            # write headers to log file
            $log_headers = 'Time', 'Host', 'User', 'Level', 'Subject', 'Message' -join ','
            $log_headers | Out-File -Force -Append -Encoding $FileEncoding -FilePath $log_file
            # report start to screen and new log file
            Write-LogToMultiple -LogFile $log_file -LogText 'script-start-newfile'
        }
        Catch {
            # report error to screen
            Write-LogToMultiple -LogLevel 'error' -LogText 'script-start-newfile-ERROR'
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
            Write-LogToMultiple -LogFile $log_file -LogText 'event-log-found'
        }
        Catch {
            # report error to screen and log file
            Write-LogToMultiple -LogLevel 'error' -LogFile $log_file -LogText 'event-log-not-found'
            # return error to caller
            Return $_
        }
        Try {
            # verify event source exists
            If ([System.Diagnostics.EventLog]::SourceExists($log_base)) { 
                Write-LogToMultiple -LogFile $log_file -LogText 'event-source-exists'
            }
            Else {
                # create event source
                New-EventLog -LogName $EventLogName -Source $log_base
                Write-LogToMultiple -LogFile $log_file -LogText 'event-source-created'
            }
        }
        Catch {
            # report error to screen and log file
            Write-LogToMultiple -LogLevel 'error' -LogFile $log_file -LogText 'event-source-ERROR'
            # return error to caller
            Return $_
        }    
    }
    Else {
        $EventLogName = [string]::Empty
    }

    # set global variables
    New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'LogToScreenAndFile' -Value (
        [pscustomobject]@{
            Started     = $true
            LogScreen   = $true
            LogHost     = $log_host
            LogUser     = $log_user
            LogFile     = $log_file
            LogEncoding = $FileEncoding
            LogEvent    = $EventLogName
            LogSource   = $log_base
        }
    )
}

Function Initialize-LogToMultiple {
    [CmdletBinding()]
    Param (
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ Test-Path -Path $_ })]
        [string]$ScriptPath,
        [Parameter(Position = 1, Mandatory = $true)]
        [string]$ScriptUser,
        [Parameter(Position = 2)]
        [string]$LogsPath = 'C:\Content\logs',
        [Parameter(Position = 3)]
        [switch]$EventLog,
        [Parameter(Position = 4)]
        [string]$LogEvent = 'Application'
    )

    # verify function run as admin
    If ([System.Security.Principal.WindowsIdentity]::GetCurrent().Groups.Value -contains 'S-1-5-32-544' -eq $false) {
        Write-Host "ERROR: this function must be run as an administrator, exiting!"
        Return
    }

    # verify script user
    Try {
        $log_path_sid = (New-Object 'System.Security.Principal.NTAccount' $ScriptUser).Translate([System.Security.Principal.SecurityIdentifier])
    }
    Catch {
        Write-Host "ERROR: could not retrieve SID for the '$ScriptUser' username, exiting!"
        Return
    }

    # build required strings
    $log_base = (Get-Item -Path $ScriptPath).BaseName
    $log_path = Join-Path -Path $LogsPath -ChildPath $log_base

    # verify log path
    Write-Host "Checking for log path: $log_path"
    If (Test-Path -Path $log_path) {
        Write-Host '...log path found'
    }
    Else {
        Try {
            # create log path
            New-Item -Path $LogsPath -Name $log_base -ItemType 'Directory' -Force
            Write-Host '...log path found created'
        }
        Catch {
            # report log path not created
            Write-Host 'ERROR: log path NOT created, exiting!'
            Return
        }
    }

    # verify log path permissions
    Write-Host "Checking permissions on log path: $log_path"
    $log_path_acl = Get-Acl -Path $log_path
    If ($null -eq ($log_path_acl.Access | Where-Object { $_.IdentityReference -match $ScriptUser -and $_.AccessControlType -match 'Allow' -and $_.FileSystemRights -match 'Modify' -and $_.InheritanceFlags -match 'ContainerInherit' -and $_.InheritanceFlags -match 'ObjectInherit' })) {
        Try {
            $log_path_ace = New-Object 'System.Security.AccessControl.FileSystemAccessRule' @($log_path_sid, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
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
$functions_to_export = @()
$functions_to_export += 'Write-LogToMultiple'
$functions_to_export += 'Start-LogToMultiple'
$functions_to_export += 'Initialize-LogToMultiple'

# export module members
Export-ModuleMember -Function $functions_to_export