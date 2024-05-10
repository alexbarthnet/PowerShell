#Requires -Modules ActiveDirectory

Function Get-ADSecurityDefaultAccessRule {
	[CmdletBinding()]
	Param (
		[Parameter(Mandatory = $true, Position = 0, ValueFromPipeline)]
		[string]$DisplayName,
		[Parameter(DontShow)]
		[System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]$Schema = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema()
	)

	# retrieve default security descriptor for class with matching display name
	Try {
		$DefaultObjectSecurityDescriptor = $Schema.FindClass($DisplayName).DefaultObjectSecurityDescriptor
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
		[switch]$LimitToSchemaClassObjects,
		[Parameter(DontShow)]
		[System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]$Schema = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema()
	)

	# retrieve schema guid for class with matching display name
	Try {
		[guid]$Guid = $Schema.FindClass($DisplayName).SchemaGuid
	}
	# if class not found...
	Catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
		# if limit to schema class objects requested...
		If ($LimitToSchemaClassObjects) {
			Return $null
		}
		# retrieve schema guid for property with matching display name
		Try {
			[guid]$Guid = $Schema.FindProperty($DisplayName).SchemaGuid
		}
		# if property not found...
		Catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
			# define LDAP path for extended rights container
			$SearchBase = 'LDAP://CN=Extended-Rights', $Schema.Name.Split(',', 2)[1] -join ','

			# define filter for matching

			# search for extended right with matching display name
			Try {
				$SearchResult = [System.DirectoryServices.DirectorySearcher]::new($SearchBase, "(&(displayName=$DisplayName)(rightsGuid=*))" , 'rightsGuid' , [System.DirectoryServices.SearchScope]::OneLevel).FindOne()
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
			$inheritedObjectType = Get-ADSecurityObjectTypeGuid -DisplayName $InheritingObjectName -LimitToSchemaClassObjects
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

Function Remove-ADSecurity {
	[CmdletBinding()]
	param (
		# one or more Active Directory objects, each value must be an ADObject or the distinguished name of an Active Directory object
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][Alias('Objects')]
		[object[]]$Identity,
		# one or more Active Directory access rules
		[Parameter(Position = 1, Mandatory = $true)][Alias('Permissions')]
		[object[]]$AccessRule,
		# string for the server where the actions will be performed, the default server is the current PDC role owner
		[Parameter(DontShow)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
	)

	# validate access rules
	ForEach ($ActiveDirectoryAccessRule in $AccessRule) {
		If ($ActiveDirectoryAccessRule -isnot [System.DirectoryServices.ActiveDirectoryAccessRule]) {
			Write-Warning -Message 'one or more values for the AccessRule parameter are not an ActiveDirectoryAccessRule object'
			Return
		}
	}

	# create list for Active Directory objects
	$ADObjects = [System.Collections.Generic.List[Microsoft.ActiveDirectory.Management.ADObject]]::new()

	# retrieve Active Directory objects for each identity
	ForEach ($Object in $Identity) {
		# if object is an ADObject...
		If ($Object -is [Microsoft.ActiveDirectory.Management.ADObject]) {
			# add object to list and continue
			$ADObjects.Add($Object)
		}
		# if object is a string...
		ElseIf ($Object -is [System.String]) {
			# get ADObject using object as identity
			Try {
				$ADObject = Get-ADObject -Server $Server -Identity $Object -Properties 'nTSecurityDescriptor'
			}
			Catch {
				Write-Warning -Message "could not retrieve object for input: '$Object'"
				Return $_
			}
			# add ADObject to list and continue
			$ADObjects.Add($ADObject)
		}
		# if object is not an ADObject or a string...
		Else {
			# warn and return
			Write-Warning -Message "could not process '[$($Object.GetType().FullName)]' object type for object: '$Object'"
			Return
		}
	}

	# reset security descriptors for each object
	ForEach ($ADObject in $ADObjects) {
		# check object for nTSecurityDescriptor property
		If ($null -eq $ADObject.nTSecurityDescriptor) {
			Try {
				$ADObject = Get-ADObject -Server $Server -Identity $ADObject.DistinguishedName -Properties 'nTSecurityDescriptor'
			}
			Catch {
				Write-Warning -Message "could not retrieve nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
				Return $_
			}
		}

		# retrieve nTSecurityDescriptor from object
		$nTSecurityDescriptor = $ADObject.nTSecurityDescriptor

		# validate nTSecurityDescriptor object type
		If ($nTSecurityDescriptor -isnot [System.DirectoryServices.ActiveDirectorySecurity]) {
			Write-Warning -Message "found invalid '[$($nTSecurityDescriptor.GetType().FullName)]' object type for nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			Return $_
		}

		# process each provided access rule
		ForEach ($ActiveDirectoryAccessRule in $AccessRule) {
			# remove provided access rule
			Try {
				$nTSecurityDescriptor.RemoveAccessRuleSpecific($ActiveDirectoryAccessRule)
			}
			Catch {
				Write-Warning -Message "could not remove specific access rule from object: '$($ADObject.DistinguishedName)'"
				Return $_
			}
		}

		# process each provided security identifier
		ForEach ($IdentityReference in $SecurityIdentifier) {
			# remove access rule with identity reference matching security identifier
			Try {
				$nTSecurityDescriptor.PurgeAccessRules($IdentityReference)
			}
			Catch {
				Write-Warning -Message "could not remove access rule for '$IdentityReference' from object: '$($ADObject.DistinguishedName)'"
				Return $_
			}
		}

		# define parameters for Set-ADObject
		$SetADObject = @{
			Identity    = $ADObject
			Server      = $Server
			Replace     = @{ nTSecurityDescriptor = $nTSecurityDescriptor }
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# call Set-ADObject
		Try {
			Set-ADObject @SetADObject
		}
		Catch {
			Write-Warning -Message "could not update nTSecurityDescriptor on object: '$($ADObject.DistinguishedName)'"
			Return $_
		}
	}
}

Function Revoke-ADSecurity {
	[CmdletBinding()]
	param (
		# one or more Active Directory objects, each value must be an ADObject or the distinguished name of an Active Directory object
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][Alias('Objects')]
		[object[]]$Identity,
		# one or more security identifiers
		[Parameter(Position = 1, Mandatory = $true)]
		[object[]]$SecurityIdentifier,
		# string for the server where the actions will be performed, the default server is the current PDC role owner
		[Parameter(DontShow)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
	)

	# validate security identifier
	ForEach ($Object in $SecurityIdentifier) {
		If ($Object -isnot [System.Security.Principal.SecurityIdentifier]) {
			Write-Warning -Message 'one or more values for the SecurityIdentifier parameter are not a SecurityIdentifier object'
			Return
		}
	}

	# create list for Active Directory objects
	$ADObjects = [System.Collections.Generic.List[Microsoft.ActiveDirectory.Management.ADObject]]::new()

	# retrieve Active Directory objects for each identity
	ForEach ($Object in $Identity) {
		# if object is an ADObject...
		If ($Object -is [Microsoft.ActiveDirectory.Management.ADObject]) {
			# add object to list and continue
			$ADObjects.Add($Object)
		}
		# if object is a string...
		ElseIf ($Object -is [System.String]) {
			# get ADObject using object as identity
			Try {
				$ADObject = Get-ADObject -Server $Server -Identity $Object -Properties 'nTSecurityDescriptor'
			}
			Catch {
				Write-Warning -Message "could not retrieve object for input: '$Object'"
				Return $_
			}
			# add ADObject to list and continue
			$ADObjects.Add($ADObject)
		}
		# if object is not an ADObject or a string...
		Else {
			# warn and return
			Write-Warning -Message "could not process '[$($Object.GetType().FullName)]' object type for object: '$Object'"
			Return
		}
	}

	# reset security descriptors for each object
	ForEach ($ADObject in $ADObjects) {
		# check object for nTSecurityDescriptor property
		If ($null -eq $ADObject.nTSecurityDescriptor) {
			Try {
				$ADObject = Get-ADObject -Server $Server -Identity $ADObject.DistinguishedName -Properties 'nTSecurityDescriptor'
			}
			Catch {
				Write-Warning -Message "could not retrieve nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
				Return $_
			}
		}

		# retrieve nTSecurityDescriptor from object
		$nTSecurityDescriptor = $ADObject.nTSecurityDescriptor

		# validate nTSecurityDescriptor object type
		If ($nTSecurityDescriptor -isnot [System.DirectoryServices.ActiveDirectorySecurity]) {
			Write-Warning -Message "found invalid '[$($nTSecurityDescriptor.GetType().FullName)]' object type for nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			Return $_
		}

		# process each provided security identifier
		ForEach ($IdentityReference in $SecurityIdentifier) {
			# remove access rule with identity reference matching security identifier
			Try {
				$nTSecurityDescriptor.PurgeAccessRules($IdentityReference)
			}
			Catch {
				Write-Warning -Message "could not revoke access for '$IdentityReference' from object: '$($ADObject.DistinguishedName)'"
				Return $_
			}
		}

		# define parameters for Set-ADObject
		$SetADObject = @{
			Identity    = $ADObject
			Server      = $Server
			Replace     = @{ nTSecurityDescriptor = $nTSecurityDescriptor }
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# call Set-ADObject
		Try {
			Set-ADObject @SetADObject
		}
		Catch {
			Write-Warning -Message "could not update nTSecurityDescriptor on object: '$($ADObject.DistinguishedName)'"
			Return $_
		}
	}
}

Function Reset-ADSecurity {
	[CmdletBinding()]
	param (
		# one or more Active Directory objects, each value must be an ADObject or the distinguished name of an Active Directory object
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][Alias('Objects')]
		[object[]]$Identity,
		# optional string or security identifier to replace the existing owner
		[Parameter(Position = 1)]
		[object]$Owner,
		# optional string to configure inheritance on the objects, the default behavior preserves the existing inheritance configuration
		[Parameter(Position = 2)][ValidateSet('Enable', 'Disable')]
		[string]$Inheritance,
		# string for the server where the actions will be performed, the default server is the current PDC role owner
		[Parameter(DontShow)]
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

	# create list for Active Directory objects
	$ADObjects = [System.Collections.Generic.List[Microsoft.ActiveDirectory.Management.ADObject]]::new()

	# retrieve Active Directory objects for each identity
	ForEach ($Object in $Identity) {
		# if object is an ADObject...
		If ($Object -is [Microsoft.ActiveDirectory.Management.ADObject]) {
			# add object to list and continue
			$ADObjects.Add($Object)
		}
		# if object is a string...
		ElseIf ($Object -is [System.String]) {
			# get ADObject using object as identity
			Try {
				$ADObject = Get-ADObject -Server $Server -Identity $Object -Properties 'nTSecurityDescriptor'
			}
			Catch {
				Write-Warning -Message "could not retrieve object for input: '$Object'"
				Return $_
			}
			# add ADObject to list and continue
			$ADObjects.Add($ADObject)
		}
		# if object is not an ADObject or a string...
		Else {
			# warn and return
			Write-Warning -Message "could not process '[$($Object.GetType().FullName)]' object type for object: '$Object'"
			Return
		}
	}

	# create hashtable for default security descriptors
	$defaultSecurityDescriptors = @{}

	# retrieve default security descriptors for each object class
	ForEach ($ADObject in $ADObjects) {
		# if object class not in hashtable for default security descriptors...
		If (!$defaultSecurityDescriptors.ContainsKey($ADObject.objectClass)) {
			# retrieve default security descriptor for object class
			Try {
				$defaultSecurityDescriptors[$ADObject.objectClass] = Get-ADSecurityDefaultAccessRule -DisplayName $ADObject.objectClass
			}
			Catch {
				Write-Warning -Message "could not retrieve default security descriptor for object class: '$($ADObject.objectClass)'"
				Return $_
			}
		}
	}

	# reset security descriptors for each object
	ForEach ($ADObject in $ADObjects) {
		# check object for nTSecurityDescriptor property
		If ($null -eq $ADObject.nTSecurityDescriptor) {
			Try {
				$ADObject = Get-ADObject -Server $Server -Identity $ADObject.DistinguishedName -Properties 'nTSecurityDescriptor'
			}
			Catch {
				Write-Warning -Message "could not retrieve nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
				Return $_
			}
		}

		# retrieve nTSecurityDescriptor from object
		$nTSecurityDescriptor = $ADObject.nTSecurityDescriptor

		# validate nTSecurityDescriptor object type
		If ($nTSecurityDescriptor -isnot [System.DirectoryServices.ActiveDirectorySecurity]) {
			Write-Warning -Message "found invalid '[$($nTSecurityDescriptor.GetType().FullName)]' object type for nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			Return $_
		}

		# if inheritance set...
		If ($PSBoundParameters.ContainsKey('Inheritance')) {
			# ...and inheritance is...
			switch ($Inheritance) {
				'Enable' {
					# disable 'protection' to enable inheritance
					$IsProtected = $false
				}
				'Disable' {
					# enable 'protection' to disable inheritance
					$IsProtected = $true
				}
			}
		}
		Else {
			# retrieve inheritance settings from security descriptor
			$IsProtected = $nTSecurityDescriptor.AreAccessRulesProtected
		}

		# disable inheritance and remove inherited access rules from object
		Try {
			$nTSecurityDescriptor.SetAccessRuleProtection($true, $false)
		}
		Catch {
			Write-Warning -Message "could not disable inheritance on nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			Return $_
		}

		# process each existing access rule
		ForEach ($AccessRule in $nTSecurityDescriptor.Access) {
			# remove existing access rule from security descriptor
			Try {
				$nTSecurityDescriptor.RemoveAccessRuleSpecific($AccessRule)
			}
			Catch {
				Write-Warning -Message "could not remove access rule on nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
				Return $_
			}
		}

		# set security descriptor to default value for object class
		Try {
			$nTSecurityDescriptor.SetSecurityDescriptorSddlForm($defaultSecurityDescriptors[$ADObject.objectClass])
		}
		Catch {
			Write-Warning -Message "could not copy default security descriptor to nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			Return $_
		}

		# set inheritance on security descriptor and copy inherited rules if inheritance enabled
		Try {
			$nTSecurityDescriptor.SetAccessRuleProtection($IsProtected, $true)
		}
		Catch {
			Write-Warning -Message "could not configure inheritance on nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			Return $_
		}

		# if owner provided...
		If ($PSBoundParameters.ContainsKey('Owner')) {
			# set owner on security descriptor
			Try {
				$nTSecurityDescriptor.SetOwner($OwnerSid)
			}
			Catch {
				Write-Warning -Message "could not set owner in nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
				Return $_
			}
		}

		# define parameters for Set-ADObject
		$SetADObject = @{
			Identity    = $ADObject
			Server      = $Server
			Replace     = @{ nTSecurityDescriptor = $nTSecurityDescriptor }
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# call Set-ADObject
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
		# one or more Active Directory objects, each value must be an ADObject or the distinguished name of an Active Directory object
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][Alias('Objects')]
		[object[]]$Identity,
		# one or more Active Directory access rules
		[Parameter(Position = 1, Mandatory = $true)][Alias('Permissions')]
		[object[]]$AccessRule,
		# optional string to change inheritance on the objects, the default behavior preserves the existing inheritance configuration
		[Parameter(Position = 2)][ValidateSet('Enable', 'Disable', 'Remove')]
		[string]$Inheritance,
		# optional switch to remove any access rules that match the identity references found in the values provided for the AccessRule parameter
		[Parameter(Position = 3)]
		[switch]$Reset,
		# string for the server where the actions will be performed, the default server is the current PDC role owner
		[Parameter(DontShow)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
	)

	# validate access rules
	ForEach ($ActiveDirectoryAccessRule in $AccessRule) {
		If ($ActiveDirectoryAccessRule -isnot [System.DirectoryServices.ActiveDirectoryAccessRule]) {
			Write-Warning -Message 'one or more values for the AccessRule parameter are not an ActiveDirectoryAccessRule'
			Return
		}
	}

	# create list for Active Directory objects
	$ADObjects = [System.Collections.Generic.List[Microsoft.ActiveDirectory.Management.ADObject]]::new()

	# retrieve Active Directory objects for each identity
	ForEach ($Object in $Identity) {
		# if object is an ADObject...
		If ($Object -is [Microsoft.ActiveDirectory.Management.ADObject]) {
			# add object to list and continue
			$ADObjects.Add($Object)
		}
		# if object is a string...
		ElseIf ($Object -is [System.String]) {
			# get ADObject using object as identity
			Try {
				$ADObject = Get-ADObject -Server $Server -Identity $Object -Properties 'nTSecurityDescriptor'
			}
			Catch {
				Write-Warning -Message "could not retrieve object for input: '$Object'"
				Return $_
			}
			# add ADObject to list and continue
			$ADObjects.Add($ADObject)
		}
		# if object is not an ADObject or a string...
		Else {
			# warn and return
			Write-Warning -Message "could not process '[$($Object.GetType().FullName)]' object type for object: '$Object'"
			Return
		}
	}

	# update security descriptors for each object
	:NextObject ForEach ($ADObject in $ADObjects) {
		# check object for nTSecurityDescriptor property
		If ($null -eq $ADObject.nTSecurityDescriptor) {
			Try {
				$ADObject = Get-ADObject -Server $Server -Identity $ADObject.DistinguishedName -Properties 'nTSecurityDescriptor'
			}
			Catch {
				Write-Warning -Message "could not retrieve nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
				Return $_
			}
		}

		# retrieve nTSecurityDescriptor from object
		$nTSecurityDescriptor = $ADObject.nTSecurityDescriptor

		# validate nTSecurityDescriptor object type
		If ($nTSecurityDescriptor -isnot [System.DirectoryServices.ActiveDirectorySecurity]) {
			Write-Warning -Message "found invalid '[$($nTSecurityDescriptor.GetType().FullName)]' object type for nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			Return $_
		}

		# if inheritance changes requested...
		If ($PSBoundParameters.ContainsKey('Inheritance')) {
			# define inheritance objects
			switch ($Inheritance) {
				'Enable' {
					# disable 'protection' to enable inheritance
					$IsProtected = $false
					# preserve inherited rules if inheritance is disabled
					$PreserveInheritance = $true
				}
				'Disable' {
					# enable 'protection' to disable inheritance
					$IsProtected = $true
					# preserve inherited rules if inheritance is disabled
					$PreserveInheritance = $true
				}
				'Remove' {
					# enable 'protection' to disable inheritance
					$IsProtected = $true
					# do not preserve inherited rules if inheritance is disabled
					$PreserveInheritance = $false
				}
			}

			# if removal of inherited rules requested but no explicit rules are defined in the access control list and no access rules provided...
			If ($Inheritance -eq 'Remove' -and -not $nTSecurityDescriptor.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) -and -not $PSBoundParameters.ContainsKey('AccessRule')) {
				Write-Warning -Message "cannot disable inheritance and remove inherited access rules when all existing access rules are inherited and AccessRule parameter is not set; could not remove inheritance for object: '$($ADObject.DistinguishedName)'"
				Return
			}

			# update inheritance settings
			Try {
				$nTSecurityDescriptor.SetAccessRuleProtection($IsProtected, $PreserveInheritance)
			}
			Catch {
				Write-Warning -Message "could not modify inheritance of ACL on object: '$($ADObject.DistinguishedName)'"
				Return $_
			}
		}

		# if reset requested...
		If ($local:Reset) {
			# retrieve unique identity references in provided access rules
			$IdentityReferences = $AccessRule.IdentityReference | Select-Object -Unique

			# retrieve existing access rules that are explicitly defined and not inherited for the unique identity references
			$ExistingAccessRules = $nTSecurityDescriptor.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]).Where({ $_.IdentityReference -in $IdentityReferences })

			# process each existing access rule
			ForEach ($ExistingAccessRule in $ExistingAccessRules) {
				# remove existing access rule
				Try {
					$nTSecurityDescriptor.RemoveAccessRuleSpecific($ExistingAccessRule)
				}
				Catch {
					Write-Warning -Message "could not remove existing access rules for '$($ExistingAccessRule.IdentityReference)' from object: '$($ADObject.DistinguishedName)'"
					Return $_
				}
			}
		}

		# process each provided access rule
		ForEach ($ActiveDirectoryAccessRule in $AccessRule) {
			# add provided access rule
			Try {
				$nTSecurityDescriptor.AddAccessRule($ActiveDirectoryAccessRule)
			}
			Catch {
				Write-Warning -Message "could not add access rule to object: '$($ADObject.DistinguishedName)'"
				Return $_
			}
		}

		# define parameters for Set-ADObject
		$SetADObject = @{
			Identity    = $ADObject
			Server      = $Server
			Replace     = @{ nTSecurityDescriptor = $nTSecurityDescriptor }
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# call Set-ADObject
		Try {
			Set-ADObject @SetADObject
		}
		Catch {
			Write-Warning -Message "could not update nTSecurityDescriptor on object: '$($ADObject.DistinguishedName)'"
			Return $_
		}
	}
}

# define functions to export
$FunctionsToExport = @(
	'Get-ADSecurityDefaultAccessRule'
	'Get-ADSecurityObjectTypeGuid'
	'Get-ADSecurityIdentifier'
	'New-ADAccessRule'
	'Remove-ADSecurity'
	'Revoke-ADSecurity'
	'Reset-ADSecurity'
	'Update-ADSecurity'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport