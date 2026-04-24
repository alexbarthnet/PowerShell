#requires -Module FailoverClusters

[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
	# mode switches
	[Parameter(Mandatory, ParameterSetName = 'Start')]
	[switch]$Start,
	[Parameter(Mandatory, ParameterSetName = 'Stop')]
	[switch]$Stop,
	[Parameter(Mandatory, ParameterSetName = 'Restart')]
	[switch]$Restart,
	[Parameter(Mandatory, ParameterSetName = 'Suspend')]
	[switch]$Suspend,
	[Parameter(Mandatory, ParameterSetName = 'Resume')]
	[switch]$Resume,
	[Parameter(Mandatory, ParameterSetName = 'Report')]
	[switch]$Report,
	# path to state file
	[Parameter(ParameterSetName = 'Start')]
	[string]$Path,
	# mode to initiate process
	[Parameter(ParameterSetName = 'Start')]
	[Parameter(ParameterSetName = 'Restart')]
	[switch]$Suspended,
	# time between scheduled task runs; default is 1 minute and must be 1 minute or greater
	[Parameter(ParameterSetName = 'Start')]
	[Parameter(ParameterSetName = 'Restart')]
	[ValidateScript({ $_ -ge [timespan]::FromMinutes(1) })]
	[timespan]$RepetitionInterval = [timespan]::FromMinutes(1),
	# define cluster task name
	[Parameter(DontShow)]
	[string]$ClusterTaskName = 'Invoke-ClusterRestart',
	# define cluster task name
	[Parameter(DontShow)]
	[string]$NodeTaskName = 'Unblock-ClusterRestart',
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipClusteredStorageCheck,
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipTranscript,
	# switch to skip text output logging
	[Parameter(DontShow)]
	[switch]$SkipTextOutput
)

begin {
	function Test-ClusterForStorageJobs {
		# retrieve storage jobs for storage pool
		try {
			$StorageJobs = Get-StorageJob | Where-Object { $_.JobState -ne 'Completed' }
		}
		catch {
			Write-Warning -Message "could not retrieve storage jobs on '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
			return $_
		}

		# if storage jobs found...
		if ($StorageJobs) {
			# report count of storage jobs
			Write-Host "found '$($StorageJobs.Count)' storage job(s) on '$env:COMPUTERNAME' cluster node"

			# loop through storage jobs
			foreach ($StorageJob in $StorageJobs) {
				# report active job
				Write-Host " - Name: $($StorageJob.Name); State: $($StorageJob.JobState); Percent Complete: $($StorageJob.PercentComplete)"
			}

			# return true after reporting
			return $true
		}
		# if storage jobs not found...
		else {
			# return false
			return $false
		}
	}

	function Test-ClusterForIncorrectStateOrStatus {
		param(
			[Microsoft.FailoverClusters.PowerShell.ClusterNodeState]$State,
			[Microsoft.FailoverClusters.PowerShell.ClusterNodeStatusInformation]$Status,
			[string]$NodeName
		)

		# if node name provided...
		if ($PSBoundParameters.ContainsKey('NodeName')) {
			# test specific cluster node
			$ClusterNodesToTest = $ClusterNodes | Where-Object { $_.NodeName -eq $NodeName }
		}
		else {
			# test all cluster nodes
			$ClusterNodesToTest = $ClusterNodes
		}

		# define boolean for state
		$IncorrectState = $false

		# check state against cluster nodes
		foreach ($ClusterNode in $ClusterNodesToTest) {
			if ($ClusterNode.State -ne $State) {
				# warn and update boolean
				Write-Warning -Message "found '$($ClusterNode.NodeName)' cluster node in $($ClusterNode.State) state instead of requested '$State' state"
				$IncorrectState = $true
			}
		}

		# define boolean for status
		$IncorrectStatus = $false

		# check status against cluster nodes
		foreach ($ClusterNode in $ClusterNodesToTest) {
			if ($ClusterNode.StatusInformation -ne $Status) {
				# warn and update boolean
				Write-Warning -Message "found '$($ClusterNode.NodeName)' cluster node with $($ClusterNode.StatusInformation) status instead of requested '$Status' status"
				$IncorrectStatus = $true
			}
		}

		# if state or status are incorrect...
		if ($IncorrectState -or $IncorrectStatus) {
			return $true
		}
		else {
			return $false
		}
	}

	# if default parameter set and skip transcript not requested...
	if ($PSCmdlet.ParameterSetName -eq 'Default' -and -not $SkipTranscript) {
		################################################
		# begin TranscriptForCommand module
		################################################

		function Start-TranscriptForCommand {
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

			param(
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
			if (!(Test-Path -Path $TranscriptPath -PathType 'Container')) {
				# define parameters for New-Item
				$NewItem = @{
					Path        = $TranscriptPath
					ItemType    = 'Directory'
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}

				# create transcript path
				try {
					$null = New-Item @NewItem
				}
				catch {
					throw $_
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
			try	{
				$null = Start-Transcript @StartTranscript
			}
			catch {
				throw $_
			}

			# if skip text requested...
			if ($SkipTextOutput) {
				# clear path of active text output file and return
				$script:TextOutputActivePath = [string]::Empty
				return
			}

			# define parameters for New-TextOutputFile
			$NewTextOutputFile = @{
				# map transcript name to text output
				TextOutputName = $TranscriptName
				# map transcript time to text output
				TextOutputTime = $TranscriptTime
			}

			# create text output file
			try	{
				New-TextOutputFile @NewTextOutputFile
			}
			catch {
				throw $_
			}
		}

		function Stop-TranscriptForCommand {
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

			param(
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
			if ($PSBoundParameters.ContainsKey('TimeSpan')) { $RemoveTextOutputFiles['TimeSpan'] = $TimeSpan }
			if ($PSBoundParameters.ContainsKey('MinimumFileCount')) { $RemoveTextOutputFiles['MinimumFileCount'] = $MinimumFileCount }

			# remove text output files
			try {
				Remove-TextOutputFiles @RemoveTextOutputFiles
			}
			catch {
				Write-Warning -Message $_.ToString()
			}

			# define required parameters for Remove-TranscriptFiles
			$RemoveTranscriptFiles = @{
				TranscriptName = $TranscriptName
			}

			# define optional parameters for Remove-TranscriptFiles
			if ($PSBoundParameters.ContainsKey('TimeSpan')) { $RemoveTranscriptFiles['TimeSpan'] = $TimeSpan }
			if ($PSBoundParameters.ContainsKey('MinimumFileCount')) { $RemoveTranscriptFiles['MinimumFileCount'] = $MinimumFileCount }

			# remove transcript files
			try {
				Remove-TranscriptFiles @RemoveTranscriptFiles
			}
			catch {
				Write-Warning -Message $_.ToString()
			}

			# stop transcript quietly
			try {
				$null = Stop-Transcript
			}
			catch {
				throw $_
			}
		}

		function Resume-TranscriptForCommand {
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

			param(
				# name for transcript items; default is sanitized name of calling script or function
				[Parameter(Position = 0)]
				[string]$TranscriptName = (Get-PSCallStack)[0].Command -replace '^<|\.ps1$|>$'
			)

			# if module hashtable does not have a key for calling script or function...
			if (!$script:TranscriptParameters.ContainsKey($TranscriptName)) {
				Write-Warning -Message 'could not resume original transcript: the module hashtable does not have a key for the calling script or function'
				return
			}

			# if value in module hashtable is not a hashtable...
			if ($script:TranscriptParameters[$TranscriptName] -isnot [System.Collections.Hashtable]) {
				Write-Warning -Message 'could not resume original transcript: the value in the module hashtable for the calling script or function is not a hashtable'
				return
			}

			# retrieve parameters from script variable
			$StartTranscript = $script:TranscriptParameters[$TranscriptName]

			# start transcript quietly
			try	{
				$null = Start-Transcript @StartTranscript
			}
			catch {
				throw $_
			}

			# if module hashtable does not have a key for calling script or function...
			if (!$script:TextOutputParameters.ContainsKey($TranscriptName)) {
				Write-Warning -Message 'could not resume original transcript: the module hashtable does not have a key for the calling script or function'
				return
			}

			# if value in module hashtable is not a string...
			if ($script:TextOutputParameters[$TranscriptName] -isnot [System.String]) {
				Write-Warning -Message 'could not resume original transcript: the value in the module hashtable for the calling script or function is not a string'
				return
			}

			# update path of active text output file to value from module hashtable
			$script:TextOutputActivePath = $script:TextOutputParameters[$TranscriptName]
		}

		function Suspend-TranscriptForCommand {
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

			param(
				# name for transcript items; default is sanitized name of calling script or function
				[Parameter(Position = 0)]
				[string]$TranscriptName = (Get-PSCallStack)[0].Command -replace '^<|\.ps1$|>$'
			)

			# if module hashtable does not have a key for calling script or function...
			if (!$script:TranscriptParameters.ContainsKey($TranscriptName)) {
				Write-Warning -Message 'will not suspend current transcript: the module hashtable does not have a key for the calling script or function'
				return
			}

			# if value in module hashtable variable is not a hashtable...
			if ($script:TranscriptParameters[$TranscriptName] -isnot [System.Collections.Hashtable]) {
				Write-Warning -Message 'will not suspend current transcript: the value in the module hashtable for the calling script or function is not a hashtable'
				return
			}

			# clear path of active text output file
			$script:TextOutputActivePath = [string]::Empty

			# stop transcript quietly
			try	{
				$null = Stop-Transcript
			}
			catch {
				throw $_
			}
		}

		function Remove-TranscriptFiles {
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

			param(
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
			if (![System.IO.Directory]::Exists($TranscriptPath)) {
				Write-Warning "could not locate path: $TranscriptPath"
				return
			}

			# if time span is negative...
			if ($TimeSpan -lt [timespan]::Zero) {
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
			try {
				$TranscriptFiles = Get-ChildItem -Path $TranscriptPath -Filter $TranscriptFilter -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message 'could not retrieve transcript files'
				return $_
			}

			# split transcript files into files-to-remain and files-to-remove based upon LastWriteTime
			try {
				$FilesToRemain, $FilesToRemove = $TranscriptFiles.Where({ $_.LastWriteTime -ge $TranscriptDate }, [System.Management.Automation.WhereOperatorSelectionMode]::Split)
			}
			catch {
				Write-Warning -Message 'could not split transcript files by LastWriteTime'
				return $_
			}

			# if count of files-to-remain is than minimum file count...
			if ($FilesToRemain.Count -lt $MinimumFileCount) {
				# declare skip and return
				Write-Verbose -Message "Skipping transcript cleanup: only '$($FilesToRemain.Count)' files would remain"
				return
			}

			# sort files-to-remove by name then process files
			foreach ($FileToRemove in ($FilesToRemove | Sort-Object -Property FullName)) {
				# remove file
				try {
					Remove-Item -Path $FileToRemove.FullName -Force -ErrorAction 'Stop'
				}
				catch {
					Write-Warning -Message "could not remove transcript file: $($FileToRemove.FullName)"
					return $_
				}
				# report complete
				Write-Verbose -Message "Removed transcript file: $($FileToRemove.FullName)"
			}
		}

		function Remove-TextOutputFiles {
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

			param(
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
			if (![System.IO.Directory]::Exists($TextOutputPath)) {
				Write-Warning "could not locate path: $TextOutputPath"
				return
			}

			# if time span is negative...
			if ($TimeSpan -lt [timespan]::Zero) {
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
			try {
				$TextOutputFiles = Get-ChildItem -Path $TextOutputPath -Filter $TextOutputFilter -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message 'could not retrieve text output files'
				return $_
			}

			# split text output files into files-to-remain and files-to-remove based upon LastWriteTime
			try {
				$FilesToRemain, $FilesToRemove = $TextOutputFiles.Where({ $_.LastWriteTime -ge $TextOutputDate }, [System.Management.Automation.WhereOperatorSelectionMode]::Split)
			}
			catch {
				Write-Warning -Message 'could not split text output files by LastWriteTime'
				return $_
			}

			# if count of files-to-remain is than minimum file count...
			if ($FilesToRemain.Count -lt $MinimumFileCount) {
				# declare skip and return
				Write-Verbose -Message "Skipping text output cleanup: only '$($FilesToRemain.Count)' files would remain"
				return
			}

			# sort files-to-remove by name then process files
			foreach ($FileToRemove in ($FilesToRemove | Sort-Object -Property FullName)) {
				# remove file
				try {
					Remove-Item -Path $FileToRemove.FullName -Force -ErrorAction 'Stop'
				}
				catch {
					Write-Warning -Message "could not remove text output file: $($FileToRemove.FullName)"
					return $_
				}
				# report complete
				Write-Verbose -Message "Removed text output file: $($FileToRemove.FullName)"
			}
		}

		function New-TextOutputFile {
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

			param(
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
			if (!(Test-Path -Path $TextOutputPath -PathType 'Container')) {
				# define parameters for New-Item
				$NewItem = @{
					Path        = $TextOutputPath
					ItemType    = 'Directory'
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}

				# create text output path
				try {
					$null = New-Item @NewItem
				}
				catch {
					throw $_
				}
			}

			# build text output file name with defined prefix, hostname, text output name and current datetime
			$TextOutputFileName = "$TextOutputLeaf.$TextOutputHost.$TextOutputName.$TextOutputTime.txt"

			# build text output file path
			$TextOutputFilePath = Join-Path -Path $TextOutputPath -ChildPath $TextOutputFileName

			# verify text output file
			if (!(Test-Path -Path $TextOutputFilePath -PathType 'Leaf')) {
				# define parameters for New-Item
				$NewItem = @{
					Path        = $TextOutputFilePath
					ItemType    = 'File'
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}

				# create text output file
				try {
					$null = New-Item @NewItem
				}
				catch {
					throw $_
				}
			}

			# store text output file path in module hashtable
			$script:TextOutputParameters[$TextOutputName] = $TextOutputFilePath

			# update path of active text output file
			$script:TextOutputActivePath = $TextOutputFilePath
		}

		function Write-TextOutputFile {
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

			param(
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
			try {
				$MessageWithoutNewLines = $Message.Replace("`r`n", ' ').Replace("`n", ' ').Replace("`r", ' ')
			}
			catch {
				$PSCmdlet.ThrowTerminatingError($_)
			}

			# update message with information prefix and new line suffix
			try {
				$MessageWithInformation = 'datetime="{0}" hostname="{1}" username="{2}" command="{3}" stream="{4}" message="{5}"{6}' -f $Datetime, $Hostname, $Username, $Command, $Stream, $MessageWithoutNewLines, [System.Environment]::NewLine
			}
			catch {
				$PSCmdlet.ThrowTerminatingError($_)
			}

			# append message to file
			try {
				[System.IO.File]::AppendAllText($Path, $MessageWithInformation)
			}
			catch {
				$PSCmdlet.ThrowTerminatingError($_)
			}
		}

		function Write-Host {
			# [System.Management.Automation.ProxyCommand]::Create([System.Management.Automation.CommandMetaData]::new((Get-Command -Name Write-Host)))

			<#
			.ForwardHelpTargetName Microsoft.PowerShell.Utility\Write-Host
			.ForwardHelpCategory Cmdlet
			#>

			[CmdletBinding(HelpUri = 'https://go.microsoft.com/fwlink/?LinkID=113426', RemotingCapability = 'None')]
			param(
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

			begin {
				# create steppable pipeline
				try {
					# get command information from execution context
					$Command = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Utility\Write-Host', [System.Management.Automation.CommandTypes]::Cmdlet)

					# create reference object for TryGetValue
					$OutBuffer = $null

					# if bound parameters contains 'OutBuffer' parameter...
					if ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$OutBuffer)) {
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
				catch {
					$PSCmdlet.ThrowTerminatingError($_)
				}
			}

			process {
				# if text output file exists...
				if ([System.IO.File]::Exists($script:TextOutputActivePath)) {
					# if separator provided...
					if ($PSBoundParameters.ContainsKey('Separator')) {
						# define message as Object joined with Separator
						try {
							$Message = [System.String]::Join($Separator, $Object)
						}
						catch {
							$Message = 'could not join Object with Separator'
						}
					}
					# if separater not provided...
					else {
						# define message as Object cast to string
						try {
							$Message = $Object -as [System.String]
						}
						catch {
							$Message = 'could not cast Object to string'
						}
					}

					# write message to text output file
					try {
						Write-TextOutputFile -Message $Message -Stream 'Information'
					}
					catch {
						# do nothing
					}
				}

				# process steppable pipeline
				try {
					$SteppablePipeline.Process($_)
				}
				catch {
					$PSCmdlet.ThrowTerminatingError($_)
				}
			}

			end {
				# stop steppable pipeline
				try {
					$SteppablePipeline.End()
				}
				catch {
					$PSCmdlet.ThrowTerminatingError($_)
				}
			}
		}

		function Write-Information {
			# [System.Management.Automation.ProxyCommand]::Create([System.Management.Automation.CommandMetaData]::new((Get-Command -Name Write-Information)))

			<#
			.ForwardHelpTargetName Microsoft.PowerShell.Utility\Write-Information
			.ForwardHelpCategory Cmdlet
			#>

			[CmdletBinding(HelpUri = 'https://go.microsoft.com/fwlink/?LinkId=525909', RemotingCapability = 'None')]
			param(
				[Parameter(Mandatory = $true, Position = 0)]
				[Alias('Msg')]
				[System.Object]
				${MessageData},

				[Parameter(Position = 1)]
				[string[]]
				${Tags}
			)

			begin {
				# create steppable pipeline
				try {
					# get command information from execution context
					$Command = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Utility\Write-Information', [System.Management.Automation.CommandTypes]::Cmdlet)

					# create reference object for TryGetValue
					$OutBuffer = $null

					# if bound parameters contains 'OutBuffer' parameter...
					if ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$OutBuffer)) {
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
				catch {
					$PSCmdlet.ThrowTerminatingError($_)
				}
			}

			process {
				# if text output file exists...
				if ([System.IO.File]::Exists($script:TextOutputActivePath)) {
					# define message as message data cast to string
					try {
						$Message = $MessageData -as [System.String]
					}
					catch {
						$Message = 'could not convert MessageData to string'
					}

					# write message to text output file
					try {
						Write-TextOutputFile -Message $Message -Stream 'Information'
					}
					catch {
						# do nothing
					}
				}

				# process steppable pipeline
				try {
					$SteppablePipeline.Process($_)
				}
				catch {
					$PSCmdlet.ThrowTerminatingError($_)
				}
			}

			end {
				# stop steppable pipeline
				try {
					$SteppablePipeline.End()
				}
				catch {
					$PSCmdlet.ThrowTerminatingError($_)
				}
			}
		}

		function Write-Verbose {
			# [System.Management.Automation.ProxyCommand]::Create([System.Management.Automation.CommandMetaData]::new((Get-Command -Name Write-Verbose)))

			<#
			.ForwardHelpTargetName Microsoft.PowerShell.Utility\Write-Verbose
			.ForwardHelpCategory Cmdlet
			#>

			[CmdletBinding(HelpUri = 'https://go.microsoft.com/fwlink/?LinkID=113429', RemotingCapability = 'None')]
			param(
				[Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
				[Alias('Msg')]
				[AllowEmptyString()]
				[string]
				${Message}
			)

			begin {
				# create steppable pipeline
				try {
					# get command information from execution context
					$Command = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Utility\Write-Verbose', [System.Management.Automation.CommandTypes]::Cmdlet)

					# create empty object for TryGetValue
					$OutBuffer = $null

					# if bound parameters contains 'OutBuffer' parameter...
					if ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$OutBuffer)) {
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
				catch {
					$PSCmdlet.ThrowTerminatingError($_)
				}
			}

			process {
				# if text output file exists...
				if ([System.IO.File]::Exists($script:TextOutputActivePath)) {
					# write message to text output file
					try {
						Write-TextOutputFile -Message $Message -Stream 'Verbose'
					}
					catch {
						# do nothing
					}
				}

				# process steppable pipeline
				try {
					$SteppablePipeline.Process($_)
				}
				catch {
					$PSCmdlet.ThrowTerminatingError($_)
				}
			}

			end {
				# stop steppable pipeline
				try {
					$SteppablePipeline.End()
				}
				catch {
					$PSCmdlet.ThrowTerminatingError($_)
				}
			}
		}

		function Write-Warning {
			# [System.Management.Automation.ProxyCommand]::Create([System.Management.Automation.CommandMetaData]::new((Get-Command -Name Write-Warning)))

			<#
			.ForwardHelpTargetName Microsoft.PowerShell.Utility\Write-Verbose
			.ForwardHelpCategory Cmdlet
			#>

			[CmdletBinding(HelpUri = 'https://go.microsoft.com/fwlink/?LinkID=113430', RemotingCapability = 'None')]
			param(
				[Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
				[Alias('Msg')]
				[AllowEmptyString()]
				[string]
				${Message}
			)

			begin {
				# create steppable pipeline
				try {
					# get command information from execution context
					$Command = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Utility\Write-Warning', [System.Management.Automation.CommandTypes]::Cmdlet)

					# create empty object for TryGetValue
					$OutBuffer = $null

					# if bound parameters contains 'OutBuffer' parameter...
					if ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$OutBuffer)) {
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
				catch {
					$PSCmdlet.ThrowTerminatingError($_)
				}
			}

			process {
				# if text output file exists...
				if ([System.IO.File]::Exists($script:TextOutputActivePath)) {
					# write message to text output file
					try {
						Write-TextOutputFile -Message $Message -Stream 'Warning'
					}
					catch {
						# do nothing
					}
				}

				# process steppable pipeline
				try {
					$SteppablePipeline.Process($_)
				}
				catch {
					$PSCmdlet.ThrowTerminatingError($_)
				}
			}

			end {
				# stop steppable pipeline
				try {
					$SteppablePipeline.End()
				}
				catch {
					$PSCmdlet.ThrowTerminatingError($_)
				}
			}
		}

		function Write-Error {
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

			begin {
				# create steppable pipeline
				try {
					# get command information from execution context
					$Command = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Utility\Write-Error', [System.Management.Automation.CommandTypes]::Cmdlet)

					# create empty object for TryGetValue
					$OutBuffer = $null

					# if bound parameters contains 'OutBuffer' parameter...
					if ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$OutBuffer)) {
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
				catch {
					$PSCmdlet.ThrowTerminatingError($_)
				}
			}

			process {
				# if text output file exists...
				if ([System.IO.File]::Exists($script:TextOutputActivePath)) {
					# if Message provided...
					if ($PSCmdlet.ParameterSetName -eq 'NoException') {
						$ErrorMessage = $Message
					}
					# if Exception provided...
					elseif ($PSCmdlet.ParameterSetName -eq 'WithException') {
						# if Exception contains an inner exception...
						if ($Exception.InnerException) {
							$ErrorMessage = '[{0}]; {1}' -f $Exception.InnerException.GetType().FullName, $Exception.InnerException.Message
						}
						# if Exception does not contain an inner exception...
						else {
							$ErrorMessage = '[{0}]; {1}' -f $Exception.GetType().FullName, $Exception.Message
						}
					}
					# if ErrorRecord provided...
					elseif ($PSCmdlet.ParameterSetName -eq 'ErrorRecord') {
						# if exception in ErrorRecord contains an inner exception...
						if ($ErrorRecord.Exception.InnerException) {
							$ErrorMessage = '[{0}]; {1}' -f $ErrorRecord.Exception.InnerException.GetType().FullName, $ErrorRecord.Exception.InnerException.Message
						}
						# if exception in ErrorRecord does not contain an inner exception...
						else {
							$ErrorMessage = '[{0}]; {1}' -f $ErrorRecord.Exception.GetType().FullName, $ErrorRecord.Exception.Message
						}
					}

					# write message to text output file
					try {
						Write-TextOutputFile -Message $ErrorMessage -Stream 'Error'
					}
					catch {
						# do nothing
					}
				}

				# process steppable pipeline
				try {
					$SteppablePipeline.Process($_)
				}
				catch {
					$PSCmdlet.ThrowTerminatingError($_)
				}
			}

			end {
				# stop steppable pipeline
				try {
					$SteppablePipeline.End()
				}
				catch {
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

		################################################
		# end TranscriptForCommand module
		################################################

		# start transcript with default parameters and skip text output if requested
		try {
			Start-TranscriptForCommand -SkipTextOutput:$SkipTextOutput
		}
		catch {
			throw $_
		}
	}

	# retrieve cluster nodes
	try {
		$ClusterNodes = Get-ClusterNode -ErrorAction 'Stop' | Sort-Object -Property NodeName
	}
	catch {
		Write-Warning -Message "could not retrieve local cluster nodes: $($_.Exception.Message)"
		$PSCmdlet.ThrowTerminatingError($_)
	}

	# retrieve clustered scheduled tasks
	try {
		$ClusteredScheduledTasks = Get-ClusteredScheduledTask -TaskName $ClusterTaskName -ErrorAction 'Stop'
	}
	catch {
		Write-Warning -Message "could not retrieve clustered scheduled tasks: $($_.Exception.Message)"
		$PSCmdlet.ThrowTerminatingError($_)
	}
}

process {
	# start
	if ($PSCmdlet.ParameterSetName -eq 'Start') {
		################################################
		# check cluster scheduled task before starting
		################################################

		# retrieve clustered scheduled task for cluster
		$ClusteredScheduledTask = $ClusteredScheduledTasks | Where-Object { $_.TaskName -eq $ClusterTaskName }

		# if clustered scheduled task found...
		if ($ClusteredScheduledTask) {
			Write-Warning -Message "found existing '$ClusterTaskName' clustered scheduled task, run this script with the Restart or Stop parameters to reset or remove the scheduled task"
			return
		}

		################################################
		# check cluster state before starting
		################################################

		# test cluster for incorrect state or status
		try {
			$IncorrectStateOrStatus = Test-ClusterForIncorrectStateOrStatus -State 'Up' -Status 'Normal'
		}
		catch {
			Write-Warning -Message "could not test cluster for incorrect state or status: $($_.Exception.Message)"
			return $_
		}

		# if incorrect state or status...
		if ($IncorrectStateOrStatus) {
			# return as warnings were issued by function
			return
		}

		################################################
		# check script path before starting
		################################################

		# if Path not provided...
		if (!$PSBoundParameters.ContainsKey('Path')) {
			# retrieve script path
			$Path = $MyInvocation.MyCommand.Path
		}

		# if skip of cluster storage check not requested...
		if (!$SkipClusteredStorageCheck) {
			# define boolean
			$PathIsNotValid = $false

			# loop through cluster nodes
			foreach ($ClusterNode in $ClusterNodes) {
				# if cluster node is not local computer...
				if ($ClusterNode.NodeName -ne $env:COMPUTERNAME) {
					# check remote computer for script
					try {
						$NotFound = Invoke-Command -ComputerName $ClusterNode.NodeName -ScriptBlock { ![System.IO.File]::Exists($using:Path) }
					}
					catch {
						Write-Warning -Message "could not check '$($ClusterNode.NodeName)' cluster node for '$Path' path: $($_.Exception.Message)"
						return $_
					}

					# if script not found...
					if ($NotFound) {
						Write-Warning -Message "could not locate script on '$($ClusterNode.NodeName)' cluster node with '$Path' path"
						$PathIsNotValid = $true
					}
				}
			}

			# if path is not valid on one or more nodes...
			if ($PathIsNotValid) {
				Write-Warning -Message 'this script MUST be available on every cluster node to continue'
				return
			}
		}

		################################################
		# create state objects
		################################################

		# create list for cluster node state objects
		try {
			$ClusterNodeStates = [System.Collections.Generic.List[object]]::new()
		}
		catch {
			Write-Warning -Message "could not create list for cluster node state objects: $($_.Exception.Message)"
			return $_
		}

		# loop through cluster nodes
		foreach ($ClusterNode in $ClusterNodes) {
			# create state object for cluster node with initial 'Ready' state
			$ClusterNodeState = [PSCustomObject]@{
				Name  = $ClusterNode.NodeName
				State = 'Ready'
			}

			# add state object to list
			$ClusterNodeStates.Add($ClusterNodeState)
		}

		# create state object for cluster
		$ClusterState = [PSCustomObject]@{
			Nodes   = $ClusterNodeStates
		}

		# sort cluster nodes in state object
		$ClusterState.Nodes = $ClusterState.Nodes | Sort-Object -Property 'Name'

		# create task description from state object
		try {
			$Description = $ClusterState | ConvertTo-Json -Compress -Depth 100
		}
		catch {
			Write-Warning -Message "could not convert cluster state object to JSON: $($_.Exception.Message)"
			return $_
		}

		################################################
		# create scheduled task
		################################################

		# define task action
		$ScheduledTaskAction = @{
			Execute  = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
			Argument = '-NonInteractive -NoProfile -ExecutionPolicy ByPass -File "{0}"' -f $Path
		}

		# create task action
		try {
			$Action = New-ScheduledTaskAction @ScheduledTaskAction
		}
		catch {
			Write-Warning -Message "could not create scheduled task action object: $($_.Exception.Message)"
			return $_
		}

		# define task action
		$ScheduledTaskSettingsSet = @{
			AllowStartIfOnBatteries    = $true
			DontStopIfGoingOnBatteries = $true
			StartWhenAvailable         = $true
		}

		# if suspended start requested...
		if ($PSBoundParameters.ContainsKey('Suspended')) {
			# define task settings with task disabled
			$ScheduledTaskSettingsSet['Disable'] = $true
		}

		# create task settings
		try {
			$Settings = New-ScheduledTaskSettingsSet @ScheduledTaskSettingsSet
		}
		catch {
			Write-Warning -Message "could not create scheduled task settings object: $($_.Exception.Message)"
			return $_
		}

		# define task trigger
		$ScheduledTaskTrigger = @{
			# run "once" to allow sub-daily repetition
			Once               = $true
			# run immediately
			At                 = [System.Datetime]::Now
			# run for (node count * days) to permit a day for storage jobs
			RepetitionDuration = [System.Timespan]::FromDays($ClusterNodes.Count)
			# run every interval
			RepetitionInterval = $RepetitionInterval
		}

		# create task trigger
		try {
			$Trigger = New-ScheduledTaskTrigger @ScheduledTaskTrigger
		}
		catch {
			Write-Warning -Message "could not create scheduled task trigger object: $($_.Exception.Message)"
			return $_
		}

		# define parameters
		$ClusteredScheduledTask = @{
			TaskName    = $ClusterTaskName
			TaskType    = 'ClusterWide'
			Action      = $Action
			Settings    = $Settings
			Trigger     = $Trigger
			Description = $Description
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# create scheduled task
		try {
			$null = Register-ClusteredScheduledTask @ClusteredScheduledTask
		}
		catch {
			Write-Warning -Message "could not register '$ClusterTaskName' clustered scheduled task: $($_.Exception.Message)"
			return $_
		}

		# report state and return
		Write-Host "created '$ClusterTaskName' clustered scheduled task"
		return
	}

	# stop
	if ($PSCmdlet.ParameterSetName -eq 'Stop') {
		################################################
		# check cluster scheduled task before starting
		################################################

		# retrieve clustered scheduled task for cluster
		$ClusteredScheduledTask = $ClusteredScheduledTasks | Where-Object { $_.TaskName -eq $ClusterTaskName }

		# if clustered scheduled task not found...
		if (!$ClusteredScheduledTask) {
			Write-Warning -Message "could not locate '$ClusterTaskName' clustered scheduled task"
			return
		}

		################################################
		# remove cluster scheduled task
		################################################

		# remove scheduled task
		try {
			$null = Unregister-ClusteredScheduledTask -TaskName $ClusterTaskName -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not unregister '$ClusterTaskName' clustered scheduled task: $($_.Exception.Message)"
			return $_
		}

		# report state and return
		Write-Host "removed '$ClusterTaskName' clustered scheduled task"
		return
	}

	# restart
	if ($PSCmdlet.ParameterSetName -eq 'Restart') {
		################################################
		# check cluster scheduled task before restarting
		################################################

		# retrieve clustered scheduled task for cluster
		$ClusteredScheduledTask = $ClusteredScheduledTasks | Where-Object { $_.TaskName -eq $ClusterTaskName }

		# if clustered scheduled task not found...
		if (!$ClusteredScheduledTask) {
			Write-Warning -Message "could not locate '$ClusterTaskName' clustered scheduled task"
			return
		}

		################################################
		# retrieve stored state for cluster from task
		################################################

		# if description is empty...
		if ([string]::IsNullOrEmpty($ClusteredScheduledTask.TaskDefinition.Description)) {
			# warn and return
			Write-Warning -Message "found empty description on '$ClusterTaskName' clustered scheduled task"
			return
		}

		# retrieve cluster state object from scheduled task description
		try {
			$ClusterState = ConvertFrom-Json -InputObject $ClusteredScheduledTask.TaskDefinition.Description -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not convert description of scheduled task to JSON: $($_.Exception.Message)"
			return $_
		}

		################################################
		# check cluster state before restarting
		################################################

		# test cluster for incorrect state or status
		try {
			$IncorrectStateOrStatus = Test-ClusterForIncorrectStateOrStatus -State 'Up' -Status 'Normal'
		}
		catch {
			Write-Warning -Message "could not test cluster for incorrect state or status: $($_.Exception.Message)"
			return $_
		}

		# if incorrect state or status...
		if ($IncorrectStateOrStatus) {
			# return as warnings were issued by function
			return
		}

		################################################
		# create state objects
		################################################

		# create list for cluster node state objects
		try {
			$ClusterNodeStates = [System.Collections.Generic.List[object]]::new()
		}
		catch {
			Write-Warning -Message "could not create list for cluster node state objects: $($_.Exception.Message)"
			return $_
		}

		# loop through cluster nodes
		foreach ($ClusterNode in $ClusterNodes) {
			# create state object for cluster node with initial 'Ready' state
			$ClusterNodeState = [PSCustomObject]@{
				Name  = $ClusterNode.NodeName
				State = 'Ready'
			}

			# add state object to list
			$ClusterNodeStates.Add($ClusterNodeState)
		}

		# create state object for cluster
		$ClusterState = [PSCustomObject]@{
			Nodes   = $ClusterNodeStates
		}

		# sort cluster nodes in state object
		$ClusterState.Nodes = $ClusterState.Nodes | Sort-Object -Property 'Name'

		# create task description from state object
		try {
			$Description = $ClusterState | ConvertTo-Json -Compress -Depth 100
		}
		catch {
			Write-Warning -Message "could not convert cluster state object to JSON: $($_.Exception.Message)"
			return $_
		}

		# update description of clustered scheduled task
		try {
			$null = Set-ClusteredScheduledTask -TaskName $ClusterTaskName -Description $Description -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not update '$ClusterTaskName' clustered scheduled task: $($_.Exception.Message)"
			return $_
		}

		# report and return
		Write-Host "reset state for '$ClusterTaskName' clustered scheduled task"
	}

	# suspend
	if ($PSCmdlet.ParameterSetName -eq 'Suspend') {
		################################################
		# check cluster scheduled task before suspending
		################################################

		# retrieve clustered scheduled task for cluster
		$ClusteredScheduledTask = $ClusteredScheduledTasks | Where-Object { $_.TaskName -eq $ClusterTaskName }

		# if clustered scheduled task not found...
		if (!$ClusteredScheduledTask) {
			Write-Warning -Message "could not locate '$ClusterTaskName' clustered scheduled task"
			return
		}

		# if clustered scheduled task is disabled...
		if ($ClusteredScheduledTask.TaskDefinition.Settings.Enabled -eq $false) {
			Write-Warning -Message "found '$ClusterTaskName' clustered scheduled task already disabled"
			return
		}

		################################################
		# disable cluster scheduled task
		################################################

		# retrieve clustered scheduled task settings
		$Settings = $ClusteredScheduledTask.TaskDefinition.Settings

		# update clustered scheduled task settings
		$Settings.Enabled = $false

		# update scheduled task
		try {
			$null = Set-ClusteredScheduledTask -TaskName $ClusterTaskName -Settings $Settings -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not disable '$ClusterTaskName' clustered scheduled task: $($_.Exception.Message)"
			return $_
		}

		# report and return
		Write-Host "disabled '$ClusterTaskName' clustered scheduled task"
		return
	}

	# resume
	if ($PSCmdlet.ParameterSetName -eq 'Resume') {
		################################################
		# check cluster scheduled task before resuming
		################################################

		# retrieve clustered scheduled task for cluster
		$ClusteredScheduledTask = $ClusteredScheduledTasks | Where-Object { $_.TaskName -eq $ClusterTaskName }

		# if clustered scheduled task not found...
		if (!$ClusteredScheduledTask) {
			Write-Warning -Message "could not locate '$ClusterTaskName' clustered scheduled task"
			return
		}

		# if clustered scheduled task is enabled...
		if ($ClusteredScheduledTask.TaskDefinition.Settings.Enabled -eq $true) {
			Write-Warning -Message "found '$ClusterTaskName' clustered scheduled task already enabled"
			return
		}

		################################################
		# enable cluster scheduled task
		################################################

		# retrieve clustered scheduled task settings
		$Settings = $ClusteredScheduledTask.TaskDefinition.Settings

		# update clustered scheduled task settings
		$Settings.Enabled = $true

		# update scheduled task
		try {
			$null = Set-ClusteredScheduledTask -TaskName $ClusterTaskName -Settings $Settings -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not enable '$ClusterTaskName' clustered scheduled task: $($_.Exception.Message)"
			return $_
		}

		# report and return
		Write-Host "enabled '$ClusterTaskName' clustered scheduled task"
		return
	}

	# report
	if ($PSCmdlet.ParameterSetName -eq 'Report') {
		################################################
		# check cluster scheduled task before reporting
		################################################

		# retrieve clustered scheduled task for cluster
		$ClusteredScheduledTask = $ClusteredScheduledTasks | Where-Object { $_.TaskName -eq $ClusterTaskName }

		# if clustered scheduled task not found...
		if (!$ClusteredScheduledTask) {
			Write-Warning -Message "could not locate '$ClusterTaskName' clustered scheduled task"
			return
		}

		################################################
		# retrieve stored state for cluster from task
		################################################

		# if description is empty...
		if ([string]::IsNullOrEmpty($ClusteredScheduledTask.TaskDefinition.Description)) {
			# warn and return
			Write-Warning -Message "found empty description on '$ClusterTaskName' clustered scheduled task"
			return
		}

		# retrieve cluster state object from scheduled task description
		try {
			$ClusterState = ConvertFrom-Json -InputObject $ClusteredScheduledTask.TaskDefinition.Description -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not convert description of scheduled task to JSON: $($_.Exception.Message)"
			return $_
		}
	}

	# default
	if ($PSCmdlet.ParameterSetName -eq 'Default') {
		################################################
		# check cluster scheduled task before running
		################################################

		# retrieve clustered scheduled task for cluster
		$ClusteredScheduledTask = $ClusteredScheduledTasks | Where-Object { $_.TaskName -eq $ClusterTaskName }

		# if clustered scheduled task not found...
		if (!$ClusteredScheduledTask) {
			Write-Warning -Message "could not locate '$ClusterTaskName' clustered scheduled task"
			return
		}

		################################################
		# retrieve stored state for cluster from task
		################################################

		# if description is empty...
		if ([string]::IsNullOrEmpty($ClusteredScheduledTask.TaskDefinition.Description)) {
			# warn and return
			Write-Warning -Message "found empty description on '$ClusterTaskName' clustered scheduled task"
			return
		}

		# retrieve cluster state object from scheduled task description
		try {
			$ClusterState = ConvertFrom-Json -InputObject $ClusteredScheduledTask.TaskDefinition.Description -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not convert description of scheduled task to JSON: $($_.Exception.Message)"
			return $_
		}

		################################################
		# validate stored state
		################################################

		# define boolean for state object
		$StateObjectIsNotValid = $false

		# loop through cluster nodes
		foreach ($ClusterNode in $ClusterNodes) {
			# get stored state of cluster node
			$Node = $ClusterState.Nodes | Where-Object { $_.Name -eq $ClusterNode.NodeName }

			# get count of entries for cluster node
			$Count = Measure-Object -InputObject $Node | Select-Object -ExpandProperty 'Count'

			# if node not found in state object...
			if ($Count -eq 0) {
				Write-Warning -Message "could not locate entry for '$($ClusterNode.NodeName)' cluster node in state object"
				$StateObjectIsNotValid = $true
			}

			# if node found multiple times in state object...
			if ($Count -gt 1) {
				Write-Warning -Message "found multiple entries for '$($ClusterNode.NodeName)' cluster node in state object"
				$StateObjectIsNotValid = $true
			}
		}

		# valid states
		$ValidStates = @('Ready', 'Paused', 'ReadyToRestart', 'Restarted', 'Resumed', 'Complete')

		# loop through entries in state object
		foreach ($Entry in $ClusterState.Nodes) {
			# if name from entry not in cluster...
			if ($Entry.Name -notin $ClusterNodes.NodeName) {
				Write-Warning -Message "found invalid cluster node name in state object: $($Entry.Name)"
				$StateObjectIsNotValid = $true
			}

			# if state from entry not valid...
			if ($Entry.State -notin $ValidStates) {
				Write-Warning -Message "found invalid cluster node state in state object: $($Entry.State)"
				$StateObjectIsNotValid = $true
			}
		}

		# if state object is not valid...
		if ($StateObjectIsNotValid) {
			Write-Warning -Message 'the state object is not valid'
			return
		}

		################################################
		# check if cluster restart has completed
		################################################

		# define boolean
		$StateIsComplete = $true

		# loop through cluster nodes
		foreach ($ClusterNode in $ClusterNodes) {
			# get stored state of cluster node that has not reached the Complete state
			$Node = $ClusterState.Nodes | Where-Object { $_.Name -eq $ClusterNode.NodeName }

			# if state of node is not complete...
			if ($Node.State -ne 'Complete') {
				$StateIsComplete = $false
			}
		}

		# if all nodes are complete...
		if ($StateIsComplete) {
			# declare complete and return
			Write-Host 'all cluster nodes have restarted'

			# retrieve owner of Cluster Group
			try {
				$ClusterGroupNode = Get-ClusterGroup -Name 'Cluster Group' -ErrorAction 'Stop' | Select-Object -ExpandProperty OwnerNode | Select-Object -ExpandProperty Name
			}
			catch {
				Write-Warning -Message "could not retrieve current owner of 'Cluster Group' cluster group on '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				return $_
			}

			# if cluster group not on current node...
			if ($ClusterGroupNode -ne $env:COMPUTERNAME) {
				return
			}

			# remove scheduled task
			try {
				$null = Unregister-ClusteredScheduledTask -TaskName $ClusterTaskName -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message "could not unregister '$ClusterTaskName' clustered scheduled task: $($_.Exception.Message)"
				return $_
			}

			# report state
			Write-Host "removed '$ClusterTaskName' clustered scheduled task"

			# loop through cluster state
			foreach ($ClusterNode in $ClusterNodes) {
				# get stored state of cluster node that has not reached the Complete state
				$Node = $ClusterState.Nodes | Where-Object { $_.Name -eq $ClusterNode.NodeName }

				# update state of node for final report
				$Node.State = 'Unregistered'
			}

			# return
			return
		}

		################################################
		# check if local computer is current node
		################################################

		# get stored state of first node that has not reached the Complete state
		$StoredClusterNode = $ClusterState.Nodes | Sort-Object -Property 'Name' | Where-Object { $_.State -ne 'Complete' } | Select-Object -First 1

		# if current node name is not local computer name...
		if ($StoredClusterNode.Name -ne $env:COMPUTERNAME) {
			# declare not current and return
			Write-Host 'local computer is not current node'
			return
		}

		################################################
		# check prereqs for state: Ready
		################################################

		# if stored state of current node is Ready...
		if ($StoredClusterNode.State -eq 'Ready') {
			# test cluster for incorrect state or status
			try {
				$IncorrectStateOrStatus = Test-ClusterForIncorrectStateOrStatus -State 'Up' -Status 'Normal' -NodeName $env:COMPUTERNAME
			}
			catch {
				Write-Warning -Message "could not test cluster for incorrect state or status on '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				return $_
			}

			# if incorrect state or status...
			if ($IncorrectStateOrStatus) {
				# return as warnings were issued by function
				return
			}

			# test cluster for storage jobs
			try {
				$StorageJobsFound = Test-ClusterForStorageJobs
			}
			catch {
				Write-Warning -Message "could not test cluster for storage jobs on '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				return $_
			}

			# if any storage jobs found...
			if ($StorageJobsFound) {
				Write-Host "exiting: waiting for storage jobs to complete on '$env:COMPUTERNAME' cluster node"
				return
			}
		}

		################################################
		# execute tasks for state: Ready
		################################################

		# if stored state of current node is Ready...
		if ($StoredClusterNode.State -eq 'Ready') {
			# suspend current node
			try {
				$null = Suspend-ClusterNode -Drain -ForceDrain -RetryDrainOnFailure -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message "could not suspend '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				return $_
			}

			# declare state
			Write-Host "paused '$env:COMPUTERNAME' cluster node"

			# update state of current node
			$StoredClusterNode.State = 'Paused'

			# sort cluster nodes in state object
			$ClusterState.Nodes = $ClusterState.Nodes | Sort-Object -Property 'Name'

			# create task description from state object
			try {
				$Description = $ClusterState | ConvertTo-Json -Compress -Depth 100
			}
			catch {
				Write-Warning -Message "could not convert cluster state object to JSON: $($_.Exception.Message)"
				return $_
			}

			# update description of clustered scheduled task
			try {
				$null = Set-ClusteredScheduledTask -TaskName $ClusterTaskName -Description $Description -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message "could not update '$ClusterTaskName' clustered scheduled task: $($_.Exception.Message)"
				return $_
			}

			# report state and return
			Write-Host "updated state for '$ClusterTaskName' clustered scheduled task: '$env:COMPUTERNAME' cluster node is now in '$($StoredClusterNode.State)' state"
			return
		}

		################################################
		# check prereqs for state: Paused
		################################################

		# if stored state of current node is Paused...
		if ($StoredClusterNode.State -eq 'Paused') {
			# test cluster for incorrect state or status
			try {
				$IncorrectStateOrStatus = Test-ClusterForIncorrectStateOrStatus -State 'Paused' -Status 'DrainCompleted' -NodeName $env:COMPUTERNAME
			}
			catch {
				Write-Warning -Message "could not test cluster for incorrect state or status on '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				return $_
			}

			# if incorrect state or status...
			if ($IncorrectStateOrStatus) {
				# return as warnings were issued by function
				return
			}
		}

		################################################
		# execute tasks for state: Paused
		################################################

		# if stored state of current node is Paused...
		if ($StoredClusterNode.State -eq 'Paused') {
			# retrieve scheduled task
			try {
				$ScheduledTask = Get-ScheduledTask -ErrorAction 'Stop' | Where-Object { $_.TaskName -eq $NodeTaskName }
			}
			catch {
				Write-Warning -Message "could not retrieve and filter scheduled tasks on '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				return $_
			}

			# if scheduled task found...
			if ($ScheduledTask) {
				# remove scheduled task
				try {
					$null = Unregister-ScheduledTask -InputObject $ScheduledTask -Confirm:$false -ErrorAction 'Stop'
				}
				catch {
					Write-Warning -Message "could not unregister '$NodeTaskName' scheduled task on '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
					return $_
				}
			}

			# define task action
			$ScheduledTaskAction = @{
				Execute     = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
				Argument    = '-NonInteractive -NoProfile -ExecutionPolicy ByPass -Command "{0}"' -f "Enable-ScheduledTask -TaskPath '\Microsoft\Windows\Failover Clustering\' -TaskName 'Invoke-ClusterRestart'"
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# create task action
			try {
				$Action = New-ScheduledTaskAction @ScheduledTaskAction
			}
			catch {
				Write-Warning -Message "could not create scheduled task action object: $($_.Exception.Message)"
				return $_
			}

			# define task principal
			$ScheduledTaskPrincial = @{
				LogonType   = 'ServiceAccount'
				RunLevel    = 'Highest'
				UserId      = 'SYSTEM'
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# create task principal
			try {
				$Principal = New-ScheduledTaskPrincipal @ScheduledTaskPrincial
			}
			catch {
				Write-Warning -Message "could not create scheduled task action object: $($_.Exception.Message)"
				return $_
			}

			# define task settings
			$ScheduledTaskSettingsSet = @{
				AllowStartIfOnBatteries    = $true
				DontStopIfGoingOnBatteries = $true
				ErrorAction                = [System.Management.Automation.ActionPreference]::Stop
			}

			# create task settings
			try {
				$Settings = New-ScheduledTaskSettingsSet @ScheduledTaskSettingsSet
			}
			catch {
				Write-Warning -Message "could not create scheduled task settings object: $($_.Exception.Message)"
				return $_
			}

			# define task trigger
			$ScheduledTaskTrigger = @{
				AtStartup   = $true
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# create task trigger
			try {
				$Trigger = New-ScheduledTaskTrigger @ScheduledTaskTrigger
			}
			catch {
				Write-Warning -Message "could not create scheduled task trigger object: $($_.Exception.Message)"
				return $_
			}

			# define parameters
			$ScheduledTask = @{
				TaskName    = $NodeTaskName
				Action      = $Action
				Principal   = $Principal
				Settings    = $Settings
				Trigger     = $Trigger
				Force       = $true
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# create scheduled task
			try {
				$null = Register-ScheduledTask @ScheduledTask
			}
			catch {
				Write-Warning -Message "could not register '$NodeTaskName' scheduled task on '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				return $_
			}

			# report state
			Write-Host "created '$NodeTaskName' scheduled task on '$env:COMPUTERNAME' cluster node"

			# update state of current node
			$StoredClusterNode.State = 'ReadyToRestart'

			# sort cluster nodes in state object
			$ClusterState.Nodes = $ClusterState.Nodes | Sort-Object -Property 'Name'

			# create task description from state object
			try {
				$Description = $ClusterState | ConvertTo-Json -Compress -Depth 100
			}
			catch {
				Write-Warning -Message "could not convert cluster state object to JSON: $($_.Exception.Message)"
				return $_
			}

			# update description of clustered scheduled task
			try {
				$null = Set-ClusteredScheduledTask -TaskName $ClusterTaskName -Description $Description -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message "could not update '$ClusterTaskName' clustered scheduled task: $($_.Exception.Message)"
				return $_
			}

			# report state
			Write-Host "updated state for '$ClusterTaskName' clustered scheduled task: '$env:COMPUTERNAME' cluster node is now in '$($StoredClusterNode.State)' state"
			return
		}

		################################################
		# check prereqs for state: ReadyToRestart
		################################################

		# if stored state of current node is ReadyToRestart...
		if ($StoredClusterNode.State -eq 'ReadyToRestart') {
			# test cluster for incorrect state or status
			try {
				$IncorrectStateOrStatus = Test-ClusterForIncorrectStateOrStatus -State 'Paused' -Status 'DrainComplete' -NodeName $env:COMPUTERNAME
			}
			catch {
				Write-Warning -Message "could not test cluster for incorrect state or status on '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				return $_
			}

			# if incorrect state or status...
			if ($IncorrectStateOrStatus) {
				# return as warnings were issued by function
				return
			}

			# retrieve scheduled task
			try {
				$ScheduledTask = Get-ScheduledTask -ErrorAction 'Stop' | Where-Object { $_.TaskName -eq $NodeTaskName }
			}
			catch {
				Write-Warning -Message "could not retrieve and filter scheduled tasks on '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				return $_
			}

			# if scheduled task not found...
			if (!$ScheduledTask) {
				Write-Warning -Message "could not find '$NodeTaskName' scheduled task on '$env:COMPUTERNAME' cluster node"
				return
			}
		}

		################################################
		# execute tasks for state: ReadyToRestart
		################################################

		# if stored state of current node is ReadyToRestart...
		if ($StoredClusterNode.State -eq 'ReadyToRestart') {
			# declare state
			Write-Host "restarting '$env:COMPUTERNAME' cluster node"

			# update state of current node
			$StoredClusterNode.State = 'Restarted'

			# sort cluster nodes in state object
			$ClusterState.Nodes = $ClusterState.Nodes | Sort-Object -Property 'Name'

			# create task description from state object
			try {
				$Description = $ClusterState | ConvertTo-Json -Compress -Depth 100
			}
			catch {
				Write-Warning -Message "could not convert cluster state object to JSON: $($_.Exception.Message)"
				return $_
			}

			# update description of clustered scheduled task
			try {
				$null = Set-ClusteredScheduledTask -TaskName $ClusterTaskName -Description $Description -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message "could not update '$ClusterTaskName' clustered scheduled task: $($_.Exception.Message)"
				return $_
			}

			# report state
			Write-Host "updated state for '$ClusterTaskName' clustered scheduled task: '$env:COMPUTERNAME' cluster node is now in '$($StoredClusterNode.State)' state"

			# restart computer AFTER updating state
			try {
				Restart-Computer -Force -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message "could not restart '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				return $_
			}

			# return
			return
		}

		################################################
		# check prereqs for state: Restarted
		################################################

		# if stored state of current node is Restarted...
		if ($StoredClusterNode.State -eq 'Restarted') {
			# test cluster for incorrect state or status
			try {
				$IncorrectStateOrStatus = Test-ClusterForIncorrectStateOrStatus -State 'Paused' -Status 'Normal' -NodeName $env:COMPUTERNAME
			}
			catch {
				Write-Warning -Message "could not test cluster for incorrect state or status on '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				return $_
			}

			# if incorrect state or status...
			if ($IncorrectStateOrStatus) {
				# return as warnings were issued by function
				return
			}

			# retrieve clustered scheduled task start time
			try {
				$StartBoundary = $ClusteredScheduledTask.TaskDefinition.Triggers.StartBoundary -as [datetime]
			}
			catch {
				Write-Warning -Message "could not retrieve start boundary as datetime for '$ClusterTaskName' clustered scheduled task: $($_.Exception.Message)"
				return $_
			}

			# retrieve last boot time
			try {
				$LastBootUpTime = (Get-CimInstance -ClassName 'Win32_OperatingSystem' -Property 'LastBootUpTime').LastBootUpTime
			}
			catch {
				Write-Warning -Message "could not retrieve last boot time for '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				return $_
			}

			# if last boot time is before scheduled task start time...
			if ($LastBootUpTime -lt $StartBoundary) {
				Write-Warning -Message "found '$env:COMPUTERNAME' cluster node in 'Restarted' state despite a last boot up time of '$LastBootUpTime' which is before the start time for '$ClusterTaskName' clustered scheduled task of '$StartBoundary'"
				return
			}
		}

		################################################
		# execute tasks for state: Restarted
		################################################

		# if stored state of current node is Restarting...
		if ($StoredClusterNode.State -eq 'Restarted') {
			# resume current node
			try {
				$null = Resume-ClusterNode -Failback 'NoFailback' -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message "could not suspend '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				return $_
			}

			# declare state
			Write-Host "resumed '$env:COMPUTERNAME' cluster node"

			# update state of current node
			$StoredClusterNode.State = 'Resumed'

			# sort cluster nodes in state object
			$ClusterState.Nodes = $ClusterState.Nodes | Sort-Object -Property 'Name'

			# create task description from state object
			try {
				$Description = $ClusterState | ConvertTo-Json -Compress -Depth 100
			}
			catch {
				Write-Warning -Message "could not convert cluster state object to JSON: $($_.Exception.Message)"
				return $_
			}

			# update description of clustered scheduled task
			try {
				$null = Set-ClusteredScheduledTask -TaskName $ClusterTaskName -Description $Description -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message "could not update '$ClusterTaskName' clustered scheduled task: $($_.Exception.Message)"
				return $_
			}

			# report state and return
			Write-Host "updated state for '$ClusterTaskName' clustered scheduled task: '$env:COMPUTERNAME' cluster node is now in '$($StoredClusterNode.State)' state"
			return
		}

		################################################
		# check prereqs for state: Resumed
		################################################

		# if stored state of current node is Resumed...
		if ($StoredClusterNode.State -eq 'Resumed') {
			# test cluster for incorrect state or status
			try {
				$IncorrectStateOrStatus = Test-ClusterForIncorrectStateOrStatus -State 'Up' -Status 'Normal' -NodeName $env:COMPUTERNAME
			}
			catch {
				Write-Warning -Message "could not test cluster for incorrect state or status on '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				return $_
			}

			# if incorrect state or status...
			if ($IncorrectStateOrStatus) {
				# return as warnings were issued by function
				return
			}

			# test cluster for storage jobs
			try {
				$StorageJobsFound = Test-ClusterForStorageJobs
			}
			catch {
				Write-Warning -Message "could not test cluster for storage jobs on '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				return $_
			}

			# if any storage jobs found...
			if ($StorageJobsFound) {
				Write-Host "exiting: waiting for storage jobs to complete on '$env:COMPUTERNAME' cluster node"
				return
			}
		}

		################################################
		# execute tasks for state: Resumed
		################################################

		# if stored state of current node is Resumed...
		if ($StoredClusterNode.State -eq 'Resumed') {
			# retrieve scheduled task
			try {
				$ScheduledTask = Get-ScheduledTask -ErrorAction 'Stop' | Where-Object { $_.TaskName -eq $NodeTaskName }
			}
			catch {
				Write-Warning -Message "could not retrieve and filter scheduled tasks on '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
				return $_
			}

			# if scheduled task found...
			if ($ScheduledTask) {
				# remove scheduled task
				try {
					$null = Unregister-ScheduledTask -InputObject $ScheduledTask -Confirm:$false -ErrorAction 'Stop'
				}
				catch {
					Write-Warning -Message "could not unregister '$NodeTaskName' scheduled task on '$env:COMPUTERNAME' cluster node: $($_.Exception.Message)"
					return $_
				}
			}

			# report state
			Write-Host "cleaned up after restart of '$env:COMPUTERNAME' cluster node"

			# update state of current node
			$StoredClusterNode.State = 'Complete'

			# sort cluster nodes in state object
			$ClusterState.Nodes = $ClusterState.Nodes | Sort-Object -Property 'Name'

			# create task description from state object
			try {
				$Description = $ClusterState | ConvertTo-Json -Compress -Depth 100
			}
			catch {
				Write-Warning -Message "could not convert cluster state object to JSON: $($_.Exception.Message)"
				return $_
			}

			# update description of clustered scheduled task
			try {
				$null = Set-ClusteredScheduledTask -TaskName $ClusterTaskName -Description $Description -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message "could not update '$ClusterTaskName' clustered scheduled task: $($_.Exception.Message)"
				return $_
			}

			# report state and return
			Write-Host "updated state for '$ClusterTaskName' clustered scheduled task: '$env:COMPUTERNAME' cluster node is now in '$($StoredClusterNode.State)' state"
			return
		}
	}
}

end {
	# if default parameter set...
	if ($PSCmdlet.ParameterSetName -eq 'Default' -or $PSCmdlet.ParameterSetName -eq 'Report') {
		# if current state found...
		if ($null -eq $ClusterState) {
			# report and display state
			Write-Host 'cluster state - not found'
		}
		else {
			# loop through cluster state
			foreach ($ClusterNode in $ClusterState.Nodes) {
				# report node name and state
				Write-Host "cluster state - Node: $($ClusterNode.Name); State: $($ClusterNode.State)"
			}
		}
	}

	# if default parameter set and skip transcript not requested...
	if ($PSCmdlet.ParameterSetName -eq 'Default' -and -not $SkipTranscript) {
		# stop transcript with default parameters
		try {
			Stop-TranscriptForCommand
		}
		catch {
			throw $_
		}
	}
}
