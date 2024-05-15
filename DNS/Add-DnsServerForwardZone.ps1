#requires -Modules DnsServer

<#
.SYNOPSIS
Adds a new forward zone to a DNS server.

.DESCRIPTION
Adds a new forward zone to a DNS server. The name of source zone can be provided to copy configuration details such as NS records and values from an SOA record to the new zone.

.PARAMETER ZoneName
The name of the new forward zone. Required.

.PARAMETER SourceZoneName
The name of an existing forward zone on the DNS server. If provided, the NS records and the values in the SOA record (less the serial number) of the existing zone will be copied to the new forward zone.

.PARAMETER NameServers
The list of name servers for new forward zone. This parameter is ignored if the SourceZoneName parameter is provided.

.PARAMETER ComputerName
The name of the DNS server where the new forward zone will be created. The default value is the domain controller with the PDC Emulator FSMO role.

.INPUTS
None.

.OUTPUTS
None.

#>

[CmdletBinding()]
Param(
	# zone name for new forward zone
	[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
	[string]$ZoneName,
	# zone name for existing forward zone
	[Parameter(Position = 1)]
	[string]$SourceZoneName,
	# domain name; default value is current domain name
	[Parameter(Position = 2)]
	[string]$Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name,
	# computer name of the DNS server; default value is current PDC role owner
	[Parameter(DontShow)]
	[string]$ComputerName = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
)

Function Add-DnsServerResourceRecordToList {
	Param(
		[Parameter(Mandatory = $true)][ValidateScript({ $_ -is [Microsoft.Management.Infrastructure.CimInstance] -and $_.CimClass.CimClassName -eq 'DnsServerResourceRecord' })]
		[object]$DnsServerResourceRecord
	)

	# create hashtable for DNS record
	$HashtableForParameters = @{
		ComputerName = $ComputerName
		ZoneName     = $ZoneName
		TimeToLive   = $DnsServerResourceRecord.TimeToLive
		ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
	}

	# update hasthable with DNS record name
	switch ($DnsServerResourceRecord.HostName) {
		$ZoneLabel {
			$HashtableForParameters['Name'] = '@'
		}
		{ $_.EndsWith(".$ZoneLabel") } {
			$HashtableForParameters['Name'] = $DnsServerResourceRecord.HostName.TrimEnd(".$ZoneLabel")
		}
		Default {
			$HashtableForParameters['Name'] = $DnsServerResourceRecord.HostName
		}
	}

	# update hashtable with DNS record type and data
	switch ($DnsServerResourceRecord.RecordType) {
		'A' {
			$HashtableForParameters['A'] = $true
			$HashtableForParameters['IPv4Address'] = $DnsServerResourceRecord.RecordData.IPv4Address.IPAddressToString
		}
		'CNAME' {
			$HashtableForParameters['CName'] = $true
			$HashtableForParameters['HostNameAlias'] = $DnsServerResourceRecord.RecordData.HostNameAlias
		}
		'NS' {
			$HashtableForParameters['NS'] = $true
			$HashtableForParameters['NameServer'] = $DnsServerResourceRecord.RecordData.NameServer
		}
		'TXT' {
			$HashtableForParameters['Txt'] = $true
			$HashtableForParameters['DescriptiveText'] = $DnsServerResourceRecord.RecordData.DescriptiveText
		}
		Default {
			Write-Warning "unsupported record type of '$_' on '$($DnsServerResourceRecord.HostName)'"
			Return
		}
	}

	# add hashtable to list
	$script:DnsServerResourceRecordsToMake.Add($HashtableForParameters)
}

# validate zone name parameter
switch ($ZoneName) {
	# if the DNS root provided...
	'.' {
		# warn and return
		Write-Warning "ZoneName parameter cannot be '.'"
		Return
	}
	# if zone name is a fully qualified DNS domain...
	{ $_.EndsWith('.') } {
		# redefine zone name without the trailing dot
		$ZoneName = $ZoneName.TrimEnd('.')
	}
}

# retrieve label of zone name
$ZoneLabel = $ZoneName.Split('.')[0]

# create list for hashtables
$DnsServerResourceRecordsToMake = [System.Collections.Generic.List[hashtable]]::new()

# retrieve zones
Write-Host "`nRetrieving forward DNS zones..."
Try {
	$DnsServerZones = Get-DnsServerZone -ComputerName $ComputerName | Where-Object { $_.ZoneType -eq 'Primary' -and -not $_.IsAutoCreated -and -not $_.IsReverseLookupZone }
	Write-Host "...found '$($DnsServerZones.Count)' forward zone(s)"
}
Catch {
	Write-Warning "could not retrieve DNS zones from server: $ComputerName"
	Return $_
}

# if zone name already exists...
If ($ZoneName -in $DnsServerZones.ZoneName) {
	Write-Warning "found existing DNS zone with zone name '$ZoneName' on server: $ComputerName"
	Return
}

# if source zone name provided and does not exist...
If ($PSBoundParameters.ContainsKey('SourceZoneName') -and $SourceZoneName -notin $DnsServerZones.ZoneName) {
	Write-Warning "could not find DNS zone with source zone name '$SourceZoneName' on server: $ComputerName"
	Return
}

# process zones
ForEach ($DnsServerZone in $DnsServerZones) {
	# if zone is child domain of existing zone...
	If ($ZoneName -eq ($ZoneLabel, $DnsServerZone.ZoneName -join '.')) {
		# declare parent zone
		Write-Host "...found parent zone: $($DnsServerZone.ZoneName)"
		# record parent zone name
		$ParentZone = $DnsServerZone
	}
	# if source zone found...
	If ($SourceZoneName -eq $DnsServer.ZoneName) {
		# create source zone object
		$SourceZone = $DnsServerZone
	}
}

# if parent zone defined but source zone not defined...
If ($null -ne $ParentZone -and $null -eq $SourceZone) {
	# declare source zone
	Write-Host '...no source zone set and parent zone found; setting parent zone as source zone'
	# define source zone
	$SourceZone = $ParentZone
}

# if source zone defined...
If ($null -ne $SourceZone) {
	# declare start
	Write-Host "`nRetrieving SOA and NS DNS records from source zone..."

	# get DNS records from source zone
	Try {
		$DnsServerResourceRecordsFromSource = Get-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $SourceZone.ZoneName -Node
	}
	Catch {
		Return $_
	}

	# retrieve SOA record from source zone
	$DnsServerResourceRecordForSOA = $DnsServerResourceRecordsFromSource | Where-Object { $_.RecordType -in 'SOA' }

	# retrieve NS records from source zone
	$DnsServerResourceRecordsForNS = $DnsServerResourceRecordsFromSource | Where-Object { $_.RecordType -in 'NS' }

	# declare count and display records
	Write-Host "...found '$($DnsServerResourceRecordsForNS.Count)' NS record(s):"
	$DnsServerResourceRecordsForNS

	# process NS DNS records
	ForEach ($DnsServerResourceRecord in $DnsServerResourceRecordsForNS) {
		# create hashtable of parameters from DNS record
		Try {
			Add-DnsServerResourceRecordToList -DnsServerResourceRecord $DnsServerResourceRecord
		}
		Catch {
			Return $_
		}
	}
}

# if parent zone defined...
If ($null -ne $ParentZone) {
	# declare start
	Write-Host "`nRetrieving matching DNS records from parent zone..."

	# get DNS records from parent zone
	Try {
		$DnsServerResourceRecordsFromParent = Get-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $ParentZone.ZoneName
	}
	Catch {
		Return $_
	}

	# retrieve any DNS records in child domain
	$DnsServerResourceRecordsToCopy = $DnsServerResourceRecordsFromParent | Where-Object { $_.HostName.EndsWith($ZoneLabel) }

	# declare count and display records
	Write-Host "...found '$($DnsServerResourceRecordsToCopy.Count)' record(s):"
	$DnsServerResourceRecordsToCopy

	# process each DNS records
	ForEach ($DnsServerResourceRecord in $DnsServerResourceRecordsToCopy) {
		# create hashtable of parameters from DNS record
		Try {
			Add-DnsServerResourceRecordToList -DnsServerResourceRecord $DnsServerResourceRecord
		}
		Catch {
			Return $_
		}
	}
}

# if sub domain records exist...
If ($DnsServerResourceRecordsToMake.Count -gt $DnsServerResourceRecordsForNS.Count -and -not $Force) {
	If (-not $Force) {
		Write-Warning "The provided zone name is a child zone of '$($ParentZone.ZoneName)' zone. Existing records in the child domain will recreated in the new zone." -WarningAction Inquire
	}
}

# define parameters
$AddDnsServerPrimaryZone = @{
	ComputerName = $ComputerName
	ZoneName     = $ZoneName
	ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
}

# if soure zone exists...
If ($null -ne $SourceZone) {
	$AddDnsServerPrimaryZone['ReplicationScope'] = $SourceZone.ReplicationScope
	$AddDnsServerPrimaryZone['DynamicUpdate'] = $SourceZone.DynamicUpdate
}

# declare state
Write-Host "`nCreating DNS zone..."

# create destination zone
Try {
	Add-DnsServerPrimaryZone @AddDnsServerPrimaryZone
}
Catch {
	Write-Warning "could not create zone: $ZoneName"
	Return $_
}

# declare state
Write-Host "`n...created DNS zone"

# declare state
Write-Host "`nRetrieving SOA record..."

# retreive destination zone SOA record
Try {
	$OldSoaRecord = Get-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $ZoneName -Name '@' -RRType Soa
}
Catch {
	Write-Warning "could not retrieve SOA record for zone: $ZoneName"
	Return $_
}

# declare state
Write-Host "`n...retrieved SOA record"

# clone SOA record
Try {
	$NewSoaRecord = $OldSoaRecord.Clone()
}
Catch {
	Write-Warning 'could not clone SOA record'
	Return $_
}

# update SOA record
Try {
	$NewSoaRecord.TimeToLive = $DnsServerResourceRecordForSOA.TimeToLive
	$NewSoaRecord.RecordData.ExpireLimit = $DnsServerResourceRecordForSOA.RecordData.ExpireLimit
	$NewSoaRecord.RecordData.MinimumTimeToLive = $DnsServerResourceRecordForSOA.RecordData.MinimumTimeToLive
	$NewSoaRecord.RecordData.RefreshInterval = $DnsServerResourceRecordForSOA.RecordData.RefreshInterval
	$NewSoaRecord.RecordData.ResponsiblePerson = $DnsServerResourceRecordForSOA.RecordData.ResponsiblePerson
	$NewSoaRecord.RecordData.RetryDelay = $DnsServerResourceRecordForSOA.RecordData.RetryDelay
}
Catch {
	Write-Warning 'could not set properties on cloned SOA record'
	Return $_
}

# define parameters
$SetDnsServerResourceRecord = @{
	ComputerName   = $ComputerName
	ZoneName       = $ZoneName
	OldInputObject = $OldSoaRecord
	NewInputObject = $NewSoaRecord
	ErrorAction    = [System.Management.Automation.ActionPreference]::Stop
}

# declare state
Write-Host "`nUpdating SOA record..."

# update destination zone SOA record
Try {
	Set-DnsServerResourceRecord @SetDnsServerResourceRecord
}
Catch {
	Write-Warning 'could not update SOA record'
	Return $_
}

# declare state
Write-Host "`n...updated SOA record"
Write-Host "`nRecreating DNS records..."

# create child domain records
ForEach ($DnsServerResourceRecord in $DnsServerResourceRecordsToMake) {
	# declare record
	Write-Host "...re-creating '$($DnsServerResourceRecordsToCopy.HostName)'"

	# create record
	Try {
		Add-DnsServerResourceRecord @DnsServerResourceRecord
	}
	Catch {
		Write-Warning "could not create record: $($DnsServerResourceRecord.HostName)"
		Return $_
	}
}
