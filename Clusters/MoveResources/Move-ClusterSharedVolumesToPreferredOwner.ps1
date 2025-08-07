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
	# get cluster owner node
	try {
		$ClusterOwnerNode = $ClusterSharedVolume | Get-ClusterOwnerNode
	}
	catch {
		Write-Warning -Message "could not retrieve owner node for cluster shared volume: $($ClusterSharedVolume.Name)"
		return $_
	}

	# if no preferred owners are defined...
	if ($ClusterOwnerNode.OwnerNodes.Count -eq 0) {
		Write-Warning -Message "no preferred owner is defined for cluster shared volume: $($ClusterSharedVolume.Name)"
		continue
	}

	# if current host in list of preferred owners
	if ($ClusterOwnerNode.OwnerNodes.Name -contains $Hostname) {
		Write-Warning -Message "current hypervisor is a preferred owner for cluster shared volume: $($ClusterSharedVolume.Name)"
		continue
	}

	# if preferred owner is not singular
	if ($ClusterOwnerNode.OwnerNodes.Count -gt 1) {
		$Node = Get-Random -InputObject $ClusterOwnerNode.OwnerNodes.Name
	}
	else {
		$Node = $ClusterOwnerNode.OwnerNodes.Name
	}

	# report intent
	Write-Verbose -Verbose -Message "starting migration for '$($ClusterSharedVolume.Name)' cluster shared volume to node: $Node"

	# move cluster shared volume to preferred owner
	try {
		$MovedClusterSharedVolume = Move-ClusterSharedVolume -InputObject $ClusterSharedVolume -Node $Node
	}
	catch {
		Write-Warning -Message "could not move cluster shared volume: $($ClusterSharedVolume.Name)"
		return $_
	}

	# report complete
	Write-Verbose -Verbose -Message "finished migration for '$($MovedClusterSharedVolume.Name)' cluster shared volume to node: $($MovedClusterSharedVolume.OwnerNode.Name)"
}
