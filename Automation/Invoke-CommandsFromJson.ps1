<#
.SYNOPSIS
Run one or more PowerShell commands with optional parameters from a JSON file.

.DESCRIPTION
Run one or more PowerShell commands with optional parameters from a JSON file. The commands can be existing cmdlets, functions, or scripts.

.PARAMETER Json
The path to a JSON file containing the configuration for this script.

.PARAMETER Show
Switch parameter to show all entries from the JSON configuration file. Cannot be combined with the Clear, Remove, or Add parameters.

.PARAMETER Clear
Switch parameter to clear all entries from the JSON configuration file. Cannot be combined with the Show, Remove, or Add parameters.

.PARAMETER Remove
Switch parameter to remove an entry from the JSON configuration file. Cannot be combined with the Show, Clear, or Add parameters.

.PARAMETER Add
Switch parameter to add an entry from the JSON configuration file. Cannot be combined with the Show, Clear, or Remove parameters.

.PARAMETER Command
The command to run. This parameter can be an existing cmdlet, function, or script. A script must be a fully qualified path.

.PARAMETER Parameters
Hashtable with parameters for the command. Cannot be combined with the Arguments parameter.

.PARAMETER Arguments
Hashtable with arguments for the command. Cannot be combined with the Parameters parameter. The keys in the hashtable define the order in which arguments are provided to the command and each key must be castable as a Character object.

.PARAMETER Expression
An optional string containing a PowerShell expression to evaluate. When the Expression parameter is provided, the evaluated expression must return a boolean of true for the command to run.

.PARAMETER Modules
The name or path of one or more PowerShell modules to import before running the command.

.PARAMETER InputName
The name of one or more script-wide variables to add to the parameters of the command.

.PARAMETER OutputName
The name of the script-wide variable where the output of the command should be stored.

.PARAMETER Order
An unsigned 16-bit integer representing the order that the command will be run when multiple commands are defined in a JSON file. The first command is assigned a value of 1 and each additional command is assigned an incrementing value. Providing a value that is already assigned will prompt the user to overwrite the command assigned the provided value.

.PARAMETER Disable
Switch parameter to skip the current command. The command will be run if this parameter is not present or set to false.

.PARAMETER SkipTranscript
Switch parameter to skip creating a transcript file for this script and any commands run by this script.

.PARAMETER SkipTextOutput
Switch parameter to skip creating a text output file for this script and any commands run by this script.

.INPUTS
String. The path to a JSON file.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Show

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Clear

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Remove -Command 'Restart-Service'

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Remove -Command 'C:\path\to\script.ps1'

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Remove -Order 2

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Add -Command 'Restart-Service' -Parameters @{ Name = 'DnsClient' }

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Add -Command 'Restart-Service' -Order 4 -Parameters @{ Name = 'DnsClient' }

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Add -Command 'C:\path\to\script.ps1' -Parameters @{ FirstParameterName = 'FirstParameterValue'; SecondParameterName = 'SecondParameterValue' }

.EXAMPLE
.\Invoke-CommandFromJson.ps1 -Json C:\Content\script-1.json -Add -Command 'C:\path\to\script.ps1' -Order 5 -Parameters @{ FirstParameterName = 'FirstParameterValue'; SecondParameterName = 'SecondParameterValue' }

#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Default')]
Param(
	# path to JSON configuration file
	[Parameter(Mandatory = $True, Position = 0)]
	[string]$Json,
	# script parameters - mode
	[Parameter(Mandatory = $True, ParameterSetName = 'Show')]
	[switch]$Show,
	[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Mandatory = $True, ParameterSetName = 'RemoveByCommand')]
	[Parameter(Mandatory = $True, ParameterSetName = 'RemoveByOrder')]
	[switch]$Remove,
	[Parameter(Mandatory = $True, ParameterSetName = 'AddWithArguments')]
	[Parameter(Mandatory = $True, ParameterSetName = 'AddWithParameters')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	# script parameter - command to run
	[Parameter(Mandatory = $True, ParameterSetName = 'RemoveByCommand')]
	[Parameter(Mandatory = $True, ParameterSetName = 'AddWithArguments')]
	[Parameter(Mandatory = $True, ParameterSetName = 'AddWithParameters')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[string]$Command,
	# script parameter - arguments for command
	[Parameter(Mandatory = $True, ParameterSetName = 'AddWithArguments')]
	[hashtable]$Arguments,
	# script parameter - parameters for command
	[Parameter(Mandatory = $True, ParameterSetName = 'AddWithParameters')]
	[hashtable]$Parameters,
	# script parameter - expression for evaluating command
	[Parameter(Mandatory = $False, ParameterSetName = 'AddWithArguments')]
	[Parameter(Mandatory = $False, ParameterSetName = 'AddWithParameters')]
	[Parameter(Mandatory = $False, ParameterSetName = 'Add')]
	[string]$Expression,
	# script parameter - modules to import before running command
	[Parameter(Mandatory = $False, ParameterSetName = 'AddWithArguments')]
	[Parameter(Mandatory = $False, ParameterSetName = 'AddWithParameters')]
	[Parameter(Mandatory = $False, ParameterSetName = 'Add')]
	[string[]]$Modules,
	# script parameter - variable names to add to parameters for command
	[Parameter(Mandatory = $False, ParameterSetName = 'AddWithArguments')]
	[Parameter(Mandatory = $False, ParameterSetName = 'AddWithParameters')]
	[Parameter(Mandatory = $False, ParameterSetName = 'Add')]
	[string[]]$InputName,
	# script parameter - variable name to hold output from command
	[Parameter(Mandatory = $False, ParameterSetName = 'AddWithArguments')]
	[Parameter(Mandatory = $False, ParameterSetName = 'AddWithParameters')]
	[Parameter(Mandatory = $False, ParameterSetName = 'Add')]
	[string]$OutputName,
	# script parameter - order of command
	[Parameter(Mandatory = $True, ParameterSetName = 'RemoveByOrder')]
	[Parameter(Mandatory = $False, ParameterSetName = 'AddWithArguments')]
	[Parameter(Mandatory = $False, ParameterSetName = 'AddWithParameters')]
	[Parameter(Mandatory = $False, ParameterSetName = 'Add')]
	[uint16]$Order = 1,
	# script parameter - disable command
	[Parameter(Mandatory = $False, ParameterSetName = 'AddWithArguments')]
	[Parameter(Mandatory = $False, ParameterSetName = 'AddWithParameters')]
	[Parameter(Mandatory = $False, ParameterSetName = 'Add')]
	[switch]$Disable,
	# switch parameter to skip transcript logging
	[switch]$SkipTranscript,
	# switch parameter to skip text output logging
	[switch]$SkipTextOutput
)

Begin {
	Function ConvertTo-Collection {
		Param (
			[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
			[object]$InputObject,
			[Parameter(Position = 1)][ValidateSet('Hashtable', 'SortedList', 'OrderedDictionary')]
			[string]$Type = 'Hashtable'
		)

		# switch on type
		switch ($Type) {
			'OrderedDictionary' {
				$Collection = [System.Collections.Specialized.OrderedDictionary]::new()
			}
			'SortedList' {
				$Collection = [System.Collections.SortedList]::new()
			}
			'Hashtable' {
				$Collection = [System.Collections.Hashtable]::new()
			}
		}

		# process each property of input object
		ForEach ($Property in $InputObject.PSObject.Properties) {
			# if property contains multiple values...
			If ($Property.Value.Count -gt 1) {
				# define list for property values
				$PropertyValues = [System.Collections.Generic.List[object]]::new($Property.Value.Count)
				# process each property value
				ForEach ($PropertyValue in $Property.Value) {
					# if property value is a pscustomobject...
					If ($PropertyValue -is [System.Management.Automation.PSCustomObject]) {
						# convert property value into collection
						$PropertyValueCollection = ConvertTo-Collection -InputObject $PropertyValue -Type $Type
						# add property value collection to list
						$PropertyValues.Add($PropertyValueCollection)
					}
					# if property value is not a pscustomobject...
					Else {
						# add property value to list
						$PropertyValues.Add($PropertyValue)
					}
				}
				# convert list to array then add array to collection
				$Collection[$Property.Name] = $PropertyValues.ToArray()
			}
			Else {
				# if property value is a pscustomobject...
				If ($Property.Value -is [System.Management.Automation.PSCustomObject]) {
					# convert property value into collection
					$PropertyValueCollection = ConvertTo-Collection -InputObject $Property.Value -Type $Type
					# add property name and value to collection
					$Collection[$Property.Name] = $PropertyValueCollection
				}
				# if property value is not a pscustomobject...
				Else {
					# add property name and value to collection
					$Collection[$Property.Name] = $Property.Value
				}
			}
		}

		# return collection
		Return $Collection
	}

	# if default parameter set and skip transcript not requested...
	If ($PSCmdlet.ParameterSetName -eq 'Default' -and -not $SkipTranscript) {
		################################################
		# begin TranscriptForCommand module
		################################################

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

		################################################
		# end TranscriptForCommand module
		################################################

		# start transcript with default parameters and skip text output if requested
		Try {
			Start-TranscriptForCommand -SkipTextOutput:$SkipTextOutput
		}
		Catch {
			Throw $_
		}
	}

	# if confirm provided and set to false...
	If ($PSBoundParameters.ContainsKey('Confirm') -and $script:Confirm -eq $false) {
		$WarningActionFromConfirm = [System.Management.Automation.ActionPreference]::Continue
	}
	# if confirm not provided or set to true...
	Else {
		$WarningActionFromConfirm = [System.Management.Automation.ActionPreference]::Inquire
	}
}

Process {
	# if JSON is not an absolute path...
	If (![System.IO.Path]::IsPathRooted($Json)) {
		# get unresolved absolute path
		Try {
			$Json = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Json)
		}
		Catch {
			Write-Warning "could not create absolute path from the provided Json parameter: $Json"
			Return
		}

		# report absolute path
		Write-Warning -Message "converted relative path in provided Json parameter to absolute path: $Json"
	}

	# if JSON file found...
	If (Test-Path -Path $Json) {
		# ...create JSON data object as array of PSCustomObjects from JSON file content
		Try {
			$JsonData = [array](Get-Content -Path $Json -ErrorAction 'Stop' | ConvertFrom-Json)
		}
		Catch {
			Write-Warning -Message "could not read configuration file: $Json"
			Return $_
		}
	}
	# if JSON file was not found...
	Else {
		# ...and Add set...
		If ($Add) {
			# ...try to create the JSON file
			Try {
				$null = New-Item -ItemType 'File' -Path $Json -Force -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not create configuration file: $Json"
				Return $_
			}
			# ...create JSON data object as empty array
			$JsonData = @()
		}
		# ...and Add not set...
		Else {
			# ...report and return
			Write-Warning -Message "could not find configuration file: $Json"
			Return
		}
	}

	# evaluate parameters
	switch ($true) {
		# show configuration file
		$Show {
			# report and display JSON contents
			Write-Host "Displaying entries in configuration file: $Json"
			$JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
		}
		# clear configuration file
		$Clear {
			# set empty string for JSON string
			$JsonValue = [string]::Empty

			# update JSON file
			Try {
				$JsonValue | Set-Content -Path $Json
			}
			Catch {
				Write-Warning "could not clear entries from configuration file: $Json"
				Return $_
			}

			# report entries cleared
			Write-Host "Cleared entries from configuration file: $Json"
		}
		# remove entry from configuration file
		$Remove {
			# if order provided...
			If ($PSBoundParameters.ContainsKey('Command')) {
				# define report parameter
				$ParametersForReporting = "Command of '$Command'"
				# remove existing entry by primary key(s)...
				$JsonDataToRemove = [array]($JsonData.Where({ $_.Command -eq $Command }))
				# if JSON data empty...
				If ($JsonDataToRemove.Count -gt 1) {
					# inquire before removing multiple entries
					Write-Warning -Message "Found multiple entries with $ParametersForReporting in configuration file: $Json" -WarningAction Continue
					Write-Warning -Message "All matching entries will be removed" -WarningAction $WarningActionFromConfirm
				}
				# remove existing entry by primary key(s)...
				$JsonData = [array]($JsonData.Where({ $_.Command -ne $Command }))
			}

			# if order provided...
			If ($PSBoundParameters.ContainsKey('Order')) {
				# define report parameter
				$ParametersForReporting = "Order of '$Order'"
				# remove existing entry by primary key(s)...
				$JsonDataToRemove = [array]($JsonData.Where({ $_.Order -eq $Order }))
				# if JSON data empty...
				If ($JsonDataToRemove.Count -gt 1) {
					# inquire before removing multiple entries
					Write-Warning -Message "Found multiple entries with $ParametersForReporting in configuration file: $Json" -WarningAction Continue
					Write-Warning -Message "All matching entries will be removed" -WarningAction $WarningActionFromConfirm
				}
				# remove existing entry by primary key(s)...
				$JsonData = [array]($JsonData.Where({ $_.Order -ne $Order }))
			}

			# if JSON data empty...
			If ($JsonData.Count -eq 0) {
				# set empty string for JSON string
				$JsonValue = [string]::Empty
			}
			# if JSON data is not empty...
			Else {
				# convert JSON data to JSON string
				Try {
					$JsonValue = $JsonData | Sort-Object -Property 'Order', 'Command' | ConvertTo-Json -Depth 100
				}
				Catch {
					Write-Warning 'could not convert object to JSON'
					Return $_
				}
			}

			# update JSON file
			Try {
				$JsonValue | Set-Content -Path $Json
			}
			Catch {
				Write-Warning "could not remove entry from configuration file: $Json"
				Return $_
			}

			# report entry removed
			Write-Host "Removed entry with $ParametersForReporting from configuration file: $Json"

			# display current entries if verbose
			If ($VerbosePreference -eq 'Continue') { $JsonValue | Format-List }
		}
		# add entry to configuration file
		$Add {
			# if order parameter not provided...
			If (!$PSBoundParameters.ContainsKey('Order')) {
				# while order is not assigned...
				While ($Order -lt [uint16]::MaxValue -and -not $OrderAssigned) {
					# if JSON contains entry with current Order...
					If ($JsonData.Where({ $_.Order -eq $Order })) {
						# increment order
						$Order++
					}
					# if JSON does not contains entry with current Order...
					Else {
						# declare order assigned
						$OrderAssigned = $true
					}
				}
			}

			# if existing entry has same primary key(s)...
			If ($JsonData.Where({ $_.Order -eq $Order })) {
				# inquire before removing existing entry
				Write-Warning -Message "Will overwrite existing entry for '$Command' with order '$Order' in configuration file: $Json" -WarningAction Continue
				Write-Warning -Message 'Any previous configuration for this entry will **NOT** be preserved' -WarningAction $WarningActionFromConfirm
				# remove existing entry with same primary key(s)
				$JsonData = [array]($JsonData.Where({ $_.Order -ne $Order }))
			}

			# create ordered dictionary for custom object
			$JsonParameters = [ordered]@{
				Order   = [uint16]$Order
				Command = [string]$Command
			}

			# if Arguments provided...
			If ($script:Arguments) {
				# process each key in Arguments
				ForEach ($Key in $Arguments.Keys) {
					# if key cannot be cast as a Character...
					If (![char]::TryParse($Key, [ref][char]::MinValue)) {
						Write-Warning "could not validate Arguments parameter: the value in the '$Key' key cannot be parsed into a Character object"
						Return
					}
				}
				# add Arguments to dictionary
				$JsonParameters['Arguments'] = [hashtable]$Arguments
			}

			# if Parameters provided...
			If ($script:Parameters) {
				# add Parameters to dictionary
				$JsonParameters['Parameters'] = [hashtable]$Parameters
			}

			# if Expression provided...
			If ($script:Expression) {
				# add Expression to dictionary
				$JsonParameters['Expression'] = [string]$Expression
			}

			# if Modules provided...
			If ($script:Modules) {
				# add Modules to dictionary
				$JsonParameters['Modules'] = [string[]]$Modules
			}

			# if InputName provided...
			If ($script:InputName) {
				# add InputName to dictionary
				$JsonParameters['InputName'] = [string[]]$InputName
			}

			# if OutputName provided...
			If ($script:OutputName) {
				# add OutputName to dictionary
				$JsonParameters['OutputName'] = [string]$OutputName
			}

			# add Disable as boolean
			$JsonParameters['Disable'] = [boolean]$Disable

			# add current time as FileDateTimeUniversal
			$JsonParameters['Updated'] = [datetime]::Now.ToString('s')

			# create custom object from hashtable
			$JsonEntry = [pscustomobject]$JsonParameters

			# add entry to data
			$JsonData += $JsonEntry

			# convert data to JSON
			Try {
				$JsonValue = $JsonData | Sort-Object -Property 'Order', 'Command' | ConvertTo-Json -Depth 100
			}
			Catch {
				Write-Warning 'could not convert object to JSON'
				Return $_
			}

			# update JSON file
			Try {
				$JsonValue | Set-Content -Path $Json
			}
			Catch {
				Write-Warning "could not add entry to configuration file: $Json"
				Return $_
			}

			# report entry added
			Write-Host "Added entry with order of '$Order' for '$Command' command to configuration file: $Json"

			# display current entries if verbose
			If ($VerbosePreference -eq 'Continue') { $JsonValue | Format-List }
		}
		# process entries in configuration file
		Default {
			# declare start
			Write-Host "Calling commands from '$Json'"

			# check entry count in configuration file
			If ($JsonData.Count -eq 0) {
				Write-Warning -Message "no entries found in configuration file: $Json"
				Return
			}

			# sort JsonData by Order then Path
			$JsonData = $JsonData | Sort-Object -Property 'Order', 'Command'

			# initialize exception boolean
			$ExceptionCaught = $false

			# process configuration file
			:NextJsonEntry ForEach ($JsonEntry in $JsonData) {
				# if exception caught on previous pass...
				If ($ExceptionCaught) {
					# return immediately
					Return
				}

				# convert custom object to hashtable
				Try {
					$HashtableFromJsonEntry = ConvertTo-Collection -InputObject $JsonEntry
				}
				Catch {
					Write-Warning -Message "could not create hashtable from entry in configuration file: $Json"
					Continue NextJsonEntry
				}

				# validate required values in hashtable with expressions that should be true
				Switch ($false) {
					($HashtableFromJsonEntry.ContainsKey('Command')) {
						Write-Warning -Message "required entry (Command) not found in configuration file: $Json"
						Continue NextJsonEntry
					}
					($HashtableFromJsonEntry.ContainsKey('Order')) {
						Write-Warning -Message "required entry (Order) not found in configuration file: $Json"
						Continue NextJsonEntry
					}
					($HashtableFromJsonEntry.ContainsKey('Order') -and [uint16]::TryParse($HashtableFromJsonEntry['Order'], [ref][uint16]::MinValue)) {
						Write-Warning -Message 'required value (Order) found in configuration file but cannot be parsed into a UInt16 object'
						Continue NextJsonEntry
					}
				}

				# validate optional values in hashtable with expressions that should be false
				Switch ($true) {
					($HashtableFromJsonEntry.ContainsKey('Disable') -and $HashtableFromJsonEntry['Disable'] -isnot [boolean]) {
						Write-Warning -Message 'optional value (Disable) found in configuration file but was not parsed into a boolean'
						Continue NextJsonEntry
					}
					($HashtableFromJsonEntry.ContainsKey('Arguments') -and $HashtableFromJsonEntry['Arguments'] -isnot [System.Collections.Hashtable]) {
						Write-Warning -Message 'optional value (Arguments) found in configuration file but was not parsed into a hashtable'
						Continue NextJsonEntry
					}
					($HashtableFromJsonEntry.ContainsKey('Parameters') -and $HashtableFromJsonEntry['Parameters'] -isnot [System.Collections.Hashtable]) {
						Write-Warning -Message 'optional value (Parameters) found in configuration file but was not parsed into a hashtable'
						Continue NextJsonEntry
					}
					($HashtableFromJsonEntry.ContainsKey('InputName') -and $HashtableFromJsonEntry['InputName'] -match '[^\w]') {
						Write-Warning -Message 'optional value (InputName) found in configuration file but contained a character not in 0-9A-Za-z_'
						Continue NextJsonEntry
					}
					($HashtableFromJsonEntry.ContainsKey('OutputName') -and $HashtableFromJsonEntry['OutputName'] -match '[^\w]') {
						Write-Warning -Message 'optional value (OutputName) found in configuration file but contained a character not in 0-9A-Za-z_'
						Continue NextJsonEntry
					}
					($HashtableFromJsonEntry.ContainsKey('Parameters') -and $HashtableFromJsonEntry.ContainsKey('Arguments')) {
						Write-Warning -Message 'optional values (Parameters and Arguments) found in configuration file but cannot be combined'
						Continue NextJsonEntry
					}
					($HashtableFromJsonEntry.ContainsKey('InputName') -and $HashtableFromJsonEntry.ContainsKey('Arguments')) {
						Write-Warning -Message 'optional values (InputName and Arguments) found in configuration file but cannot be combined'
						Continue NextJsonEntry
					}
					($HashtableFromJsonEntry.ContainsKey('OutputName') -and $HashtableFromJsonEntry.ContainsKey('Arguments')) {
						Write-Warning -Message 'optional value (OutputName and Arguments) found in configuration file but cannot be combined'
						Continue NextJsonEntry
					}
				}

				# if disable defined...
				If ($HashtableFromJsonEntry.ContainsKey('Disable') -and $HashtableFromJsonEntry['Disable'] -eq $true) {
					Write-Warning -Message "skipping disabled entry for Command: '$($HashtableFromJsonEntry['Command'])'"
					Continue NextJsonEntry
				}

				# if modules defined...
				If ($HashtableFromJsonEntry.ContainsKey('Modules')) {
					# process each module name
					ForEach ($ModuleName in $HashtableFromJsonEntry['Modules']) {
						# import module
						Try {
							Import-Module -Name $ModuleName -ErrorAction Stop
						}
						Catch {
							Write-Warning -Message "could not import PowerShell module: '$ModuleName'"
							Continue NextJsonEntry
						}
					}
				}

				# if command is a file
				If (Test-Path -Path $HashtableFromJsonEntry['Command'] -PathType 'Leaf') {
					# retrieve file
					Try {
						$Item = Get-Item -Path $HashtableFromJsonEntry['Command'] -ErrorAction 'Stop'
					}
					Catch {
						Write-Warning -Message "could not access file for Command: '$($HashtableFromJsonEntry['Command'])'"
						Continue NextJsonEntry
					}

					# check extension of file
					switch ($Item.Extension) {
						'.bat' { $HashtableFromJsonEntry['CommandType'] = 'Batch' }
						'.exe' { $HashtableFromJsonEntry['CommandType'] = 'Executable' }
						'.ps1' { $HashtableFromJsonEntry['CommandType'] = 'Script' }
						Default {
							Write-Warning -Message "unsupported '$($Item.Extension)' extension found on file for Command: '$($HashtableFromJsonEntry['Command'])'"
							Continue NextJsonEntry
						}
					}

					# define command name from basename of file
					$HashtableFromJsonEntry['CommandName'] = $Item.BaseName
				}
				# if command is not a file...
				Else {
					# retrieve command and return command type
					Try {
						$HashtableFromJsonEntry['CommandType'] = Get-Command -Name $HashtableFromJsonEntry['Command'] -ErrorAction 'Stop' | Select-Object -ExpandProperty 'CommandType'
					}
					Catch {
						Write-Warning -Message "could not locate PowerShell command for Command: '$($HashtableFromJsonEntry['Command'])'"
						Continue NextJsonEntry
					}

					# define command name from PowerShell command
					$HashtableFromJsonEntry['CommandName'] = $HashtableFromJsonEntry['Command']
				}

				# if trigger expression defined...
				If ($HashtableFromJsonEntry.ContainsKey('Expression')) {
					# invoke trigger expression
					Try {
						$Evaluation = Invoke-Expression -Command $HashtableFromJsonEntry['Expression']
					}
					Catch {
						Write-Warning -Message "exception caught calling '$($HashtableFromJsonEntry['Expression'])' Expression for the '$($HashtableFromJsonEntry['Command'])' Command: $($_.Exception.ToString())"
						Continue NextJsonEntry
					}

					# if trigger evaluation is not a boolean...
					If ($Evaluation -isnot [boolean]) {
						Write-Warning -Message "the evaluation of the '$($HashtableFromJsonEntry['Expression'])' Expression for the '$($HashtableFromJsonEntry['Command'])' Command returned an invalid type: '$($Evaluation.GetType().FullName)'"
						Continue NextJsonEntry
					}

					# if trigger evaluation is false...
					If ($Evaluation -eq $false) {
						Write-Host "The evaluation of the '$($HashtableFromJsonEntry['Expression'])' Expression for the '$($HashtableFromJsonEntry['Command'])' Command returned 'false'"
						Continue NextJsonEntry
					}
				}

				# if arguments provided...
				If ($HashtableFromJsonEntry.ContainsKey('Arguments')) {
					# process each key in Arguments
					ForEach ($Key in $HashtableFromJsonEntry['Arguments'].Keys) {
						# if key cannot be cast as a Character...
						If (![char]::TryParse($Key, [ref][char]::MinValue)) {
							Write-Warning "could not validate Arguments parameter: the value in the '$Key' key cannot be parsed into a Character object"
							Continue NextJsonEntry
						}
					}
					# convert arguments hashtable to a sorted list
					Try {
						$ArgumentList = $HashtableFromJsonEntry['Arguments'] -as [System.Collections.SortedList]
					}
					Catch {
						Write-Warning -Message "exception caught converting the Arguments object to a sorted list: $($_.Exception.ToString())"
						Continue NextJsonEntry
					}
				}
				# if arguments not provided...
				Else {
					$ArgumentList = $null
				}

				# if parameters provided...
				If ($HashtableFromJsonEntry.ContainsKey('Parameters')) {
					# create parameters from hashtable
					$Parameters = $HashtableFromJsonEntry['Parameters']

				}
				# if parameters not provided...
				Else {
					# create empty hashtable to allow splatting without changing call in next section
					$Parameters = @{}
				}

				# if one or more input names defined...
				If ($HashtableFromJsonEntry.ContainsKey('InputName')) {
					# process each named input variable
					ForEach ($VariableName in $HashtableFromJsonEntry['InputName']) {
						# retrieve value of the named variable
						Try {
							$VariableValue = Get-Variable -Name $VariableName -ValueOnly -Scope 'Global' -ErrorAction 'Stop'
						}
						Catch {
							Write-Warning -Message "exception caught retrieving value of the '$VariableName' variable: $($_.Exception.ToString())"
							Continue NextJsonEntry
						}

						# add variable name and value to parameters
						Try {
							$Parameters.Add($VariableName, $VariableValue)
						}
						Catch {
							Write-Warning -Message "exception caught adding '$VariableName' parameter to Parameters hashtable: $($_.Exception.ToString())"
							Continue NextJsonEntry
						}
					}
				}

				# if output name defined...
				If ($HashtableFromJsonEntry.ContainsKey('OutputName')) {
					# if outvariable already defined...
					If ($Parameters.ContainsKey('OutVariable')) {
						Write-Warning -Message "could not add OutputName as OutVariable; OutVariable already defined in parameters with value: $($Parameters['OutVariable'])"
						Continue NextJsonEntry
					}
					# add OutputName as OutVariable to parameters
					Try {
						$Parameters.Add('OutVariable', $HashtableFromJsonEntry['OutputName'])
					}
					Catch {
						Write-Warning -Message "exception caught adding 'OutVariable' parameter to Parameters hashtable: $($_.Exception.ToString())"
						Continue NextJsonEntry
					}
				}

				# report command
				Write-Host "Calling $($HashtableFromJsonEntry['CommandType']) Command: $($HashtableFromJsonEntry['Command'])"

				# if argument list defined...
				If ($ArgumentList -is [System.Collections.SortedList]) {
					# report each argument
					ForEach ($ArgumentValue in $ArgumentList.Values) {
						Write-Host "...with argument: $ArgumentValue"
					}
				}
				# if argument list not defined...
				Else {
					# report each parameter
					ForEach ($Parameter in $Parameters.GetEnumerator()) {
						Write-Host "...with parameter: $($Parameter.Key), $($Parameter.Value)"
					}
				}

				# suspend current transcript
				Try {
					Suspend-TranscriptForCommand
				}
				Catch {
					Write-Warning -Message "could not suspend transcript for script: $((Get-PSCallStack)[0].Command)"
					$ExceptionCaught = $true
					Continue NextJsonEntry
				}

				# start transcript for command
				Try {
					Start-TranscriptForCommand -TranscriptName $HashtableFromJsonEntry['CommandName']
				}
				Catch {
					Write-Warning -Message "could not start transcript for command: $($HashtableFromJsonEntry['Command'])"
					$ExceptionCaught = $true
					Continue NextJsonEntry
				}

				# if argument list defined...
				If ($ArgumentList -is [System.Collections.SortedList]) {
					# call command with values from argument list
					Try {
						. $HashtableFromJsonEntry['Command'] $ArgumentList.Values
					}
					Catch {
						Write-Warning -Message "exception caught calling '$($HashtableFromJsonEntry['Command'])' $($HashtableFromJsonEntry['CommandType']) command with arguments: $($_.Exception.ToString())"
						$ExceptionCaught = $true
					}
				}
				# if argument list not defined...
				Else {
					# call command with parameters
					Try {
						. $HashtableFromJsonEntry['Command'] @Parameters
					}
					Catch {
						Write-Warning -Message "exception caught calling '$($HashtableFromJsonEntry['Command'])' $($HashtableFromJsonEntry['CommandType']) command with parameters: $($_.Exception.ToString())"
						$ExceptionCaught = $true
					}
				}

				# stop transcript for command
				Try {
					Stop-TranscriptForCommand -TranscriptName $HashtableFromJsonEntry['CommandName']
				}
				Catch {
					Write-Warning -Message "could not stop transcript for command: $($HashtableFromJsonEntry['Command'])"
					$ExceptionCaught = $true
					Continue NextJsonEntry
				}

				# resume current transcript
				Try {
					Resume-TranscriptForCommand
				}
				Catch {
					Write-Warning -Message "could not resume transcript for script: $((Get-PSCallStack)[0].Command)"
					$ExceptionCaught = $true
					Continue NextJsonEntry
				}

				# if output name defined...
				If ($HashtableFromJsonEntry.ContainsKey('OutputName')) {
					# define command to unwrap OutVariable value from ArrayList
					$OutVariableCommand = '$(${0})' -f $HashtableFromJsonEntry['OutputName']

					# unwrap OutVariable value via Invoke-Expression
					Try {
						$OutputValue = Invoke-Expression -Command $OutVariableCommand -ErrorAction 'Stop'
					}
					Catch {
						Write-Warning -Message "exception caught unwrapping '$($HashtableFromJsonEntry['OutputName'])' variable: $($_.Exception.ToString())"
						$ExceptionCaught = $true
						Continue NextJsonEntry
					}

					# store OutVariable in named variable
					Try {
						New-Variable -Name $HashtableFromJsonEntry['OutputName'] -Value $OutputValue -Force -Scope 'Script' -ErrorAction 'Stop'
					}
					Catch {
						Write-Warning -Message "exception caught creating the '$($HashtableFromJsonEntry['OutputName'])' variable: $($_.Exception.ToString())"
						$ExceptionCaught = $true
						Continue NextJsonEntry
					}
				}
			}
		}
	}
}

End {
	# if default parameter set and skip transcript not requested...
	If ($PSCmdlet.ParameterSetName -eq 'Default' -and -not $SkipTranscript) {
		# stop transcript with default parameters
		Try {
			Stop-TranscriptForCommand
		}
		Catch {
			Throw $_
		}
	}
}
