#requires -Modules TranscriptWithHostAndDate, FailoverClusters

[CmdletBinding()]
Param(
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
	# get cluster shared volumes on local node
	Try {
		$ClusterVirtualMachines = Get-ClusterNode -Name $HostName | Get-ClusterGroup | Where-Object { $_.GroupType -eq 'VirtualMachine' } | Sort-Object -Property 'Name'
	}
	Catch {
		Write-Warning -Message "could not retrieve virtual machines on node: $HostName"
		Return $_
	}

	# declare count
	Write-Verbose -Verbose -Message "found '$($ClusterVirtualMachines.Count)' virtual machines on node: $HostName"

	# process cluster shared volumes
	ForEach ($ClusterVirtualMachine in $ClusterVirtualMachines) {
		# get cluster owner node
		Try {
			$ClusterOwnerNode = $ClusterVirtualMachine | Get-ClusterOwnerNode
		}
		Catch {
			Write-Warning -Message "could not retrieve owner node for virtual machine: $($ClusterVirtualMachine.Name)"
			Return $_
		}

		# if no preferred owners are defined...
		If ($ClusterOwnerNode.OwnerNodes.Count -eq 0) {
			Write-Warning -Message "no preferred owner is defined for virtual machine: $($ClusterVirtualMachine.Name)"
			Continue
		}

		# if current host in list of preferred owners
		If ($ClusterOwnerNode.OwnerNodes.Name -contains $Hostname) {
			Write-Warning -Message "current hypervisor is a preferred owner for virtual machine: $($ClusterVirtualMachine.Name)"
			Continue
		}

		# if preferred owner is not singular
		If ($ClusterOwnerNode.OwnerNodes.Count -gt 1) {
			$Node = Get-Random -InputObject $ClusterOwnerNode.OwnerNodes.Name
		}
		Else {
			$Node = $ClusterOwnerNode.OwnerNodes.Name
		}

		# report intent
		Write-Verbose -Verbose -Message "moving '$($ClusterVirtualMachine.Name)' cluster shared volume to node: $Node"

		# move virtual machine to preferred owner
		Try {
			$MovedClusterVirtualMachine = Move-ClusterVirtualMachineRole -InputObject $ClusterVirtualMachine -Node $Node -MigrationType Live
		}
		Catch {
			Write-Warning -Message "could not move virtual machine: $($ClusterVirtualMachine.Name)"
			Return $_
		}

		# report complete
		Write-Verbose -Verbose -Message "moved '$($MovedClusterVirtualMachine.Name)' virtual machine to node: $($MovedClusterVirtualMachine.OwnerNode.Name)"
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
