<#
.SYNOPSIS
Adds or removes Scheduled Tasks defined by entries in a JSON configuration file.

.DESCRIPTION
Adds or removes Scheduled Tasks defined by entries in a JSON configuration file.

.PARAMETER Json
The path to a JSON file containing the configuration for this script.

.PARAMETER Show
Switch parameter to show all entries from the JSON configuration file. Cannot be combined with the Clear, Remove, or Add parameters.

.PARAMETER Clear
Switch parameter to clear all entries from the JSON configuration file. Cannot be combined with the Remove, Add, or Run parameters.

.PARAMETER Remove
Switch parameter to remove an entry from the JSON configuration file. Cannot be combined with the Clear, Add, or Run parameters.

.PARAMETER Add
Switch parameter to add an entry from the JSON configuration file. Cannot be combined with the Clear, Remove, or Run parameters.

.PARAMETER TaskName
The name of the scheduled task. Required when the Add or Remove parameters are specified.

.PARAMETER TaskPath
The path of a folder for the scheduled task. Required when the Add or Remove parameters are specified. The following restrictions apply:
 - The task path '\' is permitted only when paired with the 'Update-ScheduledTasks' task name.
 - Any task path starting with '\Microsoft' is not permitted to avoid conflicts with built-in scheduled tasks.

.PARAMETER Execute
The path to the executable that will be run by the scheduled task. Required when the Add parameter is specified.

.PARAMETER Argument
The string containing one or more arguments for the executable that will be run by the scheduled task.

.PARAMETER TriggerAt
The datetime when the scheduled task will first run. The value can be any valid datetime.

.PARAMETER RandomDelay
The timespan between when the scheduled task is scheduled to run and when it will start. The value can be any valid timespan. The default value is 5 minutes.

.PARAMETER RepetitionInterval
The timespan between when the scheduled task is scheduled to run and when it will run next. The value can be any valid timespan. The default value is 1 hour.

.PARAMETER ExecutionTimeLimit
The timespan between when the scheduled task starts and when it will be stopped. The value can be any valid timespan. The default value is 5 minutes.

.PARAMETER UserId
The user account for the scheduled task. The value can be any valid Windows account name. The default value is 'SYSTEM'.

.PARAMETER LogonType
The logon type for the scheduled task. The accepted values are 'ServiceAccount' and 'Password'. The default value is 'ServiceAccount'. The 'Password' value is only supported when the UserId is a Group-Managed Service Account.

.PARAMETER RunLevel
The run level for the scheduled task. The accepted values are 'Highest' and 'Limited'. The default value is 'Highest'.

.PARAMETER Modules
String or array of string representing the name or path to PowerShell modules required the scheduled task. Modules are installed to the AllUsers location.

.PARAMETER RemoveOldTasks
Switch parameter to remove any scheduled task that is not defined in the JSON file and located in a task path defined on any entry in the JSON configuration file.

.PARAMETER TranscriptName
The string to substitute for the random component of the default PowerShell transcript file name.

.PARAMETER TranscriptPath
The path to an existing folder for saving PowerShell transcript files.

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Update-ScheduledTasks.ps1 -Json C:\Content\config.json

.EXAMPLE
.\Update-ScheduledTasks.ps1 -Json C:\Content\config.json -Show

.EXAMPLE
.\Update-ScheduledTasks.ps1 -Json C:\Content\config.json -Clear

.EXAMPLE
.\Update-ScheduledTasks.ps1 -Json C:\Content\config.json -Remove -TaskName 'Test-Task' -TaskPath '\TEST'

.EXAMPLE
.\Update-ScheduledTasks.ps1 -Json C:\Content\config.json -Add -TaskName 'Test-Task' -TaskPath '\TEST' -Execute 'C:\path\to\some.exe'

.EXAMPLE
.\Update-ScheduledTasks.ps1 -Json C:\Content\config.json
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# path to JSON configuration file
	[Parameter(Mandatory = $True, Position = 0)]
	[string]$Json,
	# script parameters - mode
	[Parameter(Mandatory = $True, ParameterSetName = 'Show')]
	[switch]$Show,
	[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	[Parameter(Mandatory = $True, ParameterSetName = 'Install')]
	[switch]$Install,
	[Parameter(Mandatory = $True, ParameterSetName = 'Uninstall')]
	[switch]$Uninstall,
	[Parameter(ParameterSetName = 'Default')]
	[switch]$Run,
	[Parameter(ParameterSetName = 'Default')]
	[switch]$Update,
	# scheduled task parameter - register
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[string]$TaskName,
	# scheduled task parameter - register
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[string]$TaskPath,
	# scheduled task parameter - action
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[string]$Execute,
	# scheduled task parameter - action
	[Parameter(ParameterSetName = 'Add')]
	[string]$Argument,
	# scheduled task parameter - trigger
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Install')]
	[datetime]$TriggerAt = [datetime]'00:00:00',
	# scheduled task parameter - trigger
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Install')]
	[timespan]$RandomDelay = (New-TimeSpan -Minutes 5),
	# scheduled task parameter - trigger
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Install')]
	[timespan]$RepetitionInterval = (New-TimeSpan -Hours 1),
	# scheduled task parameter - settings
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'Install')]
	[timespan]$ExecutionTimeLimit = (New-TimeSpan -Minutes 30),
	# scheduled task parameter - principal
	[Parameter(ParameterSetName = 'Add')]
	[string]$UserId = 'SYSTEM',
	# scheduled task parameter - principal
	[Parameter(ParameterSetName = 'Add')][ValidateSet('ServiceAccount', 'Password')]
	[string]$LogonType = 'ServiceAccount',
	# scheduled task parameter - principal
	[Parameter(ParameterSetName = 'Add')][ValidateSet('Highest', 'Limited')]
	[string]$RunLevel = 'Highest',
	# scheduled task parameter - modules
	[Parameter(ParameterSetName = 'Add')]
	[string[]]$Modules,
	# switch to remove old tasks during run
	[Parameter(ParameterSetName = 'Default')]
	[switch]$RemoveOldTasks,
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipTranscript,
	# name in transcript files
	[Parameter(DontShow)]
	[string]$TranscriptName,
	# path to transcript files
	[Parameter(DontShow)]
	[string]$TranscriptPath,
	# local hostname
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

Begin {
	Function Install-ModuleFromJson {
		[CmdletBinding()]
		Param(
			[string]$Path
		)

		# get source module file
		Try {
			$SourceModule = Get-Item -Path $Path -ErrorAction Stop
		}
		Catch {
			Write-Output "`nERROR: could not find source module file: '$Path'"
			Return $_
		}

		# build PowerShell module path
		Try {
			$ModulePath = Join-Path -Path ([System.Environment]::GetFolderPath('ProgramFiles')) -ChildPath 'WindowsPowerShell\Modules'
		}
		Catch {
			Write-Output "`nERROR: could not build PowerShell module path"
			Return $_
		}

		# build individual module path
		Try {
			$TargetPath = Join-Path -Path $ModulePath -ChildPath $SourceModule.BaseName
		}
		Catch {
			Write-Output "`nERROR: could not build individual module path"
			Return $_
		}

		# get target module folder
		Try {
			$TargetFolder = Get-Item -Path $TargetPath -ErrorAction Stop
		}
		Catch {
			# create target module folder
			Try {
				$TargetFolder = New-Item -Path $TargetPath -ItemType Directory
			}
			Catch {
				Write-Output "`nERROR: could not create individual module path"
				Return $_
			}
		}

		# get target module path
		Try {
			$TargetModule = Get-ChildItem -Path $TargetFolder | Where-Object { $_.BaseName -eq $SourceModule.BaseName -and $_.Extension -eq '.psm1' }
		}
		Catch {
			Write-Output "`nERROR: could not find module folder: '$TargetPath'"
			Return $_
		}

		# if target module found...
		If ($TargetModule) {
			# get source module hash
			Try {
				$SourceHash = Get-FileHash -Path $SourceModule.FullName | Select-Object -ExpandProperty Hash
			}
			Catch {
				Write-Output "`nERROR: could not get hash of source module: '$($SourceModule.FullName)'"
				Return $_
			}
			# get target module hash
			Try {
				$TargetHash = Get-FileHash -Path $TargetModule.FullName | Select-Object -ExpandProperty Hash
			}
			Catch {
				Write-Output "`nERROR: could not get hash of target module: '$($TargetModule.FullName)'"
				Return $_
			}

			# if hashes match...
			If ($TargetHash -eq $SourceHash) {
				# report and return
				Write-Output "Verified module '$($TargetModule.BaseName)' at '$($TargetModule.FullName)'"
				Return
			}
			# if hashes do not match...
			Else {
				# remove target module
				Try {
					$TargetModule | Remove-Item -Force
					Write-Output "Removed module '$($TargetModule.FullName)'"
				}
				Catch {
					Write-Output "`nERROR: could not remove old module: '$($TargetModule.FullName)'"
					Return $_
				}
				# set target module to $null
				$TargetModule = $null
			}
		}

		# if target module not found...
		If ($null -eq $TargetModule) {
			Try {
				$TargetModule = Copy-Item -Path $SourceModule.FullName -Destination $TargetFolder.FullName -PassThru
				Write-Output "Installed module '$($TargetModule.BaseName)' to '$($TargetModule.FullName)'"
			}
			Catch {
				Write-Output "`nERROR: could not copy module: '$($TargetModule.FullName)'"
				Return $_
			}
		}
	}

	Function Test-ScheduledTaskPath {
		[CmdletBinding()]
		Param(
			[string]$TaskPath
		)

		# evaluate the scheduled task path
		switch -regex ($TaskPath) {
			# taskpath must start with '\'
			'^[^\\].*' {
				Return $false
			}
			# taskpath of '\' is not permitted; the default '\' path is reserved for tasks registered by other applications and vendors
			'^\\$' {
				Return $false
			}
			# taskpath starting with '\Microsoft\' is not permitted; the \Microsoft\ path is reserved for tasks registered by Microsoft
			'^\\(Microsoft(\\.*)?)?$' {
				Return $false
			}
			Default {
				Return $true
			}
		}
	}

	Function Update-ScheduledTaskFromJson {
		[CmdletBinding()]
		Param(
			# register
			[string]$TaskName,
			[string]$TaskPath,
			# action
			[string]$Execute,
			[string]$Argument,
			# trigger
			[datetime]$TriggerAt,
			[timespan]$RandomDelay,
			[timespan]$RepetitionInterval,
			# settings
			[timespan]$ExecutionTimeLimit,
			# principal
			[string]$UserId,
			[string]$LogonType,
			[string]$RunLevel
		)

		# create params for New-ScheduledTaskAction
		$ScheduledTaskActionParams = @{
			Execute  = $Execute
			Argument = $Argument
		}

		# create params for New-ScheduledTaskSettingsSet
		$ScheduledTaskSettingsSetParams = @{
			AllowStartIfOnBatteries    = $true
			DontStopIfGoingOnBatteries = $true
		}

		# create params for New-ScheduledTaskTrigger
		$ScheduledTaskTriggerParams = @{
			Once = $true
			At   = $TriggerAt
		}

		# add execution time limit if configured
		If ($null -ne $ExecutionTimeLimit -and $ExecutionTimeLimit -ne 0) {
			$ScheduledTaskSettingsSetParams['ExecutionTimeLimit'] = $ExecutionTimeLimit
		}

		# add random delay if configured
		If ($null -ne $RandomDelay -and $RandomDelay -ne 0) {
			$ScheduledTaskTriggerParams['RandomDelay'] = $RandomDelay
		}

		# add repetition interval if configured
		If ($null -ne $RepetitionInterval -and $RepetitionInterval -ne 0) {
			$ScheduledTaskTriggerParams['RepetitionInterval'] = $RepetitionInterval
		}

		# create params for New-ScheduledTaskTrigger
		$ScheduledTaskPrincipalParams = @{
			UserId = $UserId
		}

		# add repetition interval if configured
		If ($null -ne $LogonType) {
			$ScheduledTaskPrincipalParams['LogonType'] = $LogonType
		}

		# add repetition interval if configured
		If ($null -ne $RunLevel) {
			$ScheduledTaskPrincipalParams['RunLevel'] = $RunLevel
		}

		# create scheduled task action
		Try {
			$Action = New-ScheduledTaskAction @ScheduledTaskActionParams
		}
		Catch {
			Return $_
		}

		# create scheduled task trigger
		Try {
			$Trigger = New-ScheduledTaskTrigger @ScheduledTaskTriggerParams
		}
		Catch {
			Return $_
		}

		# create scheduled task settings
		Try {
			$Settings = New-ScheduledTaskSettingsSet @ScheduledTaskSettingsSetParams
		}
		Catch {
			Return $_
		}

		# create scheduled task principal
		Try {
			$Principal = New-ScheduledTaskPrincipal @ScheduledTaskPrincipalParams
		}
		Catch {
			Return $_
		}

		# verify task path starts with \
		If (!$TaskPath.StartsWith('\')) {
			$TaskPath = "\$TaskPath"
		}

		# verify task path ends with \
		If (!$TaskPath.EndsWith('\')) {
			$TaskPath = "$TaskPath\"
		}

		# get scheduled task
		Try {
			$Existing = Get-ScheduledTask | Where-Object { $_.TaskPath -eq $TaskPath -and $_.TaskName -eq $TaskName }
		}
		Catch {
			Write-Output "`nERROR: could not retrieve scheduled tasks with filter for task '$TaskName' at path '$TaskPath'"
			Return $_
		}

		# if scheduled task exists...
		If ($Existing) {
			# ...verify task action components
			$FixExecute = $Existing.Actions[0].Execute -ne $Action.Execute
			$FixArguments = $Existing.Actions[0].Arguments -ne $Action.Arguments

			# ...verify task action
			If ($FixExecute -or $FixArguments) {
				Try {
					Write-Output "Updating action for existing scheduled task '$TaskName' at path '$TaskPath'"
					$null = Set-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $Action
				}
				Catch {
					Write-Output "`nERROR: could not update action for existing scheduled task '$TaskName' at path '$TaskPath'"
					Return $_
				}
			}

			# ...verify task trigger components
			$FixStartBoundary = [datetime]$Existing.Triggers[0].StartBoundary -ne [datetime]$Trigger.StartBoundary
			If ($null -ne $RandomDelay -or $RandomDelay -ne 0) {
				$FixRandomDelay = $Existing.Triggers[0].RandomDelay -ne $Trigger.RandomDelay
			}
			If ($null -ne $RepetitionInterval -or $RepetitionInterval -ne 0) {
				$FixRepetitionInterval = $Existing.Triggers[0].Repetition.Interval -ne $Trigger.Repetition.Interval
			}

			# ...verify task trigger
			If ($FixStartBoundary -or $FixRandomDelay -or $FixRepetitionInterval) {
				Try {
					Write-Output "Updating trigger for existing scheduled task '$TaskName' at path '$TaskPath'"
					$null = Set-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Trigger $Trigger
				}
				Catch {
					Write-Output "`nERROR: could not update trigger for existing scheduled task '$TaskName' at path '$TaskPath'"
					Return $_
				}
			}
			# ...verify task settings components
			$FixEnabled = $Existing.Settings.Enabled -ne $Settings.Enabled
			$FixStartOnBattery = $Existing.Settings.DisallowStartIfOnBatteries -ne $Settings.DisallowStartIfOnBatteries
			$FixStopIfOnBattery = $Existing.Settings.StopIfGoingOnBatteries -ne $Settings.StopIfGoingOnBatteries
			If ($null -ne $ExecutionTimeLimit -or $ExecutionTimeLimit -ne 0) {
				$FixExecutionTimeLimit = $Existing.Settings.ExecutionTimeLimit -ne $Settings.ExecutionTimeLimit
			}

			# ...verify task settings
			If ($FixEnabled -or $FixStartOnBattery -or $FixStopIfOnBattery -or $FixExecutionTimeLimit) {
				Try {
					Write-Output "Updating settings for existing scheduled task '$TaskName' at path '$TaskPath'"
					$null = Set-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Settings $Settings
				}
				Catch {
					Write-Output "`nERROR: could not update settings for existing scheduled task '$TaskName' at path '$TaskPath'"
					Return $_
				}
			}

			# ...verify task principal components
			If ($Principal.UserId.Contains('\')) {
				$FixUserId = $Existing.Principal.UserId -ne ($Principal.UserId.Split('\'))[1]
			}
			Else {
				$FixUserId = $Existing.Principal.UserId -ne $Principal.UserId
			}
			If ($null -ne $LogonType) {
				$FixLogonType = $Existing.Principal.LogonType -ne $Principal.LogonType
			}
			If ($null -ne $RunLevel) {
				$FixRunLevel = $Existing.Principal.RunLevel -ne $Principal.RunLevel
			}

			# ...verify task principal
			If ($FixUserId -or $FixLogonType -or $FixRunLevel) {
				Try {
					Write-Output "Updating principal for existing scheduled task '$TaskName' at path '$TaskPath'"
					$null = Set-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Principal $Principal
				}
				Catch {
					Write-Output "`nERROR: could not update principal for existing scheduled task '$TaskName' at path '$TaskPath'"
					Return $_
				}
			}

			# report then return
			Write-Output "Verified existing scheduled task '$TaskName' at path '$TaskPath'"
			Return
		}
		# if scheduled task does not exist...
		Else {
			# ...create params for Register-ScheduledTask
			$ScheduledTaskParams = @{
				TaskName  = $TaskName
				TaskPath  = $TaskPath
				Action    = $Action
				Trigger   = $Trigger
				Settings  = $Settings
				Principal = $Principal
				Force     = $true
			}
			# ...then register scheduled task
			Try {
				$null = Register-ScheduledTask @ScheduledTaskParams
			}
			Catch {
				Return $_
			}
			# ...then return and move to next tasks
			Write-Output "Registered new scheduled task '$TaskName' at path '$TaskPath'"
			Return
		}
	}

	Function Start-TranscriptWithHostAndDate {
		Param(
			# name for transcript file
			[Parameter()]
			[string]$TranscriptName,
			# path for transcript file
			[Parameter()]
			[string]$TranscriptPath,
			# log start time
			[Parameter(DontShow)]
			[string]$TranscriptTime = ([datetime]::Now.ToString('yyyyMMddHHmmss')),
			# local hostname
			[Parameter(DontShow)]
			[string]$TranscriptHost = ([System.Environment]::MachineName)
		)

		# verify transcript name
		If (!$PSBoundParameters.ContainsKey('TranscriptName')) {
			$TranscriptName = (Get-Item -Path $PSCommandPath | Select-Object -ExpandProperty 'BaseName')
		}

		# verify transcript path
		If (!$PSBoundParameters.ContainsKey('TranscriptPath') -or !(Test-Path -Path $TranscriptPath -PathType Container)) {
			$TranscriptPath = [System.Environment]::GetFolderPath('CommonApplicationData')
		}

		# build transcript basename from transcript name and hostname
		$TranscriptBase = "PowerShell_transcript.$TranscriptHost.$TranscriptName"

		# build transcript file name with transcript basename and current datetime
		$TranscriptFile = "$TranscriptBase.$TranscriptTime.txt"

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
			# name for transcript file
			[Parameter()]
			[string]$TranscriptName,
			# path for transcript file
			[Parameter()]
			[string]$TranscriptPath,
			# minimum number of transcript files for removal
			[Parameter(DontShow)]
			[uint16]$TranscriptCount = 7,
			# minimum age of transcript files for removal
			[Parameter(DontShow)]
			[double]$TranscriptDays = 7,
			# datetime for transcript files for removal
			[Parameter(DontShow)]
			[datetime]$TranscriptDate = ([datetime]::Now.AddDays(-$TranscriptDays)),
			# local hostname
			[Parameter(DontShow)]
			[string]$TranscriptHost = ([System.Environment]::MachineName)
		)

		# verify transcript name
		If (!$PSBoundParameters.ContainsKey('TranscriptName')) {
			$TranscriptName = (Get-Item -Path $PSCommandPath | Select-Object -ExpandProperty 'BaseName')
		}

		# verify transcript path
		If (!$PSBoundParameters.ContainsKey('TranscriptPath') -or !(Test-Path -Path $TranscriptPath -PathType Container)) {
			$TranscriptPath = [System.Environment]::GetFolderPath('CommonApplicationData')
		}

		# build transcript basename from transcript name and hostname
		$TranscriptBase = "PowerShell_transcript.$TranscriptHost.$TranscriptName"

		# declare transcript cleanup
		Write-Verbose -Message "Removing any transcripts named '$TranscriptBase' from '$TranscriptPath' that are older than '$TranscriptDays' days" -Verbose

		# get transcript files
		$TranscriptFiles = Get-ChildItem -Path $TranscriptPath | Where-Object { $_.BaseName.StartsWith($TranscriptBase, [System.StringComparison]::InvariantCultureIgnoreCase) -and $_.LastWriteTime -lt $TranscriptDate }

		# get transcript files newer than cleanup date
		$NewFiles = $TranscriptFiles | Where-Object { $_.LastWriteTime -gt $TranscriptDate }

		# if count of transcript files count is less than cleanup threshold...
		If ($TranscriptCount -lt $NewFiles.Count ) {
			# declare and continue
			Write-Verbose -Message "Skipping transcript removal; count of transcripts ($($NewFiles.Count)) would be below minimum transcript count ($TranscriptCount)" -Verbose
		}
		# if count of transcript files is not less than cleanup threshold...
		Else {
			# get log files older than cleanup date
			$OldFiles = $TranscriptFiles | Where-Object { $_.LastWriteTime -lt $TranscriptDate } | Sort-Object -Property FullName
			# remove old logs
			ForEach ($OldFile in $OldFiles) {
				Try {
					Remove-Item -Path $OldFile.FullName -Force -Verbose -ErrorAction Stop
				}
				Catch {
					$_
				}
			}
		}

		# stop transcript
		Try {
			$null = Stop-Transcript
		}
		Catch {
			Throw $_
		}
	}

	# if running...
	If ($PSCmdlet.ParameterSetName -eq 'Default') {
		# define hashtable for transcript functions
		$TranscriptWithHostAndDate = @{}
		# define parameters for transcript functions
		If ($PSBoundParameters.ContainsKey('TranscriptName')) { $TranscriptWithHostAndDate['TranscriptName'] = $TranscriptName }
		If ($PSBoundParameters.ContainsKey('TranscriptPath')) { $TranscriptWithHostAndDate['TranscriptPath'] = $TranscriptPath }
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
	# if Install set...
	If ($Install) {
		# define static parameters for Update-ScheduledTaskFromJson
		$UpdateScheduledTaskFromJson = @{
			TaskName  = 'Update-ScheduledTasks'
			TaskPath  = '\'
			Execute   = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
			Argument  = "-NonInteractive -NoProfile -ExecutionPolicy ByPass -File `"$PSCommandPath`" -Json `"$Json`""
			UserId    = 'SYSTEM'
			LogonType = 'ServiceAccount'
			RunLevel  = 'Highest'
		}

		# if TriggerAt parameter provided...
		If ($PSBoundParameters.ContainsKey('TriggerAt')) {
			$UpdateScheduledTaskFromJson['TriggerAt'] = $TriggerAt
		}
		Else {
			$UpdateScheduledTaskFromJson['TriggerAt'] = [datetime]'00:00:00'
		}

		# if RandomDelay parameter provided...
		If ($PSBoundParameters.ContainsKey('RandomDelay')) {
			$UpdateScheduledTaskFromJson['RandomDelay'] = $RandomDelay
		}
		Else {
			$UpdateScheduledTaskFromJson['RandomDelay'] = (New-TimeSpan -Minutes 0)
		}

		# if ExecutionTimeLimit parameter provided...
		If ($PSBoundParameters.ContainsKey('ExecutionTimeLimit')) {
			$UpdateScheduledTaskFromJson['ExecutionTimeLimit'] = $ExecutionTimeLimit
		}
		Else {
			$UpdateScheduledTaskFromJson['ExecutionTimeLimit'] = (New-TimeSpan -Minutes 1)
		}

		# if RepetitionInterval parameter provided...
		If ($PSBoundParameters.ContainsKey('RepetitionInterval')) {
			$UpdateScheduledTaskFromJson['RepetitionInterval'] = $RepetitionInterval
		}
		Else {
			$UpdateScheduledTaskFromJson['RepetitionInterval'] = (New-TimeSpan -Minutes 15)
		}

		# install scheduled task
		Try {
			Update-ScheduledTaskFromJson @UpdateScheduledTaskFromJson
		}
		Catch {
			Return $_
		}

		# report and return
		Write-Output "`nInstalled Update-ScheduledTasks"
		Return
	}

	# if Uninstall set...
	If ($Uninstall) {
		# define parameters for Unregister-ScheduledTask
		$UnregisterScheduledTask = @{
			TaskName = 'Update-ScheduledTasks'
			TaskPath = '\'
			Confirm  = $false
		}

		# uninstall scheduled task
		Try {
			Unregister-ScheduledTask @UnregisterScheduledTask
		}
		Catch {
			Return $_
		}

		# report and return
		Write-Output 'Uninstalled Update-ScheduledTasks'
		Return
	}

	# if JSON file found...
	If (Test-Path -Path $Json) {
		# ...create JSON data object as array of PSCustomObjects from JSON file content
		Try {
			$JsonData = [array](Get-Content -Path $Json -ErrorAction Stop | ConvertFrom-Json)
		}
		Catch {
			Write-Output "`nERROR: could not read configuration file: '$Json'"
			Return $_
		}
	}
	# if JSON file was not found...
	Else {
		# ...and Add set...
		If ($Add) {
			# ...try to create the JSON file
			Try {
				$null = New-Item -ItemType 'File' -Path $Json -ErrorAction Stop
			}
			Catch {
				Write-Output "`nERROR: could not create configuration file: '$Json'"
				Return $_
			}
			# ...create JSON data object as empty array
			$JsonData = @()
		}
		# ...and Add not set...
		Else {
			# ...report and return
			Write-Output "`nERROR: could not find configuration file: '$Json'"
			Return
		}
	}

	# evaluate parameters
	switch ($true) {
		# show configuration file
		$Show {
			Write-Output "`nDisplaying '$Json'"
			$JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
		}
		# clear configuration file
		$Clear {
			Try {
				[string]::Empty | Set-Content -Path $Json
				Write-Output "`nCleared configuration file: '$Json'"
			}
			Catch {
				Write-Output "`nERROR: could not clear configuration file: '$Json'"
				Return $_
			}
		}
		# remove entry from configuration file
		$Remove {
			Try {
				$JsonData = $JsonData | Where-Object { -not ($_.TaskName -eq $TaskName -and $_.TaskPath -eq $TaskPath) }
				If ($null -eq $JsonData) {
					[string]::Empty | Set-Content -Path $Json
					Write-Output "`nRemoved '$TaskName' at '$Taskpath' from configuration file: '$Json'"
				}
				Else {
					$JsonData | ConvertTo-Json | Set-Content -Path $Json
					Write-Output "`nRemoved '$TaskName' at '$Taskpath' from configuration file: '$Json'"
				}
				$JsonData | Format-List
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file: '$Json'"
				Return $_
			}
		}
		# add entry to configuration file
		$Add {
			Try {
				# validate task path when task name not 'Update-ScheduledTasks'
				If ($TaskName -ne 'Update-ScheduledTasks' -and -not (Test-ScheduledTaskPath -TaskPath $TaskPath)) {
					Write-Output "`nERROR: the path defined is not permitted: '$TaskPath'"
					Return
				}

				# verify task path starts with \
				If (!$TaskPath.StartsWith('\')) {
					$TaskPath = "\$TaskPath"
				}

				# verify task path ends with \
				If (!$TaskPath.EndsWith('\')) {
					$TaskPath = "$TaskPath\"
				}

				# create ordered dictionary for custom object
				$JsonParameters = [ordered]@{
					TaskName  = $TaskName
					TaskPath  = $TaskPath
					Execute   = $Execute
					Argument  = $Argument
					UserId    = $UserId
					LogonType = $LogonType
					TriggerAt = $TriggerAt
				}

				# add RandomDelay if provided as datetime value
				If ($null -ne $RandomDelay) {
					$JsonParameters['RandomDelayTime'] = [datetime]($TriggerAt + $RandomDelay)
				}

				# add ExecutionTimeLimitTime1 if provided as datetime value
				If ($null -ne $ExecutionTimeLimit) {
					$JsonParameters['ExecutionTimeLimitTime'] = [datetime]($TriggerAt + $ExecutionTimeLimit)
				}

				# add RepetitionInterval if provided as datetime value
				If ($null -ne $RepetitionInterval) {
					$JsonParameters['RepetitionIntervalTime'] = [datetime]($TriggerAt + $RepetitionInterval)
				}

				# add RunLevel if provided
				If ($null -ne $RunLevel) {
					$JsonParameters['RunLevel'] = $RunLevel
				}

				# add Modules if provided
				If ($null -ne $Modules) {
					$JsonParameters['Modules'] = $Modules
				}

				# add current time as FileDateTimeUniversal
				$JsonParameters['Updated'] = (Get-Date -Format FileDateTimeUniversal)

				# create custom object from hashtable
				$JsonDatum = [pscustomobject]$JsonParameters

				# if existing entry has same primary key(s)...
				If ($JsonData | Where-Object { $_.TaskName -eq $TaskName -and $_.TaskPath -eq $TaskPath }) {
					# inquire before removing existing entry
					Write-Warning -Message "Will overwrite existing entry for '$TaskName' at '$TaskPath' in configuration file: '$Json' `nAny previous configuration for this entry will **NOT** be preserved" -WarningAction Inquire
					# remove existing entry with same primary key(s)
					$JsonData = $JsonData | Where-Object { -not ($_.TaskName -eq $TaskName -and $_.TaskPath -eq $TaskPath) }
				}

				# add entry to data
				$JsonData += $JsonDatum

				# export JSON data
				$JsonData | Sort-Object -Property TaskPath, TaskName | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
				Write-Output "`nAdded '$TaskName' to configuration file: '$Json'"
				$JsonData | Sort-Object -Property TaskPath, TaskName | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file: '$Json'"
				Return $_
			}
		}
		# process entries in configuration file
		Default {
			# declare start
			Write-Host "`nUpdating scheduled tasks from '$Json'"

			# check entry count in configuration file
			If ($JsonData.Count -eq 0) {
				Write-Output "ERROR: no entries found in configuration file: $Json"
				Return
			}

			# create hashtable for cleanup
			Try {
				$ExpectedTasks = @{}
			}
			Catch {
				Write-Output 'ERROR: could not create hashtable for tasks'
				Return $_
			}

			# process configuration file
			:JsonDatum ForEach ($JsonDatum in $JsonData) {
				# validate values in JSON file
				Switch ($true) {
					([string]::IsNullOrEmpty($JsonDatum.TaskName)) {
						Write-Output "`nERROR: required entry (TaskName) not found in configuration file: $Json"; Continue JsonDatum
					}
					([string]::IsNullOrEmpty($JsonDatum.TaskPath)) {
						Write-Output "`nERROR: required value (TaskPath) not found in configuration file: $Json"; Continue JsonDatum
					}
					([string]::IsNullOrEmpty($JsonDatum.Execute)) {
						Write-Output "`nERROR: required value (Execute) not found in configuration file: $Json"; Continue JsonDatum
					}
					([string]::IsNullOrEmpty($JsonDatum.Argument)) {
						Write-Output "`nERROR: required value (Argument) not found in configuration file: $Json"; Continue JsonDatum
					}
					([string]::IsNullOrEmpty($JsonDatum.UserId)) {
						Write-Output "`nERROR: required value (UserId) not found in configuration file: $Json"; Continue JsonDatum
					}
					([string]::IsNullOrEmpty($JsonDatum.LogonType)) {
						Write-Output "`nERROR: required value (LogonType) not found in configuration file: $Json"; Continue JsonDatum
					}
					($JsonDatum.TriggerAt -isnot [datetime]) {
						Write-Output "`nERROR: invalid entry (TriggerAt) found in configuration file: $Json"; Continue JsonDatum
					}
					Default {
						# if valid task path provided...
						If (Test-ScheduledTaskPath -TaskPath $JsonDatum.TaskPath) {
							# check expected tasks hashtable for task path
							If (!$ExpectedTasks.ContainsKey($JsonDatum.TaskPath) -or $ExpectedTasks[$JsonDatum.TaskPath] -isnot [System.Collections.Generic.List[string]]) {
								$ExpectedTasks[$JsonDatum.TaskPath] = [System.Collections.Generic.List[string]]::new()
							}

							# update expected tasks hashtable with task name
							Try {
								$ExpectedTasks[$JsonDatum.TaskPath].Add($JsonDatum.TaskName)
							}
							Catch {
								Write-Output "ERROR: adding task to hashtable: '$($JsonDatum.TaskName)'"
								Continue JsonDatum
							}
						}

						# define hashtable for function
						$UpdateScheduledTaskFromJson = @{
							TaskName  = [string]$JsonDatum.TaskName
							TaskPath  = [string]$JsonDatum.TaskPath
							Execute   = [string]$JsonDatum.Execute
							Argument  = [string]$JsonDatum.Argument
							UserId    = [string]$JsonDatum.UserId
							LogonType = [string]$JsonDatum.LogonType
							TriggerAt = [datetime]$JsonDatum.TriggerAt
						}

						# if RunLevel defind in JSON...
						If ($null -ne $JsonDatum.RunLevel -and $JsonDatum.RunLevel -is [string]) {
							# add RunLevel to hashtable
							$UpdateScheduledTaskFromJson['RunLevel'] = [string]$RunLevel
						}

						# if TriggerAt defined in JSON...
						If ($null -ne $JsonDatum.TriggerAt) {
							# ...and TriggerAt is datetime...
							If ($JsonDatum.TriggerAt -is [datetime]) {
								# ...add TriggerAt to hashtable
								$UpdateScheduledTaskFromJson['TriggerAt'] = [datetime]$JsonDatum.TriggerAt
							}
							Else {
								Write-Output "ERROR: could not cast TriggerAt to [datetime] in task: '$($JsonDatum.TaskName)'"
								Continue JsonData
							}

							# ...and RandomDelayTime defined in JSON...
							If ($null -ne $JsonDatum.RandomDelayTime) {
								# ...and RandomDelayTime is datetime...
								If ($JsonDatum.RandomDelayTime -is [datetime]) {
									# ...and RandomDelayTime is greater than (after) TriggerAt
									If ($JsonDatum.RandomDelayTime -ge $JsonDatum.TriggerAt) {
										# ...create RandomDelay timespan and add to hashtable
										$UpdateScheduledTaskFromJson['RandomDelay'] = [timespan]($JsonDatum.RandomDelayTime - $JsonDatum.TriggerAt)
									}
									Else {
										Write-Output "ERROR: RandomDelayTime is before TriggerAt in task: '$($JsonDatum.TaskName)'"
										Continue JsonData
									}
								}
								Else {
									Write-Output "ERROR: could not cast RandomDelayTime to [datetime] in task: '$($JsonDatum.TaskName)'"
									Continue JsonData
								}
							}

							# ...and RepetitionIntervalTime defined in JSON...
							If ($null -ne $JsonDatum.RepetitionIntervalTime) {
								# ...and RepetitionIntervalTime is datetime...
								If ($JsonDatum.RepetitionIntervalTime -is [datetime]) {
									# ...and RepetitionIntervalTime is greater than (after) TriggerAt
									If ($JsonDatum.RepetitionIntervalTime -ge $JsonDatum.TriggerAt) {
										# ...create RepetitionInterval timespan and add to hashtable
										$UpdateScheduledTaskFromJson['RepetitionInterval'] = [timespan]($JsonDatum.RepetitionIntervalTime - $JsonDatum.TriggerAt)
									}
									Else {
										Write-Output "ERROR: RepetitionIntervalTime is before TriggerAt in task: '$($JsonDatum.TaskName)'"
										Continue JsonData
									}
								}
								Else {
									Write-Output "ERROR: could not cast RepetitionIntervalTime to [datetime] in task: '$($JsonDatum.TaskName)'"
									Continue JsonData
								}
							}

							# ...and ExecutionTimeLimitTime defined in JSON...
							If ($null -ne $JsonDatum.ExecutionTimeLimitTime) {
								# ...and ExecutionTimeLimitTime is datetime...
								If ($JsonDatum.ExecutionTimeLimitTime -is [datetime]) {
									# ...and ExecutionTimeLimitTime is greater than (after) TriggerAt
									If ($JsonDatum.ExecutionTimeLimitTime -ge $JsonDatum.TriggerAt) {
										# ...create ExecutionTimeLimit timespan and add to hashtable
										$UpdateScheduledTaskFromJson['ExecutionTimeLimit'] = [timespan]($JsonDatum.ExecutionTimeLimitTime - $JsonDatum.TriggerAt)
									}
									Else {
										Write-Output "ERROR: ExecutionTimeLimitTime is before TriggerAt in task: '$($JsonDatum.TaskName)'"
										Continue JsonData
									}
								}
								Else {
									Write-Output "ERROR: could not cast ExecutionTimeLimitTime to [datetime] in task: '$($JsonDatum.TaskName)'"
									Continue JsonData
								}
							}
						}

						# update scheduled task
						Try {
							Update-ScheduledTaskFromJson @UpdateScheduledTaskFromJson
						}
						Catch {
							Return $_
						}

						# if Modules defined in JSON...
						ForEach ($Module in $JsonDatum.Modules) {
							# install module
							Try {
								Install-ModuleFromJson -Path $Module
							}
							Catch {
								Return $_
							}
						}
					}
				}
			}

			# process cleanup hashtable
			:TaskPath ForEach ($TaskPath in $ExpectedTasks.Keys) {
				# check if any bad path values have been snuck in
				If (-not (Test-ScheduledTaskPath -TaskPath $TaskPath)) {
					Write-Output "`nERROR: the path defined is not permitted: '$TaskPath' for '$($ExpectedTasks[$TaskPath])'"
					Continue TaskPath
				}

				# get all tasks in TaskPath
				Try {
					$TasksInPath = Get-ScheduledTask | Where-Object { $_.TaskPath -eq $TaskPath } | Select-Object -ExpandProperty 'TaskName'
				}
				Catch {
					Write-Output "`nERROR: could not retrieve tasks from path: '$TaskPath'"
					Return $_
				}

				# process each task in key
				ForEach ($TaskName in $TasksInPath) {
					If ($TaskName -notin $ExpectedTasks[$TaskPath]) {
						Try {
							Write-Output "WARNING: the task '$TaskName' should not exist in path '$TaskPath'"
							# Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
						}
						Catch {
							Write-Output "`nERROR: could not unregister task '$TaskName' from path '$TaskPath'"
							Return $_
						}
					}
				}
			}
		}
	}
}

End {
	# if running...
	If ($PSCmdlet.ParameterSetName -eq 'Default') {
		# stop transcript with parameters
		Try {
			Stop-TranscriptWithHostAndDate @TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}
