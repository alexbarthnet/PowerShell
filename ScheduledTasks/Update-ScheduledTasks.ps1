<#
.SYNOPSIS
Adds or removes Scheduled Tasks defined by entries in a JSON configuration file.

.DESCRIPTION
Adds or removes Scheduled Tasks defined by entries in a JSON configuration file.

.PARAMETER Json
The path to a JSON file containing the configuration for this script.

.PARAMETER Show
Switch parameter to show all entries from the JSON configuration file. Cannot be combined with the Clear, Remove, Add, AddSelf, RemoveSelf, Register, or Unregister parameters.

.PARAMETER Clear
Switch parameter to clear all entries from the JSON configuration file. Cannot be combined with the Show, Remove, Add, AddSelf, RemoveSelf, Register, or Unregister parameters.

.PARAMETER Remove
Switch parameter to remove an entry from the JSON configuration file. Cannot be combined with the Show, Clear, Add, AddSelf, RemoveSelf, Register, or Unregister parameters.

.PARAMETER Add
Switch parameter to add an entry to the JSON configuration file. Cannot be combined with the Show, Clear, Remove, AddSelf, RemoveSelf, Register, or Unregister parameters.

.PARAMETER AddSelf
Switch parameter to add an entry to the JSON configuration file for this script. Cannot be combined with the Show, Clear, Remove, Add, RemoveSelf, Register, or Unregister parameters. The entry is created with the following defaults:
 - The entry will be created in the root task path
 - The entry will run this script from the current path with the provided JSON file
 - The entry will run as SYSTEM with highest privileges
 - The entry will run at the start of the next day then every 15 minutes afterwards
 - The entry will run for a maximum of 1 minute

.PARAMETER RemoveSelf
Switch parameter to remove the entry from the JSON configuration file for this script. Cannot be combined with the Show, Clear, Remove, Add, AddSelf, Register, or Unregister parameters.

.PARAMETER Register
Switch parameter to register a scheduled task for this script. Cannot be combined with the Show, Clear, Remove, Add, AddSelf, RemoveSelf, or Unregister parameters. The task is created with the following defaults:
 - The task will be created in the root task path
 - The task will run this script from the current path with the provided JSON file
 - The task will run as SYSTEM with highest privileges
 - The task will run at the start of the next day then every 15 minutes afterwards
 - The task will run for a maximum of 1 minute

.PARAMETER Unregister
Switch parameter to unregister the scheduled task created by the Register switch. Cannot be combined with the Show, Clear, Remove, Add, AddSelf, RemoveSelf, or Register parameters.

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

.PARAMETER NoTrigger
Switch parameter to create the scheduled task without a trigger.

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

.PARAMETER Disable
Switch parameter to disable the scheduled task. The scheduled task will be enabled if this parameter is not present.

.PARAMETER ReportUndefinedTasks
Switch parameter to report scheduled tasks that are not defined in the JSON file and located in any of the task paths defined on the entries in the JSON configuration file.

.PARAMETER RemoveUndefinedTasks
Switch parameter to remove scheduled tasks that are not defined in the JSON file and located in any of the task paths defined on the entries in the JSON configuration file.

.PARAMETER SkipTranscript
Switch parameter to skip creating a PowerShell transcript for this script.

.PARAMETER SkipTextOutput
Switch parameter to skip creating a text output log file when a PowerShell transcript is created for this script.

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
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	[Parameter(Mandatory = $True, ParameterSetName = 'AddSelf')]
	[switch]$AddSelf,
	[Parameter(Mandatory = $True, ParameterSetName = 'RemoveSelf')]
	[switch]$RemoveSelf,
	[Parameter(Mandatory = $True, ParameterSetName = 'Register')]
	[switch]$Register,
	[Parameter(Mandatory = $True, ParameterSetName = 'Unregister')]
	[switch]$Unregister,
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
	[switch]$NoTrigger,
	# scheduled task parameter - trigger
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'AddSelf')]
	[Parameter(ParameterSetName = 'Register')]
	[datetime]$TriggerAt = [datetime]'00:00:00',
	# scheduled task parameter - trigger
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'AddSelf')]
	[Parameter(ParameterSetName = 'Register')]
	[timespan]$RandomDelay = [timespan]::FromMinutes(5),
	# scheduled task parameter - trigger
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'AddSelf')]
	[Parameter(ParameterSetName = 'Register')]
	[timespan]$RepetitionInterval = [timespan]::FromHours(1),
	# scheduled task parameter - settings
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'AddSelf')]
	[Parameter(ParameterSetName = 'Register')]
	[timespan]$ExecutionTimeLimit = [timespan]::FromMinutes(30),
	# scheduled task parameter - principal
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'AddSelf')]
	[Parameter(ParameterSetName = 'Register')]
	[string]$UserId = 'SYSTEM',
	# scheduled task parameter - principal
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'AddSelf')]
	[Parameter(ParameterSetName = 'Register')]
	[ValidateSet('ServiceAccount', 'Password')]
	[string]$LogonType = 'ServiceAccount',
	# scheduled task parameter - principal
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'AddSelf')]
	[Parameter(ParameterSetName = 'Register')]
	[ValidateSet('Highest', 'Limited')]
	[string]$RunLevel = 'Highest',
	# switch to disable scheduled
	[Parameter(ParameterSetName = 'Add')]
	[Parameter(ParameterSetName = 'AddSelf')]
	[Parameter(ParameterSetName = 'Register')]
	[switch]$Disable,
	# switch to report undefined tasks during run
	[Parameter(ParameterSetName = 'Default')]
	[Parameter(ParameterSetName = 'AddSelf')]
	[Parameter(ParameterSetName = 'Register')]
	[switch]$ReportUndefinedTasks,
	# switch to remove undefined tasks during run
	[Parameter(ParameterSetName = 'Default')]
	[Parameter(ParameterSetName = 'AddSelf')]
	[Parameter(ParameterSetName = 'Register')]
	[switch]$RemoveUndefinedTasks,
	# legacy switch to process JSON entries for previous versions of the script
	[Parameter(ParameterSetName = 'Default')]
	[switch]$Run,
	# legacy switch to process JSON entries for previous versions of the script
	[Parameter(ParameterSetName = 'Default')]
	[switch]$Update,
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipTranscript,
	# switch to skip text output logging
	[Parameter(DontShow)]
	[switch]$SkipTextOutput
)

Begin {
	Function Compare-CimInstance {
		Param(
			[Microsoft.Management.Infrastructure.CimInstance]$ReferenceInstance,
			[Microsoft.Management.Infrastructure.CimInstance]$DifferenceInstance
		)

		# for each named typed property in the reference object...
		ForEach ($Name in $ReferenceInstance.CimInstanceProperties.Where({ $_.CimType -notin 'Instance', 'InstanceArray' }).Name) {
			# report property name
			Write-Verbose -Message "comparing '$Name' property in reference instance"
			# if property value in reference instance does not match property value in difference instance...
			If ($ReferenceInstance.$Name -ne $DifferenceInstance.$Name) {
				# return false
				Return $false
			}
		}

		# for each named typed property in the difference object...
		ForEach ($Name in $DifferenceInstance.CimInstanceProperties.Where({ $_.CimType -notin 'Instance', 'InstanceArray' }).Name) {
			# report property name
			Write-Verbose -Message "comparing '$Name' property in difference instance"
			# if property value in difference instance does not match property value in reference instance...
			If ($DifferenceInstance.$Name -ne $ReferenceInstance.$Name) {
				# return false
				Return $false
			}
		}

		# for each named instance in the reference object...
		ForEach ($InstanceName in $ReferenceInstance.CimInstanceProperties.Where({ $_.CimType -eq 'Instance' }).Name) {
			# if named instance missing from difference object...
			If ($null -eq $DifferenceInstance.CimInstanceProperties.Where({ $_.CimType -eq 'Instance' -and $_.Name -eq $InstanceName })) {
				# return false
				Return $false
			}
			# compare instance objects
			Try {
				$ForwardComparison = Compare-CimInstance -ReferenceInstance $ReferenceInstance.$InstanceName -DifferenceInstance $DifferenceInstance.$InstanceName
			}
			Catch {
				Return $_
			}
			# if forward comparison is false...
			If ($ForwardComparison -eq $false) {
				Return $false
			}
		}

		# for each named instance in the difference object...
		ForEach ($InstanceName in $DifferenceInstance.CimInstanceProperties.Where({ $_.CimType -eq 'Instance' }).Name) {
			# if named instance missing from reference object...
			If ($null -eq $ReferenceInstance.CimInstanceProperties.Where({ $_.CimType -eq 'Instance' -and $_.Name -eq $InstanceName })) {
				# return false
				Return $false
			}
			# compare instance objects
			Try {
				$ReverseComparison = Compare-CimInstance -ReferenceInstance $DifferenceInstance.$InstanceName -DifferenceInstance $ReferenceInstance.$InstanceName
			}
			Catch {
				Return $_
			}
			# if reverse comparison is false...
			If ($ReverseComparison -eq $false) {
				Return $false
			}
		}

		# TODO: complete forward check of instance arrays
		# for each named instance array in reference object...
		ForEach ($InstanceName in $ReferenceInstance.CimInstanceProperties.Where({ $_.CimType -eq 'InstanceArray' }).Name) {
			# if named instance array missing from difference object...
			If ($null -eq $DifferenceInstance.CimInstanceProperties.Where({ $_.CimType -eq 'InstanceArray' -and $_.Name -eq $InstanceName })) {
				# return false
				Return $false
			}

		}

		# TODO: complete reverse check of instance arrays
		# for each named instance array in difference object...
		ForEach ($InstanceName in $DifferenceInstance.CimInstanceProperties.Where({ $_.CimType -eq 'InstanceArray' }).Name) {
			# if named instance array missing from reference object...
			If ($null -eq $ReferenceInstance.CimInstanceProperties.Where({ $_.CimType -eq 'InstanceArray' -and $_.Name -eq $InstanceName })) {
				# return false
				Return $false
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
			[boolean]$Disable,
			[timespan]$ExecutionTimeLimit,
			# principal
			[string]$UserId,
			[string]$LogonType,
			[string]$RunLevel
		)

		# define parameters for New-ScheduledTaskAction
		$ScheduledTaskActionParameters = @{
			Execute  = $Execute
			Argument = $Argument
		}

		# define parameters for New-ScheduledTaskPrincipal
		$ScheduledTaskPrincipalParameters = @{
			UserId = $UserId
		}

		# update parameters for New-ScheduledTaskPrincipal with LogonType if provided
		If ($PSBoundParameters.ContainsKey('LogonType')) {
			$ScheduledTaskPrincipalParameters['LogonType'] = $LogonType
		}

		# update parameters for New-ScheduledTaskPrincipal with RunLevel if provided
		If ($PSBoundParameters.ContainsKey('RunLevel')) {
			$ScheduledTaskPrincipalParameters['RunLevel'] = $RunLevel
		}

		# define parameters for New-ScheduledTaskSettingsSet
		$ScheduledTaskSettingsSetParameters = @{
			AllowStartIfOnBatteries    = $true
			DontStopIfGoingOnBatteries = $true
		}

		# update parameters for New-ScheduledTaskSettingsSet with Disable if provided
		If ($PSBoundParameters.ContainsKey('Disable')) {
			$ScheduledTaskSettingsSetParameters['Disable'] = $Disable
		}

		# update parameters for New-ScheduledTaskSettingsSet with ExecutionTimeLimit if provided
		If ($PSBoundParameters.ContainsKey('ExecutionTimeLimit') -and $ExecutionTimeLimit -gt [timespan]::Zero) {
			$ScheduledTaskSettingsSetParameters['ExecutionTimeLimit'] = $ExecutionTimeLimit
		}

		# if TriggerAt provided...
		If ($PSBoundParameters.ContainsKey('TriggerAt')) {
			# define parameters for New-ScheduledTaskTrigger
			$ScheduledTaskTriggerParameters = @{
				Once = $true
				At   = $TriggerAt
			}

			# update parameters for New-ScheduledTaskTrigger with RandomDelay if provided
			If ($PSBoundParameters.ContainsKey('RandomDelay') -and $RandomDelay -gt [timespan]::Zero) {
				$ScheduledTaskTriggerParameters['RandomDelay'] = $RandomDelay
			}

			# update parameters for New-ScheduledTaskTrigger with RepetitionInterval if provided
			If ($PSBoundParameters.ContainsKey('RepetitionInterval') -and $RepetitionInterval -gt [timespan]::Zero) {
				$ScheduledTaskTriggerParameters['RepetitionInterval'] = $RepetitionInterval
			}

			# create scheduled task trigger
			Try {
				$Trigger = New-ScheduledTaskTrigger @ScheduledTaskTriggerParameters
			}
			Catch {
				Return $_
			}
		}
		Else {
			$Trigger = $null
		}

		# create scheduled task action
		Try {
			$Action = New-ScheduledTaskAction @ScheduledTaskActionParameters
		}
		Catch {
			Return $_
		}

		# create scheduled task principal
		Try {
			$Principal = New-ScheduledTaskPrincipal @ScheduledTaskPrincipalParameters
		}
		Catch {
			Return $_
		}

		# create scheduled task settings
		Try {
			$Settings = New-ScheduledTaskSettingsSet @ScheduledTaskSettingsSetParameters
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
			Write-Warning -Message "could not retrieve scheduled tasks with filter for task '$TaskName' at path '$TaskPath'"
			Return $_
		}

		# if scheduled task exists and has triggers but should not have triggers...
		If ($Existing -and $Existing.Triggers.Count -gt 0 -and -not $Trigger) {
			# unregister scheduled task
			Try {
				$null = Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not unregister existing scheduled task '$TaskName' at path '$TaskPath'"
				Return $_
			}

			# report unregistered
			Write-Verbose -Verbose -Message "Unregistered existing scheduled task '$TaskName' at path '$TaskPath' for reason: trigger defined on task but no trigger defined in JSON"

			# clear existing scheduled task object
			$Existing = $null
		}

		# if scheduled task exists...
		If ($Existing) {
			# if action defined...
			If ($Action) {
				# reset booleans
				$UpdateAction = $false

				# if actions count on existing scheduled task is not 1...
				If ($Existing.Actions.Count -ne 1) {
					$UpdateAction = $true
				}
				# if actions count on existing scheduled task is 1...
				Else {
					If ($Existing.Actions[0].Execute -ne $Action.Execute) { $UpdateAction = $true }
					If ($Existing.Actions[0].Arguments -ne $Action.Arguments) { $UpdateAction = $true }
				}

				# if task actions update requested...
				If ($UpdateAction) {
					# update task actions
					Try {
						$null = Set-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $Action
					}
					Catch {
						Write-Warning -Message "could not update action for existing scheduled task '$TaskName' at path '$TaskPath'"
						Return $_
					}

					# report task action updated
					Write-Verbose -Verbose -Message "Updated action for existing scheduled task '$TaskName' at path '$TaskPath'"
				}
			}

			# if principal is defined...
			If ($Principal) {
				# reset booleans
				$UpdatePrincipal = $false

				# if principal not present on existing scheduled task...
				If ($null -eq $Existing.Principal) {
					$UpdatePrincipal = $true
				}
				# if principal present on existing scheduled task...
				Else {
					If ($Existing.Principal.UserId -ne $Principal.UserId) { $UpdatePrincipal = $true }
					If ($Existing.Principal.LogonType -ne $Principal.LogonType) { $UpdatePrincipal = $true }
					If ($Existing.Principal.RunLevel -ne $Principal.RunLevel) { $UpdatePrincipal = $true }
				}

				# if task principal update requested...
				If ($UpdatePrincipal) {
					# update task principal
					Try {
						$null = Set-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Principal $Principal
					}
					Catch {
						Write-Warning -Message "could not update principal for existing scheduled task '$TaskName' at path '$TaskPath'"
						Return $_
					}

					# report task principal updated
					Write-Verbose -Verbose -Message "Updated principal for existing scheduled task '$TaskName' at path '$TaskPath'"
				}
			}

			# if settings are defined...
			If ($Settings) {
				# reset booleans
				$UpdateSettings = $false

				# if settings not present on existing scheduled task...
				If ($null -eq $Existing.Settings) {
					$UpdateSettings = $true
				}
				# if settings present on existing scheduled task...
				Else {
					If ($Existing.Settings.Enabled -ne $Settings.Enabled) { $UpdateSettings = $true }
					If ($Existing.Settings.DisallowStartIfOnBatteries -ne $Settings.DisallowStartIfOnBatteries) { $UpdateSettings = $true }
					If ($Existing.Settings.StopIfGoingOnBatteries -ne $Settings.StopIfGoingOnBatteries) { $UpdateSettings = $true }
					If ($Existing.Settings.ExecutionTimeLimit -ne $Settings.ExecutionTimeLimit) { $UpdateSettings = $true }
				}

				# if task settings update requested...
				If ($UpdateSettings) {
					# update task settings
					Try {
						$null = Set-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Settings $Settings
					}
					Catch {
						Write-Warning -Message "could not update settings for existing scheduled task '$TaskName' at path '$TaskPath'"
						Return $_
					}

					# report task settings updated
					Write-Verbose -Verbose -Message "Updated settings for existing scheduled task '$TaskName' at path '$TaskPath'"
				}
			}

			# if trigger is defined...
			If ($Trigger) {
				# reset booleans
				$UpdateTrigger = $false

				# if trigger count on existing scheduled task is not 1...
				If ($Existing.Triggers.Count -ne 1) {
					$UpdateTrigger = $true
				}
				# if trigger count on existing scheduled task is 1...
				Else {
					If ($Existing.Triggers[0].CimClass.CimClassName -ne $Trigger.CimClass.CimClassName) { $UpdateTrigger = $true }
					If ($Existing.Triggers[0].Enabled -ne $Trigger.Enabled) { $UpdateTrigger = $true }
					If ($Existing.Triggers[0].RandomDelay -ne $Trigger.RandomDelay) { $UpdateTrigger = $true }
					If ($Existing.Triggers[0].Repetition.Interval -ne $Trigger.Repetition.Interval) { $UpdateTrigger = $true }
					If ([datetime]$Existing.Triggers[0].StartBoundary -ne [datetime]$Trigger.StartBoundary) { $UpdateTrigger = $true }
				}

				# if task trigger update requested...
				If ($UpdateTrigger) {
					# update task trigger
					Try {
						$null = Set-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Trigger $Trigger
					}
					Catch {
						Write-Warning -Message "could not update trigger for existing scheduled task '$TaskName' at path '$TaskPath'"
						Return $_
					}

					# report task trigger updated
					Write-Verbose -Verbose -Message "Updated trigger for existing scheduled task '$TaskName' at path '$TaskPath'"
				}
			}

			# report then return
			Write-Verbose -Verbose -Message "Verified existing scheduled task '$TaskName' at path '$TaskPath'"
			Return
		}

		# define required parameters for Register-ScheduledTask
		$ScheduledTaskParams = @{
			TaskName  = $TaskName
			TaskPath  = $TaskPath
			Action    = $Action
			Settings  = $Settings
			Principal = $Principal
			Force     = $true
		}

		# define optional parameters for Register-ScheduledTask
		If ($Trigger) {
			$ScheduledTaskParams['Trigger'] = $Trigger
		}

		# register scheduled task
		Try {
			$null = Register-ScheduledTask @ScheduledTaskParams
		}
		Catch {
			Return $_
		}

		# report and return
		Write-Verbose -Verbose -Message "Registered new scheduled task '$TaskName' at path '$TaskPath'"
		Return
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
		Write-Warning "converted relative path in provided Json parameter to absolute path: $Json"
	}

	# if Register set...
	If ($Register) {
		# define parameters for Update-ScheduledTaskFromJson
		$UpdateScheduledTaskFromJson = @{
			TaskName  = 'Update-ScheduledTasks'
			TaskPath  = '\'
			Execute   = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
			Argument  = '-NonInteractive -NoProfile -ExecutionPolicy ByPass -File "{0}" -Json "{1}"' -f $PSCommandPath, $Json
			UserId    = $UserId
			LogonType = $LogonType
			RunLevel  = $RunLevel
			TriggerAt = $TriggerAt
		}

		# if ReportUndefinedTasks parameter provided...
		If ($PSBoundParameters.ContainsKey('ReportUndefinedTasks')) {
			$UpdateScheduledTaskFromJson['Argument'] = "$($UpdateScheduledTaskFromJson['Argument']) -ReportUndefinedTasks"
		}

		# if RemoveUndefinedTasks parameter provided...
		If ($PSBoundParameters.ContainsKey('RemoveUndefinedTasks')) {
			$UpdateScheduledTaskFromJson['Argument'] = "$($UpdateScheduledTaskFromJson['Argument']) -RemoveUndefinedTasks"
		}

		# if RandomDelay parameter not provided...
		If (!$PSBoundParameters.ContainsKey('RandomDelay')) {
			$UpdateScheduledTaskFromJson['RandomDelay'] = [timespan]::FromMinutes(0)
		}

		# if ExecutionTimeLimit parameter not provided...
		If (!$PSBoundParameters.ContainsKey('ExecutionTimeLimit')) {
			$UpdateScheduledTaskFromJson['ExecutionTimeLimit'] = [timespan]::FromMinutes(1)
		}

		# if RepetitionInterval parameter not provided...
		If (!$PSBoundParameters.ContainsKey('RepetitionInterval')) {
			$UpdateScheduledTaskFromJson['RepetitionInterval'] = [timespan]::FromMinutes(15)
		}

		# register scheduled task
		Try {
			Update-ScheduledTaskFromJson @UpdateScheduledTaskFromJson
		}
		Catch {
			Return $_
		}

		# return after registering task
		Return
	}

	# if Unregister set...
	If ($Unregister) {
		# define parameters for scheduled task
		$TaskName = 'Update-ScheduledTasks'
		$TaskPath = '\'

		# retrieve scheduled task
		Try {
			$ScheduledTask = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction 'SilentlyContinue'
		}
		Catch {
			Return $_
		}

		# if scheduled task not found...
		If (!$ScheduledTask) {
			Write-Warning -Message "Could not locate existing scheduled task '$TaskName' at path '$TaskPath'"
			Return
		}

		# uninstall scheduled task
		Try {
			Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
		}
		Catch {
			Return $_
		}

		# report state
		Write-Host "Unregistered existing scheduled task '$TaskName' at path '$TaskPath'"

		# return after unregistering task
		Return
	}

	# if AddSelf set...
	If ($AddSelf) {
		# set script mode to Add
		$Add = $true

		# define static parameters for Add mode
		$TaskName = 'Update-ScheduledTasks'
		$TaskPath = '\'
		$Execute = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
		$Argument = '-NonInteractive -NoProfile -ExecutionPolicy ByPass -File "{0}" -Json "{1}"' -f $PSCommandPath, $Json

		# if ReportUndefinedTasks parameter provided...
		If ($PSBoundParameters.ContainsKey('ReportUndefinedTasks')) {
			$Argument = "$Argument -ReportUndefinedTasks"
		}

		# if RemoveUndefinedTasks parameter provided...
		If ($PSBoundParameters.ContainsKey('RemoveUndefinedTasks')) {
			$Argument = "$Argument -RemoveUndefinedTasks"
		}

		# if RandomDelay parameter not provided...
		If (!$PSBoundParameters.ContainsKey('RandomDelay')) {
			$RandomDelay = [timespan]::FromMinutes(0)
		}

		# if ExecutionTimeLimit parameter not provided...
		If (!$PSBoundParameters.ContainsKey('ExecutionTimeLimit')) {
			$ExecutionTimeLimit = [timespan]::FromMinutes(1)
		}

		# if RepetitionInterval parameter not provided...
		If (!$PSBoundParameters.ContainsKey('RepetitionInterval')) {
			$RepetitionInterval = [timespan]::FromMinutes(15)
		}
	}

	# if RemoveSelf set...
	If ($RemoveSelf) {
		# set script mode to Remove
		$Remove = $true

		# define parameters for Remove mode
		$TaskName = 'Update-ScheduledTasks'
		$TaskPath = '\'
	}

	# if JSON file found...
	If (Test-Path -Path $Json) {
		# ...create JSON data object as array of PSCustomObjects from JSON file content
		Try {
			$JsonData = [array](Get-Content -Path $Json -ErrorAction 'Stop' | ConvertFrom-Json)
		}
		Catch {
			Write-Warning -Message "could not read configuration file: '$Json'"
			Return $_
		}
	}
	# if JSON file was not found...
	Else {
		# ...and Add set...
		If ($Add) {
			# ...try to create the JSON file
			Try {
				$null = New-Item -ItemType 'File' -Path $Json -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not create configuration file: '$Json'"
				Return $_
			}
			# ...create JSON data object as empty array
			$JsonData = @()
		}
		# ...and Add not set...
		Else {
			# ...report and return
			Write-Warning -Message "could not find configuration file: '$Json'"
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
				Write-Warning "could not clear entries from configuration file: '$Json'"
				Return $_
			}

			# report entries cleared
			Write-Host "Cleared entries from configuration file: '$Json'"
		}
		# remove entry from configuration file
		$Remove {
			# remove existing entry by primary key(s)...
			$JsonData = [array]($JsonData.Where({ !($_.TaskName -eq $TaskName -and $_.TaskPath -eq $TaskPath ) }))

			# if JSON data empty...
			If ($JsonData.Count -eq 0) {
				# set empty string for JSON string
				$JsonValue = [string]::Empty
			}
			# if JSON data is not empty...
			Else {
				# convert JSON data to JSON string
				Try {
					$JsonValue = $JsonData | Sort-Object -Property 'TaskPath', 'TaskName' | ConvertTo-Json -Depth 100
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
				Write-Warning "could not remove entry from configuration file: '$Json'"
				Return $_
			}

			# report entry removed
			Write-Host "Removed entry for '$TaskName' task at '$Taskpath' path from configuration file: '$Json'"

			# display current entries if verbose
			If ($VerbosePreference -eq 'Continue') { $JsonValue | Format-List }
		}
		# add entry to configuration file
		$Add {
			# if task is not Update-ScheduledTasks at the root...
			If ($TaskName -ne 'Update-ScheduledTasks' -and $TaskPath -ne '\') {
				# validate task path
				Try {
					$TaskPathIsValid = Test-ScheduledTaskPath -TaskPath $TaskPath
				}
				Catch {
					Write-Warning -Message "could not validate provided TaskPath value: '$TaskPath'"
					Return $_
				}

				# if task path is not valid...
				If (!$TaskPathIsValid) {
					Write-Warning -Message "the provided TaskPath value is not permitted: '$TaskPath'"
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
			}

			# if existing entry has same primary key(s)...
			If ($JsonData.Where({ $_.TaskName -eq $TaskName -and $_.TaskPath -eq $TaskPath })) {
				# inquire before removing existing entry
				Write-Warning -Message "Will overwrite existing entry for '$TaskName' at '$TaskPath' in configuration file: '$Json'" -WarningAction Continue
				Write-Warning -Message "Any previous configuration for this entry will **NOT** be preserved" -WarningAction $WarningActionFromConfirm
				# remove existing entry with same primary key(s)
				$JsonData = [array]($JsonData.Where({ !($_.TaskName -eq $TaskName -and $_.TaskPath -eq $TaskPath ) }))
			}

			# create ordered dictionary for custom object
			$JsonParameters = [ordered]@{
				TaskName  = [string]$TaskName
				TaskPath  = [string]$TaskPath
				Execute   = [string]$Execute
				Argument  = [string]$Argument
				UserId    = [string]$UserId
				LogonType = [string]$LogonType
			}

			# if Disable provided...
			If ($script:Disable) {
				# add Disable to parameters
				$JsonParameters['Disable'] = [boolean]$Disable
			}

			# if RunLevel provided...
			If ($script:RunLevel) {
				# add RunLevel to parameters
				$JsonParameters['RunLevel'] = [string]$RunLevel
			}

			# if TriggerAt provided and NoTrigger not set...
			If ($PSBoundParameters.ContainsKey('TriggerAt') -and -not $script:NoTrigger) {
				# add TriggerAt as datetime in IS0 8601 extended format
				$JsonParameters['TriggerAt'] = $TriggerAt.ToString('s')
			}

			# if RandomDelay provided and NoTrigger not set...
			If ($PSBoundParameters.ContainsKey('RandomDelay') -and -not $script:NoTrigger) {
				# add RandomDelay as timespan in 'constant' format
				$JsonParameters['RandomDelay'] = $RandomDelay.ToString('c')
			}

			# if RepetitionInterval provided and NoTrigger not set...
			If ($PSBoundParameters.ContainsKey('RepetitionInterval') -and -not $script:NoTrigger) {
				# add RepetitionInterval as timespan in 'constant' format
				$JsonParameters['RepetitionInterval'] = $RepetitionInterval.ToString('c')
			}

			# if ExecutionTimeLimit provided...
			If ($PSBoundParameters.ContainsKey('ExecutionTimeLimit')) {
				# add ExecutionTimeLimit as timespan in 'constant' format
				$JsonParameters['ExecutionTimeLimit'] = $ExecutionTimeLimit.ToString('c')
			}

			# add Updated as current datetime in IS0 8601 extended format
			$JsonParameters['Updated'] = [datetime]::Now.ToString('s')

			# create custom object from hashtable
			$JsonEntry = [pscustomobject]$JsonParameters

			# add entry to data
			$JsonData += $JsonEntry

			# convert data to JSON
			Try {
				$JsonValue = $JsonData | Sort-Object -Property 'TaskPath', 'TaskName' | ConvertTo-Json -Depth 100
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
				Write-Warning "could not add entry to configuration file: '$Json'"
				Return $_
			}

			# report entry added
			Write-Host "Added entry for '$TaskName' task at '$Taskpath' path to configuration file: '$Json'"

			# display current entries if verbose
			If ($VerbosePreference -eq 'Continue') { $JsonValue | Format-List }
		}
		# process entries in configuration file
		Default {
			# declare start
			Write-Host "Updating scheduled tasks from '$Json'"

			# check entry count in configuration file
			If ($JsonData.Count -eq 0) {
				Write-Warning -Message "no entries found in configuration file: $Json"
				Return
			}

			# create dictionary for expected tasks
			$ExpectedTasks = [System.Collections.Generic.Dictionary[string, [System.Collections.Generic.List[string]]]]::new()

			# process configuration file
			:NextJsonEntry ForEach ($JsonEntry in $JsonData) {
				# validate values present in JSON file
				Switch ($true) {
					([string]::IsNullOrEmpty($JsonEntry.TaskName)) {
						Write-Warning -Message "required entry (TaskName) not found in configuration file: $Json"
						Continue NextJsonEntry
					}
					([string]::IsNullOrEmpty($JsonEntry.TaskPath)) {
						Write-Warning -Message "required value (TaskPath) not found in configuration file: $Json"
						Continue NextJsonEntry
					}
					([string]::IsNullOrEmpty($JsonEntry.Execute)) {
						Write-Warning -Message "required value (Execute) not found in configuration file: $Json"
						Continue NextJsonEntry
					}
					([string]::IsNullOrEmpty($JsonEntry.Argument)) {
						Write-Warning -Message "required value (Argument) not found in configuration file: $Json"
						Continue NextJsonEntry
					}
					([string]::IsNullOrEmpty($JsonEntry.UserId)) {
						Write-Warning -Message "required value (UserId) not found in configuration file: $Json"
						Continue NextJsonEntry
					}
					([string]::IsNullOrEmpty($JsonEntry.LogonType)) {
						Write-Warning -Message "required value (LogonType) not found in configuration file: $Json"
						Continue NextJsonEntry
					}
					($null -ne $JsonEntry.Disable -and -not [boolean]::TryParse($JsonEntry.Disable, [ref][boolean]::TrueString)) {
						Write-Warning -Message 'optional value (Disable) found in configuration file but cannot be parsed into a boolean object'
						Continue NextJsonEntry
					}
					($null -ne $JsonEntry.TriggerAt -and -not [datetime]::TryParse($JsonEntry.TriggerAt, [ref][datetime]::Now)) {
						Write-Warning -Message 'optional value (TriggerAt) found in configuration file but cannot be parsed into a datetime object'
						Continue NextJsonEntry
					}
					($null -ne $JsonEntry.RandomDelay -and -not [timespan]::TryParse($JsonEntry.RandomDelay, [ref][timespan]::Zero)) {
						Write-Warning -Message 'optional value (RandomDelay) found in configuration file but cannot be parsed into a timespan object'
						Continue NextJsonEntry
					}
					($null -ne $JsonEntry.RepetitionInterval -and -not [timespan]::TryParse($JsonEntry.RepetitionInterval, [ref][timespan]::Zero)) {
						Write-Warning -Message 'optional value (RepetitionInterval) found in configuration file but cannot be parsed into a timespan object'
						Continue NextJsonEntry
					}
					($null -ne $JsonEntry.ExecutionTimeLimit -and -not [timespan]::TryParse($JsonEntry.ExecutionTimeLimit, [ref][timespan]::Zero)) {
						Write-Warning -Message 'optional value (ExecutionTimeLimit) found in configuration file but cannot be parsed into a timespan object'
						Continue NextJsonEntry
					}
				}

				# if task is not Update-ScheduledTasks at the root...
				If ($JsonEntry.TaskName -ne 'Update-ScheduledTasks' -and $JsonEntry.TaskPath -ne '\') {
					# validate task path
					Try {
						$TaskPathIsValid = Test-ScheduledTaskPath -TaskPath $JsonEntry.TaskPath
					}
					Catch {
						Write-Warning -Message "could not validate TaskPath value found in configuration file: '$($JsonEntry.TaskPath)'"
						Continue NextJsonEntry
					}

					# if task path is not valid...
					If (!$TaskPathIsValid) {
						Write-Warning -Message "the TaskPath value found in configuration file is not permitted: '$($JsonEntry.TaskPath)'"
						Continue NextJsonEntry
					}

					# if task path not in expected tasks dictionary...
					If (!$ExpectedTasks.ContainsKey($JsonEntry.TaskPath)) {
						# add list for task path to dictionary
						$ExpectedTasks.Add($JsonEntry.TaskPath, [System.Collections.Generic.List[string]]::new())
					}

					# add task name to task path list in expected tasks dictionary
					Try {
						$ExpectedTasks[$JsonEntry.TaskPath].Add($JsonEntry.TaskName)
					}
					Catch {
						Write-Warning -Message "could not add task to dictionary: '$($JsonEntry.TaskName)'"
						Continue NextJsonEntry
					}
				}

				# create hashtable with required parameters for Update-ScheduledTaskFromJson
				$UpdateScheduledTaskFromJson = @{
					TaskName  = [string]$JsonEntry.TaskName
					TaskPath  = [string]$JsonEntry.TaskPath
					Execute   = [string]$JsonEntry.Execute
					Argument  = [string]$JsonEntry.Argument
					UserId    = [string]$JsonEntry.UserId
					LogonType = [string]$JsonEntry.LogonType
				}

				# if Disable defined in JSON...
				If ($null -ne $JsonEntry.Disable) {
					# add Disable to hashtable
					$UpdateScheduledTaskFromJson['Disable'] = [boolean]($JsonEntry.Disable)
				}

				# if RunLevel defined in JSON...
				If ($null -ne $JsonEntry.RunLevel) {
					# add RunLevel to hashtable
					$UpdateScheduledTaskFromJson['RunLevel'] = [string]($JsonEntry.RunLevel)
				}

				# if TriggerAt defined in JSON...
				If ($null -ne $JsonEntry.TriggerAt) {
					# parse TriggerAt to datetime
					$TriggerAt = [datetime]::Parse($JsonEntry.TriggerAt)

					# add TriggerAt to hashtable
					$UpdateScheduledTaskFromJson['TriggerAt'] = $TriggerAt
				}

				# define timespan values
				$TimeSpanValues = 'RandomDelay', 'RepetitionInterval', 'ExecutionTimeLimit'

				# process each timespan value
				:NextTimeSpanValue ForEach ($TimeSpanValue in $TimeSpanValues) {
					# if timespan value not defined in JSON...
					If ($null -eq $JsonEntry.$TimeSpanValue) {
						# continue to next timespan value
						Continue NextTimeSpanValue
					}

					# parse timespan value to timespan
					$TimeSpan = [timespan]::Parse($JsonEntry.$TimeSpanValue)

					# if parsed timespan is a negative timespan...
					If ($TimeSpan -lt [timespan]::Zero) {
						# flip timespan with negate method
						$Timespan = $Timespan.Negate()
					}

					# add timespan to hashtable
					$UpdateScheduledTaskFromJson[$TimeSpanValue] = $TimeSpan
				}

				# update scheduled task
				Try {
					Update-ScheduledTaskFromJson @UpdateScheduledTaskFromJson
				}
				Catch {
					Return $_
				}
			}

			# if report or remove undefined tasks requested...
			If ($script:ReportUndefinedTasks -or $script:RemoveUndefinedTasks) {
				# process cleanup hashtable
				:NextTaskPath ForEach ($TaskPath in $ExpectedTasks.Keys) {
					# if task path is root...
					If ($TaskPath -eq '\') {
						# quietly continue to next task path
						Continue NextTaskPath
					}

					# validate task path
					Try {
						$TaskPathIsValid = Test-ScheduledTaskPath -TaskPath $TaskPath
					}
					Catch {
						Write-Warning -Message "could not validate TaskPath value found in expected tasks list: $TaskPath"
						Continue NextTaskPath
					}

					# if task path is not valid...
					If (!$TaskPathIsValid) {
						Write-Warning -Message "the TaskPath value found in expected tasks list is not permitted: '$($JsonEntry.TaskPath)'"
						Continue NextTaskPath
					}

					# get all tasks in TaskPath
					Try {
						$TasksInPath = Get-ScheduledTask | Where-Object { $_.TaskPath -eq $TaskPath } | Select-Object -ExpandProperty 'TaskName'
					}
					Catch {
						Write-Warning -Message "could not retrieve tasks from path: '$TaskPath'"
						Return $_
					}

					# process each task in key
					ForEach ($TaskName in $TasksInPath) {
						If ($TaskName -notin $ExpectedTasks[$TaskPath]) {
							# report undefined scheduled task
							Write-Warning -Message "Found '$TaskName' scheduled task at '$Taskpath' path not defined in configuration file: '$Json'"

							# if remove undefined tasks requested...
							If ($script:RemoveUndefinedTasks) {
								# remove undefined scheduled task
								Try {
									Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
								}
								Catch {
									Write-Warning -Message "could not unregister task '$TaskName' from path '$TaskPath'"
									Return $_
								}

								# report state
								Write-Warning -Message "Removed '$TaskName' scheduled task at '$Taskpath' path not defined in configuration file: '$Json'"
							}
						}
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
