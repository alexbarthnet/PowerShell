using namespace System.DirectoryServices.Protocols

Function Format-LdapAttribute {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Mandatory = $true)]
		[string]$LdapDisplayName,
		[Parameter(Mandatory = $true)][AllowEmptyCollection()]
		[System.DirectoryServices.Protocols.DirectoryAttribute]$DirectoryAttribute,
		[Parameter(DontShow)]
		[System.Collections.Generic.List[object]]$ExistingValues,
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

	# if existing values provided...
	If ($PSBoundParameters.ContainsKey('ExistingValues')) {
		If ($ExistingValues.Count -gt 1) {
			$List.AddRange($ExistingValues)
		}
		Else {
			$List.Add($ExistingValues)
		}
	}

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
			Return , $List
		}
	}
}

Function Invoke-LdapQuery {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Position = 0, Mandatory = $true)]
		[string]$Server,
		[Parameter(Position = 1, Mandatory = $true)]
		[string]$SearchBase,
		[Parameter(Position = 2, Mandatory = $true)]
		[string]$Filter,
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
		[switch]$Kerberos
	)

	Begin {
		# define LDAP identifer properties
		$FullyQualifiedDnsHostName = $true
		$Connectionless = $false

		# create LDAP identifier
		$LdapDirectoryIdentifier = [System.DirectoryServices.Protocols.LdapDirectoryIdentifier]::new($Server, $Port, $FullyQualifiedDnsHostName, $Connectionless)

		# create LDAP connection
		$LdapConnection = [System.DirectoryServices.Protocols.LdapConnection]::new($LdapDirectoryIdentifier)

		# update LDAP connection
		$LdapConnection.SessionOptions.ReferralChasing = [System.DirectoryServices.Protocols.ReferralChasingOptions]::None
		$LdapConnection.SessionOptions.ProtocolVersion = 3

		# define credentials
		switch ($PSCmdlet.ParameterSetName) {
			'Certificate' {
				$LdapConnection.AuthType = [System.DirectoryServices.Protocols.AuthType]::Anonymous
				$LdapConnection.SessionOptions.QueryClientCertificate = { $Certificate }
				$LdapConnection.SessionOptions.SecureSocketLayer = $SSL
			}
			'Credential' {
				$LdapConnection.AuthType = [System.DirectoryServices.Protocols.AuthType]::Basic
				$LdapConnection.Credential = $Credential
				$LdapConnection.SessionOptions.SecureSocketLayer = $SSL
			}
			'Kerberos' {
				$LdapConnection.AuthType = [System.DirectoryServices.Protocols.AuthType]::Kerberos
			}
			Default {
				$LdapConnection.AuthType = [System.DirectoryServices.Protocols.AuthType]::Negotiate
			}
		}

		# define LDAP paging controls
		$PageResultRequestControl = [System.DirectoryServices.Protocols.PageResultRequestControl]::new($PageSize)
		
		# define LDAP scope controls; instructs server not to generate LDAP referrals
		$DomainScopeControl = [System.DirectoryServices.Protocols.DomainScopeControl]::new()

		# create LDAP search request
		$SearchRequest = [System.DirectoryServices.Protocols.SearchRequest]::new($SearchBase, $Filter, $SearchScope, $Attributes)

		# update LDAP search request
		$SearchRequest.SizeLimit = $SizeLimit

		# add controls to LDAP search request
		$null = $SearchRequest.Controls.Add($PageResultRequestControl)
		$null = $SearchRequest.Controls.Add($DomainScopeControl)
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
				Return $_
			}
			Catch {
				Write-Host "ERROR: caught unknown error: '$($_.Exception)'"
				Return $_
			}

			# process each entry in the search response
			ForEach ($Entry in $SearchResponse.Entries) {
				# create sorted list for attributes
				$SortedList = [System.Collections.Generic.SortedList[string, object]]::new()

				# retrieve keys from entry
				:Key ForEach ($Key in $Entry.Attributes.Keys) {
					# if attribute value is empty...
					If ($null -eq $Entry.Attributes[$Key]) {
						# continue to next key
						Continue Key
					}
					
					# retrieve attribute name and attribute description from key
					$LdapDisplayName, $AttributeDescription = $Key -split ';'

					# if sorted list already contains attribute name...
					If ($SortedList.ContainsKey($LdapDisplayName)) {
						# ...format current attribute values then add to sorted list with existing attribute values
						$SortedList[$LdapDisplayName] = Format-LdapAttribute -LdapDisplayName $LdapDisplayName -DirectoryAttribute $Entry.Attributes[$Key] -ExistingValues $SortedList[$LdapDisplayName]
					}
					# if sorted list does not contain attribute name...
					Else {
						# ...format current attribute values then add to sorted list
						$SortedList[$LdapDisplayName] = Format-LdapAttribute -LdapDisplayName $LdapDisplayName -DirectoryAttribute $Entry.Attributes[$Key]
					}

					# if attribute description not found...
					If ([System.String]::IsNullOrEmpty($AttributeDescription)) {
						# continue to next key
						Continue Key
					}

					# if attribute description matches ranged retrieval format...
					If ($AttributeDescription -match 'range=(?<RangeLower>\d+)-(?<RangeUpper>\d+|\*)') {
						# if RangeUpper match is '*'...
						If ($Matches['RangeUpper'] -eq '*') {
							# continue to next key
							Continue Key
						}

						# define range values
						$RangeWidth = [uint32]$Matches['RangeUpper'] - [uint32]$Matches['RangeLower']
						$RangeLower = [uint32]$Matches['RangeUpper'] + 1
						$RangeUpper = $RangeLower + $RangeWidth

						# define initial parameters for LDAP query with ranged retrieval
						$InvokeLdapQuery = $PSBoundParameters

						# update attribute parameter with next attribute range
						$InvokeLdapQuery['Attributes'] = "$LdapDisplayName;range=$RangeLower-$RangeUpper"

						# invoke LDAP query with ranged retrieval
						Try {
							Invoke-LdapQuery @InvokeLdapQuery
						}
						Catch {
							Return $_
						}
					}
					# if range does not match regex...
					Else {
						Write-Warning "unrecognized attribute description: $AttributeDescription"
					}
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

Function Test-LdapQuery {
	# define parameters for Invoke-LdapQuery
	$InvokeLdapQuery = @{
		Server      = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
		SearchBase  = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName
		Filter      = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$([System.Environment]::UserName.ToLower())))"
		Attributes  = '*'
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# call Invoke-LdapQuery
	Try {
		Invoke-LdapQuery @InvokeLdapQuery
	}
	Catch {
		Return $_
	}
}

# define functions to export
$FunctionsToExport = @(
	'Invoke-LdapQuery'
	'Test-LdapQuery'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport
