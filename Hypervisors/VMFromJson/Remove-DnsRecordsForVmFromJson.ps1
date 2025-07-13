#requires -Modules ActiveDirectory,DnsServer

param(
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant(),
	[Parameter(DontShow)]
	[string[]]$RRTypes = @('A', 'AAAA'),
	[Parameter(Position = 0, Mandatory)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	[Parameter(Position = 1, Mandatory, ValueFromPipeline)]
	[string[]]$VMName
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

	# define parameters
	$GetDnsServerZone = @{
		ComputerName = $Server
		Name         = $DomainName
		ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
	}

	# retrieve DNS zone for looking up zones
	try {
		$DnsServerZone = Get-DnsServerZone @GetDnsServerZone
	}
	catch {
		Write-Warning -Message "could not retrieve zone for '$DomainName' domain on '$Server' server"
		continue NextGroup
	}

	# assign zone name
	$ZoneName = $DnsServerZone.ZoneName

	# define parameters
	$GetDnsServerResourceRecord = @{
		ComputerName = $Server
		ZoneName     = $ZoneName
		Name         = $Name
		ErrorAction  = [System.Management.Automation.ActionPreference]::Ignore
	}

	# retrieve existing DNS records from DNS
	try {
		$DnsServerResourceRecords = Get-DnsServerResourceRecord @GetDnsServerResourceRecord
	}
	catch {
		Write-Warning -Message "could not retrieve DNS records for '$Name' name in '$ZoneName' zone on '$Server' server: $($_.Exception.Message)"
		return $_
	}

	# get count of DNS records
	try {
		$DnsServerResourceRecordCount = Measure-Object -InputObject $DnsServerResourceRecords | Select-Object -ExpandProperty 'Count'
	}
	catch {
		Write-Warning -Message "could not retrieve count of DNS records for '$Name' name in '$ZoneName' zone on '$Server' server: $($_.Exception.Message)"
		continue NextADObject
	}

	# report count
	Write-Host "$Hostname,$Name - found '$DnsServerResourceRecordCount' DNS records for '$Name' name in '$ZoneName' zone on '$Server' server"

	# loop through DNS records to remove expired DNS records
	:NextDnsServerResourceRecord foreach ($DnsServerResourceRecord in $DnsServerResourceRecords) {
		# assign record type to object
		$RRType = $DnsServerResourceRecord.RecordType

		# switch on record type
		switch ($RRType) {
			'A' {
				# get existing IPv6 address as string for reporting
				$IPAddress = $DnsServerResourceRecord.RecordData.IPv4Address.IPAddressToString

				# if no IP addresses retrieved from network adapters...
				if ($IPAddresses.Count -eq 0) {
					# report and continue to next DNS record
					Write-Host "$Hostname,$Name - found existing '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server"
					continue NextDnsServerResourceRecord
				}

				# if IPv4 address is in IP addresses list...
				if ($DnsServerResourceRecord.RecordData.IPv4Address -in $IPAddresses) {
					# report and continue to next DNS record
					Write-Host "$Hostname,$Name - found expected '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server"
					continue NextDnsServerResourceRecord
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

				# if no IP addresses retrieved from network adapters...
				if ($IPAddresses.Count -eq 0) {
					# report and continue to next DNS record
					Write-Host "$Hostname,$Name - found existing '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server"
					continue NextDnsServerResourceRecord
				}

				# if IPv6 address is in IP addresses list...
				if ($DnsServerResourceRecord.RecordData.IPv6Address -in $IPAddresses) {
					# report and continue to next DNS record
					Write-Host "$Hostname,$Name - found expected '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server"
					continue NextDnsServerResourceRecord
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
			Default {
				# if no IP addresses retrieved from network adapters...
				if ($IPAddresses.Count -eq 0) {
					Write-Host "$Hostname,$Name - found existing '$RRType' DNS record for '$Name' name in '$ZoneName' zone on '$Server' server"
					continue NextDnsServerResourceRecord
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
}
