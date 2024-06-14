<#
.SYNOPSIS
Adds or removes Scheduled Tasks defined by entries in a JSON configuration file.

.DESCRIPTION
Adds or removes Scheduled Tasks defined by entries in a JSON configuration file.

.PARAMETER Json
The path to a JSON file containing the configuration for this script.

.PARAMETER Show
Switch parameter to show all entries from the JSON configuration file. Cannot be combined with the Clear, Remove, Add, Install, or Uninstall parameters.

.PARAMETER Clear
Switch parameter to clear all entries from the JSON configuration file. Cannot be combined with the Show, Remove, Add, Install, or Uninstall parameters.

.PARAMETER Remove
Switch parameter to remove an entry from the JSON configuration file. Cannot be combined with the Show, Clear, Add, Install, or Uninstall parameters.

.PARAMETER Add
Switch parameter to add an entry from the JSON configuration file. Cannot be combined with the Show, Clear, Remove, Install, or Uninstall parameters.

.PARAMETER Install
Switch parameter to create a scheduled task named "Update-ScheduledTasks" in the root task path. Cannot be combined with the Show, Clear, Remove, Add, or Uninstall parameters. The task is created with a following defaults:
 - The task will run the script from the current path with the provided JSON file
 - The task will run as SYSTEM with highest privilegs
 - The task will run at midnight then every 15 minutes afterwards
 - The task will run for a maximum of 1 minute

.PARAMETER Uninstall
Switch parameter to remove the scheduled task named "Update-ScheduledTasks" from the root task path. Cannot be combined with the Show, Clear, Remove, Add, or Install parameters.

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
String or string array representing the path to one or more PowerShell modules required by the scheduled task. Each module will be installed to the AllUsers location. The path may be one of the following:
 - A PowerShell module file (.psm1)
 - A folder containing a PowerShell module file
 - A folder containing folders containing PowerShell modules

.PARAMETER Certificates
String or string array representing the path to one or more PFX certificate files. Each certificate will be installed in the local machine personal store.

.PARAMETER RemoveOldTasks
Switch parameter to remove any scheduled task that is not defined in the JSON file and located in any of the task paths defined on the entries in the JSON configuration file.

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
	# scheduled task parameter - certificates
	[Parameter(ParameterSetName = 'Add')]
	[string[]]$Certificates,
	# switch to remove old tasks during run
	[Parameter(ParameterSetName = 'Default')]
	[switch]$RemoveOldTasks,
	# switch to process JSON entries for previous versions of the script
	[Parameter(ParameterSetName = 'Default')]
	[switch]$Run,
	# switch to process JSON entries for previous versions of the script
	[Parameter(ParameterSetName = 'Default')]
	[switch]$Update,
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipTranscript,
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
	Function Import-CertificateFromPath {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$Path,
			[Parameter(DontShow)]
			[string]$CertStoreLocation = 'Cert:\LocalMachine\My'
		)

		# if path not found...
		If (!(Test-Path -Path $Path -PathType 'Leaf')) {
			Write-Warning -Message "could not find file at path: $Path"
			Return
		}

		# get PFX data from certificate
		Try {
			$PfxData = Get-PfxData -FilePath $Path -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not retrieve PFX data from '$Path' file: $($_.Exception.Message)"
			Return $_
		}

		# get thumbprints from PFX
		Try {
			$Thumbprints = $PfxData.EndEntityCertificates | Select-Object -First 1 -ExpandProperty 'Thumbprint'
		}
		Catch {
			Write-Warning -Message "could not retrieve thumbprint from PFX data of '$Path' file: $($_.Exception.Message)"
			Return $_
		}

		# process thumbprints
		ForEach ($Thumbprint in $Thumbprints) {
			# declare thumbprint
			Write-Verbose -Verbose -Message "Found '$Thumbprint' thumbprint in PFX file at path: $Path"

			# define path to certificate
			$CertificatePath = Join-Path -Path $CertStoreLocation -ChildPath $Thumbprint

			# check for certificate by thumbprint
			If (Test-Path -Path $CertificatePath -PathType 'Leaf') {
				# get certificate by path
				Try {
					$Certificate = Get-Item -Path $CertificatePath -ErrorAction 'Stop'
				}
				Catch {
					Write-Warning -Message "could not retrieve certificate at '$Path' file: $($_.Exception.Message)"
					Continue
				}
				# if certificate has a private key...
				If ($Certificate.HasPrivateKey) {
					Write-Verbose -Verbose -Message "Verified PFX certificate imported from path: $Path"
					Continue
				}
			}

			# import certificate
			Try {
				$null = Import-PfxCertificate -CertStoreLocation $CertStoreLocation -FilePath $Path
			}
			Catch {
				Write-Warning -Message "could not import PFX certificate from file at '$Path' file: $($_.Exception.Message)"
				Continue
			}

			# report imported and return
			Write-Verbose -Verbose -Message "Imported PFX certificate from file at path: $Path"
		}
	}

	Function Install-ModuleFromPath {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$Path,
			[Parameter(DontShow)]
			[string]$AllUsers = (Join-Path -Path ([System.Environment]::GetEnvironmentVariable('ProgramFiles')) -ChildPath 'WindowsPowerShell\Modules')
		)

		# if path not found...
		If (!(Test-Path -Path $Path)) {
			Write-Warning -Message "could not find item at path: $Path"
			Return
		}

		# get item for path
		Try {
			$SourceItem = Get-Item -Path $Path -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not get item for path: $Path"
			Return $_
		}

		# define lists
		$SourceFileList = [System.Collections.Generic.List[string]]::new()
		$SourcePathList = [System.Collections.Generic.List[string]]::new()

		# if path is a folder...
		If (Test-Path -Path $Path -PathType 'Container') {
			# if files found in immediate folder...
			If (Get-ChildItem -Path $Path -File) {
				# define target parent path as folder for file
				$TargetParentPath = Join-Path -Path $AllUsers -ChildPath $SourceItem.BaseName
			}
			# if files not found in immediate folder...
			Else {
				# define target parent path as AllUsers path
				$TargetParentPath = $AllUsers
			}

			# get path to parent of source item
			$SourceParentPath = $SourceItem.FullName

			# get files in source item
			Try {
				$SourceFiles = Get-ChildItem -Path $SourceItem -Recurse -File
			}
			Catch {
				Write-Warning -Message "could not search for files in path: $Path"
				Return $_
			}

			# get folders in source item
			Try {
				$SourcePaths = Get-ChildItem -Path $SourceItem -Recurse -Directory
			}
			Catch {
				Write-Warning -Message "could not search for folders in path: $Path"
				Return $_
			}

			# for each file found...
			ForEach ($SourceFile in $SourceFiles) {
				# add full path of file to list
				$SourceFileList.Add($SourceFile.FullName)
			}

			# for each folder found...
			ForEach ($SourcePath in $SourcePaths) {
				# add full path of folder to list
				$SourcePathList.Add($SourcePath.FullName)
			}

			# if no files found...
			If ($SourceFileList.Count -eq 0) {
				Write-Warning -Message "could not locate any files in path: $Path"
				Return
			}
		}

		# if path is a file...
		If (Test-Path -Path $Path -PathType 'Leaf') {
			# define target parent path as folder for file
			$TargetParentPath = Join-Path -Path $AllUsers -ChildPath $SourceItem.BaseName

			# get path to parent of source item
			$SourceParentPath = $SourceItem.DirectoryName

			# add full path of file to list
			$SourceFileList.Add($SourceItem.FullName)
		}

		# if target module folder not found...
		If (!(Test-Path -Path $TargetParentPath -PathType 'Container')) {
			# create target module folder
			Try {
				$null = New-Item -Path $TargetParentPath -ItemType 'Directory' -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not create target module path: $TargetParentPath"
				Return $_
			}
		}

		# process source path names
		ForEach ($Source in $SourcePathList) {
			# build target folder path
			$Target = $Source.Replace($SourceParentPath, $TargetParentPath)

			# if target folder found...
			If (Test-Path -Path $Target -PathType 'Container') {
				# continue to next folder
				Continue
			}

			# create target folder
			Try {
				$null = New-Item -Path $Target -ItemType 'Directory' -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not create target folder: $Target"
				Return $_
			}
		}

		# process source file names
		ForEach ($Source in $SourceFileList) {
			# build target file path
			$Target = $Source.Replace($SourceParentPath, $TargetParentPath)

			# if target file found...
			If (Test-Path -Path $Target -PathType Leaf) {
				# get source file hash
				Try {
					$SourceHash = Get-FileHash -Path $Source | Select-Object -ExpandProperty 'Hash'
				}
				Catch {
					Write-Warning -Message "could not get hash of source file: $Source"
					Return $_
				}

				# get target file hash
				Try {
					$TargetHash = Get-FileHash -Path $Target | Select-Object -ExpandProperty 'Hash'
				}
				Catch {
					Write-Warning -Message "could not get hash of target file: $Target"
					Return $_
				}

				# if hashes match...
				If ($TargetHash -eq $SourceHash) {
					# continue to next file
					Continue
				}
				# if hashes do not match...
				Else {
					# remove target file
					Try {
						Remove-Item -Path $Target -Force -ErrorAction 'Stop'
					}
					Catch {
						Write-Warning -Message "could not remove old file: $Target"
						Return $_
					}
					# report target file removed
					Write-Verbose -Verbose -Message "Removed invalid file: $Target"
				}
			}

			# create target file from source file
			Try {
				Copy-Item -Path $Source -Destination $Target -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not write file: $Target"
				Return $_
			}

			# report source file copied
			Write-Verbose -Verbose -Message "Installed target file: $Target"
		}

		# get files in target folder not in source file list
		Try {
			$TargetFiles = Get-ChildItem -Path $TargetParentPath -Recurse -File | Sort-Object -Descending
		}
		Catch {
			Write-Warning -Message "could not search for files in path: $TargetParentPath"
			Return $_
		}

		# get paths in target folder not in source file list
		Try {
			$TargetPaths = Get-ChildItem -Path $TargetParentPath -Recurse -Directory | Sort-Object -Descending
		}
		Catch {
			Write-Warning -Message "could not search for folders in path: $TargetParentPath"
			Return $_
		}

		# process target file names
		ForEach ($Target in $TargetFiles) {
			# if source file list contains source file...
			If ($SourceFileList.Contains($Target.FullName.Replace($TargetParentPath, $SourceParentPath))) {
				# continue to next target file
				Continue
			}
			# remove target file
			Try {
				Remove-Item -Path $Target.FullName -Force -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not remove old file: $Target"
				Return $_
			}
			# report target file removed
			Write-Verbose -Verbose -Message "Removed invalid file: $Target"
		}

		# process target path names
		ForEach ($Target in $TargetPaths) {
			# if source path list contains source path...
			If ($SourcePathList.Contains($Target.FullName.Replace($TargetParentPath, $SourceParentPath))) {
				# continue to next target path
				Continue
			}
			# remove target path
			Try {
				Remove-Item -Path $Target.FullName -Force -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not remove old folder: $Target"
				Return $_
			}
			# report target path removed
			Write-Verbose -Verbose -Message "Removed invalid folder: $Target"
		}

		# report then return
		Write-Verbose -Verbose -Message "Verified module(s) from path: $Path"
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
			Write-Warning -Message "could not retrieve scheduled tasks with filter for task '$TaskName' at path '$TaskPath'"
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
					Write-Verbose -Verbose -Message "Updating action for existing scheduled task '$TaskName' at path '$TaskPath'"
					$null = Set-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $Action
				}
				Catch {
					Write-Warning -Message "could not update action for existing scheduled task '$TaskName' at path '$TaskPath'"
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
					Write-Verbose -Verbose -Message "Updating trigger for existing scheduled task '$TaskName' at path '$TaskPath'"
					$null = Set-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Trigger $Trigger
				}
				Catch {
					Write-Warning -Message "could not update trigger for existing scheduled task '$TaskName' at path '$TaskPath'"
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
					Write-Verbose -Verbose -Message "Updating settings for existing scheduled task '$TaskName' at path '$TaskPath'"
					$null = Set-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Settings $Settings
				}
				Catch {
					Write-Warning -Message "could not update settings for existing scheduled task '$TaskName' at path '$TaskPath'"
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
					Write-Verbose -Verbose -Message "Updating principal for existing scheduled task '$TaskName' at path '$TaskPath'"
					$null = Set-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Principal $Principal
				}
				Catch {
					Write-Warning -Message "could not update principal for existing scheduled task '$TaskName' at path '$TaskPath'"
					Return $_
				}
			}

			# report then return
			Write-Verbose -Verbose -Message "Verified existing scheduled task '$TaskName' at path '$TaskPath'"
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
			Write-Verbose -Verbose -Message "Registered new scheduled task '$TaskName' at path '$TaskPath'"
			Return
		}
	}

	Function Start-TranscriptWithHostAndDate {
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
					Remove-Item -Path $FileToRemove.FullName -Force -Verbose -ErrorAction 'Stop'
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

	# if parameter set is Default and SkipTranscript not set...
	If ($PSCmdlet.ParameterSetName -eq 'Default' -and -not $PSBoundParameters.ContainsKey('SkipTranscript')) {
		# start transcript with default parameters
		Try {
			Start-TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}

Process {
	# if Install set...
	If ($Install) {
		# set script mode to Add
		$Add = $true

		# define static parameters for Add mode
		$TaskName = 'Update-ScheduledTasks'
		$TaskPath = '\'
		$Execute = Join-Path -Path $PSHOME -ChildPath 'powershell.exe'
		$Argument = "-NonInteractive -NoProfile -ExecutionPolicy ByPass -File `"$PSCommandPath`" -Json `"$Json`""
		$UserId = 'SYSTEM'
		$LogonType = 'ServiceAccount'
		$RunLevel = 'Highest'

		# if TriggerAt parameter not provided...
		If (!$PSBoundParameters.ContainsKey('TriggerAt')) {
			$TriggerAt = [datetime]'00:00:00'
		}

		# if RandomDelay parameter not provided...
		If (!$PSBoundParameters.ContainsKey('RandomDelay')) {
			$RandomDelay = (New-TimeSpan -Minutes 0)
		}

		# if ExecutionTimeLimit parameter not provided...
		If (!$PSBoundParameters.ContainsKey('ExecutionTimeLimit')) {
			$ExecutionTimeLimit = (New-TimeSpan -Minutes 1)
		}

		# if RepetitionInterval parameter not provided...
		If (!$PSBoundParameters.ContainsKey('RepetitionInterval')) {
			$RepetitionInterval = (New-TimeSpan -Minutes 15)
		}
	}

	# if Uninstall set...
	If ($Uninstall) {
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
			Write-Verbose -Verbose -Message "Displaying '$Json'"
			$JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
		}
		# clear configuration file
		$Clear {
			Try {
				[string]::Empty | Set-Content -Path $Json
				Write-Verbose -Verbose -Message "Cleared configuration file: '$Json'"
			}
			Catch {
				Write-Warning -Message "could not clear configuration file: '$Json'"
				Return $_
			}
		}
		# remove entry from configuration file
		$Remove {
			Try {
				# remove existing entry by primary key(s)...
				$JsonData = [array]($JsonData.Where({ $_.TaskName -ne $TaskName -and $_.TaskPath -ne $TaskPath }))
				# if JSON data empty...
				If ($JsonData.Count -eq 0) {
					# clear JSON data
					[string]::Empty | Set-Content -Path $Json
					Write-Verbose -Verbose -Message "Removed '$TaskName' at '$Taskpath' from configuration file: '$Json'"
				}
				Else {
					# export JSON data
					$JsonData | Sort-Object -Property 'TaskPath', 'TaskName' | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
					Write-Verbose -Verbose -Message "Removed '$TaskName' at '$Taskpath' from configuration file: '$Json'"
					$JsonData | Sort-Object -Property 'TaskPath', 'TaskName' | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
				}
			}
			Catch {
				Write-Warning -Message "could not update configuration file: '$Json'"
				Return $_
			}
		}
		# add entry to configuration file
		$Add {
			Try {
				# validate task path
				Try {
					$TaskPathIsValid = Test-ScheduledTaskPath -TaskPath $TaskPath
				}
				Catch {
					Write-Warning -Message "could not validate TaskPath value: $TaskPath"
					Return
				}

				# if task name not 'Update-ScheduledTasks' and task path is not valid...
				If ($TaskName -ne 'Update-ScheduledTasks' -and -not $TaskPathIsValid) {
					Write-Warning -Message "the provided TaskPath is not permitted: '$TaskPath'"
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
					TaskName  = [string]$TaskName
					TaskPath  = [string]$TaskPath
					Execute   = [string]$Execute
					Argument  = [string]$Argument
					UserId    = [string]$UserId
					LogonType = [string]$LogonType
					TriggerAt = [datetime]$TriggerAt
				}

				# add RandomDelay if provided as datetime value
				If ($script:RandomDelay) {
					$JsonParameters['RandomDelayTime'] = [datetime]($TriggerAt + $RandomDelay)
				}

				# add ExecutionTimeLimitTime1 if provided as datetime value
				If ($script:ExecutionTimeLimit) {
					$JsonParameters['ExecutionTimeLimitTime'] = [datetime]($TriggerAt + $ExecutionTimeLimit)
				}

				# add RepetitionInterval if provided as datetime value
				If ($script:RepetitionInterval) {
					$JsonParameters['RepetitionIntervalTime'] = [datetime]($TriggerAt + $RepetitionInterval)
				}

				# add RunLevel if provided
				If ($script:RunLevel) {
					$JsonParameters['RunLevel'] = [string]$RunLevel
				}

				# add Modules if provided
				If ($script:Modules) {
					$JsonParameters['Modules'] = [string[]]$Modules
				}

				# add Certificates if provided
				If ($script:Certificates) {
					$JsonParameters['Certificates'] = [string[]]$Certificates
				}

				# add current time as FileDateTimeUniversal
				$JsonParameters['Updated'] = (Get-Date -Format FileDateTimeUniversal)

				# create custom object from hashtable
				$JsonEntry = [pscustomobject]$JsonParameters

				# if existing entry has same primary key(s)...
				If ($JsonData.Where({ $_.TaskName -eq $TaskName -and $_.TaskPath -eq $TaskPath })) {
					# inquire before removing existing entry
					Write-Warning -Message "Will overwrite existing entry for '$TaskName' at '$TaskPath' in configuration file: '$Json' `nAny previous configuration for this entry will **NOT** be preserved" -WarningAction 'Inquire'
					# remove existing entry with same primary key(s)
					$JsonData = [array]($JsonData.Where({ $_.TaskName -ne $TaskName -and $_.TaskPath -ne $TaskPath }))
				}

				# add entry to data
				$JsonData += $JsonEntry

				# export JSON data
				$JsonData | Sort-Object -Property 'TaskPath', 'TaskName' | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
				Write-Verbose -Verbose -Message "Added '$TaskName' at '$Taskpath' to configuration file: '$Json'"
				$JsonData | Sort-Object -Property 'TaskPath', 'TaskName' | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
			}
			Catch {
				Write-Warning -Message "could not update configuration file: '$Json'"
				Return $_
			}
		}
		# process entries in configuration file
		Default {
			# declare start
			Write-Host "`nUpdating scheduled tasks from '$Json'"

			# check entry count in configuration file
			If ($JsonData.Count -eq 0) {
				Write-Warning -Message "no entries found in configuration file: $Json"
				Return
			}

			# define list for all certificates
			$Certificates = [System.Collections.Generic.List[string]]::new()

			# process entries in configuration file for certificates
			ForEach ($JsonEntry in $JsonData) {
				# process each certificate defined in the scheduled task
				ForEach ($Certificate in $JsonEntry.Certificates) {
					# if certificate not in certificates list...
					If ($Certificate -notin $Certificates) {
						# add certificate to list
						$Certificates.Add($Certificate)
					}
				}
			}

			# process certificates in all certificates list
			ForEach ($Certificate in $Certificates) {
				# import certificate
				Try {
					Import-CertificateFromPath -Path $Certificate
				}
				Catch {
					Return $_
				}
			}

			# define list for all modules
			$Modules = [System.Collections.Generic.List[string]]::new()

			# process entries in configuration file for modules
			ForEach ($JsonEntry in $JsonData) {
				# process each module defined in the scheduled task
				ForEach ($Module in $JsonEntry.Modules) {
					# if module not in modules list...
					If ($Module -notin $Modules) {
						# add module to list
						$Modules.Add($Module)
					}
				}
			}

			# process modules in all modules list
			ForEach ($Module in $Modules) {
				# install module
				Try {
					Install-ModuleFromPath -Path $Module
				}
				Catch {
					Return $_
				}
			}

			# create dictionary for expected tasks
			$ExpectedTasks = [System.Collections.Generic.Dictionary[string, [System.Collections.Generic.List[string]]]]::new()

			# process configuration file
			:JsonEntry ForEach ($JsonEntry in $JsonData) {
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
					($null -eq $JsonEntry.TriggerAt) {
						Write-Warning -Message "required value (TriggerAt) not found in configuration file: $Json"
						Continue NextJsonEntry
					}
					($null -ne $JsonEntry.TriggerAt -and $JsonEntry.TriggerAt -isnot [datetime]) {
						Write-Warning -Message 'required value (TriggerAt) found in configuration file but is not a [datetime] object'
						Continue NextJsonEntry
					}
					($null -ne $JsonEntry.RandomDelayTime -and $JsonEntry.RandomDelayTime -isnot [datetime]) {
						Write-Warning -Message 'optional value (RandomDelayTime) found in configuration file but is not a [datetime] object'
						Continue NextJsonEntry
					}
					($null -ne $JsonEntry.RepetitionIntervalTime -and $JsonEntry.RepetitionIntervalTime -isnot [datetime]) {
						Write-Warning -Message 'optional value (RepetitionIntervalTime) found in configuration file but is not a [datetime] object'
						Continue NextJsonEntry
					}
					($null -ne $JsonEntry.ExecutionTimeLimitTime -and $JsonEntry.ExecutionTimeLimitTime -isnot [datetime]) {
						Write-Warning -Message 'optional value (ExecutionTimeLimitTime) found in configuration file but is not a [datetime] object'
						Continue NextJsonEntry
					}
				}

				# validate task path
				Try {
					$TaskPathIsValid = Test-ScheduledTaskPath -TaskPath $JsonEntry.TaskPath
				}
				Catch {
					Write-Warning -Message "could not validate TaskPath value found in configuration file: '$($JsonEntry.TaskPath)'"
					Continue NextJsonEntry
				}

				# if task name not 'Update-ScheduledTasks' and task path is not valid...
				If ($JsonEntry.TaskName -ne 'Update-ScheduledTasks' -and -not $TaskPathIsValid) {
					Write-Warning -Message "the TaskPath value found in configuration file is not permitted: '$($JsonEntry.TaskPath)'"
					Continue NextJsonEntry
				}

				# check expected tasks hashtable for task path
				If (!$ExpectedTasks.ContainsKey($JsonEntry.TaskPath)) {
					$ExpectedTasks.Add($JsonEntry.TaskPath, [System.Collections.Generic.List[string]]::new())
				}

				# update expected tasks hashtable with task name
				Try {
					$ExpectedTasks[$JsonEntry.TaskPath].Add($JsonEntry.TaskName)
				}
				Catch {
					Write-Warning -Message "could not add task to dictionary: '$($JsonEntry.TaskName)'"
					Continue NextJsonEntry
				}

				# define parameters for Update-ScheduledTaskFromJson
				$UpdateScheduledTaskFromJson = @{
					TaskName  = [string]$JsonEntry.TaskName
					TaskPath  = [string]$JsonEntry.TaskPath
					Execute   = [string]$JsonEntry.Execute
					Argument  = [string]$JsonEntry.Argument
					UserId    = [string]$JsonEntry.UserId
					LogonType = [string]$JsonEntry.LogonType
					TriggerAt = [datetime]$JsonEntry.TriggerAt
				}

				# if RunLevel defined in JSON...
				If ($null -ne $JsonEntry.RunLevel) {
					# add RunLevel to parameters
					$UpdateScheduledTaskFromJson['RunLevel'] = [string]$RunLevel
				}

				# if RandomDelayTime defined in JSON...
				If ($null -ne $JsonEntry.RandomDelayTime) {
					# ...and RandomDelayTime is less than (before) TriggerAt...
					If ($JsonEntry.RandomDelayTime -lt $JsonEntry.TriggerAt) {
						Write-Warning -Message "RandomDelayTime is before TriggerAt in task: '$($JsonEntry.TaskName)'"
						Continue NextJsonEntry
					}
					# create RandomDelay timespan and add to parameters
					$UpdateScheduledTaskFromJson['RandomDelay'] = [timespan]($JsonEntry.RandomDelayTime - $JsonEntry.TriggerAt)
				}

				# if RepetitionIntervalTime defined in JSON...
				If ($null -ne $JsonEntry.RepetitionIntervalTime) {
					# ...and RepetitionIntervalTime is less than (before) TriggerAt...
					If ($JsonEntry.RepetitionIntervalTime -lt $JsonEntry.TriggerAt) {
						Write-Warning -Message "RepetitionIntervalTime is before TriggerAt in task: '$($JsonEntry.TaskName)'"
						Continue NextJsonEntry
					}
					# create RepetitionInterval timespan and add to parameters
					$UpdateScheduledTaskFromJson['RepetitionInterval'] = [timespan]($JsonEntry.RepetitionIntervalTime - $JsonEntry.TriggerAt)
				}

				# if ExecutionTimeLimitTime defined in JSON...
				If ($null -ne $JsonEntry.ExecutionTimeLimitTime) {
					# ...and ExecutionTimeLimitTime is less than (before) TriggerAt...
					If ($JsonEntry.ExecutionTimeLimitTime -lt $JsonEntry.TriggerAt) {
						Write-Warning -Message "ExecutionTimeLimitTime is before TriggerAt in task: '$($JsonEntry.TaskName)'"
						Continue NextJsonEntry
					}
					# create ExecutionTimeLimit timespan and add to parameters
					$UpdateScheduledTaskFromJson['ExecutionTimeLimit'] = [timespan]($JsonEntry.ExecutionTimeLimitTime - $JsonEntry.TriggerAt)
				}

				# update scheduled task
				Try {
					Update-ScheduledTaskFromJson @UpdateScheduledTaskFromJson
				}
				Catch {
					Return $_
				}
			}

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
						# report errant scheduled task
						Write-Warning -Message "the path '$TaskPath' contains a scheduled task not defined in the JSON file: '$TaskName'"

						# remove errant scheduled task
						Try {
							# Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
						}
						Catch {
							Write-Warning -Message "could not unregister task '$TaskName' from path '$TaskPath'"
							Return $_
						}
					}
				}
			}
		}
	}

	# if Install set...
	If ($Install) {
		# define parameters for Update-ScheduledTaskFromJson
		$UpdateScheduledTaskFromJson = @{
			TaskName           = $TaskName
			TaskPath           = $TaskPath
			Execute            = $Execute
			Argument           = $Argument
			UserId             = $UserId
			LogonType          = $LogonType
			RunLevel           = $RunLevel
			TriggerAt          = $TriggerAt
			RandomDelay        = $RandomDelay
			ExecutionTimeLimit = $ExecutionTimeLimit
			RepetitionInterval = $RepetitionInterval
		}

		# install scheduled task
		Try {
			Update-ScheduledTaskFromJson @UpdateScheduledTaskFromJson
		}
		Catch {
			Return $_
		}
	}

	# if Uninstall set...
	If ($Uninstall) {
		# define parameters for scheduled task
		$UnregisterScheduledTask = @{
			TaskName = $TaskName
			TaskPath = $TaskPath
		}

		# retrieve scheduled task
		Try {
			$ScheduledTask = Get-ScheduledTask @UnregisterScheduledTask -ErrorAction 'SilentlyContinue'
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
			Unregister-ScheduledTask @UnregisterScheduledTask -Confirm:$false
		}
		Catch {
			Return $_
		}

		# report
		Write-Verbose -Verbose -Message "Unregistered existing scheduled task '$TaskName' at path '$TaskPath'"
	}
}

End {
	# if parameter set is Default and SkipTranscript not set...
	If ($PSCmdlet.ParameterSetName -eq 'Default' -and -not $PSBoundParameters.ContainsKey('SkipTranscript')) {
		# stop transcript with default parameters
		Try {
			Stop-TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}
