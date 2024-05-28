#requires -Modules DnsServer

<#
.SYNOPSIS
Create placeholder PTR records in a reverse lookup zone on a Microsoft Windows DNS server and create matching A records for the placeholder PTR records.

.DESCRIPTION
Create placeholder PTR records in a reverse lookup zone on a Microsoft Windows DNS server and create matching A records for the placeholder PTR records. Includes options to create custom PTR records using the ReservedHosts parameter, reset the PTR records in an existing zone to placeholder records, and create the matching A records in custom subdomains,

.PARAMETER Zone
Specifies the reverse lookup zone that will be added and populated with placeholder PTR records.

.PARAMETER Reset
Instructs the script to remove and recreate any existing PTR records found in an existing reverse lookup zone.

.PARAMETER SkipForwardRecords
Instructs the script to skip creating or updating matching A records.

.PARAMETER SkipSubdomain
Instructs the script to skip prefixing the Domain parameter with the Subdomain parameter when defining the forward lookup zone for the matching A records.

.PARAMETER ReservedHosts
A hashtable of custom PTR records to be created instead of the default PTR records. Each key must be an IP address in the reverse lookup zone. The value must be the domain name for the PTR record.

.PARAMETER PtrPrefix
Specifies the prefix to apply to PTR records created in the reverse lookup zone. The default value is "ip"

.PARAMETER SubDomain
Specifies the subdomain component of forward lookup zone where matching A records will be created. This parameter is overridden by the ForwardZoneName parameter.

.PARAMETER Domain
Specifies the parent domain of forward lookup zone where matching A records will be created. This parameter is overridden by the ForwardZoneName parameter.

.PARAMETER ForwardZoneName
Specifies the forward lookup zone to create matching A records. This parameter will override the values provided for the Subdomain and Domain parameters.

.PARAMETER ComputerName
Specifies the computer where the zones and records will be created. The default value is the current primary domain controller.

.INPUTS
System.String. One or more reverse lookup zones can be submitted to Add-DnsServerReverseLookupZone as an array or list via the pipeline.

.OUTPUTS
None. The script merely reports on actions taken and does not provide any actionable output.

.EXAMPLE
.\Add-DnsServerReverseLookupZone.ps1 -Zone '128-25.0.0.10.in-addr.arpa' -ReservedHosts @{ '10.0.0.129' = 'gateway.example.com'; '10.0.0.130' = 'firewall-a.example.com'; '10.0.0.131' = 'firewall-b.example.com' }

#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
	[string]$ZoneName,
	# switch to reset reverse zone to use placeholder PTR records
	[Parameter(Position = 1)]
	[switch]$Reset,
	# switch to reset reverse zone to use placeholder PTR records
	[Parameter(Position = 2)]
	[switch]$SkipForwardRecords,
	# switch to reset reverse zone to use placeholder PTR records
	[Parameter(Position = 3)]
	[switch]$SkipSubdomain,
	# hashtable containing PTR records to add to zone
	[Parameter(Position = 4)]
	[hashtable]$ReservedHosts,
	# record prefix in matching A records for placeholder PTR records
	[Parameter(Position = 5)]
	[string]$PtrPrefix = 'ip',
	# sub domain in matching A records for placeholder PTR records
	[Parameter(DontShow)]
	[string]$Subdomain = 'reverse',
	# domain name; default value is current domain name
	[Parameter(DontShow)]
	[string]$Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name,
	# zone name for matching A records for placeholder PTR records
	[Parameter(DontShow)]
	[string]$ForwardZoneName = "$Subdomain.$Domain",
	# computer name of the DNS server; default value is current PDC role owner
	[Parameter(DontShow)]
	[string]$ComputerName = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
)

Begin {

	Function Get-OctetsAndNetmaskFromZoneName {
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ZoneName
		)

		# determine zone type and split zone name into octets
		switch -regex ($ZoneName) {
			'\.in-addr\.arpa\.?$' {
				$IsIPv4ReverseLookupZone = $true
				$Octets = $ZoneName.Replace('.in-addr.arpa', $null).Split('.', [System.StringSplitOptions]::RemoveEmptyEntries)
			}
			'\.ip6\.arpa\.?$' {
				$IsIPv6ReverseLookupZone = $true
				$Octets = $ZoneName.Replace('.ip6.arpa', $null).Split('.', [System.StringSplitOptions]::RemoveEmptyEntries)
			}
			Default {
				Return 'the provided name for the reverse lookup zone is not in the IPv4 or IPv6 lookup domains'
			}
		}

		# reverse the octects
		[array]::Reverse($Octets)

		# if IPv6...
		If ($IsIPv6ReverseLookupZone) {
			Return 'IPv6 reverse lookup zones are not yet supported'
		}

		# if IPv4...
		If ($IsIPv4ReverseLookupZone) {
			switch ($Octets.Count) {
				# has 0 octets...
				0 {
					Return 'Root lookup domains are not supported'
				}
				# has 1 octet...
				1 {
					Return 'Class A subnets are not supported'
				}
				# has 2 octets...
				2 {
					Return 'Class B subnets are not supported'
				}
				# has 3 octets...
				3 {
					# create hashtable with static octets
					$Hashtable = @{
						Octet1 = $Octets[0]
						Octet2 = $Octets[1]
						Octet3 = $Octets[2]
						Octet4 = 0
						Subnet = 24
					}
				}
				# has 4 octets...
				4 {
					# if the last octet matches the common CIDR notations...
					If ($Octets[-1] -match '(?<Octet>\d+)\D(?<Netmask>\d+)') {
						# if the netmask is not in a supported range...
						If ($Matches['Netmask'] -notin 25..32) {
							Return "the provided name of the reverse lookup zone contains an invalid CIDR netmask: $($Matches['Netmask'])"
						}
						# create hashtable with static octets and matched values
						$Hashtable = @{
							Octet1 = $Octets[0]
							Octet2 = $Octets[1]
							Octet3 = $Octets[2]
							Octet4 = $Matches['Octet']
							Subnet = $Matches['Netmask']
						}
						# update the last octet to be the matched value
						$Octets[-1] = $Matches['Octet']
					}
					Else {
						Return "the provided name of the reverse lookup zone contains a fourth octet with an unrecognized CIDR notation: $($Octets[-1])"
					}
				}
				# has more than 4 octets...
				Default {
					Return 'the provided name for the reverse lookup zone is in the IPv4 lookup domain but contains too many octets'
				}
			}
		}

		# validate octet elements
		ForEach ($Octet in $Octets) {
			If (![byte]::TryParse($Octet, [ref] $null)) {
				Return "the provided name of the reverse lookup zone contains an element that cannot be converted into an byte: $Octet"
			}
		}

		# return hashtable
		Return $Hashtable
	}

	# retrieve zones
	Write-Host "`nRetrieveing DNS zones..."
	Try {
		$DnsServerZones = Get-DnsServerZone -ComputerName $ComputerName -ErrorAction 'Stop' | Where-Object { $_.ZoneName.Contains('.') -and $_.ZoneType -eq 'Primary' -and -not $_.IsAutoCreated }
	}
	Catch {
		Write-Warning -Message "could not retrieve DNS zones from server: $ComputerName"
		Throw $_
	}

	# declare zones found
	Write-Host "...found '$($DnsServerZones.Count)' zone(s)"

	# if forward zone name not provided and skip subdomain set...
	If (!$PSBoundParameters.ContainsKey('ForwardZoneName') -and $SkipSubdomain) {
		# set forward zone name to domain
		$ForwardZoneName = $Domain
	}
}

Process {
	# if reverse zone name does not exist...
	If ($ZoneName -notin $DnsServerZones.ZoneName) {
		Write-Warning "a reverse lookup zone matching the provided zone name was not found on server: $ComputerName"
		Return
	}

	# if reverse zone name permits secure dynamic update...
	If ($DnsServerZones.Where({ $_.ZoneName -eq $ZoneName }).DynamicUpdate -eq 'Secure') {
		$SecureUpdate = $true
	}

	# if forward zone name does not exist and skip forward records not set...
	If ($ForwardZoneName -notin $DnsServerZones.ZoneName -and -not $SkipForwardRecords) {
		Write-Warning "a forward lookup zone matching the provided or constructed forward zone name was not found on server: $ComputerName"
		Return
	}

	# convert zone name into octets and netmask
	Try {
		$OctetsAndNetmask = Get-OctetsAndNetmaskFromZoneName -ZoneName $ZoneName
	}
	Catch {
		Write-Warning -Message 'could not retrieve octets and netmask from zone name'
		Return $_
	}

	# if value from function is a string...
	If ($OctetsAndNetmask -is [System.String]) {
		# report string as warning and return
		Write-Warning -Message $OctetsAndNetmask
		Return
	}

	# if value from function is not a hashtable...
	If ($OctetsAndNetmask -isnot [hashtable]) {
		# report string as warning and return
		Write-Warning -Message "invalid object type returned by internal Get-OctetsAndNetmaskFromZoneName function: $($OctetsAndNetmask.GetType().FullName)"
		Return
	}

	# build static strings with values from function
	$FirstThreeAsIPAddress = $OctetsAndNetmask['Octet1'], $OctetsAndNetmask['Octet2'], $OctetsAndNetmask['Octet3'] -join '.'
	$FirstThreeAsDNSRecord = $OctetsAndNetmask['Octet1'], $OctetsAndNetmask['Octet2'], $OctetsAndNetmask['Octet3'] -join '-'

	# build byte values for range with values from function
	$Octet4FirstValue = [byte]$OctetsAndNetmask['Octet4']
	$Octet4LastValue = [byte]$OctetsAndNetmask['Octet4'] + [byte]([Math]::Pow(2, 32 - [byte]$OctetsAndNetmask['Subnet']) - 1)

	# build range of values for fourth octet
	$Range = $Octet4FirstValue..$Octet4LastValue

	# reset counters
	$DnsLocated = 0
	$DnsUpdated = 0
	$DnsCreated = 0

	# process range and create REVERSE records
	:NextOctet ForEach ($Name in $Range) {
		# build IP address and PTR record
		$IPAddress = $FirstThreeAsIPAddress, $Name -join '.'

		# if reserved hosts contains IP address...
		If ($ReservedHosts -and $ReservedHosts.ContainsKey($IPAddress)) {
			# set PTR domain name value to value from reserved hosts
			$PtrDomainName = "$($ReservedHosts[$IPAddress])"
			# if PTR domain name lacks terminating dot...
			If (!$PtrDomainName.EndsWith('.')) {
				# pad PTR domain name with terminating dot
				$PtrDomainName = "$PtrDomainName."
			}
		}
		Else {
			# build record name and domain name from existing strings and name
			$PtrRecordName = $PtrPrefix, $FirstThreeAsDNSRecord, $Name -join '-'
			$PtrDomainName = "$PtrRecordName.$ForwardZoneName."
		}

		# define parameters for record
		$DnsServerResourceRecord = @{
			ComputerName = $ComputerName
			ZoneName     = $ZoneName
			Name         = $Name
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# check for PTR record
		Try {
			# get PTR record and throw exception if not found
			$Record = Get-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $ZoneName -Name $Name -ErrorAction 'Stop'
		}
		Catch {
			# update parameters for record
			$DnsServerResourceRecord['PtrDomainName'] = $PtrDomainName

			# if secure update enabled...
			If ($SecureUpdate) {
				$DnsServerResourceRecord['AllowUpdateAny'] = $true
			}

			# create PTR record
			Try {
				Add-DnsServerResourceRecordPtr @DnsServerResourceRecord
			}
			Catch {
				Throw $_
			}

			# update counters
			$DnsCreated++

			# report and continue to next octet
			Write-Verbose -Message "added '$Name' in '$ZoneName' on '$ComputerName' with value: $PtrDomainName"
			Continue NextOctet
		}

		# if expected PTR record found...
		If ($Record.RecordData.PtrDomainName -eq $PtrDomainName) {
			# update counters
			$DnsLocated++

			# report and continue to next octet
			Write-Verbose -Message "found '$Name' in '$ZoneName' on '$ComputerName' with expected value: $PtrDomainName"
			Continue NextOctet
		}

		# if expected PTR record not found but Reset not set...
		If ($Record.RecordData.PtrDomainName -ne $PtrDomainName -and -not $Reset) {
			# update counters
			$DnsLocated++

			# report and continue to next octet
			Write-Verbose -Message "found '$Name' in '$ZoneName' on '$ComputerName' with existing value: $($Record.RecordData.PtrDomainName)"
			Continue NextOctet
		}

		# copy PTR record object
		$NewRecord = $Record.Clone()

		# update new PTR record object
		$NewRecord.RecordData.PtrDomainName = $PtrDomainName

		# set new PTR record
		Try {
			Set-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $ZoneName -OldInputObject $Record -NewInputObject $NewRecord -ErrorAction 'Stop'
		}
		Catch {
			Throw $_
		}

		# update counters
		$DnsUpdated++

		# report and continue to next octet
		Write-Verbose -Message "updated '$Name' in '$ZoneName' on '$ComputerName' with expected value: $PtrDomainName"
		Continue NextOctet
	}

	# report PTR record changes
	If ($DnsLocated) { Write-Output "...located '$DnsLocated' PTR record(s)" }
	If ($DnsUpdated) { Write-Output "...updated '$DnsUpdated' PTR record(s)" }
	If ($DnsCreated) { Write-Output "...created '$DnsCreated' PTR record(s)" }

	# if skip forward records set...
	If ($SkipForwardRecords) {
		Return
	}

	# reset counters
	$DnsLocated = 0
	$DnsUpdated = 0
	$DnsCreated = 0

	# process range and create FORWARD records
	:NextOctet ForEach ($Name in $Range) {
		# build IP address and PTR record
		$IPAddress = $FirstThreeAsIPAddress, $Name -join '.'

		# if reserved hosts contains IP address...
		If ($ReservedHosts -and $ReservedHosts.ContainsKey($IPAddress)) {
			# set PTR domain name value to value from reserved hosts
			$PtrDomainName = "$($ReservedHosts[$IPAddress])"

			# retrieve record name and domain name from PTR domain name
			$RecordName, $DomainName = $PtrDomainName.Split('.', 2)

			# if retrieved domain name not found...
			If ($DomainName -notin $DnsZones) {
				# warn and continue
				Write-Warning "Forward DNS record '$PtrDomainName' has a domain name of '$DomainName' which was not found on server: '$ComputerName'"
				Continue NextOctet
			}
		}
		# if reserved hosts does not contains IP address...
		Else {
			# build record name and domain name from existing strings and name
			$RecordName = $PtrPrefix, $FirstThreeAsDNSRecord, $Name -join '-'
			$DomainName = $ForwardZoneName
		}

		# define parameters for record
		$DnsServerResourceRecord = @{
			ComputerName = $ComputerName
			ZoneName     = $DomainName
			Name         = $RecordName
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# check for A record
		Try {
			# get A record and throw exception if not found
			$Record = Get-DnsServerResourceRecord @DnsServerResourceRecord
		}
		Catch {
			# update parameters foor record
			$DnsServerResourceRecord['IPv4Address'] = $IPAddress

			# create A record
			Try {
				Add-DnsServerResourceRecordA @DnsServerResourceRecord
			}
			Catch {
				Throw $_
			}

			# update counters
			$DnsCreated++

			# report and continue to next octet
			Write-Verbose "added '$RecordName' in '$DomainName' on '$ComputerName' with value: $IPAddress"
			Continue NextOctet
		}

		# if expected A record found...
		If ($Record.RecordData.IPv4Address.IPAddressToString -eq $IPAddress) {
			# update counters
			$DnsLocated++

			# report and continue to next octet
			Write-Verbose "found '$RecordName' in '$DomainName' on '$ComputerName' with expected value: $IPAddress"
			Continue NextOctet
		}

		# if expected A record not found but Reset not set...
		If ($Record.RecordData.IPv4Address.IPAddressToString -ne $IPAddress -and -not $Reset) {
			# update counters
			$DnsLocated++

			# report and continue to next octet
			Write-Verbose "found '$RecordName' in '$DomainName' on '$ComputerName' with existing value: $($Record.RecordData.IPv4Address.IPAddressToString)"
			Continue NextOctet
		}

		# copy A record object
		$NewRecord = $Record.Clone()

		# update new A record object
		$NewRecord.RecordData.IPv4Address = [System.Net.IPAddress]::Parse($IPAddress)

		# set new A record
		Try {
			Set-DnsServerResourceRecord -ComputerName $ComputerName -ZoneName $DomainName -OldInputObject $Record -NewInputObject $NewRecord -ErrorAction 'Stop'
		}
		Catch {
			Throw $_
		}

		# update counters
		$DnsUpdated++

		# report and continue to next octet
		Write-Verbose "updated '$RecordName' in '$DomainName' on '$ComputerName' with expected value: $PtrDomainName"
		Continue NextOctet
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
