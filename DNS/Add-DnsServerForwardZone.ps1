#requires -Modules DnsServer

<#
.SYNOPSIS
Create a forward lookup zone on a Microsoft Windows DNS server and copies any matching records from the existing domain zone to the new forward lookup zone.

.DESCRIPTION
Create a forward lookup zone on a Microsoft Windows DNS server and copies any matching records from the existing domain zone to the new forward lookup zone.

.PARAMETER ZoneName
The name of the new forward lookup zone. Required.

.PARAMETER Domain
The name of an existing forward zone on the DNS server. The NS records and SOA (less the serial number) of this zone will be copied to the new forward lookup zone.

.PARAMETER DynamicUpdate
Specifies the Dynamic Update configuration of the forward lookup zone created by the script and defaults to the 'None' configuration.

.PARAMETER ReplicationScope
Specifics the replication scope for the forward lookup zone and defaults to the 'Domain' replication scope. Custom replication scopes are not supported by this script.

.PARAMETER ComputerName
The name of the DNS server where the new forward zone will be created. The default value is the domain controller with the PDC Emulator FSMO role.

.PARAMETER SkipSoaRecordCopy
Instructs the script to skip copying the values from the SOA record of the domain.

.PARAMETER SkipNameServerCopy
Instructs the script to skip copying the name server records of the domain.

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
	# domain name; default value is current domain name
	[Parameter(Position = 1)]
	[string]$Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name,
	# dynamic update value
	[Parameter(Position = 2)][ValidateSet('None', 'NonsecureAndSecure', 'Secure')]
	[string]$DynamicUpdate = 'None',
	# replication scope for new zone
	[Parameter(Position = 3)][ValidateSet('Domain', 'Forest', 'Legacy')]
	[string]$ReplicationScope = 'Domain',
	# computer name of the DNS server; default value is current PDC role owner
	[Parameter(DontShow)]
	[string]$ComputerName = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
	# switch to skip copying the SOA records from the domain
	[Parameter(Position = 9)]
	[switch]$SkipSoaRecordCopy,
	# switch to skip copying the NS records from the domain
	[Parameter(Position = 10)]
	[switch]$SkipNameServerCopy
)

Begin {
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

	Function Copy-DnsServerSoaRecord {
		Param(
			[string]$SourceZone,
			[string]$TargetZone
		)

		# declare state
		Write-Host "`nRetrieving SOA records..."

		# retrieve souce SOA record
		Try {
			$SourceZoneSoaRecord = Get-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $SourceZone -Name '@' -RRType Soa
		}
		Catch {
			Write-Warning "could not retrieve SOA record for zone: $SourceZone"
			Return $_
		}
		
		# retreive target zone SOA record
		Try {
			$TargetZoneSoaRecord = Get-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $TargetZone -Name '@' -RRType Soa
		}
		Catch {
			Write-Warning "could not retrieve SOA record for zone: $TargetZone"
			Return $_
		}
		
		# declare state
		Write-Host "`n...retrieved SOA records"
		
		# clone SOA record
		Try {
			$TargetZoneSoaRecordCloned = $TargetZoneSoaRecord.Clone()
		}
		Catch {
			Write-Warning 'could not clone SOA record'
			Return $_
		}
		
		# update SOA record
		Try {
			$TargetZoneSoaRecordCloned.TimeToLive = $SourceZoneSoaRecord.TimeToLive
			$TargetZoneSoaRecordCloned.RecordData.ExpireLimit = $SourceZoneSoaRecord.RecordData.ExpireLimit
			$TargetZoneSoaRecordCloned.RecordData.MinimumTimeToLive = $SourceZoneSoaRecord.RecordData.MinimumTimeToLive
			$TargetZoneSoaRecordCloned.RecordData.RefreshInterval = $SourceZoneSoaRecord.RecordData.RefreshInterval
			$TargetZoneSoaRecordCloned.RecordData.ResponsiblePerson = $SourceZoneSoaRecord.RecordData.ResponsiblePerson
			$TargetZoneSoaRecordCloned.RecordData.RetryDelay = $SourceZoneSoaRecord.RecordData.RetryDelay
		}
		Catch {
			Write-Warning 'could not set properties on cloned SOA record'
			Return $_
		}
		
		# define parameters
		$SetDnsServerResourceRecord = @{
			ComputerName   = $ComputerName
			ZoneName       = $ZoneName
			OldInputObject = $TargetZoneSoaRecord
			NewInputObject = $TargetZoneSoaRecordCloned
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
	}

	# retrieve all zones
	Write-Output "`nRetrieveing DNS zones..."
	Try {
		$DnsServerZones = Get-DnsServerZone -ComputerName $ComputerName -ErrorAction 'Stop' | Where-Object { $_.ZoneName.Contains('.') -and $_.ZoneType -eq 'Primary' -and -not $_.IsAutoCreated }
	}
	Catch {
		Write-Warning -Message "could not retrieve DNS zones from server: $ComputerName"
		Throw $_
	}

	# filter all zones to forward zones
	$DnsServerZones = $DnsServerZones | Where-Object { -not $_.IsReverseLookupZone }
	Write-Host "...found '$($DnsServerZones.Count)' forward zone(s)"

	# check domain
	Write-Output "`nChecking domain zone..."
	If ($DnsServerZones.ZoneName.Contains($Domain)) {
		Write-Output "...found forward zone for domain: $Domain"
	}
	Else {
		Throw "could not locate forward zone for domain: $Domain"
	}
}

Process {
	# validate zone name parameter
	switch ($ZoneName) {
		# if ZoneName is the DNS root...
		'.' {
			# warn and return
			Write-Warning "ZoneName parameter cannot be '.'"
			Return
		}
		# if ZoneName is a single-label domain...
		{ $_.Split('.', [System.StringSplitOptions]::RemoveEmptyEntries).Count -lt 2 } {
			# warn and return
			Write-Warning 'ZoneName parameter cannot be a single-label domain'
			Return
		}
		# if ZoneName is a fully qualified DNS domain...
		{ $_.EndsWith('.') } {
			# redefine zone name without the trailing dot
			$ZoneName = $ZoneName.TrimEnd('.')
		}
	}

	# if zone name already exists...
	If ($ZoneName -in $DnsServerZones.ZoneName) {
		Write-Warning "found existing DNS zone with zone name '$ZoneName' on server: $ComputerName"
		Return
	}

	# split zone name into zone label and parent zone name
	$ZoneLabel, $ParentZoneName = $ZoneName.Split('.', 2, [System.StringSplitOptions]::RemoveEmptyEntries)

	# create list for hashtables
	$DnsServerResourceRecordsToMake = [System.Collections.Generic.List[hashtable]]::new()

	# if parent zone name in DNS server zones...
	If ($DnsServerZones.ZoneName -contains $ParentZoneName) {
		# declare parent zone
		Write-Host "...found parent zone: $ParentZoneName"

		# declare start
		Write-Host "`nRetrieving matching DNS records from parent zone..."

		# get DNS records from parent zone
		Try {
			$DnsServerResourceRecordsFromParent = Get-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $ParentZoneName | Where-Object { $_.RecordType -notin 'NS', 'SOA' }
		}
		Catch {
			Return $_
		}

		# filter DNS records from parent zone to those in child zone
		$DnsServerResourceRecordsToCopy = $DnsServerResourceRecordsFromParent | Where-Object { $_.HostName.EndsWith(".$ZoneLabel") }

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
	If ($DnsServerResourceRecordsToMake.Count -and -not $Force) {
		If (-not $Force) {
			Write-Warning "The provided zone name is a child zone of '$($ParentZone.ZoneName)' zone. Matching records in parent zone will recreated in the child zone." -WarningAction Inquire
		}
	}

	# define parameters
	$AddDnsServerPrimaryZone = @{
		ComputerName     = $ComputerName
		ZoneName         = $ZoneName
		DynamicUpdate    = $DynamicUpdate
		ReplicationScope = $ReplicationScope
		ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
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

	# copy SOA record from domain
	If (!$SkipSoaRecordCopy) {
		Try {
			Copy-DnsServerSoaRecord -SourceZone $Domain -TargetZone $ZoneName
		}
		Catch {
			Write-Warning "could not copy SOA record values from '$Domain' zone to '$ZoneName' zone"
			Return $_
		}
	}

	# declare state
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
}