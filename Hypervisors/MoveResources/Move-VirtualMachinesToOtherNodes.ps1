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
		# report intent
		Write-Verbose -Verbose -Message "moving '$($ClusterVirtualMachine.Name)' virtual machine"

		# move virtual machine
		Try {
			$MovedClusterVirtualMachine = Move-ClusterVirtualMachineRole -InputObject $ClusterVirtualMachine -MigrationType Live
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
