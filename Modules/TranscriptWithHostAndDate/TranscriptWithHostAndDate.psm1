Function New-TextOutputWithHostAndDate {
	<#
	.SYNOPSIS
	Creates a file containing text output from a PowerShell transcript session with the given parameters in a defined folder structure.

	.DESCRIPTION
	Creates a file for text output from a PowerShell session with the given parameters in a defined folder structure. The defaults create a folder for each calling script or function under a named folder in a well-known and accessible location on most operating systems.

	.PARAMETER TextOutputName
	The name of the text output file. The default is the sanitized name of the calling script or function. File extensions are removed from calling script names. Leading and trailing angle brackets are removed from sources such as '<ScriptBlock>'.

	.PARAMETER TextOutputRoot
	The path to the folder where the root text output folder will be created. The default value is the 'C:\ProgramData' folder on Windows and the '/usr/share' folder on macOS and Linux systems.

	.PARAMETER TextOutputLeaf
	The name of the immediate leaf folder in the text output root folder. The default value is 'PowerShell_textoutput'.

	.PARAMETER TextOutputBase
	The path to the folder where folders will created for each distinct calling function or script  The default value is the 'C:\ProgramData\PowerShell_textoutput' folder on Windows and the '/usr/share/PowerShell_textoutput' folder on macOS and Linux.

	.PARAMETER TextOutputPath
	The path to a folder for text output files. The default is the $TextOutputName folder under the $TextOutputBase folder.

	.PARAMETER TextOutputHost
	The name of the machine which is included in the text output file name. The default is the local machine name.

	.PARAMETER TextOutputTime
	The time the text output file was created. The default is the current time formatted with the 'yyyyMMddHHmmss' .NET datetime format string.

	.INPUTS
	None.

	.OUTPUTS
	None. The function does not generate any output.
	#>

	Param(
		# name for text output files; default is sanitized name of calling script or function
		[Parameter(Position = 0)]
		[string]$TextOutputName = (Get-PSCallStack)[0].Command -replace '^<|\.ps1$|>$',
		# root folder for text output folders; default is common application data folder
		[Parameter(DontShow)]
		[string]$TextOutputRoot = ([System.Environment]::GetFolderPath('CommonApplicationData')),
		# leaf folder for text output folders; default is 'PowerShell_textoutput'
		[Parameter(DontShow)]
		[string]$TextOutputLeaf = 'PowerShell_textoutput',
		# base folder for text output folders; default is text output leaf folder in common application data folder
		[Parameter(DontShow)]
		[string]$TextOutputBase = (Join-Path -Path $TextOutputRoot -ChildPath $TextOutputLeaf),
		# path for text output files; default is named folder under 'PowerShell_textoutput' folder in common application data folder
		[Parameter(DontShow)]
		[string]$TextOutputPath = (Join-Path -Path $TextOutputBase -ChildPath $TextOutputName),
		# host for text output file name
		[Parameter(DontShow)]
		[string]$TextOutputHost = ([System.Environment]::MachineName),
		# time for text output file name
		[Parameter(DontShow)]
		[string]$TextOutputTime = ([datetime]::Now.ToString('yyyyMMddHHmmss'))
	)

	# verify text output path
	If (!(Test-Path -Path $TextOutputPath -PathType 'Container')) {
		# define parameters for New-Item
		$NewItem = @{
			Path        = $TextOutputPath
			ItemType    = 'Directory'
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# create text output path
		Try {
			$null = New-Item @NewItem
		}
		Catch {
			Throw $_
		}
	}

	# build text output file name with defined prefix, hostname, text output name and current datetime
	$TextOutputFile = "$TextOutputLeaf.$TextOutputHost.$TextOutputName.$TextOutputTime.txt"

	# build text output file path
	$TextOutputFilePath = Join-Path -Path $TextOutputPath -ChildPath $TextOutputFile

	# verify text output file
	If (!(Test-Path -Path $TextOutputFilePath -PathType 'Leaf')) {
		# define parameters for New-Item
		$NewItem = @{
			Path        = $TextOutputFilePath
			ItemType    = 'File'
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# create text output file
		Try {
			$null = New-Item @NewItem
		}
		Catch {
			Throw $_
		}
	}

	# store path in module hashtable
	$script:TextOutputWithHostAndDate[$TranscriptName] = $TextOutputFilePath

	# store path in module string
	$script:TextOutputWithHostAndDatePath = $TextOutputFilePath
}

Function Remove-TextOutputWithHostAndDate {
	<#
	.SYNOPSIS
	Removes old text output files from the defined text output folder.

	.DESCRIPTION
	Removes old text output files from the defined text output folder.

	.PARAMETER TextOutputName
	The name of the text output file. The default is the sanitized name of the calling script or function. File extensions are removed from calling script names. Leading and trailing angle brackets are removed from sources such as '<ScriptBlock>'.

	.PARAMETER TextOutputRoot
	The path to the folder where the root text output folder will be created. The default value is the 'C:\ProgramData' folder on Windows and the '/usr/share' folder on macOS and Linux systems.

	.PARAMETER TextOutputLeaf
	The name of the immediate leaf folder in the text output root folder. The default value is 'PowerShell_textoutput'.

	.PARAMETER TextOutputBase
	The path to the folder where folders will created for each distinct calling function or script  The default value is the 'C:\ProgramData\PowerShell_textoutput' folder on Windows and the '/usr/share/PowerShell_textoutput' folder on macOS and Linux.

	.PARAMETER TextOutputPath
	The path to a folder for saving PowerShell text output files. The default is the $TextOutputName folder under the $TextOutputBase folder.

	.PARAMETER TextOutputHost
	The name of the machine which is included in the text output file name. The default is the local machine name.

	.PARAMETER TextOutputTimeSpan
	The timespan to define the minimum age of text output files to be eligible for removal. The default value is '7 days'.

	.PARAMETER TextOutputFileCount
	the uint16 to define the count of text output files that must remain if old text output files are removed. The removal of old files is skipped if the resulting count of text output files would be below this value. The default value is '7'.

	.INPUTS
	None.

	.OUTPUTS
	None. The function does not generate any output.
	#>

	Param(
		# name for text output items; default is sanitized name of calling script or function
		[Parameter()]
		[string]$TextOutputName = (Get-PSCallStack)[0].Command -replace '^<|\.ps1$|>$',
		# root folder for text output folders; default is common application data folder
		[Parameter()]
		[string]$TextOutputRoot = ([System.Environment]::GetFolderPath('CommonApplicationData')),
		# leaf folder for text output folders; default is 'PowerShell_textoutput'
		[Parameter()]
		[string]$TextOutputLeaf = 'PowerShell_textoutput',
		# base folder for text output folders; default is 'PowerShell_textoutput' folder in common application data folder
		[Parameter()]
		[string]$TextOutputBase = (Join-Path -Path $TextOutputRoot -ChildPath $TextOutputLeaf),
		# path for text output files; default is named folder under 'PowerShell_textoutput' folder in common application data folder
		[Parameter()]
		[string]$TextOutputPath = (Join-Path -Path $TextOutputBase -ChildPath $TextOutputName),
		# host for text output file names
		[Parameter(DontShow)]
		[string]$TextOutputHost = ([System.Environment]::MachineName),
		# timespan for text output cleanup
		[Parameter(DontShow)]
		[timespan]$TextOutputTimeSpan = [timespan]::FromDays(7),
		# count of files to remain after text output cleanup
		[Parameter(DontShow)]
		[uint16]$TextOutputFileCount = 7
	)

	# if text output path does not exist...
	If (![System.IO.Directory]::Exists($TextOutputPath)) {
		Write-Warning "could not locate path: $TextOutputPath"
		Return
	}

	# if time span is negative...
	If ($TextOutputTimeSpan -lt [timespan]::Zero) {
		# flip timespan with negate method
		$TextOutputTimeSpan = $TextOutputTimeSpan.Negate()
	}

	# define text output date
	$TextOutputDate = [datetime]::Now.Subtract($TextOutputTimeSpan)

	# define filter using text output leaf, hostname, and script name
	$TextOutputFilter = "$TextOutputLeaf.$TextOutputHost.$TextOutputName*"

	# declare cleanup thresholds
	Write-Verbose -Verbose -Message "Removing text output files from '$TextOutputPath' matching '$TextOutputFilter' with a LastWriteTime before '$($TextOutputDate.ToString('s'))' provided that '$TextOutputFileCount' files remain"

	# get text output files matching filter
	Try {
		$TextOutputFiles = Get-ChildItem -Path $TextOutputPath -Filter $TextOutputFilter -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message 'could not retrieve text output files'
		Return $_
	}

	# split text output files into files-to-remain and files-to-remove based upon LastWriteTime
	Try {
		$FilesToRemain, $FilesToRemove = $TextOutputFiles.Where({ $_.LastWriteTime -ge $TextOutputDate }, [System.Management.Automation.WhereOperatorSelectionMode]::Split)
	}
	Catch {
		Write-Warning -Message 'could not split text output files by LastWriteTime'
		Return $_
	}

	# if count of files-to-remain is than minimum file count...
	If ($FilesToRemain.Count -lt $TextOutputFileCount) {
		# declare skip and return
		Write-Verbose -Verbose -Message "Skipping text output cleanup: only '$($FilesToRemain.Count)' files would remain"
		Return
	}

	# sort files-to-remove by name then remove
	ForEach ($FileToRemove in ($FilesToRemove | Sort-Object -Property FullName)) {
		Try {
			Remove-Item -Path $FileToRemove.FullName -Force -Verbose -ErrorAction Stop
		}
		Catch {
			Write-Warning -Message "could not remove text output file: $($FileToRemove.FullName)"
			Return $_
		}
	}
}

Function Remove-TranscriptWithHostAndDate {
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

	.PARAMETER TranscriptTimeSpan
	The timespan to define the minimum age of transcript files to be eligible for removal. The default value is '7 days'.

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
		# timespan for transcript cleanup
		[Parameter(DontShow)]
		[timespan]$TranscriptTimeSpan = [timespan]::FromDays(7),
		# count of files to remain after transcript cleanup
		[Parameter(DontShow)]
		[uint16]$TranscriptFileCount = 7
	)

	# if transcript path does not exist...
	If (![System.IO.Directory]::Exists($TranscriptPath)) {
		Write-Warning "could not locate path: $TranscriptPath"
		Return
	}

	# if time span is negative...
	If ($TranscriptTimeSpan -lt [timespan]::Zero) {
		# flip timespan with negate method
		$TranscriptTimeSpan = $TranscriptTimeSpan.Negate()
	}

	# define transcript date
	$TranscriptDate = [datetime]::Now.Subtract($TranscriptTimeSpan)

	# define filter using default transcript prefix, hostname, and script name
	$TranscriptFilter = "$TranscriptLeaf.$TranscriptHost.$TranscriptName*"

	# declare cleanup thresholds
	Write-Verbose -Verbose -Message "Removing transcript files from '$TranscriptPath' matching '$TranscriptFilter' with a LastWriteTime before '$($TranscriptDate.ToString('s'))' provided that '$TranscriptFileCount' files remain"

	# get transcript files matching filter
	Try {
		$TranscriptFiles = Get-ChildItem -Path $TranscriptPath -Filter $TranscriptFilter -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message 'could not retrieve transcript files'
		Return $_
	}

	# split transcript files into files-to-remain and files-to-remove based upon LastWriteTime
	Try {
		$FilesToRemain, $FilesToRemove = $TranscriptFiles.Where({ $_.LastWriteTime -ge $TranscriptDate }, [System.Management.Automation.WhereOperatorSelectionMode]::Split)
	}
	Catch {
		Write-Warning -Message 'could not split transcript files by LastWriteTime'
		Return $_
	}

	# if count of files-to-remain is than minimum file count...
	If ($FilesToRemain.Count -lt $TranscriptFileCount) {
		# declare skip and return
		Write-Verbose -Verbose -Message "Skipping transcript cleanup: only '$($FilesToRemain.Count)' files would remain"
		Return
	}

	# sort files-to-remove by name then remove
	ForEach ($FileToRemove in ($FilesToRemove | Sort-Object -Property FullName)) {
		Try {
			Remove-Item -Path $FileToRemove.FullName -Force -Verbose -ErrorAction Stop
		}
		Catch {
			Write-Warning -Message "could not remove transcript file: $($FileToRemove.FullName)"
			Return $_
		}
	}
}

Function Resume-TranscriptWithHostAndDate {
	<#
	.SYNOPSIS
	Resumes a PowerShell transcript created by Start-TranscriptWithHostAndDate and stored in the module hashtable.

	.DESCRIPTION
	Resumes a PowerShell transcript created by Start-TranscriptWithHostAndDate and stored in the module hashtable.

	.PARAMETER TranscriptName
	The name of the transcript. The default is the sanitized name of the calling script or function. File extensions are removed from calling script names. Leading and trailing angle brackets are removed from sources such as '<ScriptBlock>'.

	.INPUTS
	None.

	.OUTPUTS
	None. The function does not generate any output.
	#>

	Param(
		# name for transcript items; default is sanitized name of calling script or function
		[Parameter(Position = 0)]
		[string]$TranscriptName = (Get-PSCallStack)[0].Command -replace '^<|\.ps1$|>$'
	)

	# if module hashtable does not have a key for calling script or function...
	If (!$script:TranscriptWithHostAndDate.ContainsKey($TranscriptName)) {
		Write-Warning -Message 'could not resume original transcript: the module hashtable does not have a key for the calling script or function'
		Return
	}

	# if value in module hashtable variable is not a hashtable...
	If ($script:TranscriptWithHostAndDate[$TranscriptName] -isnot [System.Collections.Hashtable]) {
		Write-Warning -Message 'could not resume original transcript: the value in the module hashtable associated with the calling script or function is not a hashtable'
		Return
	}

	# retrieve parameters from script variable
	$StartTranscriptParameters = $script:TranscriptWithHostAndDate[$TranscriptName]

	# start transcript quietly
	Try	{
		$null = Start-Transcript @StartTranscriptParameters
	}
	Catch {
		Throw $_
	}

	# if module hashtable does not have a key for calling script or function...
	If (!$script:TextOutputWithHostAndDate.ContainsKey($TranscriptName)) {
		Write-Warning -Message 'could not resume original transcript: the module hashtable does not have a key for the calling script or function'
		Return
	}

	# if value in module hashtable variable is not a string...
	If ($script:TextOutputWithHostAndDate[$TranscriptName] -isnot [System.String]) {
		Write-Warning -Message 'could not resume original transcript: the value in the module hashtable associated with the calling script or function is not a string'
		Return
	}

	# update path in module string
	$script:TextOutputWithHostAndDatePath = $script:TextOutputWithHostAndDate[$TranscriptName]
}

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
		# base folder for transcript folders; default is transcript leaf folder in common application data folder
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
		[string]$TranscriptTime = ([datetime]::Now.ToString('yyyyMMddHHmmss')),
		# switch to skip textoutput file
		[Parameter(DontShow)]
		[switch]$SkipTextOutput
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
	$TranscriptFile = "$TranscriptLeaf.$TranscriptHost.$TranscriptName.$TranscriptTime.txt"

	# define parameters for Start-Transcript
	$StartTranscriptParameters = @{
		Path        = Join-Path -Path $TranscriptPath -ChildPath $TranscriptFile
		Force       = $true
		Append      = $true
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# store parameters in module hashtable
	$script:TranscriptWithHostAndDate[$TranscriptName] = $StartTranscriptParameters

	# start transcript quietly
	Try	{
		$null = Start-Transcript @StartTranscriptParameters
	}
	Catch {
		Throw $_
	}

	# if skip text requested...
	If ($SkipTextOutput) {
		# clear path in text output module hashtable
		$script:TextOutputWithHostAndDatePath = $null
		Return
	}

	# define parameters for New-TextOutputWithHostAndDate
	$NewTextOutputWithHostAndDate = @{
		# map transcript name to text output
		TextOutputName = $TranscriptName
		# map transcript time to text output
		TextOutputTime = $TranscriptTime
	}

	# create text output file
	Try	{
		New-TextOutputWithHostAndDate @NewTextOutputWithHostAndDate
	}
	Catch {
		Throw $_
	}
}

Function Stop-TranscriptWithHostAndDate {
	<#
	.SYNOPSIS
	Stops a PowerShell transcript after removing old transcript and text output files.

	.DESCRIPTION
	Stops a PowerShell transcript after removing old transcript and text output files.

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

	.PARAMETER TranscriptTimeSpan
	The timespan to define the minimum age of transcript files to be eligible for removal. The default value is '7 days'.

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

	# clear value in module string
	$script:TextOutputWithHostAndDatePath = [string]::Empty

	# define required parameters for Remove-TextOutputWithHostAndDate
	$RemoveTextOutputWithHostAndDate = @{
		TextOutputName = $TranscriptName
	}

	# remove text output files
	Try {
		Remove-TextOutputWithHostAndDate @RemoveTextOutputWithHostAndDate
	}
	Catch {
		Write-Warning -Message $_.ToString()
	}

	# define required parameters for Remove-TranscriptWithHostAndDate
	$RemoveTranscriptWithHostAndDate = @{
		TranscriptName = $TranscriptName
	}

	# remove transcript files
	Try {
		Remove-TranscriptWithHostAndDate @RemoveTranscriptWithHostAndDate
	}
	Catch {
		Write-Warning -Message $_.ToString()
	}

	# stop transcript quietly
	Try {
		$null = Stop-Transcript
	}
	Catch {
		Throw $_
	}
}

Function Suspend-TranscriptWithHostAndDate {
	<#
	.SYNOPSIS
	Suspends a PowerShell transcript created by Start-TranscriptWithHostAndDate and stored in the module hashtable.

	.DESCRIPTION
	Suspends a PowerShell transcript created by Start-TranscriptWithHostAndDate and stored in the module hashtable.

	.INPUTS
	None.

	.OUTPUTS
	None. The function does not generate any output.
	#>

	Param(
		# name for transcript items; default is sanitized name of calling script or function
		[Parameter(Position = 0)]
		[string]$TranscriptName = (Get-PSCallStack)[0].Command -replace '^<|\.ps1$|>$'
	)

	# if module hashtable does not have a key for calling script or function...
	If (!$script:TranscriptWithHostAndDate.ContainsKey($TranscriptName)) {
		Write-Warning -Message 'will not suspend current transcript: the module hashtable does not have a key for the calling script or function'
		Return
	}

	# if value in module hashtable variable is not a hashtable...
	If ($script:TranscriptWithHostAndDate[$TranscriptName] -isnot [System.Collections.Hashtable]) {
		Write-Warning -Message 'will not suspend current transcript: the value in the module hashtable associated with the calling script or function is not a hashtable'
		Return
	}

	# clear value in module string
	$script:TextOutputWithHostAndDatePath = [string]::Empty

	# stop transcript quietly
	Try	{
		$null = Stop-Transcript
	}
	Catch {
		Throw $_
	}
}

Function Write-TranscriptWithHostAndDate {
	<#
	.SYNOPSIS
	Writes text output from a PowerShell session to a file.

	.DESCRIPTION
	Writes text output from a PowerShell session to a file.

	.PARAMETER Message
	The text output to be written to the file.

	.PARAMETER Stream
	The name of the stream associated with the text output. The default value is "Information"

	.PARAMETER Command
	The name of the command associated with the text output. The default value is the name of the function or script that called the proxy command.

	.PARAMETER Datetime
	A string containing a formatted datetime. The default value is the current time in ISO 8601 format.

	.PARAMETER Hostname
	A string containing a formatted hostname. The default value is the current hostname.

	.INPUTS
	None.

	.OUTPUTS
	None. The function does not generate any output.
	#>

	Param(
		# original text output
		[Parameter(Position = 0, Mandatory = $true)]
		[string]$Message,
		# original output stream for the text output
		[Parameter(Position = 1)]
		[string]$Stream = 'Information',
		# name of command that called the proxy functions
		[Parameter(DontShow)]
		[string]$Command = (Get-PSCallStack)[1].Command,
		# formatted datetime for message
		[Parameter(DontShow)]
		[string]$Datetime = [datetime]::Now.ToString('yyyy-MM-ddThh:mm:ss.fff'),
		# formatted hostname for message
		[Parameter(DontShow)]
		[string]$Hostname = ([System.Environment]::MachineName).ToLower()
	)

	# remove new lines from message
	$MessageWithoutNewLines = $Message.ToString().Replace("`r`n", ' ').Replace("`n", ' ').Replace("`r", ' ')

	# prepend information to message
	$MessageWithDetails = "hostname=$Hostname datetime=$Datetime command=$Command stream=$Stream message=$MessageWithoutNewLines"
	# $MessageWithDetails = "hostname={0} datetime={1} command={2} stream={3} message={4}" -f $Hostname, $Datetime, $Command, $Stream, $MessageWithoutNewLines

	# append single new line to message
	$Text = [System.String]::Concat($MessageWithDetails, [System.Environment]::NewLine)

	# append text to file
	Try {
		[System.IO.File]::AppendAllText($script:TextOutputWithHostAndDatePath, $Text)
	}
	Catch {
		$PSCmdlet.ThrowTerminatingError($_)
	}
}

Function Write-Host {
	# [System.Management.Automation.ProxyCommand]::Create([System.Management.Automation.CommandMetaData]::new((Get-Command -Name Write-Host)))

	<#
	.ForwardHelpTargetName Microsoft.PowerShell.Utility\Write-Host
	.ForwardHelpCategory Cmdlet
	#>

	[CmdletBinding(HelpUri = 'https://go.microsoft.com/fwlink/?LinkID=113426', RemotingCapability = 'None')]
	Param(
		[Parameter(Position = 0, ValueFromPipeline = $true, ValueFromRemainingArguments = $true)]
		[System.Object]
		${Object},

		[switch]
		${NoNewline},

		[System.Object]
		${Separator},

		[System.ConsoleColor]
		${ForegroundColor},

		[System.ConsoleColor]
		${BackgroundColor}
	)

	Begin {
		# create steppable pipeline
		Try {
			# get command information from execution context
			$Command = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Utility\Write-Host', [System.Management.Automation.CommandTypes]::Cmdlet)

			# create reference object for TryGetValue
			$OutBuffer = $null

			# if bound parameters contains 'OutBuffer' parameter...
			If ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$OutBuffer)) {
				# set OutBuffer to 1
				$PSBoundParameters['OutBuffer'] = 1
			}

			# define script block for steppable pipeline
			$ScriptBlock = { & $Command @PSBoundParameters }

			# create steppable pipeline from script block
			$SteppablePipeline = $ScriptBlock.GetSteppablePipeline($myInvocation.CommandOrigin)

			# start steppable pipeline
			$SteppablePipeline.Begin($PSCmdlet)
		}
		Catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}

	Process {
		# process steppable pipeline
		Try {
			$SteppablePipeline.Process($_)
		}
		Catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# if text output file exists...
		If ([System.IO.File]::Exists($script:TextOutputWithHostAndDatePath)) {
			# if separator provided...
			If ($PSBoundParameters.ContainsKey('Separator')) {
				# join Object with Separator as string
				Try {
					$Message = [System.String]::Join($Separator, $Object)
				}
				Catch {
					$Message = 'could not join Object with Separator'
				}
			}
			# if separater not provided...
			Else {
				# cast Object as string
				Try {
					$Message = [System.String]$Object
				}
				Catch {
					$Message = 'could not cast Object to string'
				}
			}
			
			# append text to file
			Try {
				Write-TranscriptWithHostAndDate -Message $Message -Stream 'Information'
			}
			Catch {
				$PSCmdlet.ThrowTerminatingError($_)
			}
		}
	}

	End {
		# stop steppable pipeline
		Try {
			$SteppablePipeline.End()
		}
		Catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}
}

Function Write-Information {
	# [System.Management.Automation.ProxyCommand]::Create([System.Management.Automation.CommandMetaData]::new((Get-Command -Name Write-Information)))

	<#
	.ForwardHelpTargetName Microsoft.PowerShell.Utility\Write-Information
	.ForwardHelpCategory Cmdlet
	#>

	[CmdletBinding(HelpUri = 'https://go.microsoft.com/fwlink/?LinkId=525909', RemotingCapability = 'None')]
	Param(
		[Parameter(Mandatory = $true, Position = 0)]
		[Alias('Msg')]
		[System.Object]
		${MessageData},

		[Parameter(Position = 1)]
		[string[]]
		${Tags}
	)

	Begin {
		# create steppable pipeline
		Try {
			# get command information from execution context
			$Command = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Utility\Write-Information', [System.Management.Automation.CommandTypes]::Cmdlet)

			# create reference object for TryGetValue
			$OutBuffer = $null

			# if bound parameters contains 'OutBuffer' parameter...
			If ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$OutBuffer)) {
				# set OutBuffer to 1
				$PSBoundParameters['OutBuffer'] = 1
			}

			# define script block for steppable pipeline
			$ScriptBlock = { & $Command @PSBoundParameters }

			# create steppable pipeline from script block
			$SteppablePipeline = $ScriptBlock.GetSteppablePipeline($myInvocation.CommandOrigin)

			# start steppable pipeline
			$SteppablePipeline.Begin($PSCmdlet)
		}
		Catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}

	Process {
		# process steppable pipeline
		Try {
			$SteppablePipeline.Process($_)
		}
		Catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# if text output file exists...
		If ([System.IO.File]::Exists($script:TextOutputWithHostAndDatePath)) {
			# convert message data to string
			Try {
				$Message = $MessageData.ToString()
			}
			Catch {
				$Message = 'could not convert MessageData to string'
			}

			# append text to file
			Try {
				Write-TranscriptWithHostAndDate -Message $Message -Stream 'Information'
			}
			Catch {
				$PSCmdlet.ThrowTerminatingError($_)
			}
		}
	}

	End {
		# stop steppable pipeline
		Try {
			$SteppablePipeline.End()
		}
		Catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}
}

Function Write-Verbose {
	# [System.Management.Automation.ProxyCommand]::Create([System.Management.Automation.CommandMetaData]::new((Get-Command -Name Write-Verbose)))

	<#
	.ForwardHelpTargetName Microsoft.PowerShell.Utility\Write-Verbose
	.ForwardHelpCategory Cmdlet
	#>

	[CmdletBinding(HelpUri = 'https://go.microsoft.com/fwlink/?LinkID=113429', RemotingCapability = 'None')]
	Param(
		[Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
		[Alias('Msg')]
		[AllowEmptyString()]
		[string]
		${Message}
	)

	Begin {
		# create steppable pipeline
		Try {
			# get command information from execution context
			$Command = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Utility\Write-Verbose', [System.Management.Automation.CommandTypes]::Cmdlet)

			# create empty object for TryGetValue
			$OutBuffer = $null

			# if bound parameters contains 'OutBuffer' parameter...
			If ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$OutBuffer)) {
				# set OutBuffer to 1
				$PSBoundParameters['OutBuffer'] = 1
			}

			# define script block for steppable pipeline
			$ScriptBlock = { & $Command @PSBoundParameters }

			# create steppable pipeline from script block
			$SteppablePipeline = $ScriptBlock.GetSteppablePipeline($myInvocation.CommandOrigin)

			# start steppable pipeline
			$SteppablePipeline.Begin($PSCmdlet)
		}
		Catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}

	Process {
		# process steppable pipeline
		Try {
			$SteppablePipeline.Process($_)
		}
		Catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# if text output file exists...
		If ([System.IO.File]::Exists($script:TextOutputWithHostAndDatePath)) {
			# write message to text output file
			Try {
				Write-TranscriptWithHostAndDate -Message $Message -Stream 'Verbose'
			}
			Catch {
				$PSCmdlet.ThrowTerminatingError($_)
			}
		}
	}

	End {
		# stop steppable pipeline
		Try {
			$SteppablePipeline.End()
		}
		Catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}
}

Function Write-Warning {
	# [System.Management.Automation.ProxyCommand]::Create([System.Management.Automation.CommandMetaData]::new((Get-Command -Name Write-Warning)))

	<#
	.ForwardHelpTargetName Microsoft.PowerShell.Utility\Write-Verbose
	.ForwardHelpCategory Cmdlet
	#>

	[CmdletBinding(HelpUri = 'https://go.microsoft.com/fwlink/?LinkID=113430', RemotingCapability = 'None')]
	Param(
		[Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
		[Alias('Msg')]
		[AllowEmptyString()]
		[string]
		${Message}
	)

	Begin {
		# create steppable pipeline
		Try {
			# get command information from execution context
			$Command = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Utility\Write-Warning', [System.Management.Automation.CommandTypes]::Cmdlet)

			# create empty object for TryGetValue
			$OutBuffer = $null

			# if bound parameters contains 'OutBuffer' parameter...
			If ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$OutBuffer)) {
				# set OutBuffer to 1
				$PSBoundParameters['OutBuffer'] = 1
			}

			# define script block for steppable pipeline
			$ScriptBlock = { & $Command @PSBoundParameters }

			# create steppable pipeline from script block
			$SteppablePipeline = $ScriptBlock.GetSteppablePipeline($myInvocation.CommandOrigin)

			# start steppable pipeline
			$SteppablePipeline.Begin($PSCmdlet)
		}
		Catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}

	Process {
		# process steppable pipeline
		Try {
			$SteppablePipeline.Process($_)
		}
		Catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# if text output file exists...
		If ([System.IO.File]::Exists($script:TextOutputWithHostAndDatePath)) {
			# write message to text output file
			Try {
				Write-TranscriptWithHostAndDate -Message $Message -Stream 'Warning'
			}
			Catch {
				$PSCmdlet.ThrowTerminatingError($_)
			}
		}
	}

	End {
		# stop steppable pipeline
		Try {
			$SteppablePipeline.End()
		}
		Catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}
	}
}

# create variable for transcript parameters
New-Variable -Name 'TranscriptWithHostAndDate' -Value @{} -Scope 'Script' -Force

# create variable for text output parameters
New-Variable -Name 'TextOutputWithHostAndDate' -Value @{} -Scope 'Script' -Force

# create variable for text output parameters
New-Variable -Name 'TextOutputWithHostAndDatePath' -Value ([string]::Empty) -Scope 'Script' -Force

# define functions to export
$FunctionsToExport = @(
	'Resume-TranscriptWithHostAndDate'
	'Start-TranscriptWithHostAndDate'
	'Suspend-TranscriptWithHostAndDate'
	'Stop-TranscriptWithHostAndDate'
	'Write-Host'
	'Write-Information'
	'Write-Warning'
	'Write-Verbose'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport
