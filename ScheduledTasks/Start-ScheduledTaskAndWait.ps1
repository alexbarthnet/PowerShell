[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Mandatory = $true)]
	[string]$TaskName,
	[Parameter()]
	[string]$TaskPath
)

# define required parameter for Start-ScheduledTask
$ScheduledTask = @{
	ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	TaskName    = $TaskName
}
	
# define optional parameter for Start-ScheduledTask
If ($PSBoundParameters.ContainsKey('TaskPath')) {
	$ScheduledTask['TaskPath'] = $TaskPath
}

# start timer
Try {
	$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
}
Catch {
	Return $_
}

# start scheduled task
Try {
	Start-ScheduledTask @ScheduledTask
}
Catch {
	Return $_
}

# loop and...
Do {
	# get scheduled task state
	Try {
		$State = (Get-ScheduledTask @ScheduledTask).State
	}
	Catch {
		Return $_
	}
}
# ...while...
While (
	# scheduled task is running
	$State -eq 'Running'
)

# stop timer
Try {
	$Stopwatch.Stop()
}
Catch {
	Return $_
}

# report time taken
Write-Verbose -Message "Scheduled task $TaskName at $TaskPath took '$($StopWatch.Elapsed.TotalSeconds)' seconds to complete"
