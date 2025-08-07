#requires -Modules FailoverClusters

[CmdletBinding()]
param(
	# local host name
	[Parameter(DontShow)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant()
)

# get cluster shared volumes on local node
try {
	$ClusterVirtualMachines = Get-ClusterNode -Name $HostName | Get-ClusterGroup | Where-Object { $_.GroupType -eq 'VirtualMachine' } | Sort-Object -Property 'Name'
}
catch {
	Write-Warning -Message "could not retrieve virtual machines on node: $HostName"
	return $_
}

# declare count
Write-Verbose -Verbose -Message "found '$($ClusterVirtualMachines.Count)' virtual machines on node: $HostName"

# process cluster shared volumes
foreach ($ClusterVirtualMachine in $ClusterVirtualMachines) {
	# report intent
	Write-Verbose -Verbose -Message "starting migration for '$($ClusterVirtualMachine.Name)' virtual machine"

	# move virtual machine
	try {
		$MovedClusterVirtualMachine = Move-ClusterVirtualMachineRole -InputObject $ClusterVirtualMachine -MigrationType Live
	}
	catch {
		Write-Warning -Message "could not move virtual machine: $($ClusterVirtualMachine.Name)"
		return $_
	}

	# report complete
	Write-Verbose -Verbose -Message "finished migration for '$($MovedClusterVirtualMachine.Name)' virtual machine to node: $($MovedClusterVirtualMachine.OwnerNode.Name)"
}
