#requires -Modules TranscriptWithHostAndDate

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# path to pre-update scheduled tasks
	[Parameter(Position = 0)]
	[string]$TaskPath = '\CAU\PreUpdateTasks\',
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
	# if skip transcript not requested...
	If (!$SkipTranscript) {
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
	# retrieve scheduled tasks in path
	Try {
		$ScheduledTasks = Get-ScheduledTask | Where-Object { $_.TaskPath -eq $TaskPath }
	}
	Catch {
		Return $_
	}

	# report scheduled task count
	Write-Verbose -Verbose -Message "found '$($ScheduledTasks.Count)' scheduled tasks in task path: $TaskPath"

	# process each scheduled task
	ForEach ($ScheduledTask in $ScheduledTasks) {
		# start timer
		Try {
			$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
		}
		Catch {
			Return $_
		}

		# start scheduled task
		Try {
			$ScheduledTask | Start-ScheduledTask
		}
		Catch {
			Return $_
		}

		# report time taken
		Write-Verbose -Verbose -Message "Scheduled task '$($ScheduledTask.TaskName)' started"

		# get scheduled task state
		Try {
			$State = $ScheduledTask | Get-ScheduledTask | Select-Object -ExpandProperty 'State'
		}
		Catch {
			Return $_
		}

		# wait for scheduled task to complete
		While ($State -ne 'Ready' -and $Timer.Elapsed.TotalSeconds -lt 30) {
			# get scheduled task state
			Try {
				$State = $ScheduledTask | Get-ScheduledTask | Select-Object -ExpandProperty 'State'
			}
			Catch {
				Return $_
			}
		}

		# stop timer
		Try {
			$Stopwatch.Stop()
		}
		Catch {
			Return $_
		}

		# report time taken
		Write-Verbose -Verbose -Message "Scheduled task '$($ScheduledTask.TaskName)' took '$($StopWatch.Elapsed.TotalSeconds)' seconds to complete"
	}
}

End {
	# if skip transcript not requested...
	If (!$SkipTranscript) {
		# stop transcript with default parameters
		Try {
			Stop-TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}
