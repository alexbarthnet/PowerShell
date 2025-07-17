#requires -Modules ActiveDirectory,DnsServer

param(
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant(),
	[Parameter(DontShow)]
	[string]$ActiveDirectoryRights = 'CreateChild, DeleteChild, ListChildren, ReadProperty, DeleteTree, ExtendedRight, Delete, GenericWrite, WriteDacl, WriteOwner',
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
		Write-Warning -Message "could not retrieve required 'ADComputer' section of '$Name' VM in configuration file: '$Json'"
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

	# if OU not provided...
	if ([string]::IsNullOrEmpty($JsonData.$Name.ADComputer.OrganizationalUnit)) {
		Write-Warning -Message "could not retrieve required 'OrganizationalUnit' value in 'ADComputer' section of '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}
	# if OU provided...
	else {
		# assign variable for ease of use
		$Path = $JsonData.$Name.ADComputer.OrganizationalUnit
	}

	# resolve domain
	try {
		$null = Resolve-DnsName -Name $DomainName -DnsOnly -Type A_AAAA -QuickTimeout -ErrorAction 'Stop'
	}
	catch {
		Write-Warning -Message "could not resolve A_AAAA record(s) for '$DomainName' domain in 'ADComputer' section of '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}

	# report state
	Write-Host ("$Hostname,$Name - connecting to domain...")

	# get domain object
	try {
		$DomainObject = Get-ADDomain -Identity $DomainName
	}
	catch [System.Security.Authentication.AuthenticationException] {
		Write-Warning -Message "could not authenticate to '$DomainName' domain in 'ADComputer' section of '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}
	catch {
		Write-Warning -Message "could not retrieve object for '$DomainName' domain in 'ADComputer' section of '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}

	# report state
	Write-Host ("$Hostname,$Name - ...connected to domain: $($DomainObject.Name)")

	# retrieve server from domain object
	$Server = $DomainObject.PDCEmulator

	# report state
	Write-Host ("$Hostname,$Name - ...located PDCEmulator: $Server")

	# report state
	Write-Host ("$Hostname,$Name - checking computer object...")

	# define identity for computer object
	$Identity = 'CN={0},{1}' -f $Name, $Path

	# define parameters
	$GetADComputer = @{
		Server      = $Server
		Identity    = $Identity
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# retrieve computer object
	try {
		$ComputerObject = Get-ADComputer @GetADComputer
		Write-Host ("$Hostname,$Name - ...computer object retrieved")
	}
	catch [System.Security.Authentication.AuthenticationException] {
		Write-Warning -Message "could not authenticate to '$Server' server for '$DomainName' domain in 'ADComputer' section of '$Name' VM in configuration file: '$Json'"
		continue NextVMName
	}
	catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
		Write-Warning -Message "could not locate computer with '$Name' name on '$Server' server for '$DomainName' domain"
		continue NextVMName
	}
	catch {
		Write-Warning -Message "could not retrieve computer with '$Name' name on '$Server' server for '$DomainName' domain: $($_.Exception.Message)"
		continue NextVMName
	}

	# if VMNetworkAdapters not found...
	if ($null -eq $JsonData.$Name.VMNetworkAdapters) {
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
					# continue to next DNS record
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
					# continue to next DNS record
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
				Write-Host "$Hostname,$Name - removed unexpected '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server"
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
				Write-Host "$Hostname,$Name - removed unexpected '$RRType' DNS record for '$Name' name in '$ZoneName' zone on '$Server' server"
			}
		}
	}

	# loop through IP addresses to create missing DNS records
	:NextIPAddress foreach ($IPAddress in $IPAddresses) {
		# switch on IP address family
		switch ($IPAddress.AddressFamily) {
			'InterNetwork' {
				# set record type
				$RRType = 'A'

				# if IP address is in DNS records data for IPv4 addresses...
				if ($IPAddress -in $DnsServerResourceRecords.RecordData.IPv4Address) {
					Write-Host "$Hostname,$Name - found existing '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server"
					continue NextIPAddress
				}

				# define parameters
				$AddDnsServerResourceRecord = @{
					ComputerName = $Server
					ZoneName     = $ZoneName
					Name         = $Name
					$RRType      = $true
					IPv4Address  = $IPAddress
					ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
				}

				# create new DNS record
				try {
					Add-DnsServerResourceRecord @AddDnsServerResourceRecord
				}
				catch {
					Write-Warning -Message "could not create '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server: $($_.Exception.Message)"
					return $_
				}

				# report state
				Write-Host "$Hostname,$Name - created missing '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server"
			}
			'InterNetworkV6' {
				# set record type
				$RRType = 'AAAA'

				# if IP address is in DNS records data for IPv6 addresses...
				if ($IPAddress -in $DnsServerResourceRecord.RecordData.IPv6Address) {
					Write-Host "$Hostname,$Name - found existing '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server"
					continue NextIPAddress
				}

				# define parameters
				$AddDnsServerResourceRecord = @{
					ComputerName = $Server
					ZoneName     = $ZoneName
					Name         = $Name
					$RRType      = $true
					RecordData   = $IPAddress
					ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
				}

				# create new DNS record
				try {
					Add-DnsServerResourceRecord @AddDnsServerResourceRecord
				}
				catch {
					Write-Warning -Message "could not create '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server: $($_.Exception.Message)"
					return $_
				}

				# report state
				Write-Host "$Hostname,$Name - created missing '$RRType' DNS record for '$Name' name with '$IPAddress' address in '$ZoneName' zone on '$Server' server"
			}
		}
	}

	####################
	# forward object
	####################

	# define DNS object identity
	$Identity = 'DC={0},{1}' -f $Name, $DnsServerZone.DistinguishedName

	# define parameters
	$GetADObject = @{
		Server      = $Server
		Identity    = $Identity
		Properties  = 'nTSecurityDescriptor'
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# retrieve DNS object
	try {
		$ADObject = Get-ADObject @GetADObject
	}
	catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
		Write-Warning -Message "could not locate AD object for DNS record with '$Name' name in '$ZoneName' zone on '$Server' server"
		return $_
	}
	catch {
		Write-Warning -Message "could not retrieve AD object for DNS record with '$Name' name in '$ZoneName' zone on '$Server' server: $($_.Exception.Message)"
		return $_
	}

	# if nTSecurityDescriptor not found...
	if ($null -eq $ADObject.nTSecurityDescriptor) {
		# warn and return
		Write-Warning -Message "could not retrieve Security Descriptor object: '$($ADObject.DistinguishedName)'"
		return
	}
	# if nTSecurityDescriptor found...
	else {
		# assign property to object
		$nTSecurityDescriptor = $ADObject.nTSecurityDescriptor
	}

	# if nTSecurityDescriptor is not the expected object type...
	if ($nTSecurityDescriptor -isnot [System.DirectoryServices.ActiveDirectorySecurity]) {
		# warn and return
		Write-Warning -Message "found invalid '[$($nTSecurityDescriptor.GetType().FullName)]' object type for nTSecurityDescriptor on '$Server' server with DN: '$($ADObject.DistinguishedName)'"
		return
	}
	# if nTSecurityDescriptor found and is the expected object type...
	else {
		# retrieve the access rules
		$AccessRules = $nTSecurityDescriptor.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])
	}

	# create access rule
	$AccessRule = [System.DirectoryServices.ActiveDirectoryAccessRule]::new($ComputerObject.SID, $ActiveDirectoryRights, 'Allow')

	# if access rules found in access rules...
	if ($AccessRules.Where({ $_.IdentityReference -eq $ComputerObject.SID -and $_.ActiveDirectoryRights -eq $ActiveDirectoryRights })) {
		# report and return
		Write-Host "$Hostname,$Name - validated access rules on AD object for DNS record with '$Name' name in '$ZoneName' zone on '$Server' server"
		return
	}

	# retrieve access rules for DNS object where identity matches computer SID
	$AccessRulesToRemove = $AccessRules.Where({ $_.IdentityReference -eq $ComputerObject.SID })

	# loop through access rules to remove
	foreach ($AccessRule in $AccessRulesToRemove) {
		$nTSecurityDescriptor.RemoveAccessRuleSpecific($AccessRule)
	}

	# add access rule to security descriptor
	$nTSecurityDescriptor.AddAccessRule($AccessRule)

	# define parameters
	$SetADObject = @{
		Server      = $Server
		Identity    = $Identity
		Replace     = @{ nTSecurityDescriptor = $nTSecurityDescriptor }
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# update security on DNS record object
	try {
		Set-ADObject @SetADObject
	}
	catch {
		Write-Warning -Message "could not update security on AD object for DNS record with '$Name' name in '$ZoneName' zone on '$Server' server: $($_.Exception.Message)"
		return $_
	}

	# report and return
	Write-Host "$Hostname,$Name - updated access rules on AD object for DNS record with '$Name' name in '$ZoneName' zone on '$Server' server"
	return
}
