#requires -Modules TranscriptWithHostAndDate, FailoverClusters

[CmdletBinding()]
Param(
	[Parameter(DontShow)]
	[switch]$SkipTranscript
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
		$ClusterSharedVolumes = Get-ClusterSharedVolume | Where-Object { $_.OwnerNode -eq [System.Environment]::MachineName } | Sort-Object -Property 'Name'
	}
	Catch {
		Write-Warning -Message 'could not retrieve cluster shared volumes'
		Return $_
	}

	# declare count
	Write-Verbose -Verbose -Message "found '$($ClusterSharedVolumes.Count)' cluster shared volumes"

	# process cluster shared volumes
	ForEach ($ClusterSharedVolume in $ClusterSharedVolumes) {
		Try {
			$MovedClusterSharedVolume = Move-ClusterSharedVolume -InputObject $ClusterSharedVolume
		}
		Catch {
			Write-Warning -Message "could not move cluster shared volume: $($ClusterSharedVolume.Name)"
			Return $_
		}

		# report complete
		Write-Verbose -Verbose -Message "moved '$($MovedClusterSharedVolume.Name)' to cluster node: $($MovedClusterSharedVolume.OwnerNode.Name)"
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
