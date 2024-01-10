Function Format-LdapAttribute {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Mandatory = $true)]
		[string]$LdapDisplayName,
		[Parameter(Mandatory = $true)]
		[System.DirectoryServices.Protocols.DirectoryAttribute]$DirectoryAttribute,
		[Parameter(DontShow)]
		[System.Globalization.CultureInfo]$Culture = (Get-Culture)
	)

	# map ldapdisplayname to attribute type
	$AttributeMap = @{
		accountExpires     = 'FileTime'
		badPasswordTime    = 'FileTime'
		lastLogon          = 'FileTime'
		lastLogonTimestamp = 'FileTime'
		objectSid          = 'SecurityIdentifier'
		pwdlastset         = 'FileTime'
		userCertificate    = 'X509Certificate2'
		userParameters     = 'ByteArray'
		whenChanged        = 'GeneralizedTime'
		whenCreated        = 'GeneralizedTime'
	}

	# create a generic list to contain values
	$List = [System.Collections.Generic.List[object]]::new()

	# process each value in directory attribute by index
	For ($Index = 0; $Index -lt $DirectoryAttribute.Count; $Index++) {
		# retrieve value from directory attribute by index
		$Value = $DirectoryAttribute[$Index]

		# retrieve attribute type from attribute map
		$AttributeType = $AttributeMap[$LdapDisplayName]

		# if attribute type not found...
		If ([string]::IsNullOrEmpty($AttributeType)) {
			# if value is 16 character byte array...
			If ($Value -is [Byte[]] -and $Value.Length -eq 16) {
				# ...convert to GUID
				$Value = [guid]$Value
			}
		}
		# if attribute type found in map...
		Else {
			# transform attribute based upon type
			switch ($AttributeType) {
				'SecurityIdentifier' {
					# create SID from value
					$Value = [System.Security.Principal.SecurityIdentifier]::new($Value, 0)
				}
				'X509Certificate2' {
					# create certificate object from value
					$Value = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($Value)
				}
				'ByteArray' {
					# encode value as bytes
					$Value = [System.Text.Encoding]::Default.GetBytes($Value)
				}
				'FileTime' {
					# if value is less than or equal to maximum datetime value...
					If ($Value -le [System.DateTime]::MaxValue.ToFileTimeUtc()) {
						# create datetime from filetime
						$Value = [System.DateTime]::FromFileTimeUtc($Value)
					}
				}
				'GeneralizedTime' {
					# create datetime from generalized time
					$Value = [System.Datetime]::ParseExact($Value, 'yyyyMMddHHmmss.fZ', $Culture)
				}
			}
		}

		# add value to list
		$List.Add($Value)
	}

	# return value based upon count
	switch ($List.Count) {
		# when no values found...
		0 {
			# ...return null
			Return $null
		}
		# when one value found...
		1 {
			# ...return first element of list
			Return $List[0]
		}
		# when multiple values found...
		Default {
			# ...return list
			Return $List
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
		[Parameter(Position = 9, Mandatory = $True, ParameterSetName = 'Certificate')]
		[System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
		[Parameter(Position = 9, Mandatory = $True, ParameterSetName = 'Credential')]
		[pscredential]$Credential,
		[Parameter(Position = 9, Mandatory = $True, ParameterSetName = 'Kerberos')]
		[switch]$Kerberos
	)

	Begin {
		# define required assemblies
		$Assemblies = @('System.DirectoryServices.Protocols')

		# retrieve loaded assemblies
		$AssembliesFound = [System.AppDomain]::CurrentDomain.GetAssemblies().GetName().Name

		# verify assemblies
		ForEach ($Assembly in $Assemblies) { If ($Assembly -notin $AssembliesFound) { $null = [System.Reflection.Assembly]::LoadWithPartialName($Assembly) } }

		# define LDAP server
		$LdapDirectoryIdentifier = [System.DirectoryServices.Protocols.LdapDirectoryIdentifier]::new($Server, $Port, $true, $false)

		# create LDAP connection
		$LdapConnection = [System.DirectoryServices.Protocols.LdapConnection]::new($LdapDirectoryIdentifier)
		$LdapConnection.SessionOptions.ReferralChasing = 'None'
		$LdapConnection.SessionOptions.ProtocolVersion = 3

		# define credentials
		switch ($PSCmdlet.ParameterSetName) {
			'Cert' {
				$LdapConnection.AuthType = 'Anonymous'
				$LdapConnection.SessionOptions.QueryClientCertificate = { $Certificate }
				$LdapConnection.SessionOptions.SecureSocketLayer = $SSL
			}
			'Cred' {
				$LdapConnection.AuthType = 'Basic'
				$LdapConnection.Credential = $Credential
				$LdapConnection.SessionOptions.SecureSocketLayer = $SSL
			}
			'Kerb' {
				$LdapConnection.AuthType = 'Kerberos'
			}
			Default {
				$LdapConnection.AuthType = 'Negotiate'
			}
		}

		# define paging configuration
		$PageResultRequestControl = [System.DirectoryServices.Protocols.PageResultRequestControl]::new($PageSize)
		$SearchOptionsControl = [System.DirectoryServices.Protocols.SearchOptionsControl]::new('DomainScope')

		# define LDAP search request
		$SearchRequest = [System.DirectoryServices.Protocols.SearchRequest]::new($BaseDN, $Filter, $Scope, $Attributes)
		$SearchRequest.SizeLimit = $SizeLimit

		# add controls to LDAP search requested
		$null = $SearchRequest.Controls.Add($PageResultRequestControl)
		$null = $SearchRequest.Controls.Add($SearchOptionsControl)
	}

	Process {
		# if authentication is not with a certificate...
		If ($PSCmdlet.ParameterSetName -ne 'Certificate') {
			# bind to LDAP server
			Try {
				$LdapConnection.Bind()
			}
			Catch {
				Write-Host 'ERROR: failure during bind'
				Return $_
			}
		}

		# execute paged query
		Do {
			# clear search response
			$SearchResponse = $null

			# submit LDAP query
			Try {
				$SearchResponse = [System.DirectoryServices.Protocols.SearchResponse]($LdapConnection.SendRequest($SearchRequest))
			}
			Catch [System.DirectoryServices.Protocols.DirectoryOperationException] {
				Write-Host 'WARNING: caught DirectoryOperationException'
			}
			Catch {
				Write-Host "ERROR: caught unknown error: '$($Error[0].Exception)'"
			}

			# process each entry in the search response
			ForEach ($Entry in $SearchResponse.Entries) {
				# create sorted list for attributes
				$SortedList = [System.Collections.Generic.SortedList[string, object]]::new()

				# retrieve unsorted attributes from entry
				ForEach ($Attribute in $Entry.Attributes.GetEnumerator()) {
					# format attribute add to sorted list
					$SortedList[$Attribute.Key] = Format-LdapAttribute -LdapDisplayName $Attribute.Key -DirectoryAttribute $Attribute.Value
				}

				# return processed entry
				$SortedList
			}

			# retrieve current state of page response control
			$PageResultResponseControl = $SearchResponse.Controls | Where-Object { $_ -is [System.DirectoryServices.Protocols.PageResultResponseControl] }

			# copy token (aka "the cookie") from page response control into token for page request control to set page position for next search request
			$PageResultRequestControl.Cookie = $PageResultResponseControl.Cookie
		}
		While (
			# process paged queries while pages remain
			$PageResultRequestControl.Cookie.Length -gt 0
		)
	}

	End {
		# close LDAP connection
		$LdapConnection.Dispose()
	}
}

# define functions to export
$FunctionsToExport = @(
	'Invoke-LdapQuery'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport
