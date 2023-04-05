[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Mandatory = $True, ParameterSetName = 'Update')]
	[switch]$Update,
	[Parameter(ParameterSetName = 'Update')]
	[switch]$RemoveOldTasks,
	[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
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
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[string]$Argument,
	# scheduled task parameter - trigger
	[Parameter(ParameterSetName = 'Add')]
	[datetime]$TriggerAt = [datetime]'00:00:00',
	# scheduled task parameter - trigger
	[Parameter(ParameterSetName = 'Add')]
	[timespan]$RandomDelay = (New-TimeSpan -Minutes 5),
	# scheduled task parameter - trigger
	[Parameter(ParameterSetName = 'Add')]
	[timespan]$RepetitionInterval = (New-TimeSpan -Hours 1),
	# scheduled task parameter - settings
	[Parameter(ParameterSetName = 'Add')]
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
	# path to JSON configuration file
	[Parameter(Mandatory = $True)]
	[string]$Json,
	# local hostname
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

Begin {
	# if updating...
	If ($Update) {
		# ...define transcript file from script path and start transcript
		Start-Transcript -Path $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, "_$HostName.txt") -Force
	}

	Function Approve-ScheduledTaskPath {
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
			# taskpath cannot be '\'
			'^\\$' {
				Return $false
			}
			# taskpath cannot be '\Microsoft'
			'^\\Microsoft$' {
				Return $false
			}
			# taskpath cannot be '\Microsoft\*'
			'^\\Microsoft\\.*$' {
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

		# create params for New-ScheduledTaskTrigger
		$ScheduledTaskTriggerParams = @{
			Once = $true
			At   = $TriggerAt
		}

		# add random delay if configured
		If ($null -ne $RandomDelay) {
			$ScheduledTaskTriggerParams['RandomDelay'] = $RandomDelay
		}

		# add repetition interval if configured
		If ($null -ne $RepetitionInterval) {
			$ScheduledTaskTriggerParams['RepetitionInterval'] = $RepetitionInterval
		}

		# create params for New-ScheduledTaskSettingsSet
		$ScheduledTaskSettingsSet = @{
			ExecutionTimeLimit = $ExecutionTimeLimit
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
			$Settings = New-ScheduledTaskSettingsSet @ScheduledTaskSettingsSet
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

		# get scheduled task
		Try {
			$Existing = Get-ScheduledTask | Where-Object { $_.TaskName -eq $TaskName -and $_.TaskPath -eq $TaskPath }
		}
		Catch {
			Write-Output "`nERROR: could not retrieve scheduled tasks with filter for task '$TaskName' at path '$TaskPath'"
			Return $_
		}

		# if scheduled task exists...
		If ($Existing) {
			# ...verify task actions
			If ($Existing.Actions -ne $Action) {
				Try {
					Set-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $Action
				}
				Catch {
					Write-Output "`nERROR: could not update action for existing scheduled task '$TaskName' at path '$TaskPath'"
					Return $_
				}
			}
			# ...verify task trigger
			If ($Existing.Actions -ne $Trigger) {
				Try {
					Set-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Trigger $Trigger
				}
				Catch {
					Write-Output "`nERROR: could not update trigger for existing scheduled task '$TaskName' at path '$TaskPath'"
					Return $_
				}
			}
			# ...verify task settings
			If ($Existing.Actions -ne $Settings) {
				Try {
					Set-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Settings $Settings
				}
				Catch {
					Write-Output "`nERROR: could not update settings for existing scheduled task '$TaskName' at path '$TaskPath'"
					Return $_
				}
			}
			# ...verify task principal
			If ($Existing.Principal -ne $Principal) {
				Try {
					Set-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Principal $Principal
				}
				Catch {
					Write-Output "`nERROR: could not update principal for existing scheduled task '$TaskName' at path '$TaskPath'"
					Return $_
				}
			}
			# ...then return and move to next task
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
		}
	}
}

Process {
	# if JSON file does not exist...
	If (-not (Test-Path -Path $Json)) {
		# ...and Add...
		If ($Add) {
			# ...create the JSON file
			Try {
				$null = New-Item -ItemType 'File' -Path $Json
			}
			Catch {
				Write-Output "`nERROR: could not create configuration file: '$Json'"
				Return $_
			}
		}
		# ...if not Add...
		Else {
			# ...report error and break
			Write-Output "`nERROR: could not find configuration file: '$Json'"
			Return
		}
	}

	# import JSON data
	Try {
		$json_data = [array](Get-Content -Path $Json | ConvertFrom-Json)
	}
	Catch {
		Write-Output "`nERROR: could not convert configuration file: '$Json'"
		Return $_
	}

	# evaluate parameters
	switch ($true) {
		# clear configuration file
		$Clear {
			If (Test-Path -Path $Json) {
				Try {
					[string]::Empty | Set-Content -Path $Json
					Write-Output "`nCleared configuration file: '$Json'"
				}
				Catch {
					Write-Output "`nERROR: could not clear configuration file: '$Json'"
					Return $_
				}
			}
		}
		# remove entry from configuration file
		$Remove {
			Try {
				$json_data = $json_data | Where-Object { -not ($_.TaskName -eq $TaskName -and $_.TaskPath -eq $TaskPath) }
				If ($null -eq $json_data) {
					[string]::Empty | Set-Content -Path $Json
					Write-Output "`nRemoved '$TaskName' at '$Taskpath' from configuration file: '$Json'"
				}
				Else {
					$json_data | ConvertTo-Json | Set-Content -Path $Json
					Write-Output "`nRemoved '$TaskName' at '$Taskpath' from configuration file: '$Json'"
				}
				$json_data | Format-List
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file: '$Json'"
			}
		}
		# add entry to configuration file
		$Add {
			Try {
				# validate input
				If (-not (Approve-ScheduledTaskPath -TaskPath $TaskPath)) {
					Write-Output "`nERROR: the path defined is not permitted: '$TaskPath'"
					Return
				}

				# create hashtable for custom object
				$json_hashtable = @{
					Updated   = (Get-Date -Format FileDateTimeUniversal)
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
					$json_hashtable['RandomDelayTime'] = [datetime]($TriggerAt - $RandomDelay)
				}

				# add RepetitionInterval if provided as datetime value
				If ($null -ne $RepetitionInterval) {
					$json_hashtable['RepetitionIntervalTime'] = [datetime]($TriggerAt - $RepetitionInterval)
				}

				# add ExecutionTimeLimitTime1 if provided as datetime value
				If ($null -ne $ExecutionTimeLimit) {
					$json_hashtable['ExecutionTimeLimitTime'] = [datetime]($TriggerAt - $ExecutionTimeLimit)
				}

				# add RunLevel if provided
				If ($null -ne $RunLevel) {
					$json_hashtable['RunLevel'] = $RunLevel
				}

				# create custom object from hashtable
				$json_datum = [pscustomobject]$json_hashtable

				# remove existing entry with same name
				If ($json_data.TaskName -contains $TaskName) {
					Write-Warning -Message "Will overwrite existing entry for '$TaskName' configuration file: '$Json' `nAny previous configuration for this entry will **NOT** be preserved" -WarningAction Inquire
					$json_data = $json_data | Where-Object { $_.TaskName -ne $TaskName }
				}

				# add datum to data
				$json_data += $json_datum
				$json_data | ConvertTo-Json | Set-Content -Path $Json
				Write-Output "`nAdded '$TaskName' to configuration file: '$Json'"
				$json_data | Format-List
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file: '$Json'"
			}
		}
		# update scheduled tasks defined in configuration file 
		$Update {
			# declare start
			Write-Host "`nUpdating scheduled tasks from '$Json'"

			# check entry count in configuration file
			If ($json_data.Count -eq 0) {
				Write-Output "ERROR: no entries found in configuration file: $Json"
				Return
			}

			# create hashtable for 
			Try {
				$ExpectedTasks = @{}
			}
			Catch {
				Write-Output 'ERROR: could not create hashtable for tasks'
				Return $_
			}

			# process configuration file
			ForEach ($json_datum in $json_data) {
				# validate values in JSON file
				Switch ($true) {
					([string]::IsNullOrEmpty($json_datum.TaskName)) {
						Write-Output "`nERROR: invalid entry (task name) in configuration file: $Json"; Break
					}
					([string]::IsNullOrEmpty($json_datum.TaskPath)) {
						Write-Output "`nERROR: invalid entry (task path) in configuration file: $Json"; Break
					}
					([string]::IsNullOrEmpty($json_datum.Execute)) {
						Write-Output "`nERROR: invalid entry (execute) in configuration file: $Json"; Break
					}
					([string]::IsNullOrEmpty($json_datum.Argument)) {
						Write-Output "`nERROR: invalid entry (argument) in configuration file: $Json"; Break
					}
					([string]::IsNullOrEmpty($json_datum.UserId)) {
						Write-Output "`nERROR: invalid entry (userid) in configuration file: $Json"; Break
					}
					([string]::IsNullOrEmpty($json_datum.LogonType)) {
						Write-Output "`nERROR: invalid entry (logontype) in configuration file: $Json"; Break
					}
					($json_datum.TriggerAt -isnot [datetime]) {
						Write-Output "`nERROR: invalid entry (datetime for trigger) in configuration file: $Json"; Break
					}
					Default {
						# check tasks hashtable for path
						If ($null -eq $ExpectedTasks[$json_datum.TaskPath]) {
							$ExpectedTasks[$json_datum.TaskPath] = [System.Collections.Generic.List[string]]::new()
						}

						# add task to tasks hashtable
						Try {
							$ExpectedTasks[$json_datum.TaskPath].Add($json_datum.TaskName)
						}
						Catch {
							Write-Output "ERROR: adding task to hashtable: '$($json_datum.TaskName)'"
							Return $_
						}

						# define hashtable for function
						$UpdateScheduledTaskFromJson = @{
							TaskName  = [string]$json_datum.TaskName
							TaskPath  = [string]$json_datum.TaskPath
							Execute   = [string]$json_datum.Execute
							Argument  = [string]$json_datum.Argument
							UserId    = [string]$json_datum.UserId
							LogonType = [string]$json_datum.LogonType
							TriggerAt = [datetime]$json_datum.TriggerAt
						}

						# add RandomDelay if RandomDelayTime in JSON
						If ($null -ne $json_datum.RandomDelayTime -and $json_datum.RandomDelayTime -is [datetime]) {
							$UpdateScheduledTaskFromJson['RandomDelayTime'] = [timespan]($json_datum.TriggerAt - $json_datum.RandomDelayTime)
						}

						# add RepetitionInterval if RepetitionIntervalTime in JSON
						If ($null -ne $json_datum.RepetitionIntervalTime -and $json_datum.RepetitionIntervalTime -is [datetime]) {
							$UpdateScheduledTaskFromJson['RepetitionInterval'] = [timespan]($json_datum.TriggerAt - $json_datum.RepetitionIntervalTime)
						}

						# add ExecutionTimeLimitTime if ExecutionTimeLimitTime in JSON
						If ($null -ne $json_datum.ExecutionTimeLimitTime -and $json_datum.ExecutionTimeLimitTime -is [datetime]) {
							$UpdateScheduledTaskFromJson['ExecutionTimeLimit'] = [timespan]($json_datum.TriggerAt - $json_datum.ExecutionTimeLimitTime)
						}

						# add RunLevel if provided
						If ($null -ne $json_datum.RunLevel -and $json_datum.RunLevel -is [string]) {
							$UpdateScheduledTaskFromJson['RunLevel'] = [string]$RunLevel
						}

						# update scheduled task
						Try {
							Update-ScheduledTaskFromJson @UpdateScheduledTaskFromJson
						}
						Catch {
							Return $_
						}
					}
				}
			}

			# process cleanup hashtable
			ForEach ($TaskPath in $ExpectedTasks.Keys) {
				# check if any bad path values have been snuck in
				If (-not (Approve-ScheduledTaskPath -TaskPath $TaskPath)) {
					Write-Output "`nERROR: the path defined is not permitted: '$TaskPath'"
					Return
				}

				# get all tasks in TaskPath
				Try {
					$TasksInPath = Get-ScheduledTask | Where-Object { $_.TaskPath -eq $TaskPath } | Select-Object -Property 'TaskName'
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
		Default {
			Write-Output "Displaying '$Json'"
			$json_data | Format-List
		}
	}
}

End {
	# if updating...
	If ($Update) {
		# ...stop transcript
		Stop-Transcript
	}
}
