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
	# get cluster owner node
	try {
		$ClusterOwnerNode = $ClusterVirtualMachine | Get-ClusterOwnerNode
	}
	catch {
		Write-Warning -Message "could not retrieve owner node for virtual machine: $($ClusterVirtualMachine.Name)"
		return $_
	}

	# if no preferred owners are defined...
	if ($ClusterOwnerNode.OwnerNodes.Count -eq 0) {
		Write-Warning -Message "no preferred owner is defined for virtual machine: $($ClusterVirtualMachine.Name)"
		continue
	}

	# if current host in list of preferred owners
	if ($ClusterOwnerNode.OwnerNodes.Name -contains $Hostname) {
		Write-Warning -Message "current hypervisor is a preferred owner for virtual machine: $($ClusterVirtualMachine.Name)"
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
	Write-Verbose -Verbose -Message "starting migration for '$($ClusterVirtualMachine.Name)' virtual machine to node: $Node"

	# move virtual machine to preferred owner
	try {
		$MovedClusterVirtualMachine = Move-ClusterVirtualMachineRole -InputObject $ClusterVirtualMachine -Node $Node -MigrationType Live
	}
	catch {
		Write-Warning -Message "could not move virtual machine: $($ClusterVirtualMachine.Name)"
		return $_
	}

	# report complete
	Write-Verbose -Verbose -Message "finished migration for '$($MovedClusterVirtualMachine.Name)' virtual machine to node: $($MovedClusterVirtualMachine.OwnerNode.Name)"
}
