[CmdletBinding()]
param(
	[uint16]$DurationHours = 1,
	[string]$ExcludeFolder = '.exclude',
	[switch]$FullRun
)

function Format-Bytes {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[uint64]$Size,
		[Parameter(Position = 1)]
		[uint32]$RoundTo = 2,
		[Parameter(Position = 2)]
		[uint32]$Decimals = 0
	)
	switch ($Size) {
		{ $_ -ge 1PB } { $Value = [math]::Round($Size / 1PB, $RoundTo); $Unit = 'PB'; break }
		{ $_ -ge 1TB } { $Value = [math]::Round($Size / 1TB, $RoundTo); $Unit = 'TB'; break }
		{ $_ -ge 1GB } { $Value = [math]::Round($Size / 1GB, $RoundTo); $Unit = 'GB'; break }
		{ $_ -ge 1MB } { $Value = [math]::Round($Size / 1MB, $RoundTo); $Unit = 'MB'; break }
		{ $_ -ge 1KB } { $Value = [math]::Round($Size / 1KB, $RoundTo); $Unit = 'KB'; break }
		default { $Value = [math]::Round($Size, $RoundTo); $Unit = 'B' }
	}
	if ($PSBoundParameters.ContainsKey('Decimals')) {
		$Value = "{0:F$Decimals}" -f $Value
	}

	return "$Value $Unit"
}

# if fullrun requested...
if ($FullRun.IsPresent) {
	$Interval = 10
}
else {
	$Interval = 1
}

# retrieve the local cluster node
$ClusterNode = Get-ClusterNode -Name $env:COMPUTERNAME

# retrieve cluster shared volumes on the local cluster node
$ClusterSharedVolumes = Get-ClusterSharedVolume -InputObject $ClusterNode

# loop through cluster shared volumes
:NextClusterSharedVolume foreach ($ClusterSharedVolume in $ClusterSharedVolumes) {
	# retrieve the volume from the cluster shared volume
	$Volume = $ClusterSharedVolume.SharedVolumeInfo.FriendlyVolumeName

	# retrieve the ReFS dedupe configuration
	$ReFSDedupStatus = Get-ReFSDedupStatus -Volume $Volume


	# if ReFS deduplication is enabled...
	if ($ReFSDedupStatus.Enabled) {
		# if ReFS deduplication job is running...
		if ($ReFSDedupStatus.State -in 'Optimizing') {
			Write-Warning -Message "$([System.Datetime]::Now.ToString('yyyy-MM-dd-HH:mm:ss')): Volume: $Volume; Type: $($ReFSDedupStatus.Type); State: $($ReFSDedupStatus.State); found existing deduplication job"
			continue NextClusterSharedVolume
		}

		# if ReFS deduplication job is running...
		if ($ReFSDedupStatus.State -notin 'Idle', 'Cancelled', 'None') {
			Write-Warning -Message "$([System.Datetime]::Now.ToString('yyyy-MM-dd-HH:mm:ss')): Volume: $Volume; Type: $($ReFSDedupStatus.Type); State: $($ReFSDedupStatus.State); found unexpected state"
			continue NextClusterSharedVolume
		}

		# define parameters
		$StartReFSDedupJob = @{
			Volume              = $Volume
			ExcludeFolder       = $ExcludeFolder
			ConcurrentOpenFiles = 1
			CpuPercentage       = 25
			ErrorAction         = [System.Management.Automation.ActionPreference]::Stop
		}

		# if fullrun requested...
		if ($FullRun.IsPresent) {
			$StartReFSDedupJob['FullRun'] = $true
		}
		else {
			$StartReFSDedupJob['Duration'] = [System.TimeSpan]::FromHours($DurationHours)
		}

		# start stopwatch
		$StopWatch = [System.Diagnostics.Stopwatch]::StartNew()

		# start a deduplication job
		$Job = Start-ReFSDedupJob @StartReFSDedupJob

		# while job exists...
		while ($Job.State -notin 'Completed', 'Failed', 'Stopped') {
			# sleep for 1 second
			Start-Sleep -Seconds $Interval

			# update job object
			$Job = Get-Job -Id $Job.Id

			# retrieve dedupe status
			$ReFSDedupStatus = Get-ReFSDedupStatus -Volume $Volume

			# if progress...
			if ($ReFSDedupStatus.Progress -gt 0 -and $ReFSDedupStatus.Progress -lt 1) {
				# write dedupe status to screen
				Write-Host "$([System.Datetime]::Now.ToString('yyyy-MM-dd-HH:mm:ss')): Volume: $Volume; Type: $($ReFSDedupStatus.Type); State: $($ReFSDedupStatus.State); Duration: $($StopWatch.Elapsed.ToString()); Progress: $($ReFSDedupStatus.Progress.ToString('P2').PadLeft(6,'0')); Processed: $(Format-Bytes -Size $ReFSDedupStatus.ProcessedOnLastRun -Decimals 2); Savings: $(Format-Bytes -Size $ReFSDedupStatus.SavingsOnLastRun -Decimals 2)"
			}
		}

		# stop stopwatch
		$StopWatch.Stop()

		# if job failed...
		if ($Job.State -eq 'Failed') {
			Write-Host "$([System.Datetime]::Now.ToString('yyyy-MMdd-HH:mm:ss')): Volume: $Volume; Type: $($ReFSDedupStatus.Type); Error: $($Job.Error.Exception.Message.Replace([System.Environment]::NewLine, ' '))"
		}
		else {
			# write dedupe status to screen
			Write-Host "$([System.Datetime]::Now.ToString('yyyy-MM-dd-HH:mm:ss')): Volume: $Volume; Type: $($ReFSDedupStatus.Type); Duration: $($ReFSDedupStatus.LastRunDuration.ToString()); Size: $(Format-Bytes -Size $ReFSDedupStatus.Size); TotalSavings: $(Format-Bytes -Size $ReFSDedupStatus.TotalSavings); ProcessedOnLastRun: $(Format-Bytes -Size $ReFSDedupStatus.ProcessedOnLastRun); SavingsOnLastRun: $(Format-Bytes -Size $ReFSDedupStatus.SavingsOnLastRun)"
		}
	}
}
