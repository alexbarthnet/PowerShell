#requires -Modules DnsServer,ActiveDirectory

<#
.SYNOPSIS
Configures DNS Policy to enable a DNS server to act as a recursive DNS resolver for approved DNS clients and an authoritative name server for all other DNS clients.

.DESCRIPTION
Creates and updates DNS Policy client subnet and query resolution policy objects using information from Active Directory subnets and Active Directory integrated DNS zones, respectively. See the Note section for more details.

.PARAMETER Location
String parameter to match against the location attribute of Active Directory subnet objects. The default value is 'Default'.

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Update-DnsServerPolicyFromADSubnets.ps1

.EXAMPLE
.\Update-DnsServerPolicyFromADSubnets.ps1 -Filter "Location -match '-AD$'"

.EXAMPLE
.\Update-DnsServerPolicyFromADSubnets.ps1 -Filter "Location -match '^DNS-'"

.NOTES
This script creates and updates two DNS Policy objects on a DNS server:
 - A client subnet object containing from subnets in Active Directory Sites and Services that match the Filter parameter.
 - A query resolution policy that blocks queries which do not originate from an IP address in the client subnet object and that are not for records in a DS-integrated DNS zone.
#>

Param(
	# local host name
	[Parameter(DontShow)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# local domain name
	[Parameter(DontShow)]
	[string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
	# local DNS hostname
	[Parameter(DontShow)]
	[string]$DnsHostName = ($HostName, $DomainName -join '.').TrimEnd('.'),
	# domain role of current system
	[Parameter(DontShow)]
	[uint16]$DomainRole = (Get-CimInstance -ClassName 'Win32_ComputerSystem' -Property 'DomainRole').DomainRole,
	# current PDC role holder
	[Parameter(DontShow)]
	[string]$PdcRoleOwner = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().PdcRoleOwner.Name,
	# suffix for DNS client subnet
	[Parameter(DontShow)]
	[string]$ClientSubnetName = "$HostName-subnets",
	# suffix for DNS client subnet
	[Parameter(DontShow)]
	[string]$QueryResolutionPolicyName = "$HostName-default",
	# filter for AD subnet objects
	[Parameter(Position = 0)]
	[string]$Filter = "Location -eq 'Default'",
	# filter for AD subnet objects
	[Parameter(Position = 2)]
	[string[]]$ZoneType = @('Primary', 'Forwarder')
)

### retrieve Active Directory objects

# define domain controller for subnets and DNS zones
If ($DomainRole -lt 4) {
	$DomainController = $PdcRoleOwner
}
Else {
	$DomainController = $DnsHostName
}

# get subnets from AD sorted by name
Try {
	$ADReplicationSubnets = Get-ADReplicationSubnet -Server $DomainController -Filter $Filter | Sort-Object -Property 'Name'
}
Catch {
	Write-Warning -Message "could not retrieve AD Replication Subnets from domain controller: $DomainController"
	Return $_
}

# if subnets not found matching location...
If (!$ADReplicationSubnets) {
	Write-Warning -Message "could not locate any AD Replication Subnets matching filter: $Filter"
	Return
}

# get primary DNS zones from AD sorted by zone type and name
Try {
	$DnsServerZones = Get-DnsServerZone -ComputerName $DomainController | Where-Object { $_.ZoneType -in $ZoneType -and $_.IsDsIntegrated -and -not $_.IsAutoCreated } | Sort-Object -Property 'IsReverseLookupZone', 'ZoneName'
}
Catch {
	Write-Warning -Message "could not retrieve DNS server zones from domain controller: $DomainController"
	Return $_
}

# if primary DNS zones not found...
If (!$DnsServerZones) {
	Write-Warning -Message "could not locate any DNS Server Zones matching zone types: $($ZoneType -join ',')"
	Return
}

### retrieve DNS server objects

# retrieve DNS client subnets
Try {
	$ClientSubnets = Get-DnsServerClientSubnet
}
Catch {
	Write-Warning -Message 'could not retrieve DNS subnets'
	Return $_
}

# filter DNS client subnets
$ClientSubnet = $ClientSubnets | Where-Object { $_.Name -eq $ClientSubnetName }

# if DNS client subnet not found...
If (!$ClientSubnet) {
	# define required parameters for default DNS subnets
	$AddDnsServerClientSubnet = @{
		Name         = $ClientSubnetName
		ComputerName = $DnsHostName
		IPv4Subnet   = '127.0.0.1/8'
		IPv6Subnet   = '::1/128'
		PassThru     = $true
		ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
	}

	# create default DNS subnets
	Try {
		$ClientSubnet = Add-DnsServerClientSubnet @AddDnsServerClientSubnet
	}
	Catch {
		Write-Warning -Message 'could not create default DNS subnet'
		Return $_
	}

	# declare default DNS subnets created
	Write-Host "Created '$($ClientSubnet.Name)' DNS client subnet with default values"
}

# retrieve DNS query resolution policies
Try {
	$QueryResolutionPolicies = Get-DnsServerQueryResolutionPolicy
}
Catch {
	Write-Warning -Message 'could not retrieve DNS policies'
	Return $_
}

# filter DNS query resolution policies
$QueryResolutionPolicy = $QueryResolutionPolicies | Where-Object { $_.Name -eq $QueryResolutionPolicyName }

# if DNS query resolution policy not found...
If (!$QueryResolutionPolicy) {
	# define required parameters for default DNS policy
	$AddDnsServerQueryResolutionPolicy = @{
		Name            = $QueryResolutionPolicyName
		ComputerName    = $DnsHostName
		Action          = 'DENY'
		Condition       = 'AND'
		ClientSubnet    = "EQ,$ClientSubnetName"
		Fqdn            = 'EQ,domain.example'
		ProcessingOrder = 1
		PassThru        = $true
		ErrorAction     = [System.Management.Automation.ActionPreference]::Stop
	}

	# create default DNS policy
	Try {
		$QueryResolutionPolicy = Add-DnsServerQueryResolutionPolicy @AddDnsServerQueryResolutionPolicy
	}
	Catch {
		Write-Warning -Message 'could not create default DNS Policy'
		Return $_
	}

	# declare default DNS policy created
	Write-Host "Created '$($QueryResolutionPolicy.Name)' DNS policy with default values"
}

### update DNS server client subnet

# define lists for subnets
$IPv4Subnets = [System.Collections.Generic.List[string]]::new()
$IPv6Subnets = [System.Collections.Generic.List[string]]::new()

# add loopback subnets lists
$IPv4Subnets.Add('127.0.0.0/8')
$IPv6Subnets.Add('::1/128')

# add replication subnets to lists
ForEach ($ADReplicationSubnet in $ADReplicationSubnets) {
	switch ($ADReplicationSubnet.Name) {
		{ $_.Contains('.') } { $IPv4Subnets.Add($_) }
		{ $_.Contains(':') } { $IPv6Subnets.Add($_) }
	}
}

# check expected IPv4 DNS client subnets
ForEach ($IPv4Subnet in $IPv4Subnets) {
	If ($IPv4Subnet -notin $ClientSubnet.IPV4Subnet) {
		Write-Host "Will update '$ClientSubnetName' client subnet to add subnet: $IPv4Subnet"
		$UpdateIPv4 = $true
	}
	Else {
		Write-Host "Verified '$ClientSubnetName' client subnet contains subnet: $IPv4Subnet"
	}
}

# check expected IPv6 DNS client subnets
ForEach ($IPv6Subnet in $IPv6Subnets) {
	If ($IPv6Subnet -notin $ClientSubnet.IPV6Subnet) {
		Write-Host "Will update '$($ClientSubnet.Name)' client subnet to add subnet: $IPv6Subnet"
		$UpdateIPv6 = $true
	}
	Else {
		Write-Host "Verified '$($ClientSubnet.Name)' client subnet contains subnet: $IPv6Subnet"
	}
}

# check existing IPv4 DNS client subnets
ForEach ($IPV4Subnet in $ClientSubnet.IPV4Subnet) {
	If ($IPv4Subnet -notin $IPv4Subnets) {
		Write-Host "Will update '$($ClientSubnet.Name)' client subnet to remove subnet: $IPv4Subnet"
		$UpdateIPv4 = $true
	}
}

# check existing IPv6 DNS client subnets
ForEach ($IPV6Subnet in $ClientSubnet.IPV6Subnet) {
	If ($IPV6Subnet -notin $IPv6Subnets) {
		Write-Host "Will update '$ClientSubnetName' client subnet to remove subnet: $IPv6Subnet"
		$UpdateIPv6 = $true
	}
}

# if update to IPv4 subnets required...
If ($UpdateIPv4) {
	Try {
		Set-DnsServerClientSubnet -Name $ClientSubnetName -IPv4Subnet $IPv4Subnets -Action 'REPLACE'
	}
	Catch {
		Write-Warning -Message "could not update IPv4 subnets in DNS client subnet: $ClientSubnetName"
		Return $_
	}

	# declare DNS subnets created
	Write-Host "Updated IPv4 subnets in '$ClientSubnetName' DNS client subnet"
}

# if update to IPv6 subnets required...
If ($UpdateIPv6) {
	Try {
		Set-DnsServerClientSubnet -Name $ClientSubnetName -IPv6Subnet $IPv6Subnets -Action 'REPLACE'
	}
	Catch {
		Write-Warning -Message "could not update IPv6 subnets in DNS client subnet: $ClientSubnetName"
		Return $_
	}

	# declare DNS subnets created
	Write-Host "Updated IPv6 subnets in '$ClientSubnetName' DNS client subnet"
}

### update DNS query resolution policy

# create list for FQDNs from DNS server zones
$FqdnsFromZones = [System.Collections.Generic.List[System.String]]::new()

# process DNS server zone names
ForEach ($ZoneName in $DnsServerZones.ZoneName) {
	# create FQDN string as DNS server zone name with wildcard prefix and terminating suffix
	$FqdnsFromZones.Add("*.$ZoneName.")
}

# join FQDN strings into FQDN criteria 
Try {
	$FqdnCriteria = $FqdnsFromZones -join ','
}
Catch {
	Return $_
}

# verify DNS policy action
If ($QueryResolutionPolicy.Action -ne 'DENY') {
	Write-Host "Will remake '$QueryResolutionPolicyName' policy to fix invalie action: $($QueryResolutionPolicy.Action)"
	$RemakePolicy = $true
}

# verify DNS policy processing order
If ($QueryResolutionPolicy.ProcessingOrder -ne 1) {
	Write-Host "Will update '$QueryResolutionPolicyName' policy to address invalid processsing order: $($QueryResolutionPolicy.ProcessingOrder)"
	$UpdatePolicy = $true
}

# verify DNS policy condition
If ($QueryResolutionPolicy.Condition -ne 'AND') {
	Write-Host "Will update '$QueryResolutionPolicyName' policy to address invalid condition: $($QueryResolutionPolicy.Condition)"
	$UpdatePolicy = $true
}

# verify DNS policy contains client subnet criteria
If (!$QueryResolutionPolicy.Criteria.Where({ $_.CriteriaType -eq 'ClientSubnet' })) {
	Write-Host "Will update '$QueryResolutionPolicyName' policy to add missing client subnet criteria"
	$UpdatePolicy = $true
}
# verify DNS policy contains 1 client subnet criteria
ElseIf ($QueryResolutionPolicy.Criteria.Where({ $_.CriteriaType -eq 'ClientSubnet' }).Count -gt 1) {
	Write-Host "Will update '$QueryResolutionPolicyName' policy to remove extra client subnet criteria"
	$UpdatePolicy = $true
}
# verify DNS policy contains expected client subnet criteria
ElseIf ($QueryResolutionPolicy.Criteria.Where({ $_.CriteriaType -eq 'ClientSubnet' }).Criteria -ne "NE,$ClientSubnetName") {
	Write-Host "Will update '$QueryResolutionPolicyName' policy to refresh client subnet criteria"
	$UpdatePolicy = $true
}
Else {
	Write-Host "Verified '$QueryResolutionPolicyName' policy contains client subnet criteria: 'NE,$ClientSubnetName'"
}

# verify DNS policy contains FQDN criteria
If (!$QueryResolutionPolicy.Criteria.Where({ $_.CriteriaType -eq 'Fqdn' })) {
	Write-Host "Will update '$QueryResolutionPolicyName' policy to add missing domain filter criteria"
	$UpdatePolicy = $true
}
# verify DNS policy contains 1 FQDN criteria
ElseIf ($QueryResolutionPolicy.Criteria.Where({ $_.CriteriaType -eq 'Fqdn' }).Count -gt 1) {
	Write-Host "Will update '$QueryResolutionPolicyName' policy to remove extra domain filter criteria"
	$UpdatePolicy = $true
}
# verify DNS policy contains expected FQDN criteria
ElseIf ($QueryResolutionPolicy.Criteria.Where({ $_.CriteriaType -eq 'Fqdn' }).Criteria -ne "NE,$FqdnCriteria") {
	Write-Host "Will update '$QueryResolutionPolicyName' policy to refresh domain filter criteria"
	$UpdatePolicy = $true
	# retrieve FQDN criteria string
	$Criteria = $QueryResolutionPolicy.Criteria.Where({ $_.CriteriaType -eq 'Fqdn' }).Criteria
	# if equality operator found...
	If ($Criteria.Contains('EQ,')) {
		Write-Host "Will update '$QueryResolutionPolicyName' policy to remove EQ operator from FQDN criteria"
	}
	Else {
		# retrieve FQDNs in policy
		$FqdnsFromCriteria = $Criteria.Split(',').Where({ $_ -ne 'NE' })
		# report FQDNs from policy to remove
		:NextFqdn ForEach ($Fqdn in $FqdnsFromCriteria) {
			If ($Fqdn -notin $FqdnsFromZones) {
				Write-Host "Will update '$QueryResolutionPolicyName' policy to remove FQDN criteria: 'NE,$Fqdn'"
			}
			Else {
				Write-Host "Verified '$QueryResolutionPolicyName' policy contains effective FQDN criteria: 'NE,$Fqdn'"
			}
		}
		# report FQDNs from server to add
		:NextFqdn ForEach ($Fqdn in $FqdnsFromZones) {
			If ($Fqdn -notin $FqdnsFromCriteria) {
				Write-Host "Will update '$QueryResolutionPolicyName' policy to add FQDN criteria: 'NE,$Fqdn'"
			}
		}
	}
}
Else {
	ForEach ($Fqdn in $FqdnsFromZones) {
		Write-Host "Verified '$QueryResolutionPolicyName' policy contains effective FQDN criteria: 'NE,$Fqdn'"
	}
}

# if update to policy required...
If ($UpdatePolicy -or $RemakePolicy) {
	# define parameters for DnsServerQueryResolutionPolicy
	$DnsServerQueryResolutionPolicy = @{
		Name            = $QueryResolutionPolicyName
		ComputerName    = $DnsHostName
		Condition       = 'AND'
		ClientSubnet    = "NE,$ClientSubnetName"
		Fqdn            = "NE,$FqdnCriteria"
		ProcessingOrder = 1
		ErrorAction     = [System.Management.Automation.ActionPreference]::Stop
	}

	# if remake required requested...
	If ($RemakePolicy) {
		# remove existing DNS server policy
		Try {
			Remove-DnsServerQueryResolutionPolicy -Name $QueryResolutionPolicyName -Force
		}
		Catch {
			Write-Warning -Message 'could not remove existing DNS policy'
			Return $_
		}

		# add new DNS server policy
		Try {
			Add-DnsServerQueryResolutionPolicy -Action 'DENY' @DnsServerQueryResolutionPolicy
		}
		Catch {
			Write-Warning -Message 'could not add new DNS policy'
			Return $_
		}

		# declare remade and return
		Write-Host "Remade '$QueryResolutionPolicyName' DNS policy"
		Return
	}

	# if update required requested...
	If ($UpdatePolicy) {
		# update DNS server policy
		Try {
			Set-DnsServerQueryResolutionPolicy @DnsServerQueryResolutionPolicy
		}
		Catch {
			Write-Warning -Message 'could not update existing DNS policy'
			Return $_
		}

		# declare updated and return
		Write-Host "Updated '$QueryResolutionPolicyName' DNS policy"
		Return
	}
}

# declare verified
Write-Host "Verified '$QueryResolutionPolicyName' DNS policy"
