using namespace System.DirectoryServices.Protocols

Function Format-LdapAttribute {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Mandatory = $true)]
		[string]$LdapDisplayName,
		[Parameter(Mandatory = $true)][AllowEmptyCollection()]
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
			Return , $List
		}
	}
}

Function Invoke-LdapQuery {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Position = 0, Mandatory = $true)]
		[string]$Server,
		[Parameter(Position = 1, Mandatory = $true)][AllowEmptyString()]
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
		[System.Management.Automation.PSCredential]$Credential,
		[Parameter(Position = 9, Mandatory = $True, ParameterSetName = 'Kerberos')]
		[switch]$Kerberos,
		[Parameter(DontShow)]
		[guid]$QueryGuid = [System.Guid]::NewGuid()
	)

	Begin {
		# define LDAP identifer properties
		$FullyQualifiedDnsHostName = $true
		$Connectionless = $false

		# create LDAP identifier
		$LdapDirectoryIdentifier = [System.DirectoryServices.Protocols.LdapDirectoryIdentifier]::new($Server, $Port, $FullyQualifiedDnsHostName, $Connectionless)

		# create LDAP connection with LDAP identifier
		$LdapConnection = [System.DirectoryServices.Protocols.LdapConnection]::new($LdapDirectoryIdentifier)

		# update protocol settings for LDAP connection
		$LdapConnection.SessionOptions.ProtocolVersion = 3
		$LdapConnection.SessionOptions.ReferralChasing = [System.DirectoryServices.Protocols.ReferralChasingOptions]::None

		# update security settings for LDAP connection 
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
				$LdapConnection.SessionOptions.Sealing = $true
				$LdapConnection.SessionOptions.Signing = $true
			}
			Default {
				$LdapConnection.AuthType = [System.DirectoryServices.Protocols.AuthType]::Negotiate
			}
		}

		# create LDAP search request
		$SearchRequest = [System.DirectoryServices.Protocols.SearchRequest]::new($SearchBase, $Filter, $SearchScope, $Attributes)

		# update LDAP search request
		$SearchRequest.SizeLimit = $SizeLimit

		# if SearchFilter is not empty...
		If (![string]::IsNullOrEmpty($SearchFilter)) {
			# define LDAP paging controls
			$PageResultRequestControl = [System.DirectoryServices.Protocols.PageResultRequestControl]::new($PageSize)
		
			# define LDAP scope controls; instructs server not to generate LDAP referrals
			$DomainScopeControl = [System.DirectoryServices.Protocols.DomainScopeControl]::new()

			# add LDAP paging controls to LDAP search request
			$null = $SearchRequest.Controls.Add($PageResultRequestControl)

			# add LDAP scope controls to LDAP search request
			$null = $SearchRequest.Controls.Add($DomainScopeControl)
		}

		# create scoped dictionary for ldap queries
		If ($script:LdapQueries -isnot [System.Collections.Generic.Dictionary[guid, object]]) {
			$script:LdapQueries = [System.Collections.Generic.Dictionary[guid, object]]::new()
		}

		# if current query is not in dictionary...
		If ($script:LdapQueries.ContainsKey($QueryGuid) -eq $false) {
			# add dictionary for current query to scoped dictionary
			$script:LdapQueries.Add($QueryGuid, [System.Collections.Generic.Dictionary[string, object]]::new())
		}

		# get reference to dictionary for current query
		$CurrentQuery = $script:LdapQueries[$QueryGuid]
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
			:NextEntry ForEach ($Entry in $SearchResponse.Entries) {
				# if dictionary for current query contains key for distinguished name from entry...
				If ($CurrentQuery.ContainsKey($Entry.DistinguishedName)) {
					# ...and value for key is not sorted list...
					If ($CurrentQuery[$Entry.DistinguishedName] -isnot [System.Collections.Generic.SortedList[string, object]]) {
						# ...reset value to new sorted list
						$CurrentQuery[$Entry.DistinguishedName] = [System.Collections.Generic.SortedList[string, object]]::new()
					}
				}
				# if dictionary for current query does not contain key for distinguished name from entry...
				Else {
					# add key for distinguished name from entry with value of new sorted list to dictionary for current query
					$CurrentQuery.Add($Entry.DistinguishedName, [System.Collections.Generic.SortedList[string, object]]::new())
				}
				
				# get reference to sorted list for current object
				$CurrentObject = $CurrentQuery[$Entry.DistinguishedName]

				# process each attribute key-value pair in attributes collection
				:NextAttribute ForEach ($Attribute in $Entry.Attributes) {
					# process each key in attribute keys
					:NextKey ForEach ($Key in $Attribute.Keys) {
						# if no value present for attribute key...
						If ($Attribute[$Key].Count -eq 0) {
							# continue to next key
							Continue NextKey
						}

						# retrieve attribute name and attribute description from key
						$AttributeName, $AttributeDescription = $Key -split ';'

						# retrieve formatted attribute values
						Try {
							$LdapAttribute = Format-LdapAttribute -LdapDisplayName $AttributeName -DirectoryAttribute $Attribute[$Key]
						}
						Catch {
							<#Do this if a terminating exception happens#>
						}

						# if current object list has existing value for attribute name...
						If ($CurrentObject.ContainsKey($AttributeName)) {
							# if existing value are not a list...
							If ($CurrentObject[$AttributeName] -isnot [System.Collections.Generic.List[object]]) {
								# cast existing value into list and update current object
								$CurrentObject[$AttributeName] = [System.Collections.Generic.List[object]]($CurrentObject[$AttributeName])
							}
							# update existing value with formatted attribute values
							If ($LdapAttribute.Count -gt 1) {
								$CurrentObject[$AttributeName].AddRange($LdapAttribute)
							}
							ElseIf ($LdapAttribute.Count -eq 1) {
								$CurrentObject[$AttributeName].Add($LdapAttribute)
							}
						}
						# if current object list does not have existing value for attribute name...
						Else {
							# add entry to current object with attribute name and formatted attribute values
							$CurrentObject.Add($AttributeName, $LdapAttribute)
						}

						# if attribute description not found...
						If ([System.String]::IsNullOrEmpty($AttributeDescription)) {
							# continue to next key
							Continue NextKey
						}

						# if attribute description matches ranged retrieval format...
						If ($AttributeDescription -match 'range=(?<RangeLower>\d+)-(?<RangeUpper>\d+|\*)') {
							# if RangeUpper match is '*'...
							If ($Matches['RangeUpper'] -eq '*') {
								# continue to next key
								Continue NextKey
							}

							# define range values
							$RangeWidth = [uint32]$Matches['RangeUpper'] - [uint32]$Matches['RangeLower']
							$RangeLower = [uint32]$Matches['RangeUpper'] + 1
							$RangeUpper = $RangeLower + $RangeWidth

							# clone $PSBoundParameters into new hashtable parameters for LDAP query with ranged retrieval
							$InvokeLdapQuery = [System.Management.Automation.PSSerializer]::Deserialize([System.Management.Automation.PSSerializer]::Serialize($PSBoundParameters))

							# update filter parameters to base search of current object
							$InvokeLdapQuery['Filter'] = '(objectClass=*)'
							$InvokeLdapQuery['SearchBase'] = $Entry.DistinguishedName
							$InvokeLdapQuery['SearchScope'] = 'Base'

							# update attributes parameter with next range
							$InvokeLdapQuery['Attributes'] = "$AttributeName;range=$RangeLower-$RangeUpper"

							# update parameters to include current query guid
							$InvokeLdapQuery['QueryGuid'] = $QueryGuid

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
				}

				# if query guid was not explicitly provided...
				If (!$PSBoundParameters.ContainsKey('QueryGuid')) {
					# return processed entry
					$CurrentObject | Select-Object -Property @{ Name = 'DistinguishedName'; Expression = { $Entry.DistinguishedName } }, @{ Name = 'Attributes'; Expression = { $CurrentObject } }
				}
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
