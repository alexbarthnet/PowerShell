using assembly 'C:\windows\Microsoft.NET\assembly\GAC_MSIL\System.DirectoryServices.Protocols\v4.0_4.0.0.0__b03f5f7f11d50a3a\System.DirectoryServices.Protocols.dll'
using namespace System.DirectoryServices.Protocols

<#
.SYNOPSIS
Writes the content from Invoke-WebRequest to a defined path.

.DESCRIPTION
Writes the content from Invoke-WebRequest to a defined path.

.PARAMETER Server
The name of the LDAP server to query.

.PARAMETER Attribute
The name of the attribute to retrieve. The default valut is "dnsHostName"

.PARAMETER Path
The path to the folder to contain the content files.

.PARAMETER FilePath
The path to content file for the local system. The default value is a text file in the provided path with name of the local host.

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Write-LdapAttributeToPath.ps1.ps1 -Server 'https://example.com/host/' -Path 'C:\Content\host'

#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
	# local host name
	[Parameter(DontShow)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# path for all script host files
	[Parameter(Position = 0, Mandatory = $True)]
	[string]$Path,
	# path for local script host file
	[Parameter(Position = 1)]
	[string]$FilePath = (Join-Path -Path $Path -ChildPath "$HostName.txt"),
	# server to query
	[Parameter(Position = 2, Mandatory = $True)]
	[string]$Server,
	# port on server
	[Parameter(Position = 2, Mandatory = $True)]
	[uint16]$Port = 389,
	# attribute to retrieve
	[Parameter(Position = 4)]
	[string]$Attribute = 'dnsHostName',
	# filter for RootDSE
	[Parameter(Position = 5)]
	[string]$Filter = '(objectClass=*)',
	# search base for RootDSE
	[Parameter(Position = 6)]
	[string]$SearchBase = [string]::Empty,
	# search scope for RootDSE
	[Parameter(Position = 7)][ValidateSet('Base', 'OneLevel', 'Subtree')]
	[string]$SearchScope = 'Base'
)

begin {
	# if path not found...
	if (![System.IO.Directory]::Exists($Path)) {
		# create path
		try {
			$null = New-Item -Path $Path -Force -ItemType 'Directory' -ErrorAction 'Stop'
		}
		catch {
			Write-Warning "could not create path: $local:Path"
			throw $_
		}
	}

	# if file not found...
	if (![System.IO.File]::Exists($local:FilePath)) {
		# create script host file
		try {
			$null = New-Item -Path $local:FilePath -Force -ItemType 'File' -ErrorAction 'Stop'
		}
		catch {
			Write-Warning "could not create script host file: '$local:FilePath"
			throw $_
		}
	}
}

process {
	# get content of hosts file
	try {
		$HostsFile = Get-Content -Path "$env:SystemRoot\System32\drivers\etc\hosts"
	}
	catch {
		Write-Warning "could not retrieve hosts file on host: $local:Hostname"
		throw $_
	}

	# define escaped server name
	$EscapedServer = [System.Text.RegularExpressions.Regex]::Escape($Server)

	# process hosts file content
	:NextLine foreach ($Line in $HostsFile) {
		# if line is commented out...
		if ($Line.StartsWith('#')) {
			# continue to the next line
			continue NextLine
		}

		# if line ends with the escaped server...
		if ($Line -match "\s$EscapedServer$") {
			# warn and return
			Write-Warning 'found server in hosts file which is not presently supported'
			return
		}
	}

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

	# if no entries present...
	if ($SearchResponse.Entries.Count -eq 0) {
		Write-Warning 'no entries returned by query'
		return
	}

	# if no entries present...
	if ($SearchResponse.Entries[0].Attributes.Count -eq 0) {
		Write-Warning 'no attributes returned by query'
		return
	}

	# retrieve first entry
	try {
		$ContentFromAttribute = $SearchResponse.Entries[0].Attributes[$Attribute][0]
	}
	catch {
		Write-Warning "could not retrieve attribute from server: $Server"
		return $_
	}

	# retrieve content from file
	try {
		$ContentFromFile = Get-Content -Path $FilePath
	}
	catch {
		Write-Warning "could not retrieve content from file: '$FilePath'"
		return $_
	}

	# if content from file is present and matches content from URI...
	if (![string]::IsNullOrEmpty($ContentFromFile) -and $ContentFromFile -eq $ContentFromAttribute) {
		Write-Host "Verified file: content from file matches content from attribute: $ContentFromAttribute"
		return
	}

	# update host name
	try {
		Set-Content -Path $FilePath -Value $ContentFromAttribute
	}
	catch {
		Write-Warning "could not update content of file: '$FilePath"
		return $_
	}

	# declare state
	Write-Host "Updated file: replaced '$ContentFromFile' content from file with content from attribute: $ContentFromAttribute"
}
