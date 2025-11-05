<#
.SYNOPSIS
Stop Active Directory and related services before shutdown of an Active Directory directory server.

.DESCRIPTION
Stop Active Directory and related services before shutdown of an Active Directory directory server.

.NOTES
This script first stops ADWS and sleeps for 30 seconds to allow load balancers to determine the server will be shutting down.
This script then exits if the server is not a full domain controller.
This script then stops KDC and NetLogon to prevent clients from attempting to authenticate to the server during shutdown.

.LINK
https://learn.microsoft.com/en-us/troubleshoot/windows-server/windows-security/cannot-authenticate-users-shut-down-domain-controller

#>

[CmdletBinding()]
Param (
	# domain role of current system
	[Parameter(DontShow)]
	[uint16]$DomainRole = (Get-CimInstance -ClassName 'Win32_ComputerSystem' -Property 'DomainRole').DomainRole
)

Begin {
	Function Stop-ServiceAndSleep {
		Param(
			[Parameter(Position = 0, Mandatory)]
			[string]$Name,
			[Parameter(Position = 1)]
			[int32]$Seconds
		)

		# get service status
		$Status = $script:Services.Where({ $_.Name -eq $Name }).Status

		# if status not found...
		If ([string]::IsNullOrEmpty($Status)) {
			# warn and continue
			Write-Warning -Message "$Name; could not retrieve status for service: $($_.Exception.Message)"
			Return
		}
		
		# if service is not running...
		If ($Status -ne 'Running') {
			Write-Warning -Message "$Name; found unexpected status for service: $Status"
			Return
		}
		
		# stop the service
		Try {
			Stop-Service -Name $Name -Force
		}
		Catch {
			Write-Warning -Message "$Name; could not stop service: $($_.Exception.Message)"
			Return $_
		}
		
		# declare stopped
		Write-Host "Stopped service: $Name"

		# if seconds provided...
		If ($PSBoundParameters.ContainsKey('Seconds')) {
			# declare sleep
			Write-Host "Sleeping for '$Seconds' seconds..."

			# sleep!
			Start-Sleep -Seconds $Seconds
		}
	}
}

Process {
	# get services
	Try {
		$Services = Get-Service
	}
	Catch {
		Write-Warning -Message "could not retrieve services: $($_.Exception.Message)"
		Return $_
	}

	# stop ADWS and sleep for 30 seconds
	Try {
		Stop-ServiceAndSleep -Name 'ADWS' -Seconds 30
	}
	Catch {
		Return $_
	}

	# if local system is not a domain controller...
	If ($DomainRole -lt 4) {
		Return
	}

	# stop KCC and do not sleep
	Try {
		Stop-ServiceAndSleep -Name 'KDC'
	}
	Catch {
		Return $_
	}

	# stop Netlogon and do not sleep
	Try {
		Stop-ServiceAndSleep -Name 'Netlogon'
	}
	Catch {
		Return $_
	}
}
