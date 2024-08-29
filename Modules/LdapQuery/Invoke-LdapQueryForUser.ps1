#Requires -module LdapQuery, ActiveDirectory

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Position = 0)]
	[string]$UserName = [System.Environment]::UserName,
	[Parameter(Position = 1)]
	[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
	[Parameter(Position = 2)]
	[string]$SearchBase = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName,
	[Parameter(Position = 3)]
	[string]$Filter = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$UserName))",
	[Parameter(Position = 4)]
	[string[]]$Attributes = '*',
	[Parameter(Position = 5)][ValidateSet('Base', 'OneLevel', 'Subtree')]
	[string]$SearchScope = 'Subtree',
	[Parameter(Position = 6)][ValidateRange(1, 65535)]
	[int]$Port = 636,
	[Parameter(Position = 7)][ValidateRange(1, [int]::MaxValue)]
	[int]$SizeLimit = [int]::MaxValue,
	[Parameter(Position = 8)][ValidateRange(1, [int]::MaxValue)]
	[int]$PageSize = [int]1000,
	[Parameter(Position = 9)]
	[boolean]$SSL = $true,
	[Parameter(Position = 10, Mandatory = $True, ParameterSetName = 'Certificate')]
	[System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
	[Parameter(Position = 10, Mandatory = $True, ParameterSetName = 'Credential')]
	[pscredential]$Credential,
	[Parameter(Position = 10, Mandatory = $True, ParameterSetName = 'Kerberos')]
	[switch]$Kerberos
)

# define required parameters
$InvokeLdapQuery = @{
	Server      = $Server
	SearchBase  = $SearchBase
	Filter      = $Filter
	Attributes  = $Attributes
	SearchScope = $SearchScope
	Port        = $Port
	SizeLimit   = $SizeLimit
	PageSize    = $PageSize
	SSL         = $SSL
}

# define optional parameters
If ($PSBoundParameters.ContainsKey('Certificate')) { $InvokeLdapQuery.Add('Certificate', $Certificate) }
If ($PSBoundParameters.ContainsKey('Credential')) { $InvokeLdapQuery.Add('Credential', $Credential) }
If ($PSBoundParameters.ContainsKey('Kerberos')) { $InvokeLdapQuery.Add('Kerberos', $Kerberos) }

# invoke LDAP query
Try {
	Invoke-LdapQuery @InvokeLdapQuery
}
Catch {
	Return $_
}
