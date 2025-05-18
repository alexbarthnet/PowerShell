#requires -Module FailoverClusters

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# define task name
	[Parameter(DontShow)]
	[string]$TaskName = 'Invoke-ClusterRestart',
	# mode switches
	[Parameter(Mandatory, ParameterSetName = 'Invoke')]
	[switch]$Invoke,
	[Parameter(Mandatory, ParameterSetName = 'Restart')]
	[switch]$Restart,
	[Parameter(Mandatory, ParameterSetName = 'Resume')]
	[switch]$Resume,
	[Parameter(Mandatory, ParameterSetName = 'Start')]
	[switch]$Start,
	[Parameter(Mandatory, ParameterSetName = 'Stop')]
	[switch]$Stop,
	[Parameter(Mandatory, ParameterSetName = 'Suspend')]
	[switch]$Suspend,
	# mode to initiate process
	[Parameter(ParameterSetName = 'Start')]
	[switch]$Suspended,
	# path to state file
	[Parameter(ParameterSetName = 'Start')]
	[string]$Path
)

Begin {
	## begin TranscriptForCommand functions

	Function Start-TranscriptForCommand {
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

		.PARAMETER SkipTextOutput
		Switch parameter to skip creating a text output file.

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
		$StartTranscript = @{
			Path        = Join-Path -Path $TranscriptPath -ChildPath $TranscriptFile
			Force       = $true
			Append      = $true
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# store parameters in module hashtable
		$script:TranscriptParameters[$TranscriptName] = $StartTranscript

		# start transcript quietly
		Try	{
			$null = Start-Transcript @StartTranscript
		}
		Catch {
			Throw $_
		}

		# if skip text requested...
		If ($SkipTextOutput) {
			# clear path of active text output file and return
			$script:TextOutputActivePath = [string]::Empty
			Return
		}

		# define parameters for New-TextOutputFile
		$NewTextOutputFile = @{
			# map transcript name to text output
			TextOutputName = $TranscriptName
			# map transcript time to text output
			TextOutputTime = $TranscriptTime
		}

		# create text output file
		Try	{
			New-TextOutputFile @NewTextOutputFile
		}
		Catch {
			Throw $_
		}
	}

	Function Stop-TranscriptForCommand {
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

		.PARAMETER TimeSpan
		The timespan to define the minimum age of files to be eligible for removal. The default value is '7 days'.

		.PARAMETER MinimumFileCount
		The uint16 to define the count of files that must remain if old transcripts are removed. The removal of old files is skipped if the resulting count of transcript files would be below this value. The default value is '7'.

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
			# timespan for transcript cleanup
			[Parameter(DontShow)]
			[timespan]$TimeSpan = [timespan]::FromDays(7),
			# count of files to remain after transcript cleanup
			[Parameter(DontShow)]
			[uint16]$MinimumFileCount = 7
		)

		# clear path of active text output file
		$script:TextOutputActivePath = [string]::Empty

		# define required parameters for Remove-TextOutputFiles
		$RemoveTextOutputFiles = @{
			TextOutputName = $TranscriptName
		}

		# define optional parameters for Remove-TextOutputFiles
		If ($PSBoundParameters.ContainsKey('TimeSpan')) { $RemoveTextOutputFiles['TimeSpan'] = $TimeSpan }
		If ($PSBoundParameters.ContainsKey('MinimumFileCount')) { $RemoveTextOutputFiles['MinimumFileCount'] = $MinimumFileCount }

		# remove text output files
		Try {
			Remove-TextOutputFiles @RemoveTextOutputFiles
		}
		Catch {
			Write-Warning -Message $_.ToString()
		}

		# define required parameters for Remove-TranscriptFiles
		$RemoveTranscriptFiles = @{
			TranscriptName = $TranscriptName
		}

		# define optional parameters for Remove-TranscriptFiles
		If ($PSBoundParameters.ContainsKey('TimeSpan')) { $RemoveTranscriptFiles['TimeSpan'] = $TimeSpan }
		If ($PSBoundParameters.ContainsKey('MinimumFileCount')) { $RemoveTranscriptFiles['MinimumFileCount'] = $MinimumFileCount }

		# remove transcript files
		Try {
			Remove-TranscriptFiles @RemoveTranscriptFiles
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

	Function Resume-TranscriptForCommand {
		<#
		.SYNOPSIS
		Resumes a PowerShell transcript created by Start-TranscriptForCommand and stored in the module hashtable.

		.DESCRIPTION
		Resumes a PowerShell transcript created by Start-TranscriptForCommand and stored in the module hashtable.

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
		If (!$script:TranscriptParameters.ContainsKey($TranscriptName)) {
			Write-Warning -Message 'could not resume original transcript: the module hashtable does not have a key for the calling script or function'
			Return
		}

		# if value in module hashtable is not a hashtable...
		If ($script:TranscriptParameters[$TranscriptName] -isnot [System.Collections.Hashtable]) {
			Write-Warning -Message 'could not resume original transcript: the value in the module hashtable for the calling script or function is not a hashtable'
			Return
		}

		# retrieve parameters from script variable
		$StartTranscript = $script:TranscriptParameters[$TranscriptName]

		# start transcript quietly
		Try	{
			$null = Start-Transcript @StartTranscript
		}
		Catch {
			Throw $_
		}

		# if module hashtable does not have a key for calling script or function...
		If (!$script:TextOutputParameters.ContainsKey($TranscriptName)) {
			Write-Warning -Message 'could not resume original transcript: the module hashtable does not have a key for the calling script or function'
			Return
		}

		# if value in module hashtable is not a string...
		If ($script:TextOutputParameters[$TranscriptName] -isnot [System.String]) {
			Write-Warning -Message 'could not resume original transcript: the value in the module hashtable for the calling script or function is not a string'
			Return
		}

		# update path of active text output file to value from module hashtable
		$script:TextOutputActivePath = $script:TextOutputParameters[$TranscriptName]
	}

	Function Suspend-TranscriptForCommand {
		<#
		.SYNOPSIS
		Suspends a PowerShell transcript created by Start-TranscriptForCommand and stored in the module hashtable.

		.DESCRIPTION
		Suspends a PowerShell transcript created by Start-TranscriptForCommand and stored in the module hashtable.

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
		If (!$script:TranscriptParameters.ContainsKey($TranscriptName)) {
			Write-Warning -Message 'will not suspend current transcript: the module hashtable does not have a key for the calling script or function'
			Return
		}

		# if value in module hashtable variable is not a hashtable...
		If ($script:TranscriptParameters[$TranscriptName] -isnot [System.Collections.Hashtable]) {
			Write-Warning -Message 'will not suspend current transcript: the value in the module hashtable for the calling script or function is not a hashtable'
			Return
		}

		# clear path of active text output file
		$script:TextOutputActivePath = [string]::Empty

		# stop transcript quietly
		Try	{
			$null = Stop-Transcript
		}
		Catch {
			Throw $_
		}
	}

	Function Remove-TranscriptFiles {
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

		.PARAMETER TimeSpan
		The timespan to define the minimum age of transcript files to be eligible for removal. The default value is '7 days'.

		.PARAMETER MinimumFileCount
		The uint16 to define the count of transcript files that must remain if old transcripts are removed. The removal of old files is skipped if the resulting count of transcript files would be below this value. The default value is '7'.

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
			[timespan]$TimeSpan = [timespan]::FromDays(7),
			# count of files to remain after transcript cleanup
			[Parameter(DontShow)]
			[uint16]$MinimumFileCount = 7
		)

		# if transcript path does not exist...
		If (![System.IO.Directory]::Exists($TranscriptPath)) {
			Write-Warning "could not locate path: $TranscriptPath"
			Return
		}

		# if time span is negative...
		If ($TimeSpan -lt [timespan]::Zero) {
			# flip timespan with negate method
			$TimeSpan = $TimeSpan.Negate()
		}

		# define transcript date
		$TranscriptDate = [datetime]::Now.Subtract($TimeSpan)

		# define filter using default transcript prefix, hostname, and script name
		$TranscriptFilter = "$TranscriptLeaf.$TranscriptHost.$TranscriptName*"

		# declare cleanup thresholds
		Write-Verbose -Message "Removing transcript files from '$TranscriptPath' matching '$TranscriptFilter' with a LastWriteTime before '$($TranscriptDate.ToString('s'))' provided that '$MinimumFileCount' files remain"

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
		If ($FilesToRemain.Count -lt $MinimumFileCount) {
			# declare skip and return
			Write-Verbose -Message "Skipping transcript cleanup: only '$($FilesToRemain.Count)' files would remain"
			Return
		}

		# sort files-to-remove by name then process files
		ForEach ($FileToRemove in ($FilesToRemove | Sort-Object -Property FullName)) {
			# remove file
			Try {
				Remove-Item -Path $FileToRemove.FullName -Force -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not remove transcript file: $($FileToRemove.FullName)"
				Return $_
			}
			# report complete
			Write-Verbose -Message "Removed transcript file: $($FileToRemove.FullName)"
		}
	}

	Function Remove-TextOutputFiles {
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

		.PARAMETER TimeSpan
		The timespan to define the minimum age of text output files to be eligible for removal. The default value is '7 days'.

		.PARAMETER MinimumFileCount
		The uint16 to define the count of text output files that must remain if old text output files are removed. The removal of old files is skipped if the resulting count of text output files would be below this value. The default value is '7'.

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
			[timespan]$TimeSpan = [timespan]::FromDays(7),
			# count of files to remain after text output cleanup
			[Parameter(DontShow)]
			[uint16]$MinimumFileCount = 7
		)

		# if text output path does not exist...
		If (![System.IO.Directory]::Exists($TextOutputPath)) {
			Write-Warning "could not locate path: $TextOutputPath"
			Return
		}

		# if time span is negative...
		If ($TimeSpan -lt [timespan]::Zero) {
			# flip timespan with negate method
			$TimeSpan = $TimeSpan.Negate()
		}

		# define text output date
		$TextOutputDate = [datetime]::Now.Subtract($TimeSpan)

		# define filter using text output leaf, hostname, and script name
		$TextOutputFilter = "$TextOutputLeaf.$TextOutputHost.$TextOutputName*"

		# declare cleanup thresholds
		Write-Verbose -Message "Removing text output files from '$TextOutputPath' matching '$TextOutputFilter' with a LastWriteTime before '$($TextOutputDate.ToString('s'))' provided that '$MinimumFileCount' files remain"

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
		If ($FilesToRemain.Count -lt $MinimumFileCount) {
			# declare skip and return
			Write-Verbose -Message "Skipping text output cleanup: only '$($FilesToRemain.Count)' files would remain"
			Return
		}

		# sort files-to-remove by name then process files
		ForEach ($FileToRemove in ($FilesToRemove | Sort-Object -Property FullName)) {
			# remove file
			Try {
				Remove-Item -Path $FileToRemove.FullName -Force -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not remove text output file: $($FileToRemove.FullName)"
				Return $_
			}
			# report complete
			Write-Verbose -Message "Removed text output file: $($FileToRemove.FullName)"
		}
	}

	Function New-TextOutputFile {
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
		$TextOutputFileName = "$TextOutputLeaf.$TextOutputHost.$TextOutputName.$TextOutputTime.txt"

		# build text output file path
		$TextOutputFilePath = Join-Path -Path $TextOutputPath -ChildPath $TextOutputFileName

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

		# store text output file path in module hashtable
		$script:TextOutputParameters[$TextOutputName] = $TextOutputFilePath

		# update path of active text output file
		$script:TextOutputActivePath = $TextOutputFilePath
	}

	Function Write-TextOutputFile {
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

		.PARAMETER Username
		A string containing a username. The default value is the current hostname.

		.PARAMETER Hostname
		A string containing a hostname. The default value is the current hostname.

		.PARAMETER Datetime
		A string containing a datetime. The default value is the current time in ISO 8601 format.

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
			[string]$Username = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
			# formatted hostname for message
			[Parameter(DontShow)]
			[string]$Hostname = [System.Environment]::MachineName,
			# formatted datetime for message
			[Parameter(DontShow)]
			[string]$Datetime = [System.DateTime]::Now.ToString('yyyy-MM-ddTHH:mm:ss.fff'),
			# path to current text output file
			[Parameter(DontShow)]
			[string]$Path = $script:TextOutputActivePath
		)

		# remove new lines from message
		Try {
			$MessageWithoutNewLines = $Message.Replace("`r`n", ' ').Replace("`n", ' ').Replace("`r", ' ')
		}
		Catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# update message with information prefix and new line suffix
		Try {
			$MessageWithInformation = 'datetime="{0}" hostname="{1}" username="{2}" command="{3}" stream="{4}" message="{5}"{6}' -f $Datetime, $Hostname, $Username, $Command, $Stream, $MessageWithoutNewLines, [System.Environment]::NewLine
		}
		Catch {
			$PSCmdlet.ThrowTerminatingError($_)
		}

		# append message to file
		Try {
			[System.IO.File]::AppendAllText($Path, $MessageWithInformation)
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
			# if text output file exists...
			If ([System.IO.File]::Exists($script:TextOutputActivePath)) {
				# if separator provided...
				If ($PSBoundParameters.ContainsKey('Separator')) {
					# define message as Object joined with Separator
					Try {
						$Message = [System.String]::Join($Separator, $Object)
					}
					Catch {
						$Message = 'could not join Object with Separator'
					}
				}
				# if separater not provided...
				Else {
					# define message as Object cast to string
					Try {
						$Message = $Object -as [System.String]
					}
					Catch {
						$Message = 'could not cast Object to string'
					}
				}

				# write message to text output file
				Try {
					Write-TextOutputFile -Message $Message -Stream 'Information'
				}
				Catch {
					# do nothing
				}
			}

			# process steppable pipeline
			Try {
				$SteppablePipeline.Process($_)
			}
			Catch {
				$PSCmdlet.ThrowTerminatingError($_)
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
			# if text output file exists...
			If ([System.IO.File]::Exists($script:TextOutputActivePath)) {
				# define message as message data cast to string
				Try {
					$Message = $MessageData -as [System.String]
				}
				Catch {
					$Message = 'could not convert MessageData to string'
				}

				# write message to text output file
				Try {
					Write-TextOutputFile -Message $Message -Stream 'Information'
				}
				Catch {
					# do nothing
				}
			}

			# process steppable pipeline
			Try {
				$SteppablePipeline.Process($_)
			}
			Catch {
				$PSCmdlet.ThrowTerminatingError($_)
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
			# if text output file exists...
			If ([System.IO.File]::Exists($script:TextOutputActivePath)) {
				# write message to text output file
				Try {
					Write-TextOutputFile -Message $Message -Stream 'Verbose'
				}
				Catch {
					# do nothing
				}
			}

			# process steppable pipeline
			Try {
				$SteppablePipeline.Process($_)
			}
			Catch {
				$PSCmdlet.ThrowTerminatingError($_)
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
			# if text output file exists...
			If ([System.IO.File]::Exists($script:TextOutputActivePath)) {
				# write message to text output file
				Try {
					Write-TextOutputFile -Message $Message -Stream 'Warning'
				}
				Catch {
					# do nothing
				}
			}

			# process steppable pipeline
			Try {
				$SteppablePipeline.Process($_)
			}
			Catch {
				$PSCmdlet.ThrowTerminatingError($_)
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

	Function Write-Error {
		# [System.Management.Automation.ProxyCommand]::Create([System.Management.Automation.CommandMetaData]::new((Get-Command -Name Write-Error)))

		<#
		.ForwardHelpTargetName Microsoft.PowerShell.Utility\Write-Error
		.ForwardHelpCategory Cmdlet
		#>

		[CmdletBinding(DefaultParameterSetName = 'NoException', HelpUri = 'https://go.microsoft.com/fwlink/?LinkID=113425', RemotingCapability = 'None')]
		param(
			[Parameter(ParameterSetName = 'WithException', Mandatory = $true)]
			[System.Exception]
			${Exception},

			[Parameter(ParameterSetName = 'WithException')]
			[Parameter(ParameterSetName = 'NoException', Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
			[Alias('Msg')]
			[AllowEmptyString()]
			[AllowNull()]
			[string]
			${Message},

			[Parameter(ParameterSetName = 'ErrorRecord', Mandatory = $true)]
			[System.Management.Automation.ErrorRecord]
			${ErrorRecord},

			[Parameter(ParameterSetName = 'NoException')]
			[Parameter(ParameterSetName = 'WithException')]
			[System.Management.Automation.ErrorCategory]
			${Category},

			[Parameter(ParameterSetName = 'WithException')]
			[Parameter(ParameterSetName = 'NoException')]
			[string]
			${ErrorId},

			[Parameter(ParameterSetName = 'NoException')]
			[Parameter(ParameterSetName = 'WithException')]
			[System.Object]
			${TargetObject},

			[string]
			${RecommendedAction},

			[Alias('Activity')]
			[string]
			${CategoryActivity},

			[Alias('Reason')]
			[string]
			${CategoryReason},

			[Alias('TargetName')]
			[string]
			${CategoryTargetName},

			[Alias('TargetType')]
			[string]
			${CategoryTargetType}
		)

		Begin {
			# create steppable pipeline
			Try {
				# get command information from execution context
				$Command = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Utility\Write-Error', [System.Management.Automation.CommandTypes]::Cmdlet)

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
			# if text output file exists...
			If ([System.IO.File]::Exists($script:TextOutputActivePath)) {
				# if Message provided...
				If ($PSCmdlet.ParameterSetName -eq 'NoException') {
					$ErrorMessage = $Message
				}
				# if Exception provided...
				ElseIf ($PSCmdlet.ParameterSetName -eq 'WithException') {
					# if Exception contains an inner exception...
					If ($Exception.InnerException) {
						$ErrorMessage = '[{0}]; {1}' -f $Exception.InnerException.GetType().FullName, $Exception.InnerException.Message
					}
					# if Exception does not contain an inner exception...
					Else {
						$ErrorMessage = '[{0}]; {1}' -f $Exception.GetType().FullName, $Exception.Message
					}
				}
				# if ErrorRecord provided...
				ElseIf ($PSCmdlet.ParameterSetName -eq 'ErrorRecord') {
					# if exception in ErrorRecord contains an inner exception...
					If ($ErrorRecord.Exception.InnerException) {
						$ErrorMessage = '[{0}]; {1}' -f $ErrorRecord.Exception.InnerException.GetType().FullName, $ErrorRecord.Exception.InnerException.Message
					}
					# if exception in ErrorRecord does not contain an inner exception...
					Else {
						$ErrorMessage = '[{0}]; {1}' -f $ErrorRecord.Exception.GetType().FullName, $ErrorRecord.Exception.Message
					}
				}

				# write message to text output file
				Try {
					Write-TextOutputFile -Message $ErrorMessage -Stream 'Error'
				}
				Catch {
					# do nothing
				}
			}

			# process steppable pipeline
			Try {
				$SteppablePipeline.Process($_)
			}
			Catch {
				$PSCmdlet.ThrowTerminatingError($_)
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

	# create variable for parameters of transcript functions
	New-Variable -Name 'TranscriptParameters' -Value @{} -Scope 'Script' -Force

	# create variable for parameters of text output functions
	New-Variable -Name 'TextOutputParameters' -Value @{} -Scope 'Script' -Force

	# create variable for active path of text output file
	New-Variable -Name 'TextOutputActivePath' -Value ([string]::Empty) -Scope 'Script' -Force

	## end TranscriptForCommand functions

	# if default parameter set and skip transcript not requested...
	If ($PSCmdlet.ParameterSetName -eq 'Default' -and -not $SkipTranscript) {
		# start transcript with default parameters and skip text output if requested
		Try {
			Start-TranscriptForCommand -SkipTextOutput:$SkipTextOutput
		}
		Catch {
			Throw $_
		}
	}
}

Process {
	# start
	If ($Start) {
		################################################
		# check cluster state before starting
		################################################

		# retrieve cluster nodes
		Try {
			$ClusterNodes = Get-ClusterNode | Sort-Object -Property NodeName
		}
		Catch {
			Write-Warning -Message "could not retrieve local cluster nodes: $($_.Exception.Message)"
			Return $_
		}

		# get nodes with state other than Up
		$NodesThatAreNotUp = $ClusterNodes | Where-Object { $_.State -ne [Microsoft.FailoverClusters.PowerShell.ClusterNodeState]::Up }

		# if any nodes are not Up...
		If ($NodesThatAreNotUp) {
			Write-Warning -Message "found one or more nodes not in the 'Up' state: $($NodesThatAreNotUp.NodeName)"
			Return
		}

		# get nodes with status other than Normal
		$NodesThatAreNotNormal = $ClusterNodes | Where-Object { $_.State -ne [Microsoft.FailoverClusters.PowerShell.ClusterNodeStatusInformation]::Normal }

		# if any nodes are not Normal...
		If ($NodesThatAreNotNormal) {
			Write-Warning -Message "found one or more nodes not in the 'Normal' status: $($NodesThatAreNotNormal.NodeName)"
			Return
		}

		################################################
		# check script path before starting
		################################################

		# if Path not provided...
		If (!$PSBoundParameters.ContainsKey('Path')) {
			# retrieve script path
			$Path = $MyInvocation.MyCommand.Path
		}

		# define boolean
		$PathIsNotValid = $false

		# loop through cluster nodes
		ForEach ($ClusterNode in $ClusterNodes) {
			# if cluster node is not local computer...
			If ($ClusterNode.NodeName -ne $env:COMPUTERNAME) {
				# check remote computer for script
				Try {
					$NotFound = Invoke-Command -ComputerName $ClusterNode.NodeName -ScriptBlock { ![System.IO.File]::Exists($using:Path) }
				}
				Catch {
					Write-Warning -Message "could not check '$($ClusterNode.NodeName)' cluster node for '$Path' path: $($_.Exception.Message)"
					Return $_
				}

				# if script not found...
				If ($NotFound) {
					Write-Warning -Message "could not locate script on '$($ClusterNode.NodeName)' cluster node with '$Path' path"
					$PathIsNotValid = $true
				}
			}
		}

		# if path is not valid on one or more nodes...
		If ($PathIsNotValid) {
			Write-Warning -Message 'this script MUST be available on every cluster node to continue'
			Return
		}

		################################################
		# create state objects
		################################################

		# create list for state objects
		Try {
			$ClusterState = [System.Collections.Generic.List[object]]::new()
		}
		Catch {
			Write-Warning -Message "could not create list for state objects: $($_.Exception.Message)"
			Return $_
		}

		# loop through cluster nodes
		ForEach ($ClusterNode in $ClusterNodes) {
			# create state object for cluster node
			$ClusterNodeState = [PSCustomObject]@{
				Name  = $ClusterNode.NodeName
				State = [string]::Empty
			}

			# add state object to list
			$ClusterState.Add($ClusterNodeState)
		}

		# create task description from state object
		Try {
			$Description = $ClusterState | Sort-Object -Property 'Name' | ConvertTo-Json -Compress -Depth 100
		}
		Catch {
			Write-Warning -Message "could not convert cluster state object to JSON: $($_.Exception.Message)"
			Return $_
		}

		################################################
		# create scheduled task
		################################################

		# define task action
		$ScheduledTaskAction = @{
			Execute  = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
			Argument = '-NonInteractive -NoProfile -ExecutionPolicy ByPass -File "{0}" -Invoke' -f $Path
		}

		# create task action
		Try {
			$Action = New-ScheduledTaskAction @ScheduledTaskAction
		}
		Catch {
			Write-Warning -Message "could not create scheduled task action object: $($_.Exception.Message)"
			Return $_
		}

		# if suspended start requested...
		If ($PSBoundParameters.ContainsKey('Suspended')) {
			# define task settings with task disabled
			$ScheduledTaskSettingsSet = @{ Disable = $true }
		}
		Else {
			# define task settings with task enabled
			$ScheduledTaskSettingsSet = @{ Disable = $false }
		}

		# create task settings
		Try {
			$Settings = New-ScheduledTaskSettingsSet @ScheduledTaskSettingsSet
		}
		Catch {
			Write-Warning -Message "could not create scheduled task settings object: $($_.Exception.Message)"
			Return $_
		}


		# define task trigger
		$ScheduledTaskTrigger = @{
			# run immediately
			At                 = [System.Datetime]::Now
			# run every minute
			RepetitionInterval = [System.Timespan]::FromMinutes(1)
			# run for (node count * days) to permit a day for storage jobs
			RepetitionDuration = [System.Timespan]::FromDays($ClusterNodes.Count)
		}

		# create task trigger
		Try {
			$Trigger = New-ScheduledTaskTrigger @ScheduledTaskTrigger
		}
		Catch {
			Write-Warning -Message "could not create scheduled task trigger object: $($_.Exception.Message)"
			Return $_
		}

		# define parameters
		$ClusteredScheduledTask = @{
			TaskName    = $TaskName
			TaskType    = 'ClusterWide'
			Action      = $Action
			Settings    = $Settings
			Trigger     = $Trigger
			Description = $Description
		}

		# create scheduled task
		Try {
			Register-ClusteredScheduledTask @ClusteredScheduledTask
		}
		Catch {
			Write-Warning -Message "could not register '$TaskName' clustered scheduled task: $($_.Exception.Message)"
			Return $_
		}

		# report state and return
		Write-Host "registered '$TaskName' clustered scheduled task"
		Return
	}

	# stop
	If ($Stop) {
		# retrieve clustered scheduled task for cluster
		Try {
			$ClusteredScheduledTask = Get-ClusteredScheduledTask -TaskName $TaskName -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not call function to retrieve '$TaskName' clustered scheduled task: $($_.Exception.Message)"
			Return $_
		}

		# if clustered scheduled task not found...
		If ($null -eq $ClusteredScheduledTask) {
			Write-Warning -Message "could not locate '$TaskName' clustered scheduled task"
			Return
		}

		# remove scheduled task
		Try {
			Unregister-ClusteredScheduledTask -TaskName $TaskName
		}
		Catch {
			Write-Warning -Message "could not unregister '$TaskName' clustered scheduled task: $($_.Exception.Message)"
			Return $_
		}
	}

	# pause
	If ($Pause) {
		# retrieve clustered scheduled task for cluster
		Try {
			$ClusteredScheduledTask = Get-ClusteredScheduledTask -TaskName $TaskName -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not call function to retrieve '$TaskName' clustered scheduled task: $($_.Exception.Message)"
			Return $_
		}

		# if clustered scheduled task not found...
		If ($null -eq $ClusteredScheduledTask) {
			Write-Warning -Message "could not locate '$TaskName' clustered scheduled task"
			Return
		}

		# if clustered scheduled task is not enabled...
		If ($ClusteredScheduledTask.TaskDefinition.Settings.Enabled -eq $false) {
			Write-Warning -Message "found '$TaskName' clustered scheduled task already disabled (paused)"
			Return
		}

		# define task settings
		$ScheduledTaskSettingsSet = @{
			Disable = $true
		}

		# create task settings
		Try {
			$Settings = New-ScheduledTaskSettingsSet @ScheduledTaskSettingsSet
		}
		Catch {
			Write-Warning -Message "could not create scheduled task settings object: $($_.Exception.Message)"
			Return $_
		}

		# update scheduled task
		Try {
			Set-ClusteredScheduledTask -TaskName $TaskName -Settings $Settings
		}
		Catch {
			Write-Warning -Message "could not update and disable '$TaskName' clustered scheduled task: $($_.Exception.Message)"
			Return $_
		}
	}

	# resume
	If ($Resume) {
		# retrieve clustered scheduled task for cluster
		Try {
			$ClusteredScheduledTask = Get-ClusteredScheduledTask -TaskName $TaskName -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not call function to retrieve '$TaskName' clustered scheduled task: $($_.Exception.Message)"
			Return $_
		}

		# if clustered scheduled task not found...
		If ($null -eq $ClusteredScheduledTask) {
			Write-Warning -Message "could not locate '$TaskName' clustered scheduled task"
			Return
		}

		# if clustered scheduled task is not enabled...
		If ($ClusteredScheduledTask.TaskDefinition.Settings.Enabled -eq $true) {
			Write-Warning -Message "found '$TaskName' clustered scheduled task already enabled (active)"
			Return
		}

		# define task settings
		$ScheduledTaskSettingsSet = @{
			Disable = $false
		}

		# create task settings
		Try {
			$Settings = New-ScheduledTaskSettingsSet @ScheduledTaskSettingsSet
		}
		Catch {
			Write-Warning -Message "could not create scheduled task settings object: $($_.Exception.Message)"
			Return $_
		}

		# update scheduled task
		Try {
			Set-ClusteredScheduledTask -TaskName $TaskName -Settings $Settings
		}
		Catch {
			Write-Warning -Message "could not update and enable '$TaskName' clustered scheduled task: $($_.Exception.Message)"
			Return $_
		}
	}

	# restart
	If ($Restart) {
		# retrieve clustered scheduled task for cluster
		Try {
			$ClusteredScheduledTask = Get-ClusteredScheduledTask -TaskName $TaskName -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not call function to retrieve '$TaskName' clustered scheduled task: $($_.Exception.Message)"
			Return $_
		}

		# if clustered scheduled task not found...
		If ($null -eq $ClusteredScheduledTask) {
			Write-Warning -Message "could not locate '$TaskName' clustered scheduled task"
			Return
		}

		################################################
		# create state objects
		################################################

		# create list for state objects
		Try {
			$ClusterState = [System.Collections.Generic.List[object]]::new()
		}
		Catch {
			Write-Warning -Message "could not create list for state objects: $($_.Exception.Message)"
			Return $_
		}

		# loop through cluster nodes
		ForEach ($ClusterNode in $ClusterNodes) {
			# create state object for cluster node
			$ClusterNodeState = [PSCustomObject]@{
				Name  = $ClusterNode.NodeName
				State = [string]::Empty
			}

			# add state object to list
			$ClusterState.Add($ClusterNodeState)
		}

		# create task description from state object
		Try {
			$Description = $ClusterState | Sort-Object -Property 'Name' | ConvertTo-Json -Compress -Depth 100
		}
		Catch {
			Write-Warning -Message "could not convert cluster state object to JSON: $($_.Exception.Message)"
			Return $_
		}

		# update description of clustered scheduled task
		Try {
			Set-ClusteredScheduledTask -TaskName $TaskName -Description $Description
		}
		Catch {
			Write-Warning -Message "could not update '$TaskName' clustered scheduled task: $($_.Exception.Message)"
			Return $_
		}

	}

	# invoke
	If ($Invoke) {
		################################################
		# retrieve stored state for cluster from task
		################################################

		# retrieve clustered scheduled task for cluster
		Try {
			$ClusteredScheduledTask = Get-ClusteredScheduledTask -TaskName $TaskName -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not call function to retrieve '$TaskName' clustered scheduled task: $($_.Exception.Message)"
			Return $_
		}

		# if clustered scheduled task not found...
		If ($null -eq $ClusteredScheduledTask) {
			Write-Warning -Message "could not locate '$TaskName' clustered scheduled task"
			Return
		}

		# if description is empty...
		If ([string]::IsNullOrEmpty($ClusteredScheduledTask.Description)) {
			# warn and return
			Write-Warning -Message "found empty description on '$TaskName' clustered scheduled task"
			Return
		}

		# retrieve cluster state object from scheduled task description
		Try {
			$ClusterState = ConvertFrom-Json -InputObject $ClusteredScheduledTask.Description -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not convert description of scheduled task to JSON: $($_.Exception.Message)"
			Return $_
		}

		################################################
		# filter stored state to first incomplete node
		################################################

		# get stored state of first node that has not reached the Complete state
		$CurrentNode = $ClusterState | Sort-Object -Property 'Name' | Where-Object { $_.State -ne 'Complete' } | Select-Object -First 1

		# if no nodes have not reached the Complete state...
		If ($null -eq $CurrentNode) {
			# unregister scheduled task?

			# declare complete and return
			Write-Host 'all cluster nodes have restarted; exiting!'
			Return
		}

		# if current node name is not local computer name...
		If ($CurrentNode.Name -ne $env:COMPUTERNAME) {
			# declare not current and return
			Write-Host 'local computer is not current node; exiting!'
			Return
		}

		# get active state of cluster node
		Try {
			$ClusterNode = Get-ClusterNode -Name $env:COMPUTERNAME
		}
		Catch {
			Write-Warning -Message "could not retrieve active state of '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
			Return $_
		}

		################################################
		# if current node state is empty...
		################################################

		# if stored state of current node is empty...
		If ([string]::IsNullOrEmpty($CurrentNode.State)) {
			# if active state of current node is not up...
			If ($ClusterNode.State -ne [Microsoft.FailoverClusters.PowerShell.ClusterNodeState]::Up ) {
				Write-Warning -Message "the '$env:COMPUTERNAME' cluster node should have 'Up' state; found unexpected state: $($ClusterNode.State)"
				Return
			}

			# if status is not Normal...
			If ($ClusterNode.StatusInformation -ne [Microsoft.FailoverClusters.PowerShell.ClusterNodeStatusInformation]::Normal) {
				Write-Warning -Message "the '$env:COMPUTERNAME' cluster node should have 'Normal' status; found unexpected status: $($ClusterNode.StatusInformation)"
				Return
			}

			# define boolean
			$StorageJobsFound = $false

			# retrieve storage jobs for storage pool
			Try {
				$StorageJobs = Get-StorageJob
			}
			Catch {
				Write-Warning -Message "could not retrieve storage jobs on '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				Return $_
			}

			# loop through storage jobs
			ForEach ($StorageJob in $StorageJobs) {
				# udpate boolean
				$StorageJobsFound = $true

				# report active job
				Write-Host "found active storage job: $($StorageJob.Name)"
			}

			# if any storage jobs found...
			If ($StorageJobsFound) {
				Write-Host "waiting for storage jobs to complete on '$env:COMPUTERNAME' cluster node before STARTING restart cycle"
				Return
			}

			# suspend current node
			Try {
				Suspend-ClusterNode -Drain -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not suspend '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				Return $_
			}

			# declare state
			Write-Host "suspended '$env:COMPUTERNAME' cluster node"

			# update state of current node
			$CurrentNode.State = 'Paused'

			# create task description from state object
			Try {
				$Description = $ClusterState | Sort-Object -Property 'Name' | ConvertTo-Json -Compress -Depth 100
			}
			Catch {
				Write-Warning -Message "could not convert cluster state object to JSON: $($_.Exception.Message)"
				Return $_
			}

			# update description of clustered scheduled task
			Try {
				Set-ClusteredScheduledTask -TaskName $TaskName -Description $Description
			}
			Catch {
				Write-Warning -Message "could not update '$TaskName' clustered scheduled task: $($_.Exception.Message)"
				Return $_
			}

			# return
			Return
		}

		################################################
		# if current node state is Paused...
		################################################

		# if stored state of current node is paused...
		If ($CurrentNode.State -eq 'Paused') {
			# if active state of current node is not Paused...
			If ($ClusterNode.State -ne [Microsoft.FailoverClusters.PowerShell.ClusterNodeState]::Paused ) {
				Write-Warning -Message "the '$env:COMPUTERNAME' cluster node should have 'Paused' state; found unexpected state: $($ClusterNode.State)"
				Return
			}

			# if drain not complete...
			If ($ClusterNode.StatusInformation -ne [Microsoft.FailoverClusters.PowerShell.ClusterNodeStatusInformation]::DrainCompleted) {
				Write-Host "waiting for drain to complete on '$env:COMPUTERNAME' cluster node, current state: $($ClusterNode.StatusInformation)"
				Return
			}

			# update state of current node
			$CurrentNode.State = 'Restarted'

			# create task description from state object
			Try {
				$Description = $ClusterState | Sort-Object -Property 'Name' | ConvertTo-Json -Compress -Depth 100
			}
			Catch {
				Write-Warning -Message "could not convert cluster state object to JSON: $($_.Exception.Message)"
				Return $_
			}

			# update description of clustered scheduled task
			Try {
				Set-ClusteredScheduledTask -TaskName $TaskName -Description $Description
			}
			Catch {
				Write-Warning -Message "could not update '$TaskName' clustered scheduled task: $($_.Exception.Message)"
				Return $_
			}

			# restart computer
			Try {
				Restart-Computer -Force
			}
			Catch {
				Write-Warning -Message "could not restart '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
			}

			# update state of current node
			$CurrentNode.State = 'RestartFailed'

			# create task description from state object
			Try {
				$Description = $ClusterState | Sort-Object -Property 'Name' | ConvertTo-Json -Compress -Depth 100
			}
			Catch {
				Write-Warning -Message "could not convert cluster state object to JSON: $($_.Exception.Message)"
				Return $_
			}

			# update description of clustered scheduled task
			Try {
				Set-ClusteredScheduledTask -TaskName $TaskName -Description $Description
			}
			Catch {
				Write-Warning -Message "could not update '$TaskName' clustered scheduled task: $($_.Exception.Message)"
				Return $_
			}

			# return
			Return
		}

		################################################
		# if current node state is Restarted...
		################################################

		# if stored state of current node is Restarted...
		If ($CurrentNode.State -eq 'Restarted') {
			# if node is not Paused...
			If ($ClusterNode.State -ne [Microsoft.FailoverClusters.PowerShell.ClusterNodeState]::Paused ) {
				Write-Warning -Message "the '$env:COMPUTERNAME' cluster node should have 'Paused' state; found unexpected state: $($ClusterNode.State)"
				Return
			}

			# retrieve clustered scheduled task start time
			Try {
				$StartBoundary = $ClusteredScheduledTask.TaskDefinition.Triggers.StartBoundary -as [datetime]
			}
			Catch {
				Write-Warning -Message "could not retrieve start boundary as datetime for '$TaskName' clustered scheduled task: $($_.Exception.Message)"
				Return $_
			}

			# retrieve last boot time
			Try {
				$LastBootUpTime = (Get-CimInstance -ClassName 'Win32_OperatingSystem' -Property 'LastBootUpTime').LastBootUpTime
			}
			Catch {
				Write-Warning -Message "could not retrieve last boot time for '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				Return $_
			}

			# if last boot time is before scheduled task start time...
			If ($LastBootUpTime -lt $StartBoundary) {
				Write-Warning -Message "found '$env:COMPUTERNAME' cluster node in 'Restarted' state despite a last boot up time of '$LastBootUpTime' which is before the start time for '$TaskName' clustered scheduled task of '$StartBoundary'"
				Return
			}

			# update state of current node
			$CurrentNode.State = 'Resumed'

			# resume current node
			Try {
				Resume-ClusterNode -Failback 'NoFailback' -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not suspend '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				Return $_
			}

			# declare state
			Write-Host "resumed '$env:COMPUTERNAME' cluster node"

			# update state of current node
			$CurrentNode.State = 'Resumed'

			# create task description from state object
			Try {
				$Description = $ClusterState | Sort-Object -Property 'Name' | ConvertTo-Json -Compress -Depth 100
			}
			Catch {
				Write-Warning -Message "could not convert cluster state object to JSON: $($_.Exception.Message)"
				Return $_
			}

			# update description of clustered scheduled task
			Try {
				Set-ClusteredScheduledTask -TaskName $TaskName -Description $Description
			}
			Catch {
				Write-Warning -Message "could not update '$TaskName' clustered scheduled task: $($_.Exception.Message)"
				Return $_
			}

			# return
			Return
		}

		################################################
		# if current node state is Resumed...
		################################################

		# if stored state of current node is Resumed...
		If ($CurrentNode.State -eq 'Resumed') {
			# if node is not Up...
			If ($ClusterNode.State -ne [Microsoft.FailoverClusters.PowerShell.ClusterNodeState]::Up ) {
				Write-Warning -Message "the '$env:COMPUTERNAME' cluster node should have 'Up' state; found unexpected state: $($ClusterNode.State)"
				Return
			}

			# if status is not Normal...
			If ($ClusterNode.StatusInformation -ne [Microsoft.FailoverClusters.PowerShell.ClusterNodeStatusInformation]::Normal) {
				Write-Warning -Message "the '$env:COMPUTERNAME' cluster node should have 'Normal' status; found unexpected status: $($ClusterNode.StatusInformation)"
				Return
			}

			# define boolean
			$StorageJobsFound = $false

			# retrieve storage jobs for storage pool
			Try {
				$StorageJobs = Get-StorageJob
			}
			Catch {
				Write-Warning -Message "could not retrieve storage jobs on '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				Return $_
			}

			# loop through storage jobs
			ForEach ($StorageJob in $StorageJobs) {
				# udpate boolean
				$StorageJobsFound = $true

				# report active job
				Write-Host "found active storage job: $($StorageJob.Name)"
			}

			# if any storage jobs found...
			If ($StorageJobsFound) {
				Write-Host "waiting for storage jobs to complete on '$env:COMPUTERNAME' cluster node before COMPLETING restart cycle"
				Return
			}

			# update state of current node
			$CurrentNode.State = 'Complete'

			# declare state
			Write-Host "completed restart of '$env:COMPUTERNAME' cluster node"

			# create task description from state object
			Try {
				$Description = $ClusterState | Sort-Object -Property 'Name' | ConvertTo-Json -Compress -Depth 100
			}
			Catch {
				Write-Warning -Message "could not convert cluster state object to JSON: $($_.Exception.Message)"
				Return $_
			}

			# update description of clustered scheduled task
			Try {
				Set-ClusteredScheduledTask -TaskName $TaskName -Description $Description
			}
			Catch {
				Write-Warning -Message "could not update '$TaskName' clustered scheduled task: $($_.Exception.Message)"
				Return $_
			}

			# return
			Return
		}
	}
}