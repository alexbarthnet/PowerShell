#requires -Modules DnsServer

<#
.SYNOPSIS
Create a forward lookup zone on a Microsoft Windows DNS server and copies any matching records from the existing domain zone to the new forward lookup zone.

.DESCRIPTION
Create a forward lookup zone on a Microsoft Windows DNS server and copies any matching records from the existing domain zone to the new forward lookup zone.

.PARAMETER ZoneName
The name of the new forward lookup zone. Required.

.PARAMETER ComputerName
The name of the DNS server where the new forward zone will be created. The default value is the domain controller with the PDC Emulator FSMO role.

.PARAMETER Domain
The name of an existing forward zone on the DNS server. The NS records and SOA (less the serial number) of this zone will be copied to the new forward lookup zone.

.PARAMETER DynamicUpdate
Specifies the Dynamic Update configuration of the forward lookup zone created by the script and defaults to the 'None' configuration.

.PARAMETER ReplicationScope
Specifics the replication scope for the forward lookup zone and defaults to the 'Domain' replication scope. Custom replication scopes are not supported by this script.

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
	# string containing name of reverse lookup zone
	[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidatePattern('.in-addr.arpa[.]{0,1}$')]
	[string]$ZoneName,
	# computer name of the DNS server; default value is current PDC role owner
	[Parameter(Position = 1)]
	[string]$ComputerName = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
	# domain name; default value is current domain name
	[Parameter(Position = 2)]
	[string]$Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name,
	# dynamic update value
	[Parameter(Position = 3)][ValidateSet('None', 'NonsecureAndSecure', 'Secure')]
	[string]$DynamicUpdate = 'None',
	# replication scope for new zone
	[Parameter(Position = 4)][ValidateSet('Domain', 'Forest', 'Legacy')]
	[string]$ReplicationScope = 'Domain',
	# switch to skip copying the SOA records from the domain
	[Parameter(Position = 5)]
	[switch]$SkipSoaRecordCopy,
	# switch to skip copying the NS records from the domain
	[Parameter(Position = 6)]
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
	Write-Output "`nRetrieving DNS zones..."
	Try {
		$DnsServerZones = Get-DnsServerZone -ComputerName $ComputerName -ErrorAction 'Stop' | Where-Object { $_.ZoneName.Contains('.') -and $_.ZoneType -eq 'Primary' -and -not $_.IsAutoCreated }
	}
	Catch {
		Write-Warning -Message "could not retrieve DNS zones from server: $ComputerName"
		Throw $_
	}

	# check domain
	Write-Output "`nChecking domain zone..."
	If ($DnsServerZones.ZoneName.Contains($Domain)) {
		Write-Output "...found zone for domain: $Domain"
	}
	Else {
		Throw "could not locate zone for domain: $Domain"
	}

	# filter all zones to forward zones
	$DnsServerZones = $DnsServerZones | Where-Object { -not $_.IsReverseLookupZone }
	Write-Host "...found '$($DnsServerZones.Count)' forward zone(s)"
}

Process {
	# if zone name already exists...
	If ($ZoneName -in $DnsServerZones.ZoneName) {
		Write-Warning "found existing DNS zone with zone name '$ZoneName' on server: $ComputerName"
		Return
	}

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

	# check for reverse zone
	Write-Output "`nChecking forward zone..."
	Try {
		$ZoneName = Get-DnsServerZone -ComputerName $ComputerName -Name $ZoneName -ErrorAction 'Stop' | Where-Object { $_.ZoneName.Contains('.') -and $_.ZoneType -eq 'Primary' -and -not $_.IsAutoCreated } | Select-Object -ExpandProperty 'ZoneName'
		Write-Output "...found forward zone: '$ZoneName'"
	}
	Catch {
		Write-Output '...creating zone...'
		Try {
			$ZoneName = Add-DnsServerPrimaryZone -ComputerName $ComputerName -Name $ZoneName -DynamicUpdate $DynamicUpdate -ReplicationScope $ReplicationScope -PassThru | Select-Object -ExpandProperty 'ZoneName'
			Write-Output "...created forward zone: '$ZoneName'"
		}
		Catch {
			Write-Error "could not create forward zone: '$ZoneName'"
			Throw $_
		}
	}

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

	# copy NS records from domain
	If (!$SkipNameServerCopy) {
		Write-Output "`nChecking NS records..."

		# define counters
		$DnsCreated = 0
		$DnsRemoved = 0

		# retrieve reverse zone NS records
		Try {
			$CurrentNSRecords = (Get-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $ZoneName -Name '@' -RRType NS).RecordData.NameServer
		}
		Catch {
			Write-Error "could not retrieve current NS records from '$ZoneName'"
			Throw $_
		}

		# retrieve desired NS records from domain
		Try {
			$DesiredNSRecords = (Get-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $Domain -Name '@' -RRType NS).RecordData.NameServer
		}
		Catch {
			Write-Error "could not retrieve desired NS records from '$Domain'"
			Throw $_
		}

		# create emtpy lists
		$CurrentNameServers = [System.Collections.Generic.List[string]]::New()
		$DesiredNameServers = [System.Collections.Generic.List[string]]::New()

		# populate lists
		ForEach ($NameServer in $CurrentNSRecords) { $CurrentNameServers.Add($NameServer) }
		ForEach ($NameServer in $DesiredNSRecords) { $DesiredNameServers.Add($NameServer) }

		# retrieve NS records that are missing
		$MissingNameServers = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($DesiredNameServers, $CurrentNameServers))

		# retrieve NS records that are invalid
		$InvalidNameServers = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($CurrentNameServers, $DesiredNameServers))

		# create any missing NS records
		ForEach ($NameServer in $MissingNameServers) {
			Try {
				Add-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $ZoneName -NS -Name '@' -NameServer $NameServer
				Write-Verbose "created NS record '$NameServer' in '$ZoneName' on '$ComputerName'"
				$DnsCreated++
			}
			Catch {
				Write-Output "could not create NS record '$NameServer'"
				Throw $_
			}
		}

		# remove any invalid NS records
		ForEach ($NameServer in $InvalidNameServers) {
			Try {
				Remove-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $ZoneName -RRType 'NS' -Name '@' -RecordData $NameServer -Confirm:$false
				Write-Verbose "removed NS record '$NameServer' from '$ZoneName' on '$ComputerName'"
				$DnsRemoved++
			}
			Catch {
				Write-Output "could not remove NS record '$NameServer'"
				Throw $_
			}
		}

		# report NS record changes
		If ($DnsCreated -eq 0 -and $DnsRemoved -eq 0) { Write-Output "...checked '$($CurrentNameServers.Count)' NS record(s)" }
		If ($DnsCreated) { Write-Output "...created '$DnsCreated' NS record(s)" }
		If ($DnsRemoved) { Write-Output "...removed '$DnsRemoved' NS record(s)" }
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