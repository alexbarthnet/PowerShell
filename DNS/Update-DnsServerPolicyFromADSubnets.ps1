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
 - A client subnet object containing from subnets in Active Directory Sites and Services where the Location attribute matches the value provided for the Location parameter.
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
	[string]$SubnetSuffix = 'subnets',
	# suffix for DNS client subnet
	[Parameter(DontShow)]
	[string]$PolicySuffix = 'default',
	# filter for AD subnet objects
	[Parameter(Position = 0)]
	[string]$Filter = "Location -eq 'Default'"
)

# define DNS client subnets name
$DnsSubnetName = $HostName, $SubnetSuffix -join '-'

# retrieve DNS client subnets
Try {
	$DnsSubnet = Get-DnsServerClientSubnet | Where-Object { $_.Name -eq $DnsSubnetName }
}
Catch {
	Write-Warning -Message 'could not retrieve DNS subnets'
	Return $_
}

# if subnets not found...
If (!$DnsSubnet) {
	# define required parameters for default DNS subnets
	$AddDnsServerClientSubnet = @{
		Name         = $DnsSubnetName
		ComputerName = $DnsHostName
		IPv4Subnet   = '127.0.0.1/8'
		IPv6Subnet   = '::1/128'
		PassThru     = $true
		ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
	}

	# create default DNS subnets
	Try {
		$DnsSubnet = Add-DnsServerClientSubnet @AddDnsServerClientSubnet
	}
	Catch {
		Write-Warning -Message 'could not create default DNS subnet'
		Return $_
	}

	# declare default DNS subnets created
	Write-Host "Created '$($DnsSubnet.Name)' DNS client subnet with default values"
}

# define DNS query resolution policy
$DnsPolicyName = $HostName, $PolicySuffix -join '-'

# retrieve DNS query resolution policy
Try {
	$DnsPolicy = Get-DnsServerQueryResolutionPolicy | Where-Object { $_.Name -eq $DnsPolicyName }
}
Catch {
	Write-Warning -Message 'could not retrieve DNS policies'
	Return $_
}

# if policy not found...
If (!$DnsPolicy) {
	# define required parameters for default DNS policy
	$AddDnsServerQueryResolutionPolicy = @{
		Name            = $DnsPolicyName
		ComputerName    = $DnsHostName
		Action          = 'DENY'
		Condition       = 'AND'
		ClientSubnet    = "EQ,$DnsSubnetName"
		Fqdn            = 'EQ,domain.example'
		ProcessingOrder = 1
		PassThru        = $true
		ErrorAction     = [System.Management.Automation.ActionPreference]::Stop
	}

	# create default DNS policy
	Try {
		$DnsPolicy = Add-DnsServerQueryResolutionPolicy @AddDnsServerQueryResolutionPolicy
	}
	Catch {
		Write-Warning -Message 'could not create default DNS Policy'
		Return $_
	}

	# declare default DNS policy created
	Write-Host "Created '$($DnsSubnet.Name)' DNS policy with default values"
}

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
	Write-Warning -Message "could not locate any AD Replication Subnets with matching filter: $Filter"
	Return
}

# get primary DNS zones from AD sorted by zone type and name
Try {
	$DnsServerZones = Get-DnsServerZone -ComputerName $DomainController | Where-Object { $_.ZoneType -eq 'Primary' -and $_.IsDsIntegrated -and -not $_.IsAutoCreated } | Sort-Object -Property 'IsReverseLookupZone', 'ZoneName'
}
Catch {
	Write-Warning -Message "could not retrieve DNS server zones from domain controller: $DomainController"
	Return $_
}

# if primary DNS zones not found...
If (!$DnsServerZones) {
	Write-Warning -Message 'could not locate any primary DNS Server Zones'
	Return
}

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
	If ($IPv4Subnet -notin $DnsSubnet.IPV4Subnet) {
		Write-Host "Will update '$DnsSubnetName' client subnet to add subnet: $IPv4Subnet"
		$UpdateIPv4 = $true
	}
	Else {
		Write-Host "Verified '$DnsSubnetName' client subnet contains subnet: $IPv4Subnet"
	}
}

# check expected IPv6 DNS client subnets
ForEach ($IPv6Subnet in $IPv6Subnets) {
	If ($IPv6Subnet -notin $DnsSubnet.IPV6Subnet) {
		Write-Host "Will update '$($DnsSubnet.Name)' client subnet to add subnet: $IPv6Subnet"
		$UpdateIPv6 = $true
	}
	Else {
		Write-Host "Verified '$($DnsSubnet.Name)' client subnet contains subnet: $IPv6Subnet"
	}
}

# check existing IPv4 DNS client subnets
ForEach ($IPV4Subnet in $DnsSubnet.IPV4Subnet) {
	If ($IPv4Subnet -notin $IPv4Subnets) {
		Write-Host "Will update '$($DnsSubnet.Name)' client subnet to remove subnet: $IPv4Subnet"
		$UpdateIPv4 = $true
	}
}

# check existing IPv6 DNS client subnets
ForEach ($IPV6Subnet in $DnsSubnet.IPV6Subnet) {
	If ($IPV6Subnet -notin $IPv6Subnets) {
		Write-Host "Will update '$DnsSubnetName' client subnet to remove subnet: $IPv6Subnet"
		$UpdateIPv6 = $true
	}
}

# if update to IPv4 subnets required...
If ($UpdateIPv4) {
	Try {
		Set-DnsServerClientSubnet -Name $DnsSubnetName -IPv4Subnet $IPv4Subnets -Action 'REPLACE'
	}
	Catch {
		Write-Warning -Message "could not update DNS subnet: $DnsSubnetName"
		Return $_
	}
}

# if update to IPv6 subnets required...
If ($UpdateIPv6) {
	Try {
		Set-DnsServerClientSubnet -Name $DnsSubnetName -IPv6Subnet $IPv6Subnets -Action 'REPLACE'
	}
	Catch {
		Write-Warning -Message "could not update DNS subnet: $DnsSubnetName"
		Return $_
	}

	# declare DNS subnets created
	Write-Host "Updated IPv6 subnets in '$DnsSubnetName' DNS client subnet"
}

# update DNS server zones with prefix and suffix
Try {
	$DnsPolicyFqdnsFromServer = ($DnsServerZones.ZoneName | ForEach-Object { "*.$_." })
}
Catch {
	Return $_
}

# join DNS server zones into single string
Try {
	$DnsPolicyFqdn = $DnsPolicyFqdnsFromServer -join ','
}
Catch {
	Return $_
}

# verify DNS policy action
If ($DnsPolicy.Action -ne 'DENY') {
	Write-Host "Will remake '$DnsPolicyName' policy to fix invalie action: $($DnsPolicy.Action)"
	$RemakePolicy = $true
}

# verify DNS policy processing order
If ($DnsPolicy.ProcessingOrder -ne 1) {
	Write-Host "Will update '$DnsPolicyName' policy to address invalid processsing order: $($DnsPolicy.ProcessingOrder)"
	$UpdatePolicy = $true
}

# verify DNS policy condition
If ($DnsPolicy.Condition -ne 'AND') {
	Write-Host "Will update '$DnsPolicyName' policy to address invalid condition: $($DnsPolicy.Condition)"
	$UpdatePolicy = $true
}

# verify DNS policy contains client subnet criteria
If (!$DnsPolicy.Criteria.Where({ $_.CriteriaType -eq 'ClientSubnet' })) {
	Write-Host "Will update '$DnsPolicyName' policy to add missing client subnet criteria"
	$UpdatePolicy = $true
}
# verify DNS policy contains 1 client subnet criteria
ElseIf ($DnsPolicy.Criteria.Where({ $_.CriteriaType -eq 'ClientSubnet' }).Count -gt 1) {
	Write-Host "Will update '$DnsPolicyName' policy to remove extra client subnet criteria"
	$UpdatePolicy = $true
}
# verify DNS policy contains expected client subnet criteria
ElseIf ($DnsPolicy.Criteria.Where({ $_.CriteriaType -eq 'ClientSubnet' }).Criteria -ne "NE,$DnsSubnetName") {
	Write-Host "Will update '$DnsPolicyName' policy to refresh client subnet criteria"
	$UpdatePolicy = $true
}
Else {
	Write-Host "Verified '$DnsPolicyName' policy contains client subnet criteria: 'NE,$DnsSubnetName'"
}

# verify DNS policy contains Fqdn criteria
If (!$DnsPolicy.Criteria.Where({ $_.CriteriaType -eq 'Fqdn' })) {
	Write-Host "Will update '$DnsPolicyName' policy to add missing domain filter criteria"
	$UpdatePolicy = $true
}
# verify DNS policy contains 1 Fqdn criteria
ElseIf ($DnsPolicy.Criteria.Where({ $_.CriteriaType -eq 'Fqdn' }).Count -gt 1) {
	Write-Host "Will update '$DnsPolicyName' policy to remove extra domain filter criteria"
	$UpdatePolicy = $true
}
# verify DNS policy contains expected Fqdn criteria
ElseIf ($DnsPolicy.Criteria.Where({ $_.CriteriaType -eq 'Fqdn' }).Criteria -ne "NE,$DnsPolicyFqdn") {
	Write-Host "Will update '$DnsPolicyName' policy to refresh domain filter criteria"
	$UpdatePolicy = $true
	# retrieve FQDNs in policy
	$DnsPolicyFqdnsFromPolicy = $DnsPolicy.Criteria.Where({ $_.CriteriaType -eq 'Fqdn' }).Criteria.Split(',', 2)[1].Split(',')
	# report FQDNs from policy to remove
	:NextFqdn ForEach ($Fqdn in $DnsPolicyFqdnsFromPolicy) {
		If ($Fqdn -notin $DnsPolicyFqdnsFromServer) {
			Write-Host "Will update '$DnsPolicyName' policy to remove FQDN criteria: 'NE,$Fqdn'"
		}
		Else {
			Write-Host "Verified '$DnsPolicyName' policy contains effective FQDN criteria: 'NE,$Fqdn'"
		}
	}
	# report FQDNs from server to add
	:NextFqdn ForEach ($Fqdn in $DnsPolicyFqdnsFromServer) {
		If ($Fqdn -notin $DnsPolicyFqdnsFromPolicy) {
			Write-Host "Will update '$DnsPolicyName' policy to add FQDN criteria: 'NE,$Fqdn'"
		}
	}
}
Else {
	ForEach ($Fqdn in $DnsPolicyFqdnsFromServer) {
		Write-Host "Verified '$DnsPolicyName' policy contains effective FQDN criteria: 'NE,$Fqdn'"
	}
}

# if update to policy required...
If ($UpdatePolicy -or $RemakePolicy) {
	# define parameters for DnsServerQueryResolutionPolicy
	$DnsServerQueryResolutionPolicy = @{
		Name            = $DnsPolicyName
		ComputerName    = $DnsHostName
		Condition       = 'AND'
		ClientSubnet    = "NE,$DnsSubnetName"
		Fqdn            = "NE,$DnsPolicyFqdn"
		ProcessingOrder = 1
		ErrorAction     = [System.Management.Automation.ActionPreference]::Stop
	}

	# if remake required requested...
	If ($RemakePolicy) {
		# remove existing DNS server policy
		Try {
			Remove-DnsServerQueryResolutionPolicy -Name $DnsPolicyName -Force
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

		# declare remade
		Write-Host "Remade '$DnsPolicyName' DNS policy"
	}
	Else {
		# update DNS server policy
		Try {
			Set-DnsServerQueryResolutionPolicy @DnsServerQueryResolutionPolicy
		}
		Catch {
			Write-Warning -Message 'could not update existing DNS policy'
			Return $_
		}

		# declare updated
		Write-Host "Updated '$DnsPolicyName' DNS policy"
	}
}
Else {
	# declare verified
	Write-Host "Verified '$DnsPolicyName' DNS policy"
}
