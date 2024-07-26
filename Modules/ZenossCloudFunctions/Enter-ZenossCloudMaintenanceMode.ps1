#requires -Modules ZenossCloudFunctions,TranscriptWithHostAndDate, CmsCredentials

[CmdletBinding(DefaultParameterSetName = 'Default')]
param (
	# string for CmsCredential identity
	[Parameter(Position = 0)]
	[string]$Identity = 'Zenoss',
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipTranscript,
	# local hostname
	[Parameter(DontShow)]
	[string]$Hostname = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# local DNS hostname
	[Parameter(DontShow)]
	[string]$Dnshostname = ($Hostname, [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant() -join '.').TrimEnd('.')
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
	# get credential object
	Try {
		$Credential = Get-CmsCredential -Identity $Identity
	}
	Catch {
		Throw $_
	}

	# define parameters for Set-ZenossCloudProductionStatec
	$SetZenossCloudProductionState = @{
		Credential  = $Credential
		Device      = $Dnshostname
		State       = 'Maintenance'
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# call zenoss function
	Try {
		Set-ZenossCloudProductionState @SetZenossCloudProductionState
	}
	Catch {
		Throw $_
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
