using namespace System.DirectoryServices.Protocols

<#
.SYNOPSIS
Test if the 'dnsHostName' in the root DSE of the provided server matches the local DNS hostname.

.DESCRIPTION
Test if the 'dnsHostName' in the root DSE of the provided server matches the local DNS hostname.

.PARAMETER Server
The name of the server to test.

.PARAMETER Port
The port of the server to test. The default value is 636.

.PARAMETER SSL
Boolean to determine if a secure connection should be used. The default value is true.

.PARAMETER DnsHostName
The DNS host name of the local machine. The default value is constructed from values from the [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties() call.

.INPUTS
String.

.OUTPUTS
Boolean.

.EXAMPLE
.\Test-LdapForDnsHostname.ps1 -Server 'ldap.example.com'
#>

param(
	# filter for RootDSE
	[Parameter(DontShow)]
	[string]$Filter = '(objectClass=*)',
	# attributes for RootDSE
	[Parameter(DontShow)]
	[string]$Attribute = 'dnsHostName',
	# search base for RootDSE
	[Parameter(DontShow)][ValidateSet('Base', 'OneLevel', 'Subtree')]
	[string]$SearchBase = [string]::Empty,
	# search scope for RootDSE
	[Parameter(DontShow)][ValidateSet('Base', 'OneLevel', 'Subtree')]
	[string]$SearchScope = 'Base',
	# local host name
	[Parameter(DontShow)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# local domain name
	[Parameter(DontShow)]
	[string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
	# server to evaluate
	[Parameter(Position = 0, Mandatory = $True)]
	[string]$Server,
	# server to evaluate
	[Parameter(Position = 1)]
	[uint16]$Port = 636,
	# SSL state
	[Parameter(Position = 2)]
	[boolean]$SSL = $true,
	# local DNS hostname
	[Parameter(Position = 3)]
	[string]$DnsHostName = ($HostName, $DomainName -join '.').TrimEnd('.'),
	# switch to write response to a variable instead of to the pipeline
	[Parameter(Position = 4)]
	[switch]$AsVariable,
	# name of variable when AsVariable is true
	[Parameter(Position = 5)]
	[name]$VariableName = 'TestLdapForDnsHostname',
	# scope of variable when AsVariable is true
	[Parameter(Position = 6)]
	[name]$VariableScope = 'global'
)

# define LDAP identifer properties
$FullyQualifiedDnsHostName = $true
$Connectionless = $false

# create LDAP identifier
try {
	$LdapDirectoryIdentifier = [System.DirectoryServices.Protocols.LdapDirectoryIdentifier]::new($Server, $Port, $FullyQualifiedDnsHostName, $Connectionless)
}
catch {
	Write-Warning -Message "could not create 'LdapDirectoryIdentifier' object: $($_.Exception.Message)"
	throw $_
}

# create LDAP connection with LDAP identifier
try {
	$LdapConnection = [System.DirectoryServices.Protocols.LdapConnection]::new($LdapDirectoryIdentifier)
}
catch {
	Write-Warning -Message "could not create 'LdapConnection' object: $($_.Exception.Message)"
	throw $_
}

# update protocol settings for LDAP connection
$LdapConnection.SessionOptions.ProtocolVersion = 3
$LdapConnection.SessionOptions.ReferralChasing = [System.DirectoryServices.Protocols.ReferralChasingOptions]::None

# update security settings for LDAP connection 
$LdapConnection.AuthType = [System.DirectoryServices.Protocols.AuthType]::Anonymous
$LdapConnection.SessionOptions.SecureSocketLayer = $SSL

# create LDAP search request
try {
	$SearchRequest = [System.DirectoryServices.Protocols.SearchRequest]::new($SearchBase, $Filter, $SearchScope, $Attribute)
}
catch {
	Write-Warning -Message "could not create 'SearchRequest' object: $($_.Exception.Message)"
	throw $_
}

# bind to LDAP server
try {
	$LdapConnection.Bind()
}
catch {
	Write-Warning -Message "could not execute 'Bind' method on 'LdapConnection' object: $($_.Exception.Message)"
	throw $_
}

# submit LDAP query
try {
	$SearchResponse = [System.DirectoryServices.Protocols.SearchResponse]($LdapConnection.SendRequest($SearchRequest))
}
catch {
	Write-Warning -Message "could not execute 'SendRequest' method on 'LdapConnection' object: $($_.Exception.Message)"
	throw $_
}

# retrieve first entry
$LdapDnsHostName = $SearchResponse.Entries[0].Attributes[$Attribute][0]

# report verbose
Write-Verbose "found dnsHostName: $LdapDnsHostName"

# if ldap DNS host name matches local DNS host name...
if ($LdapDnsHostName -eq $DnsHostName) {
	return $true
}
else {
	return $false
}
