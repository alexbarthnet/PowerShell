#requires -modules ActiveDirectory,TranscriptWithHostAndDate

<#
.SYNOPSIS
Stop services before shutdown of an Active Directory domain controller.

.DESCRIPTION
Stop services before shutdown of an Active Directory domain controller.

.PARAMETER Name
Name of services to stop. The default values are 'ADWS', 'KDC', and 'Netlogon'

#>

[CmdletBinding()]
Param (
	# string array with ordered service names
	[Parameter(Position = 0)]
	[string[]]$Name = ('ADWS', 'KDC', 'Netlogon')
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
	# get services
	Try {
		$Services = Get-Service
	}
	Catch {
		Write-Warning -Message 'could not retrieve services'
		Return $_
	}

	# process services to stop
	:NextService ForEach ($ServiceName in $Name) {
		# get service status
		$Status = $Services.Where({ $_.Name -eq $ServiceName }).Status

		# if status not found...
		If ([string]::IsNullOrEmpty($Status)) {
			# warn and continue
			Write-Warning -Message "could not retrieve status for service: $Service"
			Continue NextService
		}

		# if service is not running...
		If ($Status -ne 'Running') {
			Write-Warning -Message "found '$ServiceName' with unexpected status: $Status"
			Continue NextService
		}

		# stop the service
		Try {
			Stop-Service -Name $ServiceName -Force
		}
		Catch {
			Write-Warning -Message "could not stop service: $ServiceName"
			Return $_
		}

		# declare stopped
		Write-Verbose -Verbose -Message "stopped service: $ServiceName"
	}

	# sleep to allow clients to determine domain controller services are offline
	Start-Sleep -Seconds 60
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
