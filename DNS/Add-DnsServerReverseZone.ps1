#requires -Modules DnsServer

<#
.SYNOPSIS
Create a reverse lookup zone on a Microsoft Windows DNS server, populate the zone with placeholder PTR records, and create matching A records for the placeholder PTR records.

.DESCRIPTION
Create a reverse lookup zone on a Microsoft Windows DNS server, populate the zone with placeholder PTR records, and create matching A records for the placeholder PTR records. Includes options to create custom PTR records using the ReservedHosts parameter, reset the PTR records in an existing zone to placeholder records, and create the matching A records in custom subdomains,

.PARAMETER ZoneName
The name of the new reverse lookup zone. Required.

.PARAMETER ReservedHosts
A hashtable of custom PTR records to be created instead of the default PTR records. Each key must be an IP address in the reverse lookup zone. The value must be a DNS record that can be created in the domain zone.

.PARAMETER PtrPrefix
Specifies the prefix to apply to PTR records created in the reverse lookup zone. The default value is 'ip'.

.PARAMETER DynamicUpdate
Specifies the Dynamic Update configuration of the reverse lookup zone created by the script. As the script is focused on created reverse lookup zones for CIDR subnets, the default is 'None'.

.PARAMETER ReplicationScope
Specifics the replication scope for the reverse lookup zone and defualts to the 'Domain' replication scope. Custom replication scopes are not supported by this script.

.PARAMETER SubDomain
Specifies the subdomain of the Domain paramater for creating matching A records.

.PARAMETER Domain
Specifies the source zone for SOA and NS records and the zone name for creating matching A records. The default value is the current domain.

.PARAMETER ComputerName
Specifies the computer where the zones and records will be created. The default value is the primary domain controller of the current domain.

.PARAMETER Reset
Instructs the script to remove and recreate any existing PTR records found in an existing reverse lookup zone.

.PARAMETER SkipSoaRecordCopy
Instructs the script to skip copying the values from the SOA record of the domain.

.PARAMETER SkipNameServerCopy
Instructs the script to skip copying the name server records of the domain.

.INPUTS
System.String. One or more reverse lookup zones can be submitted to Add-DnsServerReverseLookupZone as an array or list via the pipeline.

.OUTPUTS
None. The script reports on actions taken and does not provide any actionable output.

.EXAMPLE
.\Add-DnsServerReverseLookupZone.ps1 -Zone '128-25.0.0.10.in-addr.arpa' -ReservedHosts @{ '10.0.0.129' = 'gateway.example.com'; '10.0.0.130' = 'firewall-a.example.com'; '10.0.0.131' = 'firewall-b.example.com' }

#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# string containing name of reverse lookup zone
	[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidatePattern('.in-addr.arpa[.]{0,1}$')]
	[string]$ZoneName,
	# hashtable containing PTR records to add to zone
	[Parameter(Position = 1)]
	[hashtable]$ReservedHosts = @{},
	# dynamic update value
	[Parameter(Position = 2)][ValidateSet('None', 'NonsecureAndSecure', 'Secure')]
	[string]$DynamicUpdate = 'None',
	# replication scope for new zone
	[Parameter(Position = 3)][ValidateSet('Domain', 'Forest', 'Legacy')]
	[string]$ReplicationScope = 'Domain',
	# record prefix in matching A records for placeholder PTR records
	[Parameter(Position = 4)]
	[string]$PtrPrefix = 'ip',
	# sub domain in matching A records for placeholder PTR records
	[Parameter(Position = 5)]
	[string]$SubDomain = 'reverse',
	# domain name; default value is current domain name
	[Parameter(Position = 6)]
	[string]$Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name,
	# computer name of the DNS server; default value is current PDC role owner
	[Parameter(Position = 7)]
	[string]$ComputerName = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
	# switch to reset reverse zone to use placeholder PTR records
	[Parameter(Position = 8)]
	[switch]$Reset,
	# switch to skip copying the SOA records from the domain
	[Parameter(Position = 9)]
	[switch]$SkipSoaRecordCopy,
	# switch to skip copying the NS records from the domain
	[Parameter(Position = 10)]
	[switch]$SkipNameServerCopy
)

Begin {
	# retrieve all zones
	Write-Output "`nRetrieveing DNS zones..."
	Try {
		$DnsZones = Get-DnsServerZone -ComputerName $ComputerName -ErrorAction 'Stop' | Where-Object { $_.ZoneName.Contains('.') -and $_.ZoneType -eq 'Primary' -and -not $_.IsAutoCreated } | Select-Object -ExpandProperty 'ZoneName'
	}
	Catch {
		Write-Error "Could not retrieve DNS zones from server: '$ComputerName'"
		Throw $_
	}

	# check foward zone
	Write-Output "`nChecking forward zone..."
	Try {
		$ForwardZone = Get-DnsServerZone -ComputerName $ComputerName -ZoneName "$SubDomain.$Domain" -ErrorAction 'Stop' | Where-Object { $_.ZoneName.Contains('.') -and $_.ZoneType -eq 'Primary' -and -not $_.IsAutoCreated } | Select-Object -ExpandProperty 'ZoneName'
		Write-Output "...found forward zone for subdomain: '$ForwardZone'"
	}
	Catch {
		Try {
			$ForwardZone = Get-DnsServerZone -ComputerName $ComputerName -ZoneName "$Domain" -ErrorAction 'Stop' | Where-Object { $_.ZoneName.Contains('.') -and $_.ZoneType -eq 'Primary' -and -not $_.IsAutoCreated } | Select-Object -ExpandProperty 'ZoneName'
			Write-Output "...found forward zone for domain: '$ForwardZone'"
		}
		Catch {
			Write-Error "Could not locate forward zone: '$Domain'"
			Throw $_
		}
	}
}

Process {
	# create and reverse array from zone input
	Try {
		# create array of octets in zone name
		$Array = $Zone.Replace('.in-addr.arpa', $null).Split('.', [System.StringSplitOptions]::RemoveEmptyEntries)
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

	# check for reverse zone
	Write-Output "`nChecking reverse zone..."
	Try {
		$ReverseZone = Get-DnsServerZone -ComputerName $ComputerName -Name $Zone -ErrorAction 'Stop' | Where-Object { $_.ZoneName.Contains('.') -and $_.ZoneType -eq 'Primary' -and -not $_.IsAutoCreated } | Select-Object -ExpandProperty 'ZoneName'
		Write-Output "...found reverse zone: '$ReverseZone'"
	}
	Catch {
		Write-Output '...creating zone...'
		Try {
			$ReverseZone = Add-DnsServerPrimaryZone -ComputerName $ComputerName -Name $Zone -DynamicUpdate 'Secure' -ReplicationScope $ReplicationScope -PassThru | Select-Object -ExpandProperty 'ZoneName'
			Write-Output "...created reverse zone: '$ReverseZone'"
		}
		Catch {
			Write-Error "could not create reverse zone: '$Zone'"
			Throw $_
		}
	}

	# configure reverse zone
	If ($UseNameServersFromDomain) {
		Write-Output "`nChecking NS records..."

		# define counters
		$DnsCreated = 0
		$DnsRemoved = 0

		# retrieve forward zone NS records
		Try {
			$ForwardNSRecords = (Get-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $ForwardZone -Name '@' -RRType NS).RecordData.NameServer
		}
		Catch {
			Write-Error "could not retrieve NS records from '$ForwardZone'"
			Throw $_
		}

		# retrieve reverse zone NS records
		Try {
			$ReverseNSRecords = (Get-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $ReverseZone -Name '@' -RRType NS).RecordData.NameServer
		}
		Catch {
			Write-Error "could not retrieve NS records from '$ReverseZone'"
			Throw $_
		}

		# create emtpy lists
		$ForwardNameServers = [System.Collections.Generic.List[string]]::New()
		$ReverseNameServers = [System.Collections.Generic.List[string]]::New()

		# populate lists
		ForEach ($NameServer in $ForwardNSRecords) { $ForwardNameServers.Add($NameServer) }
		ForEach ($NameServer in $ReverseNSRecords) { $ReverseNameServers.Add($NameServer) }

		# retrieve NS records that are missing
		$MissingNameServers = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($ForwardNameServers, $ReverseNameServers))

		# retrieve NS records that are invalid
		$InvalidNameServers = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($ReverseNameServers, $ForwardNameServers))

		# create any missing NS records
		ForEach ($NameServer in $MissingNameServers) {
			Try {
				Add-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $ReverseZone -NS -Name '@' -NameServer $NameServer
				Write-Verbose "created NS record '$NameServer' in '$ReverseZone' on '$ComputerName'"
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
				Remove-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $ReverseZone -RRType 'NS' -Name '@' -RecordData $NameServer -Confirm:$false
				Write-Verbose "removed NS record '$NameServer' from '$ReverseZone' on '$ComputerName'"
				$DnsRemoved++
			}
			Catch {
				Write-Output "could not remove NS record '$NameServer'"
				Throw $_
			}
		}

		# report NS record changes
		If ($DnsCreated -eq 0 -and $DnsRemoved -eq 0) { Write-Output "...checked '$($ReverseNameServers.Count)' NS record(s)" }
		If ($DnsCreated) { Write-Output "...created '$DnsCreated' NS record(s)" }
		If ($DnsRemoved) { Write-Output "...removed '$DnsRemoved' NS record(s)" }
	}

	# define first IP and counter from address and netmask
	$FirstIP = [uint32]($Network.Split('.')[-1])
	$Counter = [uint32]$FirstIP + [Math]::Pow(2, (32 - [uint32]$Netmask))

	# define counters
	$DnsLocated = 0
	$DnsUpdated = 0
	$DnsCreated = 0

	# create PTR records
	Write-Output "`nChecking PTR records..."
	For ($Name = $FirstIP; $Name -lt $Counter; $Name++) {
		# create octet array from base address
		$Octets = $Network.Split('.')

		# update octet array with current octet
		$Octets[-1] = [string]$Name

		# create current IP address from octet array
		$IPAddress = $Octets -join '.'

		# check reserved hosts hashtable
		If ($ReservedHosts -and $ReservedHosts.ContainsKey($IPAddress)) {
			$PtrDomainName = "$($ReservedHosts[$IPAddress])"
		}
		Else {
			$IPAddressWithDashes = $Octets -join '-'
			$PtrDomainName = "$PtrPrefix-$IPAddressWithDashes.$ForwardZone."
		}

		# check PTR record
		Try {
			# throw exception if PTR record not found
			$Record = Get-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $Zone -Name $Name -ErrorAction 'Stop'
			# report expected PTR record
			If ($Record.RecordData.PtrDomainName -eq $PtrDomainName) {
				Write-Verbose "found '$Name' in '$Zone' on '$ComputerName' with expected value: $PtrDomainName"
				$DnsLocated++
			}
			# report existing PTR record when Reset not set
			ElseIf ($Record.RecordData.PtrDomainName -ne $PtrDomainName -and -not $Reset) {
				Write-Verbose "found '$Name' in '$Zone' on '$ComputerName' with existing value: $PtrDomainName"
				$DnsLocated++
			}
			# update existing PTR record
			Else {
				# copy PTR record object
				$NewRecord = $Record
				# update new PTR record object
				$NewRecord.RecordData.PtrDomainName = $PtrDomainName
				# set new PTR record
				Try {
					Set-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $Zone -OldInputObject $Record -NewInputObject $NewRecord -ErrorAction 'Stop'
					Write-Verbose "updated '$Name' in '$Zone' on '$ComputerName' with expected value: $PtrDomainName"
					$DnsUpdated++
				}
				Catch {
					Throw $_
				}
			}
		}
		Catch {
			# create PTR record
			Try {
				Add-DnsServerResourceRecordPtr -ComputerName $ComputerName -ZoneName $Zone -Name $Name -PtrDomainName $PtrDomainName
				Write-Verbose "created '$Name' in '$Zone' on '$ComputerName' with value: $PtrDomainName"
				$DnsCreated++
			}
			Catch {
				Throw $_
			}
		}
	}

	# report PTR record changes
	If ($DnsLocated) { Write-Output "...located '$DnsLocated' PTR record(s)" }
	If ($DnsUpdated) { Write-Output "...updated '$DnsUpdated' PTR record(s)" }
	If ($DnsCreated) { Write-Output "...created '$DnsCreated' PTR record(s)" }

	# define counters
	$DnsLocated = 0
	$DnsUpdated = 0
	$DnsCreated = 0

	# create A records
	Write-Output "`nChecking A records..."
	For ($Name = $FirstIP; $Name -lt $Counter; $Name++) {
		# create octet array from base address
		$Octets = $Network.Split('.')

		# update octet array with current octet
		$Octets[-1] = [string]$Name

		# create current IP address from octet array
		$IPAddress = $Octets -join '.'

		# check reserved hosts hashtable
		If ($ReservedHosts -and $ReservedHosts.ContainsKey($IPAddress)) {
			$PtrDomainName = "$($ReservedHosts[$IPAddress])"
		}
		Else {
			$IPAddressWithDashes = $Octets -join '-'
			$PtrDomainName = "$PtrPrefix-$IPAddressWithDashes.$ForwardZone"
		}

		# retrieve record name from PTR domain name
		$RecordName = $PtrDomainName.Split('.', 2)[0]
		$DomainName = $PtrDomainName.Split('.', 2)[1]

		# verify zone
		If ($DnsZones -notcontains $DomainName) {
			Write-Warning "DNS record '$PtrDomainName' has a domain name of '$DomainName' which was not found on server: '$ComputerName'"
			Continue
		}

		# check A record
		Try {
			# throw exception if A record not found
			$Record = Get-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $DomainName -Name $RecordName -ErrorAction 'Stop'
			# report expected A record
			If ($Record.RecordData.IPv4Address.IPAddressToString -eq $IPAddress) {
				Write-Verbose "found '$RecordName' in '$ForwardZone' on '$ComputerName' with expected value: $IPAddress"
				$DnsLocated++
			}
			# report existing A record when Reset not set
			ElseIf ($Record.RecordData.IPv4Address.IPAddressToString -ne $IPAddress -and -not $Reset) {
				Write-Verbose "found '$RecordName' in '$ForwardZone' on '$ComputerName' with existing value: $IPAddress"
				$DnsLocated++
			}
			# update existing A record
			Else {
				# copy A record object
				$NewRecord = $Record
				# update new A record object
				$NewRecord.RecordData.IPv4Address = [System.Net.IPAddress]::Parse($IPAddress)
				# set new A record
				Try {
					Set-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $DomainName -OldInputObject $Record -NewInputObject $NewRecord -ErrorAction 'Stop'
					Write-Verbose "updated '$RecordName' in '$ForwardZone' on '$ComputerName' with expected value: $IPAddress"
					$DnsUpdated++
				}
				Catch {
					Throw $_
				}
			}
		}
		Catch {
			# create A record
			Try {
				Add-DnsServerResourceRecordA -ComputerName $ComputerName -ZoneName $DomainName -Name $RecordName -IPv4Address $IPAddress -ErrorAction 'Stop'
				Write-Verbose "created '$RecordName' in '$ForwardZone' on '$ComputerName' with expected value: $IPAddress"
				$DnsCreated++
			}
			Catch {
				Throw $_
			}
		}
	}

	# report A record changes
	If ($DnsLocated) { Write-Output "...located '$DnsLocated' A record(s)" }
	If ($DnsUpdated) { Write-Output "...updated '$DnsUpdated' A record(s)" }
	If ($DnsCreated) { Write-Output "...created '$DnsCreated' A record(s)" }
}

End {
	# close with empty line
	Write-Output ''
}
