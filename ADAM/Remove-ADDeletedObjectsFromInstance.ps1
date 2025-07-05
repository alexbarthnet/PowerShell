#requires -Modules ActiveDirectory

[CmdletBinding()]
param (
	# local host name
	[Parameter(DontShow)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# local domain name
	[Parameter(DontShow)]
	[string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
	# local DNS hostname
	[Parameter(DontShow)]
	[string]$DnsHostName = ($HostName, $DomainName -join '.').TrimEnd('.'),
	# PDC role owner for computer domain
	[Parameter(DontShow)]
	[string]$PdcRoleOwner = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().PdcRoleOwner.Name,
	# naming context for computer domain
	[Parameter(DontShow)]
	[string]$DomainNCName = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().GetDirectoryEntry().DistinguishedName,
	# port for ADAM instance
	[Parameter(DontShow)]
	[uint16]$Port = 389,
	# port for ADAM instance
	[Parameter(DontShow)]
	[string]$Server = ('{0}:{1}' -f $DnsHostName, $Port)
)

Begin {
	# test access to Deleted Objects container on PDC
	Try {
		$DeletedObjectsContainer = Get-ADObject -Server $PdcRoleOwner -Identity "CN=Deleted Objects,$DomainNCName" -IncludeDeletedObjects | Select-Object -ExpandProperty 'DistinguishedName'
	}
	Catch {
		Write-Warning -Message "could not access Deleted Objects container on server: $PdcRoleOwner"
		Throw $_
	}

	# retreive matching partition from local instance
	Try {
		$PartitionRoot = Get-ADObject -Server $Server -Identity $DomainNCName -Properties 'whenCreated'
	}
	Catch {
		Write-Warning -Message "could not access expected '$DomainNCName' partition on server: $Server"
		Throw $_
	}

	# retreive configuration NC from local instance
	Try {
		$ConfigurationNC = Get-ADRootDSE -Server $Server | Select-Object -ExpandProperty 'configurationNamingContext'
	}
	Catch {
		Write-Warning -Message "could not retrieve configuration naming context from 'rootDSE' object on server: $Server"
		Throw $_
	}

	# define ADAM Sync Services direction
	$ServiceName = 'ADAMSync'
	$ServiceMode = 'Reverse'

	# define ADAM Sync Services object and parent container
	$ServicesContainer = "CN=Services,$ConfigurationNC"
	$ADAMSyncParentContainer = "CN=$ServiceName,$ServicesContainer"
	$ADAMSyncStatusContainer = "CN=$ServiceMode,$ADAMSyncParentContainer"

	# retrieve ADAMSync Services container
	Try {
		$null = Get-ADObject -Server $Server -Identity $ADAMSyncParentContainer
	}
	Catch {
		# create ADAMSync Services object with properties
		Try {
			New-ADObject -Type 'container' -Name $ServiceName -Path $ServicesContainer
		}
		Catch {
			Write-Warning -Message "could not create '$ServiceName' container in '$ServicesContainer' on server: $Server"
			Throw $_
		}
	}

	# retrieve ADAMSync Services object with properties
	Try {
		$ADAMSyncObject = Get-ADObject -Server $Server -Identity $ADAMSyncStatusContainer -Properties 'adminDescription', 'whenChanged', 'whenCreated'
	}
	Catch {
		# create ADAMSync Services object with properties
		Try {
			New-ADObject -Type 'container' -Name $ServiceMode -Path $ADAMSyncParentContainer
		}
		Catch {
			Write-Warning -Message "could not create '$ServiceMode' container in '$ADAMSyncParentContainer' on server: $Server"
			Throw $_
		}

		# retrieve ADAMSync Services object with properties
		Try {
			$ADAMSyncObject = Get-ADObject -Server $Server -Identity $ADAMSyncStatusContainer -Properties 'adminDescription', 'whenChanged', 'whenCreated'
		}
		Catch {
			Write-Warning -Message "could not retrieve '$ServiceMode' container in '$ADAMSyncParentContainer' on server: $Server"
			Throw $_
		}
	}

	# if whenChanged matches whenCreated...
	If ($ADAMSyncObject.whenChanged -eq $ADAMSyncObject.whenCreated) {
		# set WhenChanged string to when partition was created
		$WhenChanged = $PartitionRoot.whenCreated.ToString('yyyyMMddHHmmss.fZ')
	}
	# if whenChanged does not match whenCreated...
	Else {
		# set WhenChanged string to when ADAMSync Services object was last updated was created
		$WhenChanged = $ADAMSyncObject.whenChanged.ToString('yyyyMMddHHmmss.fZ')
	}
}

Process {
	# define parameters
	$GetADObject = @{
		Server                = $PdcRoleOwner
		SearchBase            = $DeletedObjectsContainer
		Filter                = "objectClass -eq 'user' -and whenChanged -gt '$WhenChanged'"
		Properties            = 'objectGuid'
		IncludeDeletedObjects = $true
	}

	# retrieve deleted objects in scope
	Try {
		$DeletedObjects = Get-ADObject @GetADObject | Select-Object -Property $Properties
	}
	Catch {
		Write-Warning -Message "could not retrieve deleted objects since '$WhenChanged' from '$Domain' domain on server: $Server"
		Throw $_
	}
	
	# loop through deleted objects
	:NextDeletedObject ForEach ($DeletedObject in $DeletedObjects) {
		# retrieve original object name from deleted object DN
		$ExistingObjectIdentity = '{0},{1}' -f $DeletedObject.DistinguishedName.Split('\0ADEL:', 2)[0], $DeletedObject.LastKnownParent

		# if WhatIf provided...
		If ($PSCmdlet.ShouldProcess($ExistingObjectIdentity)) {
			# remove existing object
			Try {
				Remove-ADObject -Server $Server -Identity $ExistingObjectIdentity -Confirm:$false
			}
			# continue to next deleted object if object not found
			Catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
				Continue NextDeletedObject
			}
			# throw error if exception other than object not found
			Catch {
				Throw $_
			}
		}
	}
}

End {
	# update ADAMSync Services object
	Try {
		Set-ADObject -Server $Server -Identity $ADAMSyncContainer -Replace @{ adminDescription = "Sync on $Server against '$PdcRoleOwner' domain controller" }
	}
	Catch {
		Write-Warning -Message "could not update 'ADAMSync' container in '$ServicesContainer' on server: $Server"
		Throw $_
	}
}
