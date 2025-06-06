#requires -Modules DnsServer

<#
.SYNOPSIS
Create a reverse lookup zone on a Microsoft Windows DNS server.

.DESCRIPTION
Create a reverse lookup zone on a Microsoft Windows DNS server.

.PARAMETER ZoneName
The name of the new reverse lookup zone. Required.

.PARAMETER ComputerName
Specifies the computer where the zones and records will be created. The default value is the primary domain controller of the current domain.

.PARAMETER Domain
Specifies the source zone for SOA and NS records and the zone name for creating matching A records. The default value is the current domain.

.PARAMETER DynamicUpdate
Specifies the Dynamic Update configuration of the reverse lookup zone created by the script. As the script is focused on created reverse lookup zones for CIDR subnets, the default is 'None'.

.PARAMETER ReplicationScope
Specifics the replication scope for the reverse lookup zone and defualts to the 'Domain' replication scope. Custom replication scopes are not supported by this script.

.PARAMETER SkipSoaRecordCopy
Instructs the script to skip copying the values from the SOA record of the domain.

.PARAMETER SkipNameServerCopy
Instructs the script to skip copying the name server records of the domain.

.INPUTS
System.String. One or more reverse lookup zones can be submitted to Add-DnsServerReverseLookupZone as an array or list via the pipeline.

.OUTPUTS
None. The script reports on actions taken and does not provide any actionable output.

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

	# check domain
	Write-Output "`nChecking domain zone..."
	If ($DnsServerZones.ZoneName.Contains($Domain)) {
		Write-Output "...found zone for domain: $Domain"
	}
	Else {
		Throw "could not locate zone for domain: $Domain"
	}

	# filter all zones to forward zones
	$DnsServerZones = $DnsServerZones | Where-Object { $_.IsReverseLookupZone }
	Write-Host "...found '$($DnsServerZones.Count)' reverse zone(s)"
}

Process {
	# if zone name already exists...
	If ($ZoneName -in $DnsServerZones.ZoneName) {
		Write-Warning "found existing DNS zone with zone name '$ZoneName' on server: $ComputerName"
		Return
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

	# create and reverse array from zone input
	Try {
		# create array of octets in zone name
		$Array = $ZoneName.Replace('.in-addr.arpa', $null).Split('.', [System.StringSplitOptions]::RemoveEmptyEntries)
		# get count of octets
		$Count = $Array.Count
		# reverse array
		[array]::Reverse($Array)
	}
	Catch {
		Throw $_
	}

	# get components from array
	switch ($Count) {
		# class A subnet
		1 {
			Write-Output 'Class A subnets not yet supported'
			Return
		}
		# class B
		2 {
			Write-Output 'Class B subnets not yet supported'
			Return
		}
		# class C subnet
		3 {
			$Network = ($Array -join '.') + '.0'
			$Netmask = '24'
		}
		# CIDR subnet
		4 {
			$Network = ($Array -join '.' -split '-')[0]
			$Netmask = ($Array -join '.' -split '-')[1]
		}
		Default {
			Write-Error 'Too many octets in Zone parameter.'
			Return
		}
	}

	# report subnet found
	Write-Host "Retrieved network from zone name: $Network"
	Write-Host "Retrieved netmask from zone name: $Netmask"

	# check for reverse zone
	Write-Output "`nChecking reverse zone..."
	Try {
		$ReverseZone = Get-DnsServerZone -ComputerName $ComputerName -Name $ZoneName -ErrorAction 'Stop' | Where-Object { $_.ZoneName.Contains('.') -and $_.ZoneType -eq 'Primary' -and -not $_.IsAutoCreated } | Select-Object -ExpandProperty 'ZoneName'
		Write-Output "...found reverse zone: '$ReverseZone'"
	}
	Catch {
		Write-Output '...creating zone...'
		Try {
			$ReverseZone = Add-DnsServerPrimaryZone -ComputerName $ComputerName -Name $ZoneName -DynamicUpdate 'Secure' -ReplicationScope $ReplicationScope -PassThru | Select-Object -ExpandProperty 'ZoneName'
			Write-Output "...created reverse zone: '$ReverseZone'"
		}
		Catch {
			Write-Error "could not create reverse zone: '$ZoneName'"
			Throw $_
		}
	}

	# copy SOA record from domain
	If (!$SkipSoaRecordCopy) {
		Try {
			Copy-DnsServerSoaRecord -SourceZone $Domain -TargetZone $ReverseZone
		}
		Catch {
			Write-Warning "could not copy SOA record values from '$Domain' zone to '$ReverseZone' zone"
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
}

End {
	# close with empty line
	Write-Output ''
}
