<#
.SYNOPSIS
Template for writing PowerShell transcripts for a script.

.DESCRIPTION
Template for writing PowerShell transcripts for a script. The End block will remove any transcript files that match the generated transcript file name less the date and are older than the computed transcript cleanup date.

.PARAMETER Parameter1
Example parameter for script

.PARAMETER SkipTranscript
Switch parameter to skip writing transcript and transcript cleanup.

.PARAMETER TranscriptName
The string to substitute for the random component of the default PowerShell transcript file name.

.PARAMETER TranscriptPath
The path to a folder for saving PowerShell transcript files.

.PARAMETER TranscriptDateUnits
The units for computing the transcript cleanup date. Must be one of: Hours, Days, Months, Years

.PARAMETER TranscriptDateValue
The value for computing the transcript cleanup date. Must be an unsigned integer and at least 1

.PARAMETER TranscriptFileCount
The number of transcript files that must remain after cleanup. Transcript cleanup will not run if the count of transcript files that would remain is not at least the value of this parameter.

.PARAMETER HostName
The host name for the current computer.

.PARAMETER DomainName
The domain name for the current computer.

.PARAMETER DnsHostName
The fully qualified DNS host name for the current computer.

.INPUTS
None.

.OUTPUTS
None.
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# parameter for script
	[Parameter()]
	[string]$Parameter1,
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipTranscript,
	# name in transcript files
	[Parameter(DontShow)]
	[string]$TranscriptName,
	# path to transcript files
	[Parameter(DontShow)]
	[string]$TranscriptPath,
	# units for transcript cleanup date
	[Parameter(DontShow)][ValidateSet('Hours', 'Days', 'Weeks', 'Months', 'Years')]
	[string]$TranscriptDateUnits,
	# value for transcript cleanup date
	[Parameter(DontShow)][ValidateScript({ $_ -ge 1 })]
	[uint16]$TranscriptDateValue,
	# count of files to remain after transcript cleanup
	[Parameter(DontShow)]
	[uint16]$TranscriptFileCount,
	# local host name
	[Parameter(DontShow)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# local domain name
	[Parameter(DontShow)]
	[string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
	# local DNS hostname
	[Parameter(DontShow)]
	[string]$DnsHostName = ($HostName, $DomainName -join '.').TrimEnd('.')
)

Begin {
	Function Start-TranscriptWithHostAndDate {
		Param(
			# name for transcript items; default is sanitized name of calling script or function
			[Parameter()]
			[string]$TranscriptName = (Get-PSCallStack)[0].Command -replace '^<|\.ps1$|>$',
			# folder path for transcript files; default is named folder under 'PowerShell_transcript' folder in common application data folder
			[Parameter()]
			[string]$TranscriptPath = ([System.Environment]::GetFolderPath('CommonApplicationData'), 'PowerShell_transcript', $TranscriptName -join '\'),
			# host for transcript file name
			[Parameter(DontShow)]
			[string]$TranscriptHost = ([System.Environment]::MachineName),
			# time for transcript file name
			[Parameter(DontShow)]
			[string]$TranscriptTime = ([datetime]::Now.ToString('yyyyMMddHHmmss'))
		)

		# verify transcript path
		If (!(Test-Path -Path $TranscriptPath -PathType 'Container')) {
			# define parameters for New-Item
			$NewItem = @{
				Path        = $TranscriptPath
				ItemType    = 'Directory'
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# create transcript path
			Try {
				$null = New-Item @NewItem
			}
			Catch {
				Throw $_
			}
		}

		# build transcript file name with defined prefix, hostname, transcript name and current datetime
		$TranscriptFile = "PowerShell_transcript.$TranscriptHost.$TranscriptName.$TranscriptTime.txt"

		# define parameters for Start-Transcript
		$StartTranscript = @{
			Path        = Join-Path -Path $TranscriptPath -ChildPath $TranscriptFile
			Force       = $true
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# start transcript
		Try	{
			$null = Start-Transcript @StartTranscript
		}
		Catch {
			Throw $_
		}
	}

	Function Stop-TranscriptWithHostAndDate {
		Param(
			# name for transcript items; default is sanitized name of calling script or function
			[Parameter()]
			[string]$TranscriptName = (Get-PSCallStack)[0].Command -replace '^<|\.ps1$|>$',
			# folder path for transcript files; default is named folder under 'PowerShell_transcript' folder in common application data folder
			[Parameter()]
			[string]$TranscriptPath = ([System.Environment]::GetFolderPath('CommonApplicationData'), 'PowerShell_transcript', $TranscriptName -join '\'),
			# host for transcript file names
			[Parameter(DontShow)]
			[string]$TranscriptHost = ([System.Environment]::MachineName),
			# units for transcript cleanup date
			[Parameter(DontShow)][ValidateSet('Hours', 'Days', 'Weeks', 'Months', 'Years')]
			[string]$TranscriptDateUnits = 'Days',
			# value for transcript cleanup date
			[Parameter(DontShow)][ValidateScript({ $_ -ge 1 })]
			[uint16]$TranscriptDateValue = 7,
			# count of files to remain after transcript cleanup
			[Parameter(DontShow)]
			[uint16]$TranscriptFileCount = 7
		)

		# define filter using default transcript prefix, hostname, and script name
		$TranscriptFilter = "PowerShell_transcript.$TranscriptHost.$TranscriptName*"

		# get transcript files matching filter
		Try {
			$TranscriptFiles = Get-ChildItem -Path $TranscriptPath -Filter $TranscriptFilter -ErrorAction 'SilentlyContinue'
		}
		Catch {
			Write-Warning -Message $_.ToString()
		}

		# define transcript date
		switch ($TranscriptDateUnits) {
			'Hours' {
				$TranscriptDate = [datetime]::Now.AddHours(-$TranscriptDateValue)
			}
			'Days' {
				$TranscriptDate = [datetime]::Now.AddDays(-$TranscriptDateValue)
			}
			'Months' {
				$TranscriptDate = [datetime]::Now.AddMonths(-$TranscriptDateValue)
			}
			'Years' {
				$TranscriptDate = [datetime]::Now.AddYears(-$TranscriptDateValue)
			}
			Default {
				$TranscriptDate = [datetime]::FromFileTime(0)
			}
		}

		# declare cleanup thresholds
		Write-Verbose -Verbose -Message "Removing transcript files from '$TranscriptPath' matching '$TranscriptFilter' with a LastWriteTime before '$($TranscriptDate.ToString('s'))' provided that '$TranscriptFileCount' files remain"

		# split transcript files into files-to-remain and files-to-remove based upon LastWriteTime
		Try {
			$FilesToRemain, $FilesToRemove = $TranscriptFiles.Where({ $_.LastWriteTime -ge $TranscriptDate }, [System.Management.Automation.WhereOperatorSelectionMode]::Split)
		}
		Catch {
			Write-Warning -Message $_.ToString()
		}

		# if count of files-to-remain is than minimum file count...
		If ($FilesToRemain.Count -lt $TranscriptFileCount) {
			# declare skipping cleanup
			Write-Verbose -Verbose -Message "Skipping transcript cleanup: only '$($FilesToRemain.Count)' files would remain"
		}
		Else {
			# sort files-to-remove by name then remove
			ForEach ($FileToRemove in ($FilesToRemove | Sort-Object -Property FullName)) {
				Try {
					Remove-Item -Path $FileToRemove.FullName -Force -Verbose -ErrorAction Stop
				}
				Catch {
					Write-Warning -Message $_.ToString()
				}
			}
		}

		# stop transcript
		Try {
			Stop-Transcript
		}
		Catch {
			Throw $_
		}
	}

	Function Write-TranscriptWithHostAndDate {
		[CmdletBinding(DefaultParameterSetName = 'Default')]
		Param(
			# message for transcript
			[Parameter(Position = 0, Mandatory = $true)]
			[string]$Message,
			# optional prefix type for message; add datetime
			[Parameter(ParameterSetName = 'Basic')]
			[switch]$Basic,
			# optional prefix type for message; add datetime and command, messsage is collection of key/value pairs
			[Parameter(ParameterSetName = 'Collection')]
			[switch]$Collection,
			# optional prefix type for message; add datetime and command, message will be wrapped in double quotes
			[Parameter(ParameterSetName = 'Wrap')]
			[switch]$Wrap,
			# command name for transcript
			[Parameter(DontShow)]
			[string]$Command = (Get-PSCallStack)[0].Command,
			# formatted datetime for message
			[Parameter(DontShow)]
			[string]$Datetime = [datetime]::Now.ToString('yyyy-MM-ddThh:mm:ss.fffZ')
		)
	
		# update message per parameters
		switch ($PSCmdlet.ParameterSetName) {
			'Basic' {
				$Message = "$Datetime $Message"; Break
			}
			'Collection' {
				$Message = "datetime=$Datetime command=$Command $Message"; Break
			}
			'Wrap' {
				$Message = "datetime=$Datetime command=$Command message=`"$Message`""; Break
			}
		}
	
		# address bug in PowerShell 5 with transcripts and Write-Information
		If ($PSVersionTable.PSVersion.Major -lt 6) {
			Write-Information -MessageData $Message -InformationAction SilentlyContinue
		}
	
		# prefix message
		$Message = "INFO: $Message"
	
		# write information message
		Write-Information -MessageData $Message -InformationAction Continue
	}

	Function Write-VerboseToTranscriptWithHostAndDate {
		[CmdletBinding(DefaultParameterSetName = 'Default')]
		Param(
			# message for transcript
			[Parameter(Position = 0, Mandatory = $true)]
			[string]$Message,
			# optional prefix type for message; add datetime
			[Parameter(ParameterSetName = 'Basic')]
			[switch]$Basic,
			# optional prefix type for message; add datetime and command, messsage is collection of key/value pairs
			[Parameter(ParameterSetName = 'Collection')]
			[switch]$Collection,
			# optional prefix type for message; add datetime and command, message will be wrapped in double quotes
			[Parameter(ParameterSetName = 'Wrap')]
			[switch]$Wrap,
			# command name for transcript
			[Parameter(DontShow)]
			[string]$Command = (Get-PSCallStack)[0].Command,
			# formatted datetime for message
			[Parameter(DontShow)]
			[string]$Datetime = [datetime]::Now.ToString('yyyy-MM-ddThh:mm:ss.fffZ')
		)
	
		# update message per parameters
		switch ($PSCmdlet.ParameterSetName) {
			'Basic' {
				$Message = "$Datetime $Message"; Break
			}
			'Collection' {
				$Message = "datetime=$Datetime command=$Command $Message"; Break
			}
			'Wrap' {
				$Message = "datetime=$Datetime command=$Command message=`"$Message`""; Break
			}
		}
	
		# write verbose message
		Write-Verbose -Message $Message -Verbose
	}

	Function Write-WarningToTranscriptWithHostAndDate {
		[CmdletBinding(DefaultParameterSetName = 'Default')]
		Param(
			# message for transcript
			[Parameter(Position = 0, Mandatory = $true)]
			[string]$Message,
			# optional prefix type for message; add datetime
			[Parameter(ParameterSetName = 'Basic')]
			[switch]$Basic,
			# optional prefix type for message; add datetime and command, messsage is collection of key/value pairs
			[Parameter(ParameterSetName = 'Collection')]
			[switch]$Collection,
			# optional prefix type for message; add datetime and command, message will be wrapped in double quotes
			[Parameter(ParameterSetName = 'Wrap')]
			[switch]$Wrap,
			# command name for transcript
			[Parameter(DontShow)]
			[string]$Command = (Get-PSCallStack)[0].Command,
			# formatted datetime for message
			[Parameter(DontShow)]
			[string]$Datetime = [datetime]::Now.ToString('yyyy-MM-ddThh:mm:ss.fffZ')
		)
	
		# update message per parameters
		switch ($PSCmdlet.ParameterSetName) {
			'Basic' {
				$Message = "$Datetime $Message"; Break
			}
			'Collection' {
				$Message = "datetime=$Datetime command=$Command $Message"; Break
			}
			'Wrap' {
				$Message = "datetime=$Datetime command=$Command message=`"$Message`""; Break
			}
		}
	
		# write warning message
		Write-Warning -Message $Message -WarningAction Continue
	}

	# if skip transcript not requested...
	If ($SkipTranscript -eq $false) {
		# define hashtable for transcript functions
		$TranscriptWithHostAndDate = @{}
		# define parameters for transcript functions
		If ($PSBoundParameters.ContainsKey('TranscriptName')) { $TranscriptWithHostAndDate['TranscriptName'] = $PSBoundParameters['TranscriptName'] }
		If ($PSBoundParameters.ContainsKey('TranscriptPath')) { $TranscriptWithHostAndDate['TranscriptPath'] = $PSBoundParameters['TranscriptPath'] }
		# start transcript with parameters
		Try {
			Start-TranscriptWithHostAndDate @TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}

Process {
	# example try/catch block
	Try {
		# insert commands here
		$null = Get-PSCallStack
		# write to transcript example
		Write-TranscriptWithHostAndDate -Message 'retrieved PSCallStack'
	}
	Catch {
		# write to transcript example for warning
		Write-WarningToTranscriptWithHostAndDate -Message $_.ToString()
		# use return to hand errors to the calling function or console
		Return $_
		# avoid using Throw in the Process section; calling Throw will terminate the script, skip the End block, and skip transcript cleanup
	}
}

End {
	# if skip transcript not requested...
	If ($SkipTranscript -eq $false) {
		# update parameters for transcript functions
		If ($PSBoundParameters.ContainsKey('TranscriptDateUnits')) { $TranscriptWithHostAndDate['TranscriptDateUnits'] = $PSBoundParameters['TranscriptDateUnits'] }
		If ($PSBoundParameters.ContainsKey('TranscriptDateValue')) { $TranscriptWithHostAndDate['TranscriptDateValue'] = $PSBoundParameters['TranscriptDateValue'] }
		If ($PSBoundParameters.ContainsKey('TranscriptFileCount')) { $TranscriptWithHostAndDate['TranscriptFileCount'] = $PSBoundParameters['TranscriptFileCount'] }
		# stop transcript with parameters
		Try {
			Stop-TranscriptWithHostAndDate @TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}
