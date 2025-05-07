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
		Write-Warning -Message "could not retrieve cluster shared volumes on node: $HostName"
		Return $_
	}

	# declare count
	Write-Verbose -Verbose -Message "found '$($ClusterSharedVolumes.Count)' cluster shared volumes on node: $HostName"

	# process cluster shared volumes
	ForEach ($ClusterSharedVolume in $ClusterSharedVolumes) {
		# report intent
		Write-Verbose -Verbose -Message "starting migration for '$($ClusterSharedVolume.Name)' cluster shared volume"

		# move cluster shared volume
		Try {
			$MovedClusterSharedVolume = Move-ClusterSharedVolume -InputObject $ClusterSharedVolume
		}
		Catch {
			Write-Warning -Message "could not move cluster shared volume: $($ClusterSharedVolume.Name)"
			Return $_
		}

		# report complete
		Write-Verbose -Verbose -Message "finished migration for '$($MovedClusterSharedVolume.Name)' cluster shared volume to node: $($MovedClusterSharedVolume.OwnerNode.Name)"
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
