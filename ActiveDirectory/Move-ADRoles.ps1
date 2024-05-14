#requires -modules ActiveDirectory,TranscriptWithHostAndDate

<#
.SYNOPSIS
Move all Flexible Master Single Operation (FSMO) roles on the local system to next available domain controller.

.DESCRIPTION
Move all Flexible Master Single Operation (FSMO) roles on the local system to next available domain controller.

.PARAMETER SiteName
String parameter for the Active Directory site name to search for the next available domain controller. The default value is the site for the local system.

#>
[CmdletBinding()]
Param (
	[Parameter(Position = 0)]
	[string]$SiteName = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySite]::GetComputerSite().Name,
	# domain role of current system
	[Parameter(DontShow)]
	[uint16]$DomainRole = (Get-CimInstance -ClassName 'Win32_ComputerSystem' -Property 'DomainRole').DomainRole,
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
	# if local system is not a domain controller...
	If ($DomainRole -lt 4) {
		# report and return
		Write-Warning -Message 'local system is not a domain controller'
		Return
	}

	# get local domain controller by name
	Try {
		$ADDomainController = Get-ADDomainController -Identity $DnsHostName
	}
	Catch {
		Return $_
	}

	# if local domain controller does not host any roles...
	If ($ADDomainController.OperationMasterRoles.Count -eq 0) {
		# report and return
		Write-Verbose -Verbose -Message 'no operation master roles found on local system'
		Return
	}

	# get other domain controller in same site
	Try {
		$ADDomainControllersInSite = Get-ADDomainController -Filter "Site -eq '$SiteName'" | Where-Object { $_.HostName -ne $DnsHostName } | Sort-Object -Property Name
	}
	Catch {
		Return $_
	}

	# if other domain controllers not found...
	If ($null -eq $ADDomainControllersInSite) {
		# warn and return
		Write-Warning -Message "no other domain controllers found in site: '$($ADDomainController.Site)'"
		Return
	}

	# for each other domain controller in the same site...
	:NextDomainController ForEach ($ADDomainControllerInSite in $ADDomainControllersInSite) {
		# get next domain controller information from domain controller
		Try {
			$NextDomainController = Get-ADDomainController -Server $ADDomainControllerInSite.HostName -Identity $ADDomainControllerInSite
		}
		Catch {
			Write-Warning -Message "could not retrieve domain controller: '$($ADDomainControllerInSite.HostName)'"
			Continue NextDomainController
		}
		# if domain controller found...
		If ($script:NextDomainController) {
			Write-Verbose -Verbose -Message "found next available domain controller in same site: '$($NextDomainController.HostName)'"
			Break NextDomainController
		}
	}

	# if next domain controllers not found...
	If ($null -eq $script:NextDomainController) {
		# warn and return
		Write-Warning -Message "could not connect to any other domain controllers in site: '$($ADDomainController.Site)'"
		Return
	}

	# for each local operation master role...
	ForEach ($OperationMasterRole in $ADDomainController.OperationMasterRoles) {
		# move operation master role to next domain controller
		Try {
			Move-ADDirectoryServerOperationMasterRole -Server $NextDomainController.HostName -Identity $NextDomainController -OperationMasterRole $OperationMasterRole -Confirm:$false
		}
		Catch {
			Write-Warning -Message "could not move '$OperationMasterRole' role to domain controller: '$($NextDomainController.HostName)'"
			Return $_
		}
		# declare move
		Write-Verbose -Verbose -Message "moved '$OperationMasterRole' role to domain controller: '$($NextDomainController.HostName)'"
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
