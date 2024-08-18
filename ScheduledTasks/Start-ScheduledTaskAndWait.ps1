#requires -Modules TranscriptWithHostAndDate

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Mandatory = $true)]
	[string]$TaskName,
	[Parameter()]
	[string]$TaskPath
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
	# start timer
	Try {
		$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
	}
	Catch {
		Return $_
	}

	# define required parameter for Start-ScheduledTask
	$ScheduledTask = @{
		TaskName = $TaskName
	}

	# define optional parameter for Start-ScheduledTask
	If ($PSBoundParameters.ContainsKey('TaskPath')) {
		$ScheduledTask['TaskPath'] = $TaskPath
	}

	# start scheduled task
	Try {
		Start-ScheduledTask @ScheduledTask
	}
	Catch {
		Return $_
	}

	# get scheduled task state
	Try {
		$State = Get-ScheduledTask @ScheduledTask | Select-Object -ExpandProperty 'State'
	}
	Catch {
		Return $_
	}

	# wait for scheduled task to complete
	While ($State -ne 'Ready' -and $Timer.Elapsed.TotalSeconds -lt 30) {
		# get scheduled task state
		Try {
			$State = Get-ScheduledTask @ScheduledTask | Select-Object -ExpandProperty 'State'
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
	Write-Verbose -Verbose -Message "Scheduled task $TaskName at $TaskPath took '$($StopWatch.Elapsed.TotalSeconds)' seconds to complete"
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
