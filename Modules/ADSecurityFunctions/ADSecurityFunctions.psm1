#Requires -Modules ActiveDirectory

Function Get-ADSecurityObjectDefaultAcl {
	[CmdletBinding()]
	Param (
		[Parameter(Mandatory = $true, Position = 0, ValueFromPipeline)]
		[string]$DisplayName
	)

	# retrieve default security descriptor for class with matching display name
	Try {
		$DefaultObjectSecurityDescriptor = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema().FindClass($DisplayName).DefaultObjectSecurityDescriptor
	}
	# if class not found...
	Catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
		Return $null
	}
	# if any other error thrown...
	Catch {
		Return $_
	}

	# return default security descriptor
	Return $DefaultObjectSecurityDescriptor
}

Function Get-ADSecurityObjectTypeGuid {
	[CmdletBinding()]
	Param (
		[Parameter(Mandatory = $true, Position = 0, ValueFromPipeline)]
		[string]$DisplayName,
		[Parameter(Mandatory = $false)]
		[switch]$SchemaClassObjectsOnly,
		[Parameter(DontShow)]
		[string]$SchemaNamingContext = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema().Name
	)

	# retrieve schema guid for class matching with display name
	Try {
		[guid]$Guid = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema().FindClass($DisplayName).SchemaGuid
	}
	# if class not found...
	Catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
		# if schema class objects only requested...
		If ($SchemaClassObjectsOnly) {
			Return $null
		}
		# retrieve schema guid for property matching display name
		Try {
			[guid]$Guid = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema().FindProperty($DisplayName).SchemaGuid
		}
		# if property not found...
		Catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
			# define objects for directory searcher
			$SearchBase = 'LDAP://CN=Extended-Rights', $SchemaNamingContext.Split(',', 2)[1] -join ','

			# create directory searcher
			Try {
				$Searcher = [System.DirectoryServices.DirectorySearcher]::new($SearchBase, "(&(displayName=$DisplayName)(rightsGuid=*))" , 'rightsGuid' , [System.DirectoryServices.SearchScope]::OneLevel)
			}
			Catch {
				Return $_
			}

			# retrieve search result from directory searcher
			Try {
				$SearchResult = $Searcher.FindOne()
			}
			Catch {
				Return $_
			}

			# if search result found...
			If ($SearchResult -is [System.DirectoryServices.SearchResult]) {
				# ...and first value in search result can parse into a GUID...
				If ([guid]::TryParse($SearchResult.Properties['rightsGuid'][0], [ref][guid]::empty)) {
					# retrieve rights guid from first value in search result
					[guid]$Guid = $SearchResult.Properties['rightsGuid'][0]
				}
			}
			# if search result not found...
			Else {
				Return $null
			}
		}
	}
	Catch {
		Return $_
	}

	# return guid
	Return $Guid
}

Function Get-ADSecurityIdentifier {
	[CmdletBinding()]
	param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[object]$Principal,
		[Parameter(Position = 1)]
		[string]$Domain = [System.Environment]::UserDomainName
	)

	# verify the input
	If ($Principal -isnot [System.String] -and $Principal -is [System.Security.Principal.SecurityIdentifier]) {
		$Principal = $Principal.Value
	}

	# translate principal to SID
	Try {
		# check for specific well-known SIDs or translate the SID
		switch ($Principal) {
			# well-known built-in SID that only translates on a domain controller
			{ ($_ -eq 'Windows Authorization Access Group') -or ($_ -eq "$Domain\Windows Authorization Access Group") } {
				Return [System.Security.Principal.SecurityIdentifier]('S-1-5-32-560')
			}
			# a SID in string format
			{ ($_ -match 'S-1-\d{1,2}-\d+') } {
				Return [System.Security.Principal.SecurityIdentifier]($Principal)
			}
			# a principal with domain prefix or suffix
			{ ($_ -match '^[\w\s\.-]+\\[\w\s\.-]+\$*$') -or ($_ -match '^[\w\.-]+@[\w\.-]+$') } {
				Return ([System.Security.Principal.NTAccount]($Principal)).Translate([System.Security.Principal.SecurityIdentifier])
			}
			# a principal without domain prefix or suffix
			Default {
				Return ([System.Security.Principal.NTAccount]("$Domain\$Principal")).Translate([System.Security.Principal.SecurityIdentifier])
			}
		}
	}
	Catch {
		# return error
		Return $_
	}
}

Function New-ADAccessRule {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param (
		# the security identifier for the access rule
		[Parameter(Mandatory = $true, Position = 0, ValueFromPipeline)]
		[System.Security.Principal.SecurityIdentifier]$SecurityIdentifier,
		# a preset that returns multiple access rules
		[Parameter(Mandatory = $true, Position = 1, ParameterSetName = 'Preset')]
		[string]$Preset,
		# the rights for the access rule, the default is "Read", set to "Self" for extended rights
		[Parameter(Mandatory = $false, ParameterSetName = 'Default')]
		[System.DirectoryServices.ActiveDirectoryRights]$Rights = 'GenericRead',
		# display name of inheriting object type, can be an Active Directory object type
		[Parameter(Mandatory = $false, ParameterSetName = 'Default')]
		[string]$ObjectName,
		# the access type for the access rule, the default is "Allow"
		[Parameter(Mandatory = $false, ParameterSetName = 'Default')]
		[System.Security.AccessControl.AccessControlType]$AccessControlType = 'Allow',
		# the inheritance for the access rule, the default is "This object and all child objects"
		[Parameter(Mandatory = $false, ParameterSetName = 'Default')]
		[System.DirectoryServices.ActiveDirectorySecurityInheritance]$InheritanceType = 'All',
		# display name of inheriting object type, can be an Active Directory object type
		[Parameter(Mandatory = $false, ParameterSetName = 'Default')]
		[string]$InheritingObjectName,
		# create list for ActiveDirectoryAccessRule objects; supports importing existing ActiveDirectoryAccessRule object or existing list of ActiveDirectoryAccessRule objects
		[Parameter(Mandatory = $false)]
		[System.Collections.Generic.List[System.DirectoryServices.ActiveDirectoryAccessRule]]$AccessRule = [System.Collections.Generic.List[System.DirectoryServices.ActiveDirectoryAccessRule]]::new()
	)

	# if preset provided...
	If ($PSBoundParameters.ContainsKey('Preset')) {
		# process the requested delegation type
		switch ($Preset) {
			'Department' {
				# define ACE: deny 'WriteProperty' on the 'ou' attribute on 'this object only'
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'WriteProperty'
					type                = 'Deny'
					objectType          = [guid]'bf9679f0-0de6-11d0-a285-00aa003049e2' # GUID for 'ou' attribute
					inheritanceType     = 'None'
					inheritedObjectType = [guid]::empty
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: deny 'WriteDacl' on 'this object only'
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'WriteDacl'
					type                = 'Deny'
					objectType          = [guid]::empty
					inheritanceType     = 'None'
					inheritedObjectType = [guid]::empty
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: deny 'WriteDacl' on descendent 'organizationalUnit' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'WriteDacl'
					type                = 'Deny'
					objectType          = [guid]::empty
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967aa5-0de6-11d0-a285-00aa003049e2' # GUID for 'organizationalUnit' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: deny 'CreateChild','DeleteChild' of 'user' objects on 'this object and all child objects'
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'CreateChild', 'DeleteChild'
					type                = 'Deny'
					objectType          = [guid]'bf967aba-0de6-11d0-a285-00aa003049e2' # GUID for 'user' objects
					inheritanceType     = 'All'
					inheritedObjectType = [guid]::empty
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: deny 'CreateChild','DeleteChild' of 'inetOrgPerson' objects on 'this object and all child objects'
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'CreateChild', 'DeleteChild'
					type                = 'Deny'
					objectType          = [guid]'4828cc14-1437-45bc-9b07-ad6f015e5f28' # GUID for 'inetOrgPerson' objects
					inheritanceType     = 'All'
					inheritedObjectType = [guid]::empty
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: deny 'CreateChild','DeleteChild' of 'account' objects on 'this object and all child objects'
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'CreateChild', 'DeleteChild'
					type                = 'Deny'
					objectType          = [guid]'2628a46a-a6ad-4ae0-b854-2b12d9fe6f9e' # GUID for 'account' objects
					inheritanceType     = 'All'
					inheritedObjectType = [guid]::empty
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'GenericAll' on 'this object and all child objects'
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'GenericAll'
					type                = 'Allow'
					objectType          = [guid]::empty
					inheritanceType     = 'All'
					inheritedObjectType = [guid]::empty
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))
			}
			'Computer' {
				# define ACE: allow 'CreateChild','DeleteChild' of 'computer' objects on 'this object and all child objects'
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'CreateChild', 'DeleteChild'
					type                = 'Allow'
					objectType          = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
					inheritanceType     = 'All'
					inheritedObjectType = [guid]::empty
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'GenericAll' on descendent 'computer' objects"
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'GenericAll'
					type                = 'Allow'
					objectType          = [guid]::empty
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'GenericAll' on descendent 'msFVE-RecoveryInformation' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'GenericAll'
					type                = 'Allow'
					objectType          = [guid]::empty
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'ea715d30-8f53-40d0-bd1e-6109186d782c' # GUID for 'msFVE-RecoveryInformation' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))
			}
			'ComputerCreate' {
				# define ACE: allow 'CreateChild' of 'computer' objects on 'this object and all child objects'
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'CreateChild'
					type                = 'Allow'
					objectType          = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
					inheritanceType     = 'All'
					inheritedObjectType = [guid]::empty
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))
			}
			'ComputerDelete' {
				# define ACE: allow 'DeleteChild' of 'computer' objects on 'this object and all child objects'
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'DeleteChild'
					type                = 'Allow'
					objectType          = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
					inheritanceType     = 'All'
					inheritedObjectType = [guid]::empty
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))
			}
			'ComputerDenyCreate' {
				# define ACE: deny 'CreateChild' of 'computer' objects on 'this object and all child objects'
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'CreateChild'
					type                = 'Deny'
					objectType          = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
					inheritanceType     = 'All'
					inheritedObjectType = [guid]::empty
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))
			}
			'ComputerLAPS' {
				# define ACE: allow 'ReadProperty','ExtendedRight' on the 'ms-Mcs-AdmPwd' attribute on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'ReadProperty', 'ExtendedRight'
					type                = 'Allow'
					objectType          = [guid]'18c34bdf-9362-4ad4-9e4c-5f22796cc969' # GUID for 'ms-Mcs-AdmPwd' attribute
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))
			}
			'ComputerWindowsLAPS' {
				# define ACE: allow 'ReadProperty','ExtendedRight' on the 'msLAPS-Password' attribute on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'ReadProperty', 'ExtendedRight'
					type                = 'Allow'
					objectType          = [guid]'23f208e9-5657-4fc0-a61c-f3bbe4a45277' # GUID for 'msLAPS-Password' attribute
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'ReadProperty','ExtendedRight' on the 'msLAPS-EncryptedPassword' attribute on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'ReadProperty', 'ExtendedRight'
					type                = 'Allow'
					objectType          = [guid]'291d1f487-0bda-4d78-8df9-38072e3b827a' # GUID for 'msLAPS-EncryptedPassword' attribute
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'ReadProperty','ExtendedRight' on the 'msLAPS-EncryptedPasswordHistory' attribute on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'ReadProperty', 'ExtendedRight'
					type                = 'Allow'
					objectType          = [guid]'18100c82-7fdc-4fba-8b0c-0cc7930ebfcd' # GUID for 'msLAPS-EncryptedPasswordHistory' attribute
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'ReadProperty' on the 'msLAPS-PasswordExpirationTime' attribute on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'ReadProperty'
					type                = 'Allow'
					objectType          = [guid]'1762af1f-0320-43c4-9847-fb4de0c4b9d0' # GUID for 'msLAPS-PasswordExpirationTime' attribute
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))
			}
			'ComputerBitLocker' {
				# define ACE: allow 'GenericAll' on descendent 'msFVE-RecoveryInformation' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'GenericAll'
					type                = 'Allow'
					objectType          = [guid]::empty
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'ea715d30-8f53-40d0-bd1e-6109186d782c' # GUID for 'msFVE-RecoveryInformation' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))
			}
			'ComputerJoin' {
				# define ACE: allow 'WriteProperty' on the 'Account Restrictions' property set on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'WriteProperty'
					type                = 'Allow'
					objectType          = [guid]'4c164200-20c0-11d0-a768-00aa006e0529' # GUID for 'Account Restrictions' property set
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'Reset Password' on descendent 'computer' objects"
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'Self'
					type                = 'Allow'
					objectType          = [guid]'00299570-246d-11d0-a768-00aa006e0529' # GUID for 'Reset Password' rights
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'Validated write to DNS host name' rights on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'Self'
					type                = 'Allow'
					objectType          = [guid]'72e39547-7b18-11d1-adef-00c04fd8d5cd' # GUID for 'Validated write to DNS host name' rights
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'Validated write to service principal name' rights on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'Self'
					type                = 'Allow'
					objectType          = [guid]'f3a64788-5306-11d1-a9c5-0000f80367c1' # GUID for 'Validated write to service principal name' rights
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))
			}
			'ComputerRename' {
				# define ACE: allow 'ReadProperty','WriteProperty' on the 'cn' attribute on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'WriteProperty'
					type                = 'Allow'
					objectType          = [guid]'bf96793f-0de6-11d0-a285-00aa003049e2' # GUID for 'cn' attribute
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'ReadProperty','WriteProperty' on the 'sAMAccountName' attribute on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'WriteProperty'
					type                = 'Allow'
					objectType          = [guid]'3e0abfd0-126a-11d0-a060-00aa006c33ed' # GUID for 'sAMAccountName' attribute
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'WriteProperty' on the 'Account Restrictions' property set on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'WriteProperty'
					type                = 'Allow'
					objectType          = [guid]'4c164200-20c0-11d0-a768-00aa006e0529' # GUID for 'Account Restrictions' property set
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'Validated write to DNS host name' rights on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'Self'
					type                = 'Allow'
					objectType          = [guid]'72e39547-7b18-11d1-adef-00c04fd8d5cd' # GUID for 'Validated write to DNS host name' rights
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'Validated write to service principal name' rights on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'Self'
					type                = 'Allow'
					objectType          = [guid]'f3a64788-5306-11d1-a9c5-0000f80367c1' # GUID for 'Validated write to service principal name' rights
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967a86-0de6-11d0-a285-00aa003049e2' # GUID for 'computer' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))
			}
			'Group' {
				# define ACE: allow 'CreateChild','DeleteChild' of 'group' objects on 'this object and all child objects'
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'CreateChild', 'DeleteChild'
					type                = 'Allow'
					objectType          = [guid]'bf967a9c-0de6-11d0-a285-00aa003049e2' # GUID for 'group' objects
					inheritanceType     = 'All'
					inheritedObjectType = [guid]::empty
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'GenericAll' on all descendent 'group' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'GenericAll'
					type                = 'Allow'
					objectType          = [guid]::empty
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967a9c-0de6-11d0-a285-00aa003049e2' # GUID for 'group' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))
			}
			'GroupMembership' {
				# define ACE: allow 'ReadProperty','WriteProperty' on the 'member' attribute on descendent 'group' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'ReadProperty', 'WriteProperty'
					type                = 'Allow'
					objectType          = [guid]'bf9679c0-0de6-11d0-a285-00aa003049e2' # GUID for 'member' attribute
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967a9c-0de6-11d0-a285-00aa003049e2' # GUID for 'group' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))
			}
			'GroupPolicy' {
				# define ACE: allow 'ReadProperty','WriteProperty' on the 'gPLink' attribute on 'this object only'
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'ReadProperty', 'WriteProperty'
					type                = 'Allow'
					objectType          = [guid]'f30e3bbe-9ff0-11d1-b603-0000f80367c1' # GUID for 'gPLink' attribute
					inheritanceType     = 'None'
					inheritedObjectType = [guid]::empty
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'ReadProperty','WriteProperty' on the 'gPOptions' attribute on 'this object only'
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'ReadProperty', 'WriteProperty'
					type                = 'Allow'
					objectType          = [guid]'f30e3bbf-9ff0-11d1-b603-0000f80367c1' # GUID for 'gPOptions' attribute
					inheritanceType     = 'None'
					inheritedObjectType = [guid]::empty
				}
				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'ReadProperty','WriteProperty' on the 'gPLink' attribute on descendent 'organizationalUnit' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'ReadProperty', 'WriteProperty'
					type                = 'Allow'
					objectType          = [guid]'f30e3bbe-9ff0-11d1-b603-0000f80367c1' # GUID for 'gPLink' attribute
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967aa5-0de6-11d0-a285-00aa003049e2' # GUID for 'organizationalUnit' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'ReadProperty','WriteProperty' on the 'gPOptions' attribute on descendent 'organizationalUnit' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'ReadProperty', 'WriteProperty'
					type                = 'Allow'
					objectType          = [guid]'f30e3bbf-9ff0-11d1-b603-0000f80367c1' # GUID for 'gPOptions' attribute
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967aa5-0de6-11d0-a285-00aa003049e2' # GUID for 'organizationalUnit' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))
			}
			'OU' {
				# define ACE: allow 'CreateChild','DeleteChild' of 'organizationalUnit' objects on 'this object and all child objects'
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'CreateChild', 'DeleteChild'
					type                = 'Allow'
					objectType          = [guid]'bf967aa5-0de6-11d0-a285-00aa003049e2' # GUID for 'organizationalUnit' objects
					inheritanceType     = 'All'
					inheritedObjectType = [guid]::empty
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'WriteProperty' on the 'ou' attribute on all descendent 'organizationalUnit' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'ReadProperty', 'WriteProperty'
					type                = 'Allow'
					objectType          = [guid]'bf9679f0-0de6-11d0-a285-00aa003049e2' # GUID for 'ou' attribute
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967aa5-0de6-11d0-a285-00aa003049e2' # GUID for 'organizationalUnit' objects
				}
				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'WriteProperty' on the 'description' attribute on all descendent 'organizationalUnit' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'ReadProperty', 'WriteProperty'
					type                = 'Allow'
					objectType          = [guid]'bf967950-0de6-11d0-a285-00aa003049e2' # GUID for 'description' attribute
					inheritanceType     = 'Descendents'
					inheritedObjectType = [guid]'bf967aa5-0de6-11d0-a285-00aa003049e2' # GUID for 'organizationalUnit' objects
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))
			}
			Default {
				$AccessRule = $null
			}
		}
	}
	# if preset not provided...
	Else {
		# translate object name to GUID of schema class object, attribute object, or a control access right
		If ($PSBoundParameters.ContainsKey('ObjectName')) {
			$objectType = Get-ADSecurityObjectTypeGuid -DisplayName $ObjectName
		}
		Else {
			$objectType = [guid]::empty
		}

		# translate inheriting object name to GUID of schema class object
		If ($PSBoundParameters.ContainsKey('InheritingObjectName')) {
			$inheritedObjectType = Get-ADSecurityObjectTypeGuid -DisplayName $InheritingObjectName -SchemaClassObjectsOnly
		}
		Else {
			$inheritedObjectType = [guid]::empty
		}

		# define ACE: deny 'WriteProperty' on the 'ou' attribute on 'this object only'
		$Ace = @{
			objectSid           = $SecurityIdentifier
			adRights            = $Rights
			type                = $AccessControlType
			objectType          = $objectType
			inheritanceType     = $InheritanceType
			inheritedObjectType = $inheritedObjectType
		}

		# create ACE and add to list
		$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))
	}

	# return ACE objects
	Return $AccessRule
}

Function Reset-ADSecurity {
	[CmdletBinding()]
	param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][Alias('Objects')]
		[object[]]$Identity,
		[Parameter(Position = 1)]
		[object]$Owner,
		[Parameter(Position = 2)]
		[switch]$BlockInheritance,
		[Parameter(Position = 3)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
	)

	# if owner provided and not a SID...
	If ($PSBoundParameters.ContainsKey('Owner') -and $Owner -isnot [System.Security.Principal.SecurityIdentifier]) {
		# get owner SID
		Try {
			$Owner = Get-ADSecurityIdentifier -Principal $Owner
		}
		Catch {
			Write-Warning -Message "could not retrieve SID for owner: '$Owner'"
			Return $_
		}
	}

	# create list for objects
	$ADObjects = [System.Collections.Generic.List[object]]::new()

	# retrieve objects from input
	:NextIdentity ForEach ($Object in $Identity) {
		If ($Object -is [Microsoft.ActiveDirectory.Management.ADObject]) {
			# add object to list and continue
			$ADObjects.Add($Object)
			Continue NextIdentity
		}

		# if object is a string...
		If ($Object -is [System.String]) {
			# get ADObject using object as identity
			Try {
				$ADObject = Get-ADObject -Server $Server -Identity $Object -Properties 'nTSecurityDescriptor'
			}
			Catch {
				Write-Warning -Message "could not retrieve object for '$Object'"
			}

			# add object to list and continue
			$ADObjects.Add($ADObject)
			Continue NextIdentity
		}

		# if any other object type, continue to next iteration of foreeach loop
		Write-Warning -Message "could not process '[$($Object.GetType().FullName)]' object type for object: '$Object'"
	}

	# create hashtable for default security descriptors
	$defaultSecurityDescriptors = @{}

	# process objects retrieved from input
	:NextObject ForEach ($ADObject in $ADObjects) {
		# if object class not in hashtable for default security descriptors...
		If (!$defaultSecurityDescriptors.ContainsKey($ADObject.objectClass)) {
			# retrieve default security descriptor for object class
			Try {
				$defaultSecurityDescriptors[$ADObject.objectClass] = Get-ADSecurityObjectDefaultAcl -DisplayName $ADObject.objectClass
			}
			Catch {
				Write-Warning -Message "could not retrieve default security descriptor for object class: '$($ADObject.objectClass)'"
				Continue NextObject
			}
		}

		# check object for nTSecurityDescriptor property
		If ($null -eq $ADObject.nTSecurityDescriptor) {
			Try {
				$ADObject = Get-ADObject -Server $Server -Identity $ADObject.DistinguishedName -Properties 'nTSecurityDescriptor'
			}
			Catch {
				Write-Warning -Message "could not retrieve nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
				Continue NextObject
			}
		}

		# retrieve nTSecurityDescriptor from object
		$nTSecurityDescriptor = $ADObject.nTSecurityDescriptor

		# validate nTSecurityDescriptor object type
		If ($nTSecurityDescriptor -isnot [System.DirectoryServices.ActiveDirectorySecurity]) {
			Write-Warning -Message "found invalid '[$($nTSecurityDescriptor.GetType().FullName)]' object type for nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			Continue NextObject
		}

		# if block inheritance set...
		If ($PSBoundParameters.ContainsKey('BlockInheritance')) {
			# define inheritance settings
			$IsProtected = $BlockInheritance.ToBool()
		}
		Else {
			# retrieve inheritance settings
			$IsProtected = $nTSecurityDescriptor.AreAccessRulesProtected
		}

		# remove inheritance from object
		Try {
			$nTSecurityDescriptor.SetAccessRuleProtection($true, $false)
		}
		Catch {
			Write-Warning -Message "could not disable inheritance on nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			Continue NextObject
		}

		# process each access rule
		ForEach ($AccessRule in $nTSecurityDescriptor.Access) {
			# remove existing ACEs from object
			Try {
				$nTSecurityDescriptor.RemoveAccessRuleSpecific($AccessRule)
			}	
			Catch {
				Write-Warning -Message "could not remove access rule on nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
				Continue NextObject
			}
		}

		# add default SDDL to ACL
		Try {
			$nTSecurityDescriptor.SetSecurityDescriptorSddlForm($defaultSecurityDescriptors[$ADObject.objectClass])
		}
		Catch {
			Write-Warning -Message "could not copy default security descriptor to nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			Continue NextObject
		}

		# set inheritance on object
		Try {
			$nTSecurityDescriptor.SetAccessRuleProtection($IsProtected, $true)
		}
		Catch {
			Write-Warning -Message "could not configure inheritance on nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			Continue NextObject
		}

		# if owner provided...
		If ($PSBoundParameters.ContainsKey('Owner')) {
			# set owner on object
			Try {
				$nTSecurityDescriptor.SetOwner($OwnerSid)
			}
			Catch {
				Write-Warning -Message "could not set owner in nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
				Continue NextObject
			}
		}

		# define parameters for Set-Acl
		$SetADObject = @{
			Identity    = $ADObject.DistinguishedName
			Server      = $Server
			Replace     = @{ nTSecurityDescriptor = $nTSecurityDescriptor }
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# set ACL for object
		Try {
			Set-ADObject @SetADObject
		}
		Catch {
			Write-Warning -Message "could not update nTSecurityDescriptor on object: '$($ADObject.DistinguishedName)'"
			Return $_
		}
	}
}

Function Update-ADSecurity {
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][Alias('Objects')]
		[object[]]$Identity,
		[Parameter(Position = 1)][Alias('Permissions')]
		[object[]]$AccessRule,
		[Parameter(Position = 2)]
		[object[]]$SID,
		[Parameter(Position = 3)][ValidateSet('Enable', 'Disable', 'Remove')]
		[string]$Inheritance,
		[Parameter(Position = 4)]
		[switch]$Reset,
		[Parameter(Position = 5)]
		[switch]$KeepInheritedRulesForEmptyACL,
		[Parameter(Position = 6)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
	)

	# validate access rules
	ForEach ($ActiveDirectoryAccessRule in $AccessRule) {
		If ($ActiveDirectoryAccessRule -isnot [System.DirectoryServices.ActiveDirectoryAccessRule]) {
			Write-Warning -Message 'one or more values for the AccessRule parameter are not an ActiveDirectoryAccessRule'
			Return
		}
	}

	# validate SIDs
	ForEach ($SecurityIdentifier in $SID) {
		If ($SecurityIdentifier -isnot [System.Security.Principal.SecurityIdentifier]) {
			Write-Warning -Message 'one or more values for the SID parameter are not a SecurityIdentifier'
			Return
		}
	}

	# create list for objects
	$ADObjects = [System.Collections.Generic.List[object]]::new()

	# retrieve objects from input
	:NextIdentity ForEach ($Object in $Identity) {
		If ($Object -is [Microsoft.ActiveDirectory.Management.ADObject]) {
			# add object to list and continue
			$ADObjects.Add($Object)
			Continue NextIdentity
		}

		# if object is a string...
		If ($Object -is [System.String]) {
			# get ADObject using object as identity
			Try {
				$ADObject = Get-ADObject -Server $Server -Identity $Object -Properties 'nTSecurityDescriptor'
			}
			Catch {
				Write-Warning -Message "could not retrieve object for '$Object'"
			}

			# add object to list and continue
			$ADObjects.Add($ADObject)
			Continue NextIdentity
		}

		# if any other object type, continue to next iteration of foreeach loop
		Write-Warning -Message "could not process object type: '[$($Object.GetType().FullName)]'"
	}

	# process DNs
	:NextObject ForEach ($ADObject in $ADObjects) {
		# check object for nTSecurityDescriptor property
		If ($null -eq $ADObject.nTSecurityDescriptor) {
			Try {
				$ADObject = Get-ADObject -Server $Server -Identity $ADObject.DistinguishedName -Properties 'nTSecurityDescriptor'
			}
			Catch {
				Write-Warning -Message "could not retrieve nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
				Continue NextObject
			}
		}

		# retrieve nTSecurityDescriptor from object
		$nTSecurityDescriptor = $ADObject.nTSecurityDescriptor

		# if inheritance changes requested...
		If ($PSBoundParameters.ContainsKey('Inheritance')) {
			switch ($Inheritance) {
				'Enable' {
					# enable inheritance
					$DisableInheritance = $false
					$KeepInheritedRules = $false
				}
				'Disable' {
					# disable inheritance and retain inherited permissions
					$DisableInheritance = $true
					$KeepInheritedRules = $true
				}
				'Remove' {
					# disable inheritance and remove inherited permissions
					$DisableInheritance = $true
					$KeepInheritedRules = $false
				}
			}

			# if remove requested and no explicit rules are defined in the access control list...
			If ($Inheritance -eq 'Remove' -and -not $nTSecurityDescriptor.Access.Where({ !$_.IsInherited }) -and -not $KeepInheritedRulesForEmptyACL -and -not $PSBoundParameters.ContainsKey('AccessRule')) {
				# ...and keep inherited rules for empty ACL was set...
				If ($KeepInheritedRulesForEmptyACL) {
					# retain inherited permissions
					$KeepInheritedRules = $true
				}
				# ...and no access rules provided to fill otherwise empty ACL...
				ElseIf (-not $PSBoundParameters.ContainsKey('AccessRule')) {
					Write-Warning -Message "cannot remove inherited access rules without replacement access rules if resultant ACL would be empty; could remove Inheritance for on object: '$($ADObject.DistinguishedName)'"
					Continue NextObject
				}
			}

			# update inheritance settings
			Try {
				$nTSecurityDescriptor.SetAccessRuleProtection($DisableInheritance, $KeepInheritedRules)
			}
			Catch {
				Write-Warning -Message "could not modify inheritance of ACL on object: '$($ADObject.DistinguishedName)'"
				Continue NextObject
			}
		}

		# if reset requested...
		If ($local:Reset) {
			# ...and access rules provided...
			If ($PSBoundParameters.ContainsKey('AccessRule')) {
				# process each provided access rule...
				ForEach ($ActiveDirectoryAccessRule in $AccessRule) {
					# ...and remove existing access rules matching the identity in the provided access rule
					Try {
						$nTSecurityDescriptor.PurgeAccessRules($ActiveDirectoryAccessRule.IdentityReference)
						Write-Warning "removed existing access rules for '$($ActiveDirectoryAccessRule.IdentityReference)' from object: '$($ADObject.DistinguishedName)'"
					}
					Catch {
						Write-Warning -Message "could not remove existing access rules for '$($ActiveDirectoryAccessRule.IdentityReference)' from object: '$($ADObject.DistinguishedName)'"
						Continue NextObject
					}
				}
			}
			# ...and SID provided...
			If ($PSBoundParameters.ContainsKey('SID')) {
				# process each provided SID...
				ForEach ($SecurityIdentifier in $SID) {
					# ...and remove existing access rules matching the SID
					Try {
						$nTSecurityDescriptor.PurgeAccessRules($SecurityIdentifier)
						Write-Warning "removed existing access rules for '$($SecurityIdentifier.Value)' from object: '$($ADObject.DistinguishedName)'"
					}
					Catch {
						Write-Warning -Message "could not remove existing access rules for '$($SecurityIdentifier.Value)' from object: '$($ADObject.DistinguishedName)'"
						Continue NextObject
					}
				}
			}
		}

		# process each access rule
		ForEach ($ActiveDirectoryAccessRule in $AccessRule) {
			Try {
				$nTSecurityDescriptor.AddAccessRule($ActiveDirectoryAccessRule)
			}
			Catch {
				Write-Warning -Message "could not add access rule to object: '$($ADObject.DistinguishedName)'"
				Continue NextObject
			}
		}

		# define parameters for Set-Acl
		$SetADObject = @{
			Identity    = $ADObject.DistinguishedName
			Server      = $Server
			Replace     = @{ nTSecurityDescriptor = $nTSecurityDescriptor }
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# set ACL for object
		Try {
			Set-ADObject @SetADObject
		}
		Catch {
			Write-Warning -Message "could not update nTSecurityDescriptor on object: '$($ADObject.DistinguishedName)'"
			Continue NextObject
		}
	}
}

# define functions to export
$FunctionsToExport = @(
	'Get-ADSecurityObjectTypeGuid'
	'Get-ADSecurityIdentifier'
	'New-ADAccessRuleList'
	'Reset-ADSecurity'
	'Update-ADSecurity'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport