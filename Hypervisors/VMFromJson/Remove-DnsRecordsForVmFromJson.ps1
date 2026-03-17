#requires -Modules ActiveDirectory,DnsServer,DnsClient

param(
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant(),
	[Parameter(DontShow)]
	[string[]]$RRTypes = @('A', 'AAAA'),
	[Parameter(Position = 0, Mandatory)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	[Parameter(Position = 1, Mandatory, ValueFromPipeline)]
	[string[]]$VMName,
	[Parameter(Position = 2)]
	[switch]$RemoveOtherRecords
)

# if Json is not an absolute path...
if (![System.IO.Path]::IsPathRooted($Json)) {
	# get unresolved absolute path
	try {
		$Json = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Json)
	}
	catch {
		Write-Warning -Message "could not create absolute path from the provided Json parameter: $Json"
		return
	}

	# report absolute path
	Write-Warning -Message "converted relative path in provided Json parameter to absolute path: $Json"
}

# import JSON data
try {
	$JsonData = [array](Get-Content -Path $Json -ErrorAction Stop | ConvertFrom-Json)
}
catch {
	Write-Warning -Message "could not read configuration file: '$Json'"
	throw $_
}

# loop through VM names
:NextVMName foreach ($Name in $VMName) {
	# if ADComputer not found...
	if ($null -eq $JsonData.$Name.ADComputer) {
		Write-Warning -Message "could not retrieve 'ADComputer' section of '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}

	# if domain not provided...
	if ([string]::IsNullOrEmpty($JsonData.$Name.ADComputer.DomainName)) {
		Write-Warning -Message "could not retrieve required 'DomainName' value in 'ADComputer' section of '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}
	# if domain provided...
	else {
		# assign variable to provided domain for ease of use
		$DomainName = $JsonData.$Name.ADComputer.DomainName
	}

	# resolve domain
	try {
		$null = Resolve-DnsName -Name $DomainName -DnsOnly -Type A_AAAA -QuickTimeout -ErrorAction 'Stop'
	}
	catch {
		Write-Warning -Message "could not resolve A_AAAA record(s) for '$DomainName' domain in 'ADComputer' section for '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}

	# get domain object
	try {
		$DomainObject = Get-ADDomain -Identity $DomainName
	}
	catch [System.Security.Authentication.AuthenticationException] {
		Write-Warning -Message "could not authenticate to '$DomainName' domain in 'ADComputer' section for '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}
	catch {
		Write-Warning -Message "could not retrieve object for '$DomainName' domain in 'ADComputer' section for '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}

	# retrieve server from domain object
	$Server = $DomainObject.PDCEmulator

	# define parameters
	$GetDnsServerZone = @{
		ComputerName = $Server
		ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
	}

	# retrieve DNS zone for looking up zones
	try {
		$DnsServerZones = Get-DnsServerZone @GetDnsServerZone
	}
	catch {
		Write-Warning -Message "could not retrieve zones on '$Server' server: $($_.Exception.Message)"
		continue NextVMName
	}

	# create list for IP address objects
	$IPAddresses = [System.Collections.Generic.List[System.Net.IPAddress]]::new()

	# loop through VMNetwork adapters
	:NextVMNetworkAdapter foreach ($VMNetworkAdapter in $JsonData.$Name.VMNetworkAdapters) {
		# if VM network adapter does not have a name or an IP address...
		if ([string]::IsNullOrEmpty($VMNetworkAdapter.NetworkAdapterName) -or [string]::IsNullOrEmpty($VMNetworkAdapter.IPAddress)) {
			continue NextVMNetworkAdapter
		}

		# create IP address object from properties
		try {
			$IPAddress = [System.Net.IPAddress]::Parse($VMNetworkAdapter.IPAddress)
		}
		catch {
			Write-Warning -Message "could not parse '$($VMNetworkAdapter.IPAddress)' value in IPAddress on '$($VMNetworkAdapter.NetworkAdapterName)' network adapter: $($_.Exception.Message)"
			continue NextVMNetworkAdapter
		}

		# add IP address object to list
		$IPAddresses.Add($IPAddress)
	}

	# report count
	Write-Host "$Hostname,$Name - found '$($IPAddresses.Count)' IP addresses for '$Name' VM in configuration file: '$Json'"

	####################
	# forward records
	####################

	# assign zone name from domain name
	$ZoneName = $DomainName

	# if zone name not found in zones...
	if ($ZoneName -notin $DnsServerZones.ZoneName) {
		Write-Warning -Message "could not find zone for '$ZoneName' domain on '$Server' server"
		continue NextVMName
	}

	# define parameters
	$GetDnsServerResourceRecord = @{
		ComputerName = $Server
		ZoneName     = $ZoneName
		Name         = $Name
		ErrorAction  = [System.Management.Automation.ActionPreference]::Ignore
	}

	# retrieve existing DNS records from DNS
	try {
		$ForwardDnsServerResourceRecords = Get-DnsServerResourceRecord @GetDnsServerResourceRecord
	}
	catch {
		Write-Warning -Message "could not retrieve forward DNS records for '$Name' name in '$ZoneName' zone on '$Server' server: $($_.Exception.Message)"
		return $_
	}

	# get count of DNS records
	try {
		$ForwardDnsServerResourceRecordCount = Measure-Object -InputObject $ForwardDnsServerResourceRecords | Select-Object -ExpandProperty 'Count'
	}
	catch {
		Write-Warning -Message "could not retrieve count of forward DNS records for '$Name' name in '$ZoneName' zone on '$Server' server: $($_.Exception.Message)"
		continue NextVMName
	}

	# report count
	Write-Host "$Hostname,$Name - found '$ForwardDnsServerResourceRecordCount' forward DNS records for '$Name' name in '$ZoneName' zone on '$Server' server"

	# create lists for IPv4 and IPv6 addresses
	$IPAddressesFromDnsRecords = [System.Collections.Generic.List[string]]::new()

	# loop through DNS records to remove expired DNS records
	:NextForwardDnsServerResourceRecord foreach ($DnsServerResourceRecord in $ForwardDnsServerResourceRecords) {
		# assign record type to object
		$RRType = $DnsServerResourceRecord.RecordType

		# switch on record type
		switch ($RRType) {
			'A' {
				# get existing IPv4 address as string for reporting
				$IPAddress = $DnsServerResourceRecord.RecordData.IPv4Address.IPAddressToString

				# add existing IPv4 address to list for pointer removal
				$IPAddressesFromDnsRecords.Add($IPAddress)

				# if no IP addresses retrieved from network adapters...
				if ($IPAddresses.Count -eq 0) {
					# report and continue to next DNS record
					Write-Host "$Hostname,$Name - found existing '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server"
				}

				# if IPv4 address is in IP addresses list...
				if ($DnsServerResourceRecord.RecordData.IPv4Address -in $IPAddresses) {
					# report and continue to next DNS record
					Write-Host "$Hostname,$Name - found expected '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server"
				}

				# define parameters
				$RemoveDnsServerResourceRecord = @{
					ComputerName = $Server
					ZoneName     = $ZoneName
					Name         = $Name
					RRType       = $RRType
					RecordData   = $IPAddress
					Force        = $true
					ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
				}

				# retrieve existing DNS record
				try {
					Remove-DnsServerResourceRecord @RemoveDnsServerResourceRecord
				}
				catch {
					Write-Warning -Message "could not remove '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server: $($_.Exception.Message)"
					return $_
				}

				# report state
				Write-Host "$Hostname,$Name - removed '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server"
			}
			'AAAA' {
				# get existing IPv6 address as string for reporting
				$IPAddress = $DnsServerResourceRecord.RecordData.IPv6Address.IPAddressToString

				# add existing IPv6 address to list for pointer removal
				$IPAddressesFromDnsRecords.Add($IPAddress)

				# if no IP addresses retrieved from network adapters...
				if ($IPAddresses.Count -eq 0) {
					# report and continue to next DNS record
					Write-Host "$Hostname,$Name - found existing '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server"
				}

				# if IPv6 address is in IP addresses list...
				if ($DnsServerResourceRecord.RecordData.IPv6Address -in $IPAddresses) {
					# report and continue to next DNS record
					Write-Host "$Hostname,$Name - found expected '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server"
				}

				# define parameters
				$RemoveDnsServerResourceRecord = @{
					ComputerName = $Server
					ZoneName     = $ZoneName
					Name         = $Name
					RRType       = $RRType
					RecordData   = $IPAddress
					Force        = $true
					ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
				}

				# retrieve existing DNS record
				try {
					Remove-DnsServerResourceRecord @RemoveDnsServerResourceRecord
				}
				catch {
					Write-Warning -Message "could not remove '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server: $($_.Exception.Message)"
					return $_
				}

				# report state
				Write-Host "$Hostname,$Name - removed '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server"
			}
			default {
				# if no IP addresses retrieved from network adapters...
				if ($IPAddresses.Count -eq 0 -or -not $RemoveOtherRecords) {
					Write-Host "$Hostname,$Name - found existing '$RRType' DNS record for '$Name' name in '$ZoneName' zone on '$Server' server"
					continue NextForwardDnsServerResourceRecord
				}

				# define parameters
				$RemoveDnsServerResourceRecord = @{
					ComputerName = $Server
					ZoneName     = $ZoneName
					Name         = $Name
					RRType       = $RRType
					Force        = $true
					ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
				}

				# retrieve existing DNS record
				try {
					Remove-DnsServerResourceRecord @RemoveDnsServerResourceRecord
				}
				catch {
					Write-Warning -Message "could not remove '$RRType' DNS record for '$Name' name in '$ZoneName' zone on '$Server' server: $($_.Exception.Message)"
					return $_
				}

				# report state
				Write-Host "$Hostname,$Name - removed '$RRType' DNS record for '$Name' name in '$ZoneName' zone on '$Server' server"
			}
		}
	}

	####################
	# reverse records
	####################

	# loop through IP addresses from DNS records
	:NextIPAddressFromDnsRecord foreach ($IPAddressFromDnsRecord in $IPAddressesFromDnsRecords) {
		# try to parse the IP address
		try {
			$IPAddress = [System.Net.IPAddress]::Parse($IPAddressFromDnsRecord)
		}
		catch {
			Write-Warning -Message "could not parse '$IPAddressFromDnsRecord' into an IP address: $($_.Exception.Message)"
			return $_
		}

		# switch on IP address family
		switch ($IPAddress.AddressFamily) {
			'InterNetwork' {
				# split IPv4 address into octets
				$Octets = $IPAddress.IPAddressToString.Split('.')
				# define IPv6 PTR suffix for DNS record
				$DnsRecordSuffix = 'in-addr.arpa.'
			}
			'InterNetworkV6' {
				# split IPv6 address into octets
				$Octets = $IPAddress.IPAddressToString.Split(':')
				# define IPv6 PTR suffix for DNS record
				$DnsRecordSuffix = 'ip6.arpa.'

				# warn and continue
				Write-Warning -Message 'found IPv6 address which is not currently supported by this script'
				continue NextIPAddressFromDnsRecord

			}
			default {
				Write-Warning -Message "found unknown '$($IPAddress.AddressFamily)' address family for '$IPAddressFromDnsRecord' IP address: $($_.Exception.Message)"
				continue NextIPAddressFromDnsRecord
			}
		}

		# split IPv4 address into octets
		$Octets = $IPAddress.IPAddressToString.Split('.')

		# reverse octets
		[array]::Reverse($Octets)

		# create PTR record
		$PtrRecordName = '{0}.{1}' -f ($Octets -join '.'), $DnsRecordSuffix

		# define parameters
		$ResolveDnsName = @{
			Server       = $Server
			Name         = $PtrRecordName 
			Type         = 'PTR'
			DnsOnly      = $true
			QuickTimeout = $true
			ErrorAction  = [System.Management.Automation.ActionPreference]::Ignore
		}

		# resolve PTR record
		try {
			$DnsRecords = Resolve-DnsName @ResolveDnsName
		}
		catch {
			Write-Warning -Message "could not query '$Server' server for '$PtrRecordName' PTR record for '$IPAddressFromDnsRecord' IPv4 address: $($_.Exception.Message)"
			return $_
		}

		# loop through DNS names
		:NextReverseDnsRecord foreach ($DnsRecord in $DnsRecords) {
			# assign record data to object
			$RRData = $DnsRecord.NameHost

			# assign record type to object
			$RRType = $DnsRecord.Type

			# switch on record type
			switch ($RRType) {
				'PTR' {
					# extract record name and zone name from resolved DNS name
					$RRName, $ZoneName = $DnsRecord.Name.Split('.', 2)

					# if zone name not found in zones...
					if ($ZoneName -notin $DnsServerZones.ZoneName) {
						Write-Host "$Hostname,$Name - skipping removal of '$RRType' DNS records with '$RRName' name for '$Name' computer; could not find '$ZoneName' zone on '$Server' server"
						continue NextReverseDnsRecord
					}

					# define parameters
					$RemoveDnsServerResourceRecord = @{
						ComputerName = $Server
						ZoneName     = $ZoneName
						Name         = $RRName
						RRType       = $RRType
						RecordData   = $RRData
						Force        = $true
						ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
					}

					# retrieve existing DNS record
					try {
						Remove-DnsServerResourceRecord @RemoveDnsServerResourceRecord
					}
					catch {
						Write-Warning -Message "could not remove '$RRType' DNS record with '$RRName' name for '$Name' computer in '$ZoneName' zone on '$Server' server: $($_.Exception.Message)"
						return $_
					}

					# report state
					Write-Host "$Hostname,$Name - removed '$RRType' DNS record with '$RRName' name for '$Name' computer in '$ZoneName' zone on '$Server' server"
				}
			}
		}
	}

	####################
	# service records
	####################

	# assign zone name from domain name
	$ZoneName = $DomainName

	# if zone name not found in zones...
	if ($ZoneName -notin $DnsServerZones.ZoneName) {
		Write-Warning -Message "could not find zone for '$ZoneName' domain on '$Server' server"
		continue NextVMName
	}

	# define DNS host name with dot-terminator
	$DnsHostNameWithDot = '{0}.{1}.' -f $Name, $DomainName

	# define parameters
	$GetDnsServerResourceRecord = @{
		ComputerName = $Server
		ZoneName     = $ZoneName
		RRType       = 'SRV'
		ErrorAction  = [System.Management.Automation.ActionPreference]::Ignore
	}

	# retrieve existing DNS records from DNS
	try {
		$DnsServerResourceRecords = Get-DnsServerResourceRecord @GetDnsServerResourceRecord | Where-Object { $_.RecordData.DomainName -eq $DnsHostNameWithDot }
	}
	catch {
		Write-Warning -Message "could not retrieve service DNS records for '$Name' name in '$ZoneName' zone on '$Server' server: $($_.Exception.Message)"
		return $_
	}

	# get count of DNS records
	try {
		$DnsServerResourceRecordCount = Measure-Object -InputObject $DnsServerResourceRecords | Select-Object -ExpandProperty 'Count'
	}
	catch {
		Write-Warning -Message "could not retrieve count of service DNS records for '$Name' name in '$ZoneName' zone on '$Server' server: $($_.Exception.Message)"
		continue NextVMName
	}

	# report count
	Write-Host "$Hostname,$Name - found '$DnsServerResourceRecordCount' service DNS records for '$Name' name in '$ZoneName' zone on '$Server' server"

	# create lists for IPv4 and IPv6 addresses
	$IPAddressesFromDnsRecords = [System.Collections.Generic.List[string]]::new()

	# loop through DNS records to remove expired DNS records
	:NextDnsServerResourceRecord foreach ($DnsServerResourceRecord in $DnsServerResourceRecords) {
		# assign record name to object
		$RRName = $DnsServerResourceRecord.Name

		# assign record type to object
		$RRType = $DnsServerResourceRecord.RecordType

		# switch on record type
		switch ($RRType) {
			'SRV' {
				# define record data array
				$RecordData = @(
					$DnsServerResourceRecord.RecordData.Priority
					$DnsServerResourceRecord.RecordData.Weight
					$DnsServerResourceRecord.RecordData.Port
					$DnsServerResourceRecord.RecordData.DomainName
				)

				# define parameters
				$RemoveDnsServerResourceRecord = @{
					ComputerName = $Server
					ZoneName     = $ZoneName
					Name         = $RRName
					RRType       = $RRType
					RecordData   = $RecordData
					Force        = $true
					ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
				}

				# retrieve existing DNS record
				try {
					Remove-DnsServerResourceRecord @RemoveDnsServerResourceRecord
				}
				catch {
					Write-Warning -Message "could not remove '$RRType' DNS record with '$RRName' name for '$Name' computer in '$ZoneName' zone on '$Server' server: $($_.Exception.Message)"
					return $_
				}

				# report state
				Write-Host "$Hostname,$Name - removed '$RRType' DNS record with '$RRName' name for '$Name' computer in '$ZoneName' zone on '$Server' server"
			}
		}
	}
}
