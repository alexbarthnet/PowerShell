<#
.SYNOPSIS
Update NS records in one or more existing zone delegations.

.DESCRIPTION
Update NS records in one or more existing zone delegations. New zone delegations can be created with the "Add-DnsServerZoneDelegation" function.

.PARAMETER ZoneName
The name of the zone hosting the zone delegations. The zone hosting the delegations is also known as the parent zone. Required.

.PARAMETER ZoneDelegation
The single-label name of one or more existing zone delegations. The zone delegations are also known as the child zones. Required.

.PARAMETER NameServers
The fully-qualified names of one or more name servers for the zone delegations. The values for this parameter must resolve to A or AAAA DNS records. The NameServers parameter cannot be combined with the Recursive parameter. Optional.

.PARAMETER Recursive
Switch to configure the existing zone delegations as recursive zone delegations. See the Notes section for details on recursive zone delegations. The Recursive parameter cannot be combined with the NameServers parameter. Optional.

.PARAMETER ComputerName
The name of the DNS server hosting the zone and zone delegations. The default value is the domain controller in the current domain with the PDC Emulator FSMO role.

.INPUTS
None.

.OUTPUTS
None.

.EXAMPLE
.\Update-DnsServerZoneDelegation.ps1 -ZoneName 'example.com' -ZoneDelegation 'test' -NameServers ns1.example.com, ns2.example.com

.EXAMPLE
.\Update-DnsServerZoneDelegation.ps1 -ZoneName 'example.com' -ZoneDelegation 'test' -Recursive

.NOTES
A recursive zone delegation is a zone delegation where the zone hosting the zone delegations and the zone delegations are on the same server. The most common exammple of a recursive zone delegation is the "_msdcs" zone of an Active Directory forest.

A recursive zone delegation can be used to create a child zone with different permissions from the parent zone while both zones are hosted on the same servers. Examples include child zones for email functionality such as the _dmarc and _domainkey child zones.
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# name of the zone
	[Parameter(Mandatory)]
	[string]$ZoneName,
	# name of the delegation(s)
	[Parameter(Mandatory)]
	[string[]]$ZoneDelegation,
	# fully qualified name servers for the delegation(s)
	[Parameter(ParameterSetName = 'Default')]
	[string[]]$NameServers,
	# switch to create recursive zone delegations
	[Parameter(ParameterSetName = 'Recursive')]
	[switch]$Recursive,
	# computer name of DNS server, default value is PDC emulator
	[Parameter(DontShow)]
	[string]$ComputerName = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
)

# create list for name server values
$NameServerList = [System.Collections.Generic.List[string]]::new()

# if name servers provided...
If ($PSBoundParameters.ContainsKey('NameServers')) {
	# process name server values
	ForEach ($NameServer in $NameServers) {
		# if name server value is not fully qualified...
		If (!$NameServer.EndsWith('.')) {
			# ...append the trailing dot per RFC 1034
			$NameServer = "$NameServer."
		}

		# add fully qualified name server value to list
		$NameServerList.Add($NameServer)
	}
}
# if name servers not provided...
Else {
	# ...and recursive not set...
	If ($Recursive -ne $true) {
		# warn about recursive zone delegation
		Write-Warning "'Neither the NameServers or Recursive parameters were defined. The zone delegation(s) will be configured as a recursive zone delegation(s) using NS records in the '$ZoneName' zone.'" -WarningAction Inquire
	}

	# declare start
	Write-Host "`nRetrieving NS records..."

	# retrieve NS records in zone
	Try {
		$DnsServerResourceRecords = Get-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $ZoneName -Node -RRType 'NS'
	}
	Catch {
		Write-Warning "could not retrieve the NS records of zone '$ZoneName' on DNS server: $ComputerName"
		Return $_
	}

	# if NS records not found...
	If ($DnsServerResourceRecords.Count -eq 0) {
		Write-Warning "could not locate any NS records in zone '$ZoneName' on DNS server: $ComputerName"
		Return
	}

	# declare count of NS records
	Write-Host "...found '$($DnsServerResourceRecords.Count)' NS record(s) for zone: $ZoneName"

	# processs name server records
	ForEach ($DnsServerResourceRecord in $DnsServerResourceRecords) {
		# retrieve name server value from name server record
		$NameServer = $DnsServerResourceRecord.RecordData.NameServer

		# if name server value is not fully qualified...
		If (!$NameServer.EndsWith('.')) {
			# ...append the trailing dot per RFC 1034
			$NameServer = "$NameServer."
		}

		# add fully qualified name server value to list
		$NameServerList.Add($NameServer)
	}
}

# declare state
Write-Host "`nValidating glue records for name servers..."

# validate NS records
ForEach ($NameServer in $NameServerList) {
	# if name server value contains fully qualified zone name...
	If ($NameServer.EndsWith(".$ZoneName.")) {
		# define name value for glue record as name server value less fully qualified zone name
		$Name = $NameServer.Remove($NameServer.Length - ".$ZoneName.".Length)
	}
	Else {
		# define name value for glue record as nameserver
		$Name = $NameServer
	}

	# define parameters
	$GetDnsServerResourceRecord = @{
		ComputerName = $ComputerName
		ZoneName     = $ZoneName
		Name         = $Name
		ErrorAction  = [System.Management.Automation.ActionPreference]::SilentlyContinue
	}

	# retrieve glue records for name server
	$DnsServerResourceRecords = Get-DnsServerResourceRecord @GetDnsServerResourceRecord

	# define parameters
	$ResolveDnsName = @{
		Server      = $ComputerName
		Name        = $NameServer
		Type        = 'A_AAAA'
		DnsOnly     = $true
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# resolve glue records to DNS records
	Try {
		$DnsNames = Resolve-DnsName @ResolveDnsName
	}
	Catch {
		Write-Warning "could not resolve '$NameServer' to A or AAAA record: $($_.ToString())"
		Return
	}

	# process each DNS record to create missing glue records
	:NextDnsName ForEach ($DnsName in $DnsNames) {
		# define parameters
		$AddDnsServerResourceRecord = @{
			ComputerName = $ComputerName
			ZoneName     = $ZoneName
			Name         = $Name
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# check dns records by type
		switch ($DnsName.Type) {
			'A' {
				If ($DnsName.IPAddress -in $DnsServerResourceRecords.RecordData.IPv4Address.IPAddressToString) {
					# $ValidatedGlueRecord = $true
					Continue NextDnsName
				}
				Else {
					$AddDnsServerResourceRecord['A'] = $true
					$AddDnsServerResourceRecord['IPv4Address'] = $DnsName.IPAddress
				}
			}
			'AAAA' {
				If ($DnsName.IPAddress -in $DnsServerResourceRecords.RecordData.IPv6Address.IPAddressToString) {
					# $ValidatedGlueRecord = $true
					Continue NextDnsName
				}
				Else {
					$AddDnsServerResourceRecord['AAAA'] = $true
					$AddDnsServerResourceRecord['IPv6Address'] = $DnsName.IPAddress
				}
			}
		}

		# create glue record for name server
		Try {
			$null = Add-DnsServerResourceRecord @AddDnsServerResourceRecord
		}
		Catch {
			Write-Warning "could not create missing glue record: $NameServer`t$($DnsName.Type)`t$($DnsName.IPAddress)"
			Return $_
		}

		# declare state
		Write-Host "...created missing glue record: $NameServer`t$($DnsName.Type)`t$($DnsName.IPAddress)"
	}

	# process each glue record for remove invalid glue records
	:NextDnsServerResourceRecord ForEach ($DnsServerResourceRecord in $DnsServerResourceRecords) {
		# define parameters
		$RemoveDnsServerResourceRecord = @{
			ComputerName = $ComputerName
			ZoneName     = $ZoneName
			InputObject  = $DnsServerResourceRecord
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# check glue records by type
		switch ($DnsServerResourceRecord.RecordType) {
			'A' {
				If ($DnsServerResourceRecord.RecordData.IPv4Address.IPAddressToString -in $DnsNames.IPAddress) {
					# $ValidatedGlueRecord = $true
					Continue NextDnsServerResourceRecord

				}
				Else {
					$IPAddress = $DnsServerResourceRecord.RecordData.IPv4Address.IPAddressToString
				}
			}
			'AAAA' {
				If ($DnsServerResourceRecord.RecordData.IPv6Address.IPAddressToString -in $DnsNames.IPAddress) {
					# $ValidatedGlueRecord = $true
					Continue NextDnsServerResourceRecord
				}
				Else {
					$IPAddress = $DnsServerResourceRecord.RecordData.IPv6Address.IPAddressToString
				}
			}
		}

		# retrieve glue record for name server
		Try {
			$null = Remove-DnsServerResourceRecord @RemoveDnsServerResourceRecord
		}
		Catch {
			Write-Warning "could not remove invalid glue record with IP address: $NameServer`t$($DnsServerResourceRecord.RecordType)`t$IPAddress"
			Return $_
		}

		# declare state
		Write-Host "...removed invalid glue record: $NameServer`t$($DnsServerResourceRecord.RecordType)`t$IPAddress"
	}

	# declare state
	Write-Host "...validated glue record: $NameServer"
}

# process each child zone name
:NextChildZoneName ForEach ($ChildZoneName in $ZoneDelegation) {
	# if child zone contains a dot...
	If ($ChildZoneName.Contains('.')) {
		# remove first dot and all characters that follow
		$ChildZoneName = $ChildZoneName.Remove($ChildZoneName.IndexOf('.'))
	}

	# declare start
	Write-Host "`nRetrieving NS records for zone delegation: $ChildZoneName.$ZoneName"

	# get delegation records
	Try {
		$DnsServerZoneDelegations = Get-DnsServerZoneDelegation -ComputerName $ComputerName -Name $ZoneName -ChildZoneName $ChildZoneName
	}
	Catch {
		Write-Warning "could not retrieve delegation records from server: $ComputerName"
		Return $_
	}

	# process each NS record to add missing name servers
	ForEach ($NameServer in $NameServerList) {
		# if name server missing...
		If ($NameServer -notin $DnsServerZoneDelegations.NameServer.RecordData.NameServer) {
			# define parameters
			$DnsServerResourceRecord = @{
				ComputerName = $ComputerName
				ZoneName     = $ZoneName
				Name         = $ChildZoneName
				NS           = $true
				NameServer   = $NameServer
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# add NS record
			Try {
				Add-DnsServerResourceRecord @DnsServerResourceRecord
			}
			Catch {
				Write-Warning "could not add NS record: $NameServer"
				Return $_
			}

			# declare state
			Write-Host "...added NS record: $NameServer"
		}
		Else {
			Write-Host "...validated NS record: $NameServer"
		}
	}

	# process each zone delegation to remove invalid delegations
	ForEach ($DnsServerZoneDelegation in $DnsServerZoneDelegations) {
		# retrieve name server value from zone delegation
		$NameServer = $DnsServerZoneDelegation.NameServer.RecordData.NameServer

		# if name server invalid...
		If ($NameServer -notin $NameServerList) {
			# define parameters
			$DnsServerResourceRecord = @{
				ComputerName = $ComputerName
				ZoneName     = $ZoneName
				Name         = $ChildZoneName
				RRType       = 'NS'
				RecordData   = $NameServer
				Force        = $true
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# remove NS record
			Try {
				Remove-DnsServerResourceRecord @DnsServerResourceRecord
			}
			Catch {
				Write-Warning "could not remove NS record: $NameServer"
				Return $_
			}

			# declare state
			Write-Host "...removed NS record: $NameServer"
		}
	}
}
