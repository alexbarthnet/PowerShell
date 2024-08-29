#Requires -module LdapQuery,ActiveDirectory

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Position = 0)]
	[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
	[Parameter(Position = 1)]
	[string]$SearchBase = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName,
	[Parameter(Position = 2)]
	[string]$Filter = "(&(objectCategory=computer)(objectClass=computer)(sAMAccountName=$([System.Environment]::MachineName)$))",
	[Parameter(Position = 3)]
	[string[]]$Attributes = '*',
	[Parameter(Position = 4)][ValidateSet('Base', 'OneLevel', 'Subtree')]
	[string]$SearchScope = 'Subtree',
	[Parameter(Position = 5)][ValidateRange(1, 65535)]
	[int]$Port = 636,
	[Parameter(Position = 6)][ValidateRange(1, [int]::MaxValue)]
	[int]$SizeLimit = [int]::MaxValue,
	[Parameter(Position = 7)][ValidateRange(1, [int]::MaxValue)]
	[int]$PageSize = [int]1000,
	[Parameter(Position = 8)]
	[boolean]$SSL = $true,
	[Parameter(Position = 9, Mandatory = $True, ParameterSetName = 'Certificate')]
	[System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
	[Parameter(Position = 9, Mandatory = $True, ParameterSetName = 'Credential')]
	[pscredential]$Credential,
	[Parameter(Position = 9, Mandatory = $True, ParameterSetName = 'Kerberos')]
	[switch]$Kerberos,
	[Parameter(DontShow)]
	[guid]$QueryGuid = [System.Guid]::NewGuid()
)

# invoke LDAP query with values for Active Directory domain of current user
Try {
	Invoke-LdapQuery @PSBoundParameters
}
Catch {
	Return $_
}
