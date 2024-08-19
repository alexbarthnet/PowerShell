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
		$ClusterSharedVolumes = Get-ClusterNode -Name $HostName | Get-ClusterSharedVolume | Sort-Object -Property 'Name'
	}
	Catch {
		Write-Warning -Message "'could not retrieve cluster shared volumes on node: $HostName"
		Return $_
	}

	# declare count
	Write-Verbose -Verbose -Message "found '$($ClusterSharedVolumes.Count)' cluster shared volumes on node: $HostName"

	# process cluster shared volumes
	ForEach ($ClusterSharedVolume in $ClusterSharedVolumes) {
		# get cluster owner node
		Try {
			$ClusterOwnerNode = $ClusterSharedVolume | Get-ClusterOwnerNode
		}
		Catch {
			Write-Warning -Message "could not retrieve owner node for cluster shared volume: $($ClusterSharedVolume.Name)"
			Return $_
		}

		# if no preferred owners are defined...
		If ($ClusterOwnerNode.OwnerNodes.Count -eq 0) {
			Write-Warning -Message "no preferred owner is defined for cluster shared volume: $($ClusterSharedVolume.Name)"
			Continue
		}

		# if current host in list of preferred owners
		If ($ClusterOwnerNode.OwnerNodes.Name -contains $Hostname) {
			Write-Warning -Message "current hypervisor is a preferred owner for cluster shared volume: $($ClusterSharedVolume.Name)"
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
		Write-Verbose -Verbose -Message "moving '$($ClusterSharedVolume.Name)' cluster shared volume to node: $Node"

		# move cluster shared volume to preferred owner
		Try {
			$MovedClusterSharedVolume = Move-ClusterSharedVolume -InputObject $ClusterSharedVolume -Node $Node
		}
		Catch {
			Write-Warning -Message "could not move cluster shared volume: $($ClusterSharedVolume.Name)"
			Return $_
		}

		# report complete
		Write-Verbose -Verbose -Message "moved '$($MovedClusterSharedVolume.Name)' cluster shared volume to node: $($MovedClusterSharedVolume.OwnerNode.Name)"
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
