#requires -Modules ActiveDirectory

[CmdletBinding(SupportsShouldProcess)]
param (
	# when changed time
	[Parameter(Position = 0)]
	[string]$WhenChanged,
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

begin {
	function Remove-ADDeletedObject {
		[CmdletBinding(SupportsShouldProcess)]
		param(
			[string]$Identity
		)

		# if WhatIf provided...
		if ($PSCmdlet.ShouldProcess($ExistingObjectIdentity)) {
			# remove existing object
			try {
				Remove-ADObject -Server $Server -Identity $ExistingObjectIdentity -Confirm:$false
			}
			# continue to next deleted object if object not found
			catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
				continue NextDeletedObject
			}
			# throw error if exception other than object not found
			catch {
				throw $_
			}
		}
	}

	# test access to domain root on PDC
	try {
		$DomainRoot = Get-ADObject -Server $PdcRoleOwner -Identity $DomainNCName
	}
	catch {
		Write-Warning -Message "could not access domain root on server: $PdcRoleOwner"
		throw $_
	}

	# test access to Deleted Objects container on PDC
	try {
		$DeletedObjectsContainer = Get-ADObject -Server $PdcRoleOwner -Identity "CN=Deleted Objects,$DomainNCName" -IncludeDeletedObjects | Select-Object -ExpandProperty 'DistinguishedName'
	}
	catch {
		Write-Warning -Message "could not access Deleted Objects container on server: $PdcRoleOwner"
		throw $_
	}

	# retreive matching partition from local instance
	try {
		$PartitionRoot = Get-ADObject -Server $Server -Identity $DomainNCName -Properties 'whenCreated'
	}
	catch {
		Write-Warning -Message "could not access expected '$DomainNCName' partition on server: $Server"
		throw $_
	}

	# retreive configuration NC from local instance
	try {
		$ConfigurationNC = Get-ADRootDSE -Server $Server | Select-Object -ExpandProperty 'configurationNamingContext'
	}
	catch {
		Write-Warning -Message "could not retrieve configuration naming context from 'rootDSE' object on server: $Server"
		throw $_
	}

	# define ADAM Sync Services direction
	$ServiceGuid = $DomainRoot.objectGuid
	$ServiceName = 'ADAMSync'
	$ServiceMode = 'Reverse'

	# define ADAM Sync Services object and parent container
	$ConfigServicesContainer = 'CN=Services,{0}' -f $ConfigurationNC
	$ADAMSyncParentContainer = 'CN={0},{1}' -f $ServiceName, $ConfigServicesContainer
	$ADAMSyncDomainContainer = 'CN={0},{1}' -f $ServiceGuid, $ADAMSyncParentContainer
	$ADAMSyncStatusContainer = 'CN={0},{1}' -f $ServiceMode, $ADAMSyncDomainContainer

	# verify ADAMSync Parent container
	try {
		$null = Get-ADObject -Server $Server -Identity $ADAMSyncParentContainer
	}
	catch {
		# create ADAMSync Parent container in Services container
		try {
			New-ADObject -Type 'container' -Name $ServiceName -Path $ConfigServicesContainer
		}
		catch {
			Write-Warning -Message "could not create '$ServiceName' container in '$ConfigServicesContainer' on server: $Server"
			throw $_
		}
	}

	# verify ADAMSync Domain container
	try {
		$null = Get-ADObject -Server $Server -Identity $ADAMSyncDomainContainer
	}
	catch {
		# create ADAMSync Domain container in Parent container
		try {
			New-ADObject -Type 'container' -Name $ServiceGuid -Path $ADAMSyncParentContainer
		}
		catch {
			Write-Warning -Message "could not create '$ServiceGuid' container in '$ADAMSyncParentContainer' on server: $Server"
			throw $_
		}
	}

	# verify ADAMSync Status container
	try {
		$null = Get-ADObject -Server $Server -Identity $ADAMSyncStatusContainer
	}
	catch {
		# create ADAMSync Status container in Domain container
		try {
			New-ADObject -Type 'container' -Name $ServiceMode -Path $ADAMSyncDomainContainer
		}
		catch {
			Write-Warning -Message "could not create '$ServiceMode' container in '$ADAMSyncDomainContainer' on server: $Server"
			throw $_
		}
	}

	# retrieve ADAMSync Services object with properties
	try {
		$ADAMSyncObject = Get-ADObject -Server $Server -Identity $ADAMSyncStatusContainer -Properties 'adminDescription', 'whenChanged', 'whenCreated'
	}
	catch {
		Write-Warning -Message "could not retrieve '$ServiceMode' container in '$ADAMSyncDomainContainer' on server: $Server"
		throw $_
	}

	# if whenChanged matches whenCreated...
	if ($ADAMSyncObject.whenChanged -eq $ADAMSyncObject.whenCreated) {
		# set WhenChanged string to when partition was created
		$WhenChanged = $PartitionRoot.whenCreated.ToString('yyyyMMddHHmmss.fZ')
	}
	# if whenChanged does not match whenCreated...
	else {
		# set WhenChanged string to when ADAMSync Services object was last updated was created
		$WhenChanged = $ADAMSyncObject.whenChanged.ToString('yyyyMMddHHmmss.fZ')
	}
}

process {
	# define LDAP filter
	$LDAPFilter = "(&(!(objectClass=contact))(!(objectClass=computer))(|(objectClass=user)(objectClass=group))(whenChanged>=$WhenChanged))"

	# define parameters
	$GetADObject = @{
		Server                = $PdcRoleOwner
		SearchBase            = $DeletedObjectsContainer
		LDAPFilter            = $LDAPFilter
		Properties            = 'objectGuid'
		IncludeDeletedObjects = $true
	}

	# retrieve deleted objects in scope
	try {
		$DeletedObjects = Get-ADObject @GetADObject | Select-Object -Property $Properties
	}
	catch {
		Write-Warning -Message "could not retrieve deleted objects since '$WhenChanged' from '$Domain' domain on server: $Server"
		throw $_
	}
	
	# loop through deleted objects
	:NextDeletedObject foreach ($DeletedObject in $DeletedObjects) {
		# retrieve original object class from deleted object
		$ObjectClass = $DeletedObject.objectClass
		
		# retrieve original object name from deleted object DN
		$ExistingObjectIdentity = '{0},{1}' -f $DeletedObject.DistinguishedName.Split('\0ADEL:', 2)[0], $DeletedObject.LastKnownParent

		# report state
		Write-Host "found deleted '$ObjectClass' object in source with identity: $ExistingObjectIdentity"

		# if WhatIf provided...
		if ($PSCmdlet.ShouldProcess($ExistingObjectIdentity)) {
			# remove existing object
			try {
				Remove-ADObject -Server $Server -Identity $ExistingObjectIdentity -Confirm:$false
			}
			# continue to next deleted object if object not found
			catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
				continue NextDeletedObject
			}
			# throw error if exception other than object not found
			catch {
				throw $_
			}

			# report state
			Write-Host "removed '$ObjectClass' object in target with identity: $ExistingObjectIdentity"
		}
	}
}

end {
	# update ADAMSync Services object
	try {
		Set-ADObject -Server $Server -Identity $ADAMSyncStatusContainer -Replace @{ adminDescription = "Completed '$ServiceMode' sync on $Server against '$PdcRoleOwner' domain controller" }
	}
	catch {
		Write-Warning -Message "could not update 'adminDescription' property on '$ADAMSyncStatusContainer' container on server: $Server"
		throw $_
	}
}
