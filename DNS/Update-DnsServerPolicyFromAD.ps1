#requires -Modules DnsServer,ActiveDirectory

<#
.SYNOPSIS
Configures DNS Policy to enable a DNS server to act as a recursive DNS resolver for approved DNS clients and an authoritative name server for all other DNS clients.

.DESCRIPTION
Creates and updates DNS Policy client subnet and query resolution policy objects using information from Active Directory subnets and Active Directory integrated DNS zones, respectively. See the Note section for more details.

.PARAMETER Filter
String parameter to filter Active Directory subnet objects. The default value is "Location -eq 'Default'".

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Update-DnsServerPolicyFromAD.ps1

.EXAMPLE
.\Update-DnsServerPolicyFromAD.ps1 -Filter "Location -match '-AD$'"

.EXAMPLE
.\Update-DnsServerPolicyFromAD.ps1 -Filter "Location -match '^DNS-'"

.NOTES
This script creates and updates two DNS Policy objects on a DNS server:
 - A client subnet object containing from subnets in Active Directory Sites and Services that match the Filter parameter.
 - A query resolution policy that blocks queries which do not originate from an IP address in the client subnet object and that are not for records in a DS-integrated DNS zone.
#>

param(
	# type for DNS zones
	[Parameter(DontShow)]
	[string[]]$ZoneType = @('Primary', 'Forwarder'),
	# local computer name
	[Parameter(DontShow)]
	[string]$ComputerName = $env:COMPUTERNAME.ToLowerInvariant(),
	# domain role of current system
	[Parameter(DontShow)]
	[uint16]$DomainRole = (Get-CimInstance -ClassName 'Win32_ComputerSystem' -Property 'DomainRole').DomainRole,
	# current PDC role holder
	[Parameter(DontShow)]
	[string]$PdcRoleOwner = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().PdcRoleOwner.Name,
	# filter for AD subnet objects
	[Parameter(Position = 0)]
	[string]$Filter = "Location -eq 'Default'",
	# switch to skip localhost policy
	[switch]$SkipLocalhostPolicy,
	# switch to skip recursion policy
	[switch]$SkipRecursionPolicy
)

################################
# determine AD role
################################

# define domain controller for subnets and DNS zones
if ($DomainRole -lt 4) {
	$DomainController = $PdcRoleOwner
}
else {
	$DomainController = $ComputerName
}

################################
# retrieve AD subnets
################################

# get subnet objects from AD sorted by name
try {
	$ADReplicationSubnets = Get-ADReplicationSubnet -Server $DomainController -Filter $Filter | Sort-Object -Property 'Name'
}
catch {
	Write-Warning -Message "could not retrieve AD Replication Subnets from domain controller: $DomainController"
	return $_
}

# if subnet objects not found matching location...
if (!$ADReplicationSubnets) {
	Write-Warning -Message "could not locate any AD Replication Subnets matching filter: $Filter"
	return
}

# retrieve subnets from object names
$Subnets = $ADReplicationSubnets.Name

################################
# retrieve DNS zones
################################

# get primary DNS zones from AD sorted by zone type and name
try {
	$DnsServerZones = Get-DnsServerZone -ComputerName $DomainController | Where-Object { $_.ZoneType -in $ZoneType -and $_.IsDsIntegrated -and -not $_.IsAutoCreated -and -not $_.IgnorePolicies } | Sort-Object -Property 'IsReverseLookupZone', 'ZoneName'
}
catch {
	Write-Warning -Message "could not retrieve DNS server zones from domain controller: $DomainController"
	return $_
}

# if primary DNS zones not found...
if (!$DnsServerZones) {
	Write-Warning -Message "could not locate any DNS Server Zones matching zone types: $($ZoneType -join ',')"
	return
}

# get forward primary DNS zones
$ForwardDnsServerZones = $DnsServerZones | Where-Object { !$_.IsReverseLookupZone }

################################
# retrieve DNS policy objects
################################

# retrieve DNS client subnets
try {
	$ClientSubnets = Get-DnsServerClientSubnet
}
catch {
	Write-Warning -Message 'could not retrieve DNS subnets'
	return $_
}

# retrieve DNS query resolution policies
try {
	$QueryResolutionPolicies = Get-DnsServerQueryResolutionPolicy
}
catch {
	Write-Warning -Message 'could not retrieve DNS policies'
	return $_
}

# if skip localhost policy not requested...
if (!$SkipLocalhostPolicy.IsPresent) {
	# define name for localhost policy
	$QueryResolutionPolicyName = "$ComputerName-localhost"

	# define query action
	$QueryAction = 'DENY'

	# define policy processing order
	$PolicyProcessingOrder = 1

	################################
	# define FQDN criteria
	################################

	# create list for FQDNs from DNS server zones
	$FqdnsForPolicy = [System.Collections.Generic.List[System.String]]::new()

	# process forward DNS server zone names
	foreach ($ZoneName in $ForwardDnsServerZones.ZoneName) {
		# create FQDN string as DNS server zone name with wildcard prefix and terminating suffix
		$FqdnsForPolicy.Add("localhost.$ZoneName.")
	}

	# join FQDN strings into FQDN criteria
	try {
		$FqdnCriteria = $FqdnsForPolicy -join ','
	}
	catch {
		return $_
	}

	################################
	# create DNS policy
	################################

	# filter DNS query resolution policies
	$QueryResolutionPolicy = $QueryResolutionPolicies | Where-Object { $_.Name -eq $QueryResolutionPolicyName }

	# if DNS query resolution policy not found...
	if (!$QueryResolutionPolicy) {
		# define required parameters for default DNS policy
		$AddDnsServerQueryResolutionPolicy = @{
			Name            = $QueryResolutionPolicyName
			ComputerName    = $ComputerName
			Action          = $QueryAction
			Fqdn            = 'EQ,domain.example'
			ProcessingOrder = $PolicyProcessingOrder
			PassThru        = $true
			ErrorAction     = [System.Management.Automation.ActionPreference]::Stop
		}

		# create default DNS policy
		try {
			$QueryResolutionPolicy = Add-DnsServerQueryResolutionPolicy @AddDnsServerQueryResolutionPolicy
		}
		catch {
			Write-Warning -Message 'could not create default DNS Policy'
			return $_
		}

		# declare default DNS policy created
		Write-Host "Created '$($QueryResolutionPolicy.Name)' DNS policy with default values"
	}

	# refresh DNS query resolution policy name
	$QueryResolutionPolicyName = $QueryResolutionPolicy.Name

	################################
	# update DNS policy
	################################

	# verify DNS policy action
	if ($QueryResolutionPolicy.Action -ne $QueryAction) {
		Write-Host "Will remake '$QueryResolutionPolicyName' policy to fix invalid action: $($QueryResolutionPolicy.Action)"
		$RemakePolicy = $true
	}

	# verify DNS policy processing order
	if ($QueryResolutionPolicy.ProcessingOrder -ne $PolicyProcessingOrder) {
		Write-Host "Will update '$QueryResolutionPolicyName' policy to address invalid processsing order: $($QueryResolutionPolicy.ProcessingOrder)"
		$UpdatePolicy = $true
	}

	# verify DNS policy contains FQDN criteria
	if (!$QueryResolutionPolicy.Criteria.Where({ $_.CriteriaType -eq 'Fqdn' })) {
		Write-Host "Will update '$QueryResolutionPolicyName' policy to add missing domain filter criteria"
		$UpdatePolicy = $true
	}
	# verify DNS policy contains 1 FQDN criteria
	elseif ($QueryResolutionPolicy.Criteria.Where({ $_.CriteriaType -eq 'Fqdn' }).Count -gt 1) {
		Write-Host "Will update '$QueryResolutionPolicyName' policy to remove extra domain filter criteria"
		$UpdatePolicy = $true
	}
	# verify DNS policy contains expected FQDN criteria
	elseif ($QueryResolutionPolicy.Criteria.Where({ $_.CriteriaType -eq 'Fqdn' }).Criteria -ne "EQ,$FqdnCriteria") {
		Write-Host "Will update '$QueryResolutionPolicyName' policy to refresh domain filter criteria"
		$UpdatePolicy = $true
		# retrieve FQDN criteria string
		$Criteria = $QueryResolutionPolicy.Criteria.Where({ $_.CriteriaType -eq 'Fqdn' }).Criteria
		# if equality operator found...
		if ($Criteria.Contains('NE,')) {
			Write-Host "Will update '$QueryResolutionPolicyName' policy to remove NE operator from FQDN criteria"
		}
		else {
			# retrieve FQDNs in policy
			$FqdnsFromCriteria = $Criteria.Split(',').Where({ $_ -ne 'EQ' })
			# report FQDNs from policy to remove
			:NextFqdn foreach ($Fqdn in $FqdnsFromCriteria) {
				if ($Fqdn -notin $FqdnsForPolicy) {
					Write-Host "Will update '$QueryResolutionPolicyName' policy to remove FQDN criteria: 'EQ,$Fqdn'"
				}
				else {
					Write-Host "Verified '$QueryResolutionPolicyName' policy contains effective FQDN criteria: 'EQ,$Fqdn'"
				}
			}
			# report FQDNs from server to add
			:NextFqdn foreach ($Fqdn in $FqdnsForPolicy) {
				if ($Fqdn -notin $FqdnsFromCriteria) {
					Write-Host "Will update '$QueryResolutionPolicyName' policy to add FQDN criteria: 'EQ,$Fqdn'"
				}
			}
		}
	}
	else {
		foreach ($Fqdn in $FqdnsForPolicy) {
			Write-Host "Verified '$QueryResolutionPolicyName' policy contains effective FQDN criteria: 'EQ,$Fqdn'"
		}
	}

	# if update to policy required...
	if ($UpdatePolicy -or $RemakePolicy) {
		# define parameters for DnsServerQueryResolutionPolicy
		$DnsServerQueryResolutionPolicy = @{
			Name            = $QueryResolutionPolicyName
			ComputerName    = $ComputerName
			Fqdn            = "EQ,$FqdnCriteria"
			ProcessingOrder = $PolicyProcessingOrder
			ErrorAction     = [System.Management.Automation.ActionPreference]::Stop
		}

		# if remake required requested...
		if ($RemakePolicy) {
			# remove existing DNS server policy
			try {
				Remove-DnsServerQueryResolutionPolicy -ComputerName $ComputerName -Name $QueryResolutionPolicyName -Force
			}
			catch {
				Write-Warning -Message 'could not remove existing DNS policy'
				return $_
			}

			# add new DNS server policy
			try {
				Add-DnsServerQueryResolutionPolicy -Action $QueryAction @DnsServerQueryResolutionPolicy
			}
			catch {
				Write-Warning -Message 'could not add new DNS policy'
				return $_
			}

			# declare remade and return
			Write-Host "Remade '$QueryResolutionPolicyName' DNS policy"
		}

		# if update required requested...
		if ($UpdatePolicy) {
			# update DNS server policy
			try {
				Set-DnsServerQueryResolutionPolicy @DnsServerQueryResolutionPolicy
			}
			catch {
				Write-Warning -Message 'could not update existing DNS policy'
				return $_
			}

			# declare updated and return
			Write-Host "Updated '$QueryResolutionPolicyName' DNS policy"
		}
	}
	else {
		# declare verified
		Write-Host "Verified '$QueryResolutionPolicyName' DNS policy"
	}
}

# if skip recursion policy not requested...
if (!$SkipRecursionPolicy.IsPresent) {
	# define name for policy
	$QueryResolutionPolicyName = "$ComputerName-recursion"

	# define action for query
	$QueryAction = 'DENY'

	# define policy processing order
	if ($SkipLocalhostPolicy.IsPresent) {
		$PolicyProcessingOrder = 1
	}
	else {
		$PolicyProcessingOrder = 2
	}

	################################
	# define FQDN criteria
	################################

	# create list for FQDNs from DNS server zones
	$FqdnsForPolicy = [System.Collections.Generic.List[System.String]]::new()

	# process DNS server zone names
	foreach ($ZoneName in $DnsServerZones.ZoneName) {
		# create FQDN string as DNS server zone name with wildcard prefix and terminating suffix
		$FqdnsForPolicy.Add("*.$ZoneName.")
	}

	# join FQDN strings into FQDN criteria
	try {
		$FqdnCriteria = $FqdnsForPolicy -join ','
	}
	catch {
		return $_
	}

	################################
	# create DNS client subnet
	################################

	# define name for DNS client subnet
	$ClientSubnetName = "$ComputerName-recursion"

	# filter DNS client subnets
	$ClientSubnet = $ClientSubnets | Where-Object { $_.Name -eq $ClientSubnetName }

	# if DNS client subnet not found...
	if (!$ClientSubnet) {
		# define required parameters for default DNS subnets
		$AddDnsServerClientSubnet = @{
			Name         = $ClientSubnetName
			ComputerName = $ComputerName
			IPv4Subnet   = '127.0.0.1/8'
			IPv6Subnet   = '::1/128'
			PassThru     = $true
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# create default DNS subnets
		try {
			$ClientSubnet = Add-DnsServerClientSubnet @AddDnsServerClientSubnet
		}
		catch {
			Write-Warning -Message 'could not create default DNS subnet'
			return $_
		}

		# declare default DNS subnets created
		Write-Host "Created '$($ClientSubnet.Name)' DNS client subnet with default values"
	}

	# refresh DNS client subnet name
	$ClientSubnetName = $ClientSubnet.Name

	################################
	# update DNS client subnet
	################################

	# define lists for subnets
	$IPv4Subnets = [System.Collections.Generic.List[string]]::new()
	$IPv6Subnets = [System.Collections.Generic.List[string]]::new()

	# add loopback subnets lists
	$IPv4Subnets.Add('127.0.0.0/8')
	$IPv6Subnets.Add('::1/128')

	# add replication subnets to lists
	foreach ($Subnet in $Subnets) {
		switch ($Subnet) {
			{ $_.Contains('.') } { $IPv4Subnets.Add($_) }
			{ $_.Contains(':') } { $IPv6Subnets.Add($_) }
		}
	}

	# check expected IPv4 DNS client subnets
	foreach ($IPv4Subnet in $IPv4Subnets) {
		if ($IPv4Subnet -notin $ClientSubnet.IPV4Subnet) {
			Write-Host "Will update '$ClientSubnetName' client subnet to add subnet: $IPv4Subnet"
			$UpdateIPv4 = $true
		}
		else {
			Write-Host "Verified '$ClientSubnetName' client subnet contains subnet: $IPv4Subnet"
		}
	}

	# check expected IPv6 DNS client subnets
	foreach ($IPv6Subnet in $IPv6Subnets) {
		if ($IPv6Subnet -notin $ClientSubnet.IPV6Subnet) {
			Write-Host "Will update '$ClientSubnetName' client subnet to add subnet: $IPv6Subnet"
			$UpdateIPv6 = $true
		}
		else {
			Write-Host "Verified '$ClientSubnetName' client subnet contains subnet: $IPv6Subnet"
		}
	}

	# check existing IPv4 DNS client subnets
	foreach ($IPV4Subnet in $ClientSubnet.IPV4Subnet) {
		if ($IPv4Subnet -notin $IPv4Subnets) {
			Write-Host "Will update '$ClientSubnetName' client subnet to remove subnet: $IPv4Subnet"
			$UpdateIPv4 = $true
		}
	}

	# check existing IPv6 DNS client subnets
	foreach ($IPV6Subnet in $ClientSubnet.IPV6Subnet) {
		if ($IPV6Subnet -notin $IPv6Subnets) {
			Write-Host "Will update '$ClientSubnetName' client subnet to remove subnet: $IPv6Subnet"
			$UpdateIPv6 = $true
		}
	}

	# if update to IPv4 subnets required...
	if ($UpdateIPv4) {
		try {
			Set-DnsServerClientSubnet -ComputerName $ComputerName -Name $ClientSubnetName -IPv4Subnet $IPv4Subnets -Action 'REPLACE'
		}
		catch {
			Write-Warning -Message "could not update IPv4 subnets in DNS client subnet: $ClientSubnetName"
			return $_
		}

		# declare DNS subnets created
		Write-Host "Updated IPv4 subnets in '$ClientSubnetName' DNS client subnet"
	}

	# if update to IPv6 subnets required...
	if ($UpdateIPv6) {
		try {
			Set-DnsServerClientSubnet -ComputerName $ComputerName -Name $ClientSubnetName -IPv6Subnet $IPv6Subnets -Action 'REPLACE'
		}
		catch {
			Write-Warning -Message "could not update IPv6 subnets in DNS client subnet: $ClientSubnetName"
			return $_
		}

		# declare DNS subnets created
		Write-Host "Updated IPv6 subnets in '$ClientSubnetName' DNS client subnet"
	}

	################################
	# create DNS policy
	################################

	# filter DNS query resolution policies
	$QueryResolutionPolicy = $QueryResolutionPolicies | Where-Object { $_.Name -eq $QueryResolutionPolicyName }

	# if DNS query resolution policy not found...
	if (!$QueryResolutionPolicy) {
		# define required parameters for default DNS policy
		$AddDnsServerQueryResolutionPolicy = @{
			Name            = $QueryResolutionPolicyName
			ComputerName    = $ComputerName
			Action          = $QueryAction
			Condition       = 'AND'
			ClientSubnet    = "EQ,$ClientSubnetName"
			Fqdn            = 'EQ,domain.example'
			ProcessingOrder = $PolicyProcessingOrder
			PassThru        = $true
			ErrorAction     = [System.Management.Automation.ActionPreference]::Stop
		}

		# create default DNS policy
		try {
			$QueryResolutionPolicy = Add-DnsServerQueryResolutionPolicy @AddDnsServerQueryResolutionPolicy
		}
		catch {
			Write-Warning -Message 'could not create default DNS Policy'
			return $_
		}

		# declare default DNS policy created
		Write-Host "Created '$($QueryResolutionPolicy.Name)' DNS policy with default values"
	}

	# refresh DNS query resolution policy name
	$QueryResolutionPolicyName = $QueryResolutionPolicy.Name

	################################
	# update DNS policy
	################################

	# verify DNS policy action
	if ($QueryResolutionPolicy.Action -ne $QueryAction) {
		Write-Host "Will remake '$QueryResolutionPolicyName' policy to fix invalid action: $($QueryResolutionPolicy.Action)"
		$RemakePolicy = $true
	}

	# verify DNS policy processing order
	if ($QueryResolutionPolicy.ProcessingOrder -ne $PolicyProcessingOrder) {
		Write-Host "Will update '$QueryResolutionPolicyName' policy to address invalid processsing order: $($QueryResolutionPolicy.ProcessingOrder)"
		$UpdatePolicy = $true
	}

	# verify DNS policy condition
	if ($QueryResolutionPolicy.Condition -ne 'AND') {
		Write-Host "Will update '$QueryResolutionPolicyName' policy to address invalid condition: $($QueryResolutionPolicy.Condition)"
		$UpdatePolicy = $true
	}

	# verify DNS policy contains client subnet criteria
	if (!$QueryResolutionPolicy.Criteria.Where({ $_.CriteriaType -eq 'ClientSubnet' })) {
		Write-Host "Will update '$QueryResolutionPolicyName' policy to add missing client subnet criteria"
		$UpdatePolicy = $true
	}
	# verify DNS policy contains 1 client subnet criteria
	elseif ($QueryResolutionPolicy.Criteria.Where({ $_.CriteriaType -eq 'ClientSubnet' }).Count -gt 1) {
		Write-Host "Will update '$QueryResolutionPolicyName' policy to remove extra client subnet criteria"
		$UpdatePolicy = $true
	}
	# verify DNS policy contains expected client subnet criteria
	elseif ($QueryResolutionPolicy.Criteria.Where({ $_.CriteriaType -eq 'ClientSubnet' }).Criteria -ne "NE,$ClientSubnetName") {
		Write-Host "Will update '$QueryResolutionPolicyName' policy to refresh client subnet criteria"
		$UpdatePolicy = $true
	}
	else {
		Write-Host "Verified '$QueryResolutionPolicyName' policy contains client subnet criteria: 'NE,$ClientSubnetName'"
	}

	# verify DNS policy contains FQDN criteria
	if (!$QueryResolutionPolicy.Criteria.Where({ $_.CriteriaType -eq 'Fqdn' })) {
		Write-Host "Will update '$QueryResolutionPolicyName' policy to add missing domain filter criteria"
		$UpdatePolicy = $true
	}
	# verify DNS policy contains 1 FQDN criteria
	elseif ($QueryResolutionPolicy.Criteria.Where({ $_.CriteriaType -eq 'Fqdn' }).Count -gt 1) {
		Write-Host "Will update '$QueryResolutionPolicyName' policy to remove extra domain filter criteria"
		$UpdatePolicy = $true
	}
	# verify DNS policy contains expected FQDN criteria
	elseif ($QueryResolutionPolicy.Criteria.Where({ $_.CriteriaType -eq 'Fqdn' }).Criteria -ne "NE,$FqdnCriteria") {
		Write-Host "Will update '$QueryResolutionPolicyName' policy to refresh domain filter criteria"
		$UpdatePolicy = $true
		# retrieve FQDN criteria string
		$Criteria = $QueryResolutionPolicy.Criteria.Where({ $_.CriteriaType -eq 'Fqdn' }).Criteria
		# if equality operator found...
		if ($Criteria.Contains('EQ,')) {
			Write-Host "Will update '$QueryResolutionPolicyName' policy to remove EQ operator from FQDN criteria"
		}
		else {
			# retrieve FQDNs in policy
			$FqdnsFromCriteria = $Criteria.Split(',').Where({ $_ -ne 'NE' })
			# report FQDNs from policy to remove
			:NextFqdn foreach ($Fqdn in $FqdnsFromCriteria) {
				if ($Fqdn -notin $FqdnsForPolicy) {
					Write-Host "Will update '$QueryResolutionPolicyName' policy to remove FQDN criteria: 'NE,$Fqdn'"
				}
				else {
					Write-Host "Verified '$QueryResolutionPolicyName' policy contains effective FQDN criteria: 'NE,$Fqdn'"
				}
			}
			# report FQDNs from server to add
			:NextFqdn foreach ($Fqdn in $FqdnsForPolicy) {
				if ($Fqdn -notin $FqdnsFromCriteria) {
					Write-Host "Will update '$QueryResolutionPolicyName' policy to add FQDN criteria: 'NE,$Fqdn'"
				}
			}
		}
	}
	else {
		foreach ($Fqdn in $FqdnsForPolicy) {
			Write-Host "Verified '$QueryResolutionPolicyName' policy contains effective FQDN criteria: 'NE,$Fqdn'"
		}
	}

	# if update to policy required...
	if ($UpdatePolicy -or $RemakePolicy) {
		# define parameters for DnsServerQueryResolutionPolicy
		$DnsServerQueryResolutionPolicy = @{
			Name            = $QueryResolutionPolicyName
			ComputerName    = $ComputerName
			Condition       = 'AND'
			ClientSubnet    = "NE,$ClientSubnetName"
			Fqdn            = "NE,$FqdnCriteria"
			ProcessingOrder = $PolicyProcessingOrder
			ErrorAction     = [System.Management.Automation.ActionPreference]::Stop
		}

		# if remake required requested...
		if ($RemakePolicy) {
			# remove existing DNS server policy
			try {
				Remove-DnsServerQueryResolutionPolicy -ComputerName $ComputerName -Name $QueryResolutionPolicyName -Force
			}
			catch {
				Write-Warning -Message 'could not remove existing DNS policy'
				return $_
			}

			# add new DNS server policy
			try {
				Add-DnsServerQueryResolutionPolicy -Action $QueryAction @DnsServerQueryResolutionPolicy
			}
			catch {
				Write-Warning -Message 'could not add new DNS policy'
				return $_
			}

			# declare remade and return
			Write-Host "Remade '$QueryResolutionPolicyName' DNS policy"
		}

		# if update required requested...
		if ($UpdatePolicy) {
			# update DNS server policy
			try {
				Set-DnsServerQueryResolutionPolicy @DnsServerQueryResolutionPolicy
			}
			catch {
				Write-Warning -Message 'could not update existing DNS policy'
				return $_
			}

			# declare updated and return
			Write-Host "Updated '$QueryResolutionPolicyName' DNS policy"

		}
	}
	else {
		# declare verified
		Write-Host "Verified '$QueryResolutionPolicyName' DNS policy"
	}
}


# filter DNS query resolution policies for old name
$QueryResolutionPolicy = $QueryResolutionPolicies | Where-Object { $_.Name -eq "$ComputerName-default" }

# if policy with old name found...
If ($QueryResolutionPolicy) {
	# refresh DNS query resolution policy name
	$QueryResolutionPolicyName = $QueryResolutionPolicy.Name

	# remove DNS query resolution policy
	try {
		Remove-DnsServerQueryResolutionPolicy -Name $QueryResolutionPolicyName -Force
	}
	catch {
		return $_
	}

	# declare removed
	Write-Host "Removed legacy '$QueryResolutionPolicyName' DNS policy"
}

# filter client subnets for old name
$ClientSubnet = $ClientSubnets | Where-Object { $_.Name -eq "$ComputerName-subnets" }

# if client subnets with old name found...
If ($ClientSubnet) {
	# refresh client subnet name
	$ClientSubnetName = $ClientSubnet.Name

	# remove client subnet
	try {
		Remove-DnsServerClientSubnet -Name $ClientSubnetName -Force
	}
	catch {
		return $_
	}

	# declare removed
	Write-Host "Removed legacy '$QueryResolutionPolicyName' client subnet"
}
