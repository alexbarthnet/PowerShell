Function Start-TranscriptWithHostAndDate {
	<#
	.SYNOPSIS
	Starts a PowerShell transcript with the given parameters in a defined folder structure.

	.DESCRIPTION
	Starts a PowerShell transcript with the given parameters in a defined folder structure. The defaults create a folder for each calling script or function under a named folder in a well-known and accessible location on most operating systems.

	.PARAMETER TranscriptName
	The name of the transcript. The default is the sanitized name of the calling script or function. File extensions are removed from calling script names. Leading and trailing angle brackets are removed from sources such as '<ScriptBlock>'.

	.PARAMETER TranscriptRoot
	The path to the folder where the root transcript folder will be created. The default value is the 'C:\ProgramData' folder on Windows and the '/usr/share' folder on macOS and Linux systems.

	.PARAMETER TranscriptLeaf
	The name of the immediate leaf folder in the transcript root folder. The default value is 'PowerShell_transcript'.

	.PARAMETER TranscriptBase
	The path to the folder where folders will created for each distinct calling function or script  The default value is the 'C:\ProgramData\PowerShell_transcript' folder on Windows and the '/usr/share/PowerShell_transcript' folder on macOS and Linux.
	
	.PARAMETER TranscriptPath
	The path to a folder for saving PowerShell transcript files. The default is the $TranscriptName folder under the $TranscriptBase folder.

	.PARAMETER TranscriptHost
	The name of the machine which is included in the transcript file name. The default is the local machine name.

	.PARAMETER TranscriptTime
	The time the transcript was created. The default is the current time formatted with the 'yyyyMMddHHmmss' .NET datetime format string.

	.INPUTS
	None.

	.OUTPUTS
	None. The function does not generate any output.
	#>

	Param(
		# name for transcript items; default is sanitized name of calling script or function
		[Parameter(Position = 0)]
		[string]$TranscriptName = (Get-PSCallStack)[0].Command -replace '^<|\.ps1$|>$',
		# root folder for transcript folders; default is common application data folder
		[Parameter(DontShow)]
		[string]$TranscriptRoot = ([System.Environment]::GetFolderPath('CommonApplicationData')),
		# leaf folder for transcript folders; default is 'PowerShell_transcript'
		[Parameter(DontShow)]
		[string]$TranscriptLeaf = 'PowerShell_transcript',
		# base folder for transcript folders; default is 'PowerShell_transcript' folder in common application data folder
		[Parameter(DontShow)]
		[string]$TranscriptBase = (Join-Path -Path $TranscriptRoot -ChildPath $TranscriptLeaf),
		# path for transcript files; default is named folder under 'PowerShell_transcript' folder in common application data folder
		[Parameter(DontShow)]
		[string]$TranscriptPath = (Join-Path -Path $TranscriptBase -ChildPath $TranscriptName),
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
	<#
	.SYNOPSIS
	Stops a PowerShell transcript after removing old transcript files from the defined transcript folder.

	.DESCRIPTION
	Stops a PowerShell transcript after removing old transcript files from the defined transcript folder.

	.PARAMETER TranscriptName
	The name of the transcript. The default is the sanitized name of the calling script or function. File extensions are removed from calling script names. Leading and trailing angle brackets are removed from sources such as '<ScriptBlock>'.

	.PARAMETER TranscriptRoot
	The path to the folder where the root transcript folder will be created. The default value is the 'C:\ProgramData' folder on Windows and the '/usr/share' folder on macOS and Linux systems.

	.PARAMETER TranscriptLeaf
	The name of the immediate leaf folder in the transcript root folder. The default value is 'PowerShell_transcript'.

	.PARAMETER TranscriptBase
	The path to the folder where folders will created for each distinct calling function or script  The default value is the 'C:\ProgramData\PowerShell_transcript' folder on Windows and the '/usr/share/PowerShell_transcript' folder on macOS and Linux.
	
	.PARAMETER TranscriptPath
	The path to a folder for saving PowerShell transcript files. The default is the $TranscriptName folder under the $TranscriptBase folder.

	.PARAMETER TranscriptHost
	The name of the machine which is included in the transcript file name. The default is the local machine name.

	.PARAMETER TranscriptTime
	The time the transcript was created. The default is the current time formatted with the 'yyyyMMddHHmmss' .NET datetime format string.

	.PARAMETER TranscriptDateUnits
	The string to define the datetime units for computing a datetime offset. The default value is 'Days'. The valid values are 'Hours', 'Days', 'Weeks', 'Months', and 'Years'.

	.PARAMETER TranscriptDateValue
	The uint16 to define the datetime value for computing a datetime offset. The default value is '7'. The valid values between 1 and 65535.

	.PARAMETER TranscriptFileCount
	the uint16 to define the count of transcript files that must remain if old transcripts are removed. The removal of old files is skipped if the resulting count of transcript files would be below this value. The default value is '7'.

	.INPUTS
	None.

	.OUTPUTS
	None. The function does not generate any output.
	#>

	Param(
		# name for transcript items; default is sanitized name of calling script or function
		[Parameter()]
		[string]$TranscriptName = (Get-PSCallStack)[0].Command -replace '^<|\.ps1$|>$',
		# root folder for transcript folders; default is common application data folder
		[Parameter()]
		[string]$TranscriptRoot = ([System.Environment]::GetFolderPath('CommonApplicationData')),
		# leaf folder for transcript folders; default is 'PowerShell_transcript'
		[Parameter()]
		[string]$TranscriptLeaf = 'PowerShell_transcript',
		# base folder for transcript folders; default is 'PowerShell_transcript' folder in common application data folder
		[Parameter()]
		[string]$TranscriptBase = (Join-Path -Path $TranscriptRoot -ChildPath $TranscriptLeaf),
		# path for transcript files; default is named folder under 'PowerShell_transcript' folder in common application data folder
		[Parameter()]
		[string]$TranscriptPath = (Join-Path -Path $TranscriptBase -ChildPath $TranscriptName),
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
	<#
	.SYNOPSIS
	Writes information to both console and transcript with optional formatting.

	.DESCRIPTION
	Writes information to both console and transcript with optional formatting.

	.PARAMETER Message
	The string containing information to be written to the console and transcript.

	.PARAMETER Basic
	Switch parameter to prefix the message parameter with the value of the Datetime parameter. Cannot be combined with the 'Collection' or 'Wrap' parameters

	.PARAMETER Collection
	Switch parameter to prefix the message parameter with the values of the Datetime and Command parameters as key/value pairs and assumes the value of the Message parameter is an existing string of key/value pairs. Cannot be combined with the 'Basic' or 'Wrap' parameters

	.PARAMETER Wrap
	Switch parameter to prefix the message parameter with the values of the Datetime and Command parameters as key/value pairs then creates a key/value pair using the value of the Message parameter wrapped double quotes. Cannot be combined with the 'Basic' or 'Collection' parameters
	
	.PARAMETER Command
	The name of the command that originated the message. The default value is the name of the calling function or script.

	.PARAMETER Datetime
	A string containing a formatted datetime. The default value is the current time in ISO 8601 format.

	.INPUTS
	None.

	.OUTPUTS
	None. The function does not generate any output.
	#>

	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		# message for transcript
		[Parameter(Position = 0, Mandatory = $true)]
		[string]$Message,
		# optional prefix type for message; prefix datetime
		[Parameter(ParameterSetName = 'Basic')]
		[switch]$Basic,
		# optional prefix type for message; prefix datetime and command as key/value pairs, messsage is collection of key/value pairs
		[Parameter(ParameterSetName = 'Collection')]
		[switch]$Collection,
		# optional prefix type for message; prefix datetime and command as key/value pairs, message will be wrapped in double quotes
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

	# address known issue in PowerShell 5 with transcripts and Write-Information
	If ($PSVersionTable.PSVersion.Major -lt 6) {
		Write-Information -MessageData $Message -InformationAction SilentlyContinue
	}

	# prefix message after addressing known issue in PowerShell 5 
	$Message = "INFO: $Message"

	# write information message
	Microsoft.PowerShell.Utility\Write-Information -MessageData $Message -InformationAction Continue
}

Function Write-VerboseToTranscriptWithHostAndDate {
	<#
	.SYNOPSIS
	Writes verbose output to both console and transcript with optional formatting.

	.DESCRIPTION
	Writes verbose output to both console and transcript with optional formatting.

	.PARAMETER Message
	The string containing verbose output to be written to the console and transcript.

	.PARAMETER Basic
	Switch parameter to prefix the message parameter with the value of the Datetime parameter. Cannot be combined with the 'Collection' or 'Wrap' parameters

	.PARAMETER Collection
	Switch parameter to prefix the message parameter with the values of the Datetime and Command parameters as key/value pairs and assumes the value of the Message parameter is an existing string of key/value pairs. Cannot be combined with the 'Basic' or 'Wrap' parameters

	.PARAMETER Wrap
	Switch parameter to prefix the message parameter with the values of the Datetime and Command parameters as key/value pairs then creates a key/value pair using the value of the Message parameter wrapped double quotes. Cannot be combined with the 'Basic' or 'Collection' parameters
	
	.PARAMETER Command
	The name of the command that originated the message. The default value is the name of the calling function or script.

	.PARAMETER Datetime
	A string containing a formatted datetime. The default value is the current time in ISO 8601 format.

	.INPUTS
	None.

	.OUTPUTS
	None. The function does not generate any output.
	#>

	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		# message for transcript
		[Parameter(Position = 0, Mandatory = $true)]
		[string]$Message,
		# optional prefix type for message; prefix datetime
		[Parameter(ParameterSetName = 'Basic')]
		[switch]$Basic,
		# optional prefix type for message; prefix datetime and command as key/value pairs, messsage is collection of key/value pairs
		[Parameter(ParameterSetName = 'Collection')]
		[switch]$Collection,
		# optional prefix type for message; prefix datetime and command as key/value pairs, message will be wrapped in double quotes
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
	Microsoft.PowerShell.Utility\Write-Verbose -Message $Message -Verbose
}

Function Write-WarningToTranscriptWithHostAndDate {
	<#
	.SYNOPSIS
	Writes a warning to both console and transcript with optional formatting.

	.DESCRIPTION
	Writes a warning to both console and transcript with optional formatting.

	.PARAMETER Message
	The string containing a warning to be written to the console and transcript.

	.PARAMETER Basic
	Switch parameter to prefix the message parameter with the value of the Datetime parameter. Cannot be combined with the 'Collection' or 'Wrap' parameters

	.PARAMETER Collection
	Switch parameter to prefix the message parameter with the values of the Datetime and Command parameters as key/value pairs and assumes the value of the Message parameter is an existing string of key/value pairs. Cannot be combined with the 'Basic' or 'Wrap' parameters

	.PARAMETER Wrap
	Switch parameter to prefix the message parameter with the values of the Datetime and Command parameters as key/value pairs then creates a key/value pair using the value of the Message parameter wrapped double quotes. Cannot be combined with the 'Basic' or 'Collection' parameters
	
	.PARAMETER Command
	The name of the command that originated the message. The default value is the name of the calling function or script.

	.PARAMETER Datetime
	A string containing a formatted datetime. The default value is the current time in ISO 8601 format.

	.INPUTS
	None.

	.OUTPUTS
	None. The function does not generate any output.
	#>

	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		# message for transcript
		[Parameter(Position = 0, Mandatory = $true)]
		[string]$Message,
		# optional prefix type for message; prefix datetime
		[Parameter(ParameterSetName = 'Basic')]
		[switch]$Basic,
		# optional prefix type for message; prefix datetime and command as key/value pairs, messsage is collection of key/value pairs
		[Parameter(ParameterSetName = 'Collection')]
		[switch]$Collection,
		# optional prefix type for message; prefix datetime and command as key/value pairs, message will be wrapped in double quotes
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
	Microsoft.PowerShell.Utility\Write-Warning -Message $Message -WarningAction Continue
}

# define functions to export
$FunctionsToExport = @(
	'Start-TranscriptWithHostAndDate'
	'Stop-TranscriptWithHostAndDate'
	'Write-TranscriptWithHostAndDate'
	'Write-VerboseToTranscriptWithHostAndDate'
	'Write-WarningToTranscriptWithHostAndDate'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport
