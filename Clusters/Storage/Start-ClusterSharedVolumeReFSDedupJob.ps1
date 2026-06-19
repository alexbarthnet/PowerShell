[CmdletBinding()]
param(
    [string]$ExcludeFolder = '.exclude'
)

function Format-Bytes {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[uint64]$Size,
		[Parameter(Position = 1)]
		[int32]$RoundTo = 2
	)
	switch ($Size) {
		{ $_ -ge 1PB } { "$([math]::Round($Size / 1PB,$RoundTo)) PB"; break }
		{ $_ -ge 1TB } { "$([math]::Round($Size / 1TB,$RoundTo)) TB"; break }
		{ $_ -ge 1GB } { "$([math]::Round($Size / 1GB,$RoundTo)) GB"; break }
		{ $_ -ge 1MB } { "$([math]::Round($Size / 1MB,$RoundTo)) MB"; break }
		{ $_ -ge 1KB } { "$([math]::Round($Size / 1KB,$RoundTo)) KB"; break }
		default { "$([math]::Round($Size,$RoundTo)) B" }
	}
}

# retrieve the local cluster node
$ClusterNode = Get-ClusterNode -Name $env:COMPUTERNAME

# retrieve cluster shared volumes on the local cluster node
$ClusterSharedVolumes = Get-ClusterSharedVolume -InputObject $ClusterNode

# loop through cluster shared volumes
foreach ($ClusterSharedVolume in $ClusterSharedVolumes) {
    # retrieve the volume from the cluster shared volume
    $Volume = $ClusterSharedVolume.SharedVolumeInfo.FriendlyVolumeName

    # retrieve the ReFS dedupe configuration
    $ReFSDedupStatus = Get-ReFSDedupStatus -Volume $Volume
    
    # if ReFS deduplication is enabled...
    if ($ReFSDedupStatus.Enabled) {
        # start a deduplication job
        $Job = Start-ReFSDedupJob -Volume $Volume -ExcludeFolder $ExcludeFolder -CpuPercentage 25 -ConcurrentOpenFiles 1 -Duration ([System.TimeSpan]::FromHours(1))

        # while job exists...
        while ($Job.State -notin 'Completed', 'Failed') {
            # sleep for 1 second
            Start-Sleep -Seconds 1

            # update job object
            $Job = Get-Job -Id $Job.Id

            # retrieve dedupe status
            $ReFSDedupStatus = Get-ReFSDedupStatus -Volume $Volume

            # write dedupe status to screen
            Write-Host "Volume: $Volume; Type: $($ReFSDedupStatus.Type); State: $($ReFSDedupStatus.State)"
        }

        # if job failed...
        if ($Job.State -eq 'Failed') {
            Write-Host "Volume: $Volume; Type: $($ReFSDedupStatus.Type); State: $($ReFSDedupStatus.State); Error: $($Job.Error.Exception.Message.Replace([System.Environment]::NewLine, ' '))"
        }
        else {
            # write dedupe status to screen
            Write-Host "Volume: $Volume; Type: $($ReFSDedupStatus.Type); State: $($ReFSDedupStatus.State); Duration: $($ReFSDedupStatus.LastRunDuration.ToString()); Size: $(Format-Bytes -Size $ReFSDedupStatus.Size); TotalSavings: $(Format-Bytes -Size $ReFSDedupStatus.TotalSavings); SavingsOnLastRun: $(Format-Bytes -Size $ReFSDedupStatus.SavingsOnLastRun)"
        }
    }
}
