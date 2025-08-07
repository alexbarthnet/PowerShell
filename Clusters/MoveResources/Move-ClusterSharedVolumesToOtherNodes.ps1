#requires -Modules FailoverClusters

[CmdletBinding()]
param(
	# local host name
	[Parameter(DontShow)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant()
)

# get cluster shared volumes on local node
try {
	$ClusterSharedVolumes = Get-ClusterNode -Name $HostName | Get-ClusterSharedVolume | Sort-Object -Property 'Name'
}
catch {
	Write-Warning -Message "could not retrieve cluster shared volumes on node: $HostName"
	return $_
}

# declare count
Write-Verbose -Verbose -Message "found '$($ClusterSharedVolumes.Count)' cluster shared volumes on node: $HostName"

# process cluster shared volumes
foreach ($ClusterSharedVolume in $ClusterSharedVolumes) {
	# report intent
	Write-Verbose -Verbose -Message "starting migration for '$($ClusterSharedVolume.Name)' cluster shared volume"

	# move cluster shared volume
	try {
		$MovedClusterSharedVolume = Move-ClusterSharedVolume -InputObject $ClusterSharedVolume
	}
	catch {
		Write-Warning -Message "could not move cluster shared volume: $($ClusterSharedVolume.Name)"
		return $_
	}

	# report complete
	Write-Verbose -Verbose -Message "finished migration for '$($MovedClusterSharedVolume.Name)' cluster shared volume to node: $($MovedClusterSharedVolume.OwnerNode.Name)"
}
