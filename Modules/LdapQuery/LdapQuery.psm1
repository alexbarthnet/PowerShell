Function ConvertFrom-LdapEntry {
	Param(
		[Parameter(Mandatory = $True)]
		[object]$Entry,
		[Parameter(Mandatory = $True)]
		[string]$Attribute
	)

	# create empty array for values in attribute
	$values = @()

	# process values in attribute
	For ($index = 0; $index -lt $Entry.Attributes[$Attribute].Count; $index++) {
		# retrieve value from attribute
		$value = $entry.Attributes[$Attribute][$index]

		# check for known attributes
		switch ($Attribute) {
			'objectSid' {
				# create SID object with value
				$values += New-Object -TypeName 'System.Security.Principal.SecurityIdentifier' -ArgumentList @($value, 0)
			}
			'userCertificate' {
				# create certificate object with value after casting to byte array
				$values += New-Object -TypeName 'System.Security.Cryptography.X509Certificates.X509Certificate2' -ArgumentList @([byte[]]$value, $null)
			}
			'userParameters' {
				# encode value as bytes
				$values += [System.Text.Encoding]::Default.GetBytes($value)
			}
			Default {
				# convert 16 character byte arrays to GUID
				If ($value -is [Byte[]] -and $value.Length -eq 16) {
					$values += [guid]$value
				}
				# return all other attribute values as is
				Else {
					$values += $value
				}
			}
		}
	}

	# check count of values
	switch ($values.Count) {
		# return null for no values
		0 {
			Return $null
		}

		# return first value for single valued arrays
		1 {
			Return $values[0]
		}

		# return values in array
		Default {
			Return $values
		}
	}
}

Function Invoke-LdapQuery {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Position = 0)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
		[Parameter(Position = 1)]
		[string]$BaseDN = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName,
		[Parameter(Position = 2)]
		[string]$Filter = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$([System.Environment]::UserName.ToLower())))",
		[Parameter(Position = 3)]
		[string[]]$Attributes = '*',
		[Parameter(Position = 4)][ValidateSet('Base', 'OneLevel', 'Subtree')]
		[string]$Scope = 'Subtree',
		[Parameter(Position = 5)][ValidateRange(1, 65535)]
		[int]$Port = 636,
		[Parameter(Position = 6)][ValidateRange(1, [int]::MaxValue)]
		[int]$SizeLimit = [int]::MaxValue,
		[Parameter(Position = 7)][ValidateRange(1, [int]::MaxValue)]
		[int]$PageSize = [int]1000,
		[Parameter(Position = 8)]
		[boolean]$SSL = $true,
		[Parameter(Position = 9, Mandatory = $True, ParameterSetName = 'Cred', ValueFromPipeline = $true)]
		[pscredential]$Cred,
		[Parameter(Position = 9, Mandatory = $True, ParameterSetName = 'Kerb')]
		[switch]$Kerberos,
		[Parameter(Position = 9, Mandatory = $True, ParameterSetName = 'Pass')]
		[string]$Username,
		[Parameter(Position = 10, Mandatory = $True, ParameterSetName = 'Pass')]
		[securestring]$Password
	)

	# verify .net assemblies
	$assembly = [string]::Empty
	$assembly = [System.AppDomain]::CurrentDomain.GetAssemblies().Location -match 'System\.DirectoryServices\.Protocols'
	If ([string]::IsNullOrEmpty($assembly)) { $null = [System.Reflection.Assembly]::LoadWithPartialName('System.DirectoryServices.Protocols') }

	# define LDAP server
	$identifier = New-Object 'System.DirectoryServices.Protocols.LdapDirectoryIdentifier' -ArgumentList $Server, $Port

	# create LDAP connection
	$ldap = New-Object 'System.DirectoryServices.Protocols.LdapConnection' -ArgumentList $identifier
	$ldap.SessionOptions.ReferralChasing = 'None'
	$ldap.SessionOptions.ProtocolVersion = 3
	$ldap.SessionOptions.SecureSocketLayer = $SSL

	# define credentials
	switch ($PSCmdlet.ParameterSetName) {
		'Cred' {
			$ldap.AuthType = 'Basic'
			$ldap.Credential = $Cred
		}
		'Pass' {
			$ldap.AuthType = 'Basic'
			$ldap.Credential = New-Object 'System.Management.Automation.PSCredential' -ArgumentList $Username, $Password 
		}
		'Kerb' {
			$ldap.AuthType = 'Kerberos'
		}
		Default {
			$ldap.AuthType = 'Negotiate'
		}
	}

	# bind to LDAP server
	Try {
		$ldap.Bind()
		If ($VerbosePreference -ne 'SilentlyContinue') {
			# translate to unenumerated protcols
			switch ($ldap.SessionOptions.SslInformation.Protocol) {
				2048 { $ldap_protocol = 'TLS 1.2' }
				Default { $ldap_protocol = $ldap.SessionOptions.SslInformation.CipherStrength }
			}

			# report connection
			Write-Verbose 'Connected to server...'
			Write-Verbose " - server    : $($ldap.Directory.Servers):$($ldap.Directory.Port)"
			Write-Verbose " - protocol  : $ldap_protocol"
			Write-Verbose " - algorithm : $ldap.SessionOptions.SslInformation.AlgorithmIdentifier"
			Write-Verbose " - hash      : $ldap.SessionOptions.SslInformation.Hash"
		}
	}
	Catch {
		Write-Host 'ERROR: failure during bind'
		Write-Host $_
		# Exit
	}

	# define paging configuration
	$pageRequestControl = New-Object 'System.DirectoryServices.Protocols.PageResultRequestControl' -ArgumentList $PageSize
	$searchScopeControl = New-Object 'System.DirectoryServices.Protocols.SearchOptionsControl' -ArgumentList 'DomainScope'

	# define LDAP search request
	$request = New-Object 'System.DirectoryServices.Protocols.SearchRequest' -ArgumentList $BaseDn, $Filter, $Scope, $Attributes
	$request.SizeLimit = $SizeLimit

	# add controls to LDAP search requested
	$null = $request.Controls.Add($pageRequestControl)
	$null = $request.Controls.Add($searchScopeControl)

	# execute paged query
	Do {
		# clear search response
		$response = $null

		# submit LDAP query
		Try {
			$response = [System.DirectoryServices.Protocols.SearchResponse]($ldap.SendRequest($request))
		}
		Catch [System.DirectoryServices.Protocols.DirectoryOperationException] {
			Write-Host 'WARNING: caught DirectoryOperationException'
		}
		Catch {
			Write-Host "ERROR: caught unknown error: '$($Error[0].Exception)'"
		}
		
		# process each entry in response
		ForEach ($entry in $response.Entries) {
			# create empty array for unsorted attributes
			$attributes_unsorted = @()

			# retrieve unsorted attributes from entry
			ForEach ($attribute in $entry.Attributes.Keys) { $attributes_unsorted += $attribute }

			# sort attributes
			$attributes_sorted = [array][Linq.Enumerable]::OrderBy($attributes_unsorted, [Func[object, string]] { $args[0] })

			# create empty hashtable for processed attributes
			$processed = [ordered]@{}

			# process each attribute in sorted order
			ForEach ($attribute in $attributes_sorted) { $processed[$attribute] = ConvertFrom-LdapEntry -Entry $entry -Attribute $attribute }

			# return processed entry
			$processed
		}

		# retrieve current state of page response control
		$pageResponseControl = $response.Controls | Where-Object { $_ -is [System.DirectoryServices.Protocols.PageResultResponseControl] }

		# copy token (aka "the cookie") from page response control into token for page request control to set page position for next search request
		$pageRequestControl.Cookie = $pageResponseControl.Cookie
	}
	While (
		# process paged queries while pages remain
		$pageRequestControl.Cookie.Length -gt 0
	)

	# close LDAP connection
	$ldap.Dispose()
}

# define functions to export
$functions_to_export = @()
$functions_to_export += 'Invoke-LdapQuery'

# export module members
Export-ModuleMember -Function $functions_to_export
