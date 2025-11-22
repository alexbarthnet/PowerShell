#Requires -Modules ActiveDirectory

function Get-ADObjectTypeDefaultAccessRule {
	<#
	.SYNOPSIS
	Retrieve the default access rule from the schema definition of an object type in Active Directory.

	.DESCRIPTION
	Retrieve the default access rule from the schema definition of an object type in Active Directory.

	.PARAMETER DisplayName
	Specifies the value of the ldapDisplayName attribute of the schema object.

	.INPUTS
	System.String.

	.OUTPUTS
	System.DirectoryServices.ActiveDirectorySecurity.

	.EXAMPLE
	PS> Get-ADObjectTypeDefaultAccessRule -DisplayName 'User'
	#>

	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true, Position = 0, ValueFromPipeline)]
		[string]$DisplayName,
		# string for the server to query for GUIDs of schema objects and extended rights, the default server is the current PDC role owner
		[Parameter(Mandatory = $false)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
	)

	# build directory context from server
	try {
		$DirectoryContext = [System.DirectoryServices.ActiveDirectory.DirectoryContext]::new([System.DirectoryServices.ActiveDirectory.DirectoryContextType]::DirectoryServer, $Server)
	}
	catch {
		throw $_
	}

	# retrieve schema from directory context
	try {
		$Schema = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetSchema($DirectoryContext)
	}
	catch {
		throw $_
	}

	# retrieve default security descriptor for class with matching display name
	try {
		[System.DirectoryServices.ActiveDirectorySecurity]$DefaultObjectSecurityDescriptor = $Schema.FindClass($DisplayName).DefaultObjectSecurityDescriptor
	}
	# if class not found...
	catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
		return $null
	}
	# if any other error thrown...
	catch {
		return $_
	}

	# return default security descriptor
	return $DefaultObjectSecurityDescriptor
}

function Get-ADObjectTypeGuid {
	<#
	.SYNOPSIS
	Retrieve the GUID for an object type or an extended right in Active Directory.

	.DESCRIPTION
	Retrieve the GUID for an object type or an extended right in Active Directory.

	.PARAMETER DisplayName
	Specifies the value of the ldapDisplayName attribute of the object type or the displayName of the extended right.

	.PARAMETER LimitToSchemaClassObjects
	Switch to limit the search to only schema class objects.

	.INPUTS
	System.String.

	.OUTPUTS
	System.Guid.

	.EXAMPLE
	PS> Get-ADObjectTypeGuid -DisplayName 'User'

	.EXAMPLE
	PS> Get-ADObjectTypeGuid -DisplayName 'SamAccountName'

	.EXAMPLE
	PS> Get-ADObjectTypeGuid -DisplayName 'Reset Password'
	#>

	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true, Position = 0, ValueFromPipeline)]
		[string]$DisplayName,
		[Parameter(Mandatory = $false)]
		[switch]$LimitToSchemaClassObjects,
		# string for the server where the schema will be queried, the default server is the current PDC role owner
		[Parameter(Mandatory = $false)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
	)

	# build directory context from server
	try {
		$DirectoryContext = [System.DirectoryServices.ActiveDirectory.DirectoryContext]::new([System.DirectoryServices.ActiveDirectory.DirectoryContextType]::DirectoryServer, $Server)
	}
	catch {
		throw $_
	}

	# retrieve schema from directory context
	try {
		$Schema = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetSchema($DirectoryContext)
	}
	catch {
		throw $_
	}

	# retrieve schema guid for class with matching display name
	try {
		[guid]$Guid = $Schema.FindClass($DisplayName).SchemaGuid
	}
	# if class not found...
	catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
		# if limit to schema class objects requested...
		if ($LimitToSchemaClassObjects) {
			return $null
		}
		# retrieve schema guid for property with matching display name
		try {
			[guid]$Guid = $Schema.FindProperty($DisplayName).SchemaGuid
		}
		# if property not found...
		catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
			# define LDAP path for extended rights container
			$SearchBase = 'LDAP://CN=Extended-Rights', $Schema.Name.Split(',', 2)[1] -join ','

			# define filter for matching display name where rights guid is defined
			$Filter = "(&(displayName=$DisplayName)(rightsGuid=*))"

			# search for extended right with matching display name
			try {
				$SearchResult = [System.DirectoryServices.DirectorySearcher]::new($SearchBase, $Filter , 'rightsGuid' , [System.DirectoryServices.SearchScope]::OneLevel).FindOne()
			}
			catch {
				return $_
			}

			# if search result found...
			if ($SearchResult -is [System.DirectoryServices.SearchResult]) {
				# ...and the first search result contains the 'rightsGuid' property...
				if ($SearchResult[0].Properties.PropertyNames -contains 'rightsGuid') {
					# ...and first value in 'rightsGuid' property can parse into a GUID...
					if ([guid]::TryParse($SearchResult[0].Properties['rightsGuid'][0], [ref][guid]::empty)) {
						# retrieve the rights guid
						[guid]$Guid = $SearchResult[0].Properties['rightsGuid'][0]
					}
				}
			}
			# if search result not found...
			else {
				return $null
			}
		}
	}
	catch {
		return $_
	}

	# return guid
	return $Guid
}

function Get-ADPrincipal {
	<#
	.SYNOPSIS
	Retrieve a NTAccount-style principal from a security identifier.

	.DESCRIPTION
	Retrieve a NTAccount-style principal from a security identifier.

	.PARAMETER SecurityIdentifier
	A valid security identifier object.

	.INPUTS
	System.Security.Principal.SecurityIdentifier.

	.OUTPUTS
	System.String.

	.EXAMPLE
	PS> Get-ADPrincipal -SecurityIdentifier 'S-1-5-11'
	#>

	[CmdletBinding()]
	param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[System.Security.Principal.SecurityIdentifier]$SecurityIdentifier
	)

	# translate SID to NTAccount principal
	try {
		$SecurityIdentifier.Translate([System.Security.Principal.NTAccount]).Value
	}
	catch {
		# return error
		return $_
	}
}

function Get-ADSecurityIdentifier {
	<#
	.SYNOPSIS
	Retrieve the security identifier for a security principal in Active Directory.

	.DESCRIPTION
	Retrieve the security identifier for a security principal in Active Directory.

	.PARAMETER Principal
	A object representing a security principal in Active Directory. Must be one of the following object types:
	 - a Security Identifier object
	 - an NTAccount object
	 - an ADPrincipal-derived object such as an Active Directory user, computer, or group object
	 - a string containing a Security Identifier in SDDL format
	 - a string containing a value that can be translated into a Security Identifier object

	.PARAMETER Server
	An optional value to specify the domain controller to query for retrieving the security identifier

	 .INPUTS
	System.String, System.Security.Principal.NTAccount, System.Security.Principal.SecurityIdentifier, Microsoft.ActiveDirectory.Management.ADPrincipal.

	.OUTPUTS
	System.Security.Principal.SecurityIdentifier.

	.EXAMPLE
	PS> Get-ADSecurityIdentifier -Principal 'Administrator'

	.EXAMPLE
	PS> Get-ADSecurityIdentifier -Principal 'Domain Users'

	.EXAMPLE
	PS> Get-ADSecurityIdentifier -Principal 'administrator@example.com'
	#>

	[CmdletBinding()]
	param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[object]$Principal,
		[Parameter(Position = 1)]
		[string]$Server
	)

	# if principal is a SecurityIdentifier object...
	if ($Principal -is [System.Security.Principal.SecurityIdentifier]) {
		# return principal as-is
		return $Principal
	}

	# if principal is an NTAccount object...
	if ($Principal -is [System.Security.Principal.NTAccount]) {
		# return principal translated to SecurityIdentifier
		return $Principal.Translate([System.Security.Principal.SecurityIdentifier])
	}

	# if principal is an ADPrincipal object...
	if ($Principal -is [Microsoft.ActiveDirectory.Management.ADPrincipal]) {
		# return SID property from principal
		return $Principal.SID
	}

	# if principal is not a string...
	if ($Principal -isnot [System.String]) {
		Write-Warning -Message "an unsupported object type was provided: $($Principal.GetType().FullName)"
		return $null
	}

	# if principal is a SID in SDDL format...
	if ($Principal -match '^S-1-\d{1,2}-\d+') {
		# return SecurityIdentifier constructed from principal
		return [System.Security.Principal.SecurityIdentifier]::new($Principal)
	}

	# if principal matches the name of a well-known SID that only translate on servers or domain controllers...
	# reference: https://learn.microsoft.com/en-us/windows/win32/secauthz/well-known-sids
	switch -regex ($Principal) {
		# return SecurityIdentifier constructed from matching well-known SID
		'(^|^\w+\\)Account Operators$' {
			return [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-548')
		}
		'(^|^\w+\\)Server Operators$' {
			return [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-549')
		}
		'(^|^\w+\\)Print Operators$' {
			return [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-550')
		}
		'(^|^\w+\\)Pre–Windows 2000 Compatible Access$' {
			return [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-554')
		}
		'(^|^\w+\\)Incoming Forest Trust Builders$' {
			return [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-557')
		}
		'(^|^\w+\\)Windows Authorization Access Group$' {
			return [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-560')
		}
		'(^|^\w+\\)Terminal Server License Servers$' {
			return [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-561')
		}
	}

	# if server provided...
	if ($PSBoundParameters.ContainsKey('Server')) {
		# define parameters for Get-ADObject
		$GetADObject = @{
			Server      = $Server
			Properties  = 'ObjectSid'
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve object by UserPrincipalName
		try {
			$ADObject = Get-ADObject @GetADObject -Filter "UserPrincipalName -eq '$Principal'"
		}
		catch {
			Write-Warning -Message "could not query Active Directory for object by UserPrincipalName for principal: $Principal"
			return $_
		}

		# if ADObject found...
		if ($ADObject) {
			return $ADObject.ObjectSid
		}

		# retrieve object by SamAccountName
		try {
			$ADObject = Get-ADObject @GetADObject -Filter "SamAccountName -eq '$Principal'"
		}
		catch {
			Write-Warning -Message "could not query Active Directory for object by SamAccountName for principal: $Principal"
			return $_
		}

		# if ADObject found...
		if ($ADObject) {
			return $ADObject.ObjectSid
		}

		# retrieve object by SamAccountName with $ suffix for computer objects
		try {
			$ADObject = Get-ADObject @GetADObject -Filter "SamAccountName -eq '$Principal$'"
		}
		catch {
			Write-Warning -Message "could not query Active Directory for object by SamAccountName for principal: $Principal"
			return $_
		}

		# if ADObject found...
		if ($ADObject) {
			return $ADObject.ObjectSid
		}
	}

	# translate principal to SID
	return ([System.Security.Principal.NTAccount]::new($Principal)).Translate([System.Security.Principal.SecurityIdentifier])
}

function Get-ADAccessRule {
	<#
	.SYNOPSIS
	Retrieve the Active Directory access rules from an existing object.

	.DESCRIPTION
	Retrieve the Active Directory access rules from an existing object.

	.PARAMETER Identity
	One or more Active Directory objects. Each value must be a valid distinguished name for an Active Directory object or a Microsoft.ActiveDirectory.Management.ADObject object.

	.PARAMETER IncludeInherited
	Optional parameter to included inherited permissions. The default configuration retrieves explicitly defined access rules.

	.PARAMETER SecurityIdentifier
	Optional parameter to filter access rules to the provided security identifier. Only access rules that contain the matching values will be returned.

	.PARAMETER Rights
	Optional parameter to filter access rules to the provided Active Directory rights value. Only access rules that contain the matching values will be returned.

	.PARAMETER ObjectName
	Optional parameter to filter access rules to the provided object type name. Only access rules that contain the matching values will be returned.

	.PARAMETER AccessControlType
	Optional parameter to filter access rules to the provided access control type. Only access rules that contain the matching values will be returned.

	.PARAMETER InheritanceType
	Optional parameter to filter access rules to the provided inheritance type. Only access rules that contain the matching values will be returned.

	.PARAMETER InheritingObjectName
	Optional parameter to filter access rules to the provided inheriting object type name. Only access rules that contain the matching values will be returned.

	.PARAMETER AccessRule
	Optional parameter for an existing list of access rules. The access rules retrieved will be added to this list and the updated list will be returned.

	.INPUTS
	System.Object.

	.OUTPUTS
	[System.Collections.Generic.List[System.DirectoryServices.ActiveDirectoryAccessRule]].

	.EXAMPLE
	PS> Get-ADAccessRule -Identity 'CN=Computers,DC=example,DC=com'

	.EXAMPLE
	PS> Get-ADAccessRule -Identity 'CN=Computers,DC=example,DC=com' -IncludedInherited
	#>

	[CmdletBinding(DefaultParameterSetName = 'Default')]
	param (
		# one or more Active Directory objects, each value must be an ADObject or the distinguished name of an Active Directory object
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][Alias('Objects')]
		[object[]]$Identity,
		# switch to include inherited permissions
		[Parameter(Mandatory = $false)]
		[switch]$IncludeInherited,
		# the security identifier for the access rule
		[Parameter(Mandatory = $false)]
		[System.Security.Principal.SecurityIdentifier]$SecurityIdentifier,
		# the rights for the access rule, the default is "Read", set to "Self" for extended rights
		[Parameter(Mandatory = $false)]
		[System.DirectoryServices.ActiveDirectoryRights]$Rights,
		# display name of inheriting object type, can be an Active Directory object type
		[Parameter(Mandatory = $false)]
		[string]$ObjectName,
		# the access type for the access rule, the default is "Allow"
		[Parameter(Mandatory = $false)]
		[System.Security.AccessControl.AccessControlType]$AccessControlType,
		# the inheritance for the access rule, the default is "This object and all child objects"
		[Parameter(Mandatory = $false)]
		[System.DirectoryServices.ActiveDirectorySecurityInheritance]$InheritanceType,
		# display name of inheriting object type, can be an Active Directory object type
		[Parameter(Mandatory = $false)]
		[string]$InheritingObjectName,
		# create list for ActiveDirectoryAccessRule objects; supports importing existing ActiveDirectoryAccessRule object or existing list of ActiveDirectoryAccessRule objects
		[Parameter(Mandatory = $false)]
		[System.Collections.Generic.List[System.DirectoryServices.ActiveDirectoryAccessRule]]$AccessRule = [System.Collections.Generic.List[System.DirectoryServices.ActiveDirectoryAccessRule]]::new(),
		# string for the server where the actions will be performed, the default server is the current PDC role owner
		[Parameter(DontShow)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
	)

	# translate object name to GUID of schema class object, attribute object, or a control access right
	if ($PSBoundParameters.ContainsKey('ObjectName')) {
		$objectType = Get-ADObjectTypeGuid -DisplayName $ObjectName
	}
	else {
		$objectType = [guid]::empty
	}

	# translate inheriting object name to GUID of schema class object
	if ($PSBoundParameters.ContainsKey('InheritingObjectName')) {
		$inheritedObjectType = Get-ADObjectTypeGuid -DisplayName $InheritingObjectName -LimitToSchemaClassObjects
	}
	else {
		$inheritedObjectType = [guid]::empty
	}

	# create list for Active Directory objects
	$ADObjects = [System.Collections.Generic.List[Microsoft.ActiveDirectory.Management.ADObject]]::new()

	# retrieve Active Directory objects for each identity
	foreach ($Object in $Identity) {
		# if object is an ADObject...
		if ($Object -is [Microsoft.ActiveDirectory.Management.ADObject]) {
			# add object to list and continue
			$ADObjects.Add($Object)
		}
		# if object is a string...
		elseif ($Object -is [System.String]) {
			# get ADObject using object as identity
			try {
				$ADObject = Get-ADObject -Server $Server -Identity $Object -Properties 'nTSecurityDescriptor'
			}
			catch {
				Write-Warning -Message "could not retrieve object for input: '$Object'"
				return $_
			}
			# add ADObject to list and continue
			$ADObjects.Add($ADObject)
		}
		# if object is not an ADObject or a string...
		else {
			# warn and return
			Write-Warning -Message "could not process '[$($Object.GetType().FullName)]' object type for object: '$Object'"
			return
		}
	}

	# reset security descriptors for each object
	foreach ($ADObject in $ADObjects) {
		# check object for nTSecurityDescriptor property
		if ($null -eq $ADObject.nTSecurityDescriptor) {
			try {
				$ADObject = Get-ADObject -Server $Server -Identity $ADObject.DistinguishedName -Properties 'nTSecurityDescriptor'
			}
			catch {
				Write-Warning -Message "could not retrieve nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
				return $_
			}
		}

		# retrieve nTSecurityDescriptor from object
		$nTSecurityDescriptor = $ADObject.nTSecurityDescriptor

		# validate nTSecurityDescriptor object type
		if ($nTSecurityDescriptor -isnot [System.DirectoryServices.ActiveDirectorySecurity]) {
			Write-Warning -Message "found invalid '[$($nTSecurityDescriptor.GetType().FullName)]' object type for nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			return $_
		}

		# retrieve existing access rules that are explicitly defined and not inherited for the unique identity references
		$ExistingAccessRules = $nTSecurityDescriptor.GetAccessRules($true, $IncludeInherited, [System.Security.Principal.SecurityIdentifier])

		# filter existing access rules
		:NextAccessRule foreach ($ExistingAccessRule in $ExistingAccessRules) {
			# if security identifier provided...
			if ($PSBoundParameters.ContainsKey('SecurityIdentifier')) {
				# ...and existing access rule does not contain security identifier...
				if ($ExistingAccessRule.IdentityReference -ne $SecurityIdentifier) {
					# ...continue to next access rule
					continue NextAccessRule
				}
			}

			# if active directory rights provided...
			if ($PSBoundParameters.ContainsKey('Rights')) {
				# ...and existing access rule does not contain active directory rights...
				if ($ExistingAccessRule.ActiveDirectoryRights -ne $Rights) {
					# ...continue to next access rule
					continue NextAccessRule
				}
			}

			# if access control type provided...
			if ($PSBoundParameters.ContainsKey('AccessControlType')) {
				# ...and existing access rule does not contain access control type...
				if ($ExistingAccessRule.ActiveDirectoryRights -ne $AccessControlType) {
					# ...continue to next access rule
					continue NextAccessRule
				}
			}

			# if inheritance type provided...
			if ($PSBoundParameters.ContainsKey('InheritanceType')) {
				# ...and existing access rule does not contain inheritance type...
				if ($ExistingAccessRule.InheritanceType -ne $InheritanceType) {
					# ...continue to next access rule
					continue NextAccessRule
				}
			}

			# if object name provided...
			if ($PSBoundParameters.ContainsKey('ObjectName')) {
				# ...and existing access rule does not contain associated object type...
				if ($ExistingAccessRule.objectType -ne $objectType) {
					# ...continue to next access rule
					continue NextAccessRule
				}
			}

			# if inheriting object name provided...
			if ($PSBoundParameters.ContainsKey('InheritingObjectName')) {
				# ...and existing access rule does not contain associated inherited object type...
				if ($ExistingAccessRule.InheritedObjectType -ne $inheritedObjectType) {
					# ...continue to next access rule
					continue NextAccessRule
				}
			}

			# add existing access rule to list
			$AccessRule.Add($ExistingAccessRule)
		}
	}

	# return ACE objects
	return $AccessRule
}

function New-ADAccessRule {
	<#
	.SYNOPSIS
	Create an Active Directory access rule.

	.DESCRIPTION
	Create an Active Directory access rule.

	.PARAMETER SecurityIdentifier
	The security identifier to include in the access rule.

	.PARAMETER Preset
	One or more strings defining a preset that creates multiple access rules for the provided security identifier.

	.PARAMETER Rights
	The Active Directory rights for the access rule. The default value is 'GenericRead'

	.PARAMETER ObjectName
	The display name of the object type for the access rule.

	.PARAMETER AccessControlType
	The access control type for the access rule. The default value is 'Allow'

	.PARAMETER InheritanceType
	The inheritance type for the access rule. The default value is 'All'

	.PARAMETER InheritingObjectName
	The display name of the inheriting object type for the access rule.

	.PARAMETER AccessRule
	Optional parameter for an existing list of access rules. The access rules created will be added to this list and the updated list will be returned.

	.INPUTS
	System.Security.Principal.SecurityIdentifier.

	.OUTPUTS
	System.Collections.Generic.List[System.DirectoryServices.ActiveDirectoryAccessRule].

	.EXAMPLE
	PS> New-ADAccessRule -SecurityIdentifier (Get-ADSecurityIdentifier -Principal 'Domain Users') -Preset 'ComputerCreate', 'ComputerJoin'

	.EXAMPLE
	PS> New-ADAccessRule -SecurityIdentifier (Get-ADSecurityIdentifier -Principal 'Domain Users') -Rights 'CreateChild' -ObjectName 'Computer' -AccessControlType 'Allow' -InheritanceType 'Descendents' -InheritingObjectName 'organizationalUnit'
	#>

	[CmdletBinding(DefaultParameterSetName = 'Default')]
	param (
		# the security identifier for the access rule
		[Parameter(Mandatory = $true, Position = 0, ValueFromPipeline)]
		[System.Security.Principal.SecurityIdentifier]$SecurityIdentifier,
		# a preset that returns multiple access rules
		[Parameter(Mandatory = $true, Position = 1, ParameterSetName = 'Preset')]
		[string[]]$Preset,
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
		[System.Collections.Generic.List[System.DirectoryServices.ActiveDirectoryAccessRule]]$AccessRule = [System.Collections.Generic.List[System.DirectoryServices.ActiveDirectoryAccessRule]]::new(),
		# string for the server to query for GUIDs of schema objects and extended rights, the default server is the current PDC role owner
		[Parameter(Mandatory = $false)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
	)

	# build directory context from server
	try {
		$DirectoryContext = [System.DirectoryServices.ActiveDirectory.DirectoryContext]::new([System.DirectoryServices.ActiveDirectory.DirectoryContextType]::DirectoryServer, $Server)
	}
	catch {
		throw $_
	}

	# retrieve schema from directory context
	try {
		$Schema = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetSchema($DirectoryContext)
	}
	catch {
		throw $_
	}

	# define script block for ScriptMethod
	$ScriptBlock = {
		# define distinguished name for control access right
		$DistinguishedName = 'LDAP://CN={0},CN=Extended-Rights,{1}' -f $args[0], $this.Name.Split(',', 2)[1]
		# retrieve control access right
		$DirectoryEntry = [System.DirectoryServices.DirectoryEntry]::new($DistinguishedName)
		# if control access right not found...
		if ([string]::IsNullOrEmpty($DirectoryEntry.DistinguishedName)) {
			# create exception
			$Exception = [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException]::new('The Specified directory object cannot be found.')
			# throw error record with exception
			throw [System.Management.Automation.ErrorRecord]::new($Exception, $Exception.GetType().Name, [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
		}
		# create custom control access right object
		$ControlAccessRight = [pscustomobject]@{ 
			Name              = [string]$DirectoryEntry.Name[0]
			DisplayName       = [string]$DirectoryEntry.DisplayName[0]
			DistinguishedName = [string]$DirectoryEntry.DistinguishedName
			AppliesTo         = [guid[]]$DirectoryEntry.appliesTo
			RightsGuid        = [guid]$DirectoryEntry.rightsGUID[0]
			
		}
		# return custom control access right object
		return $ControlAccessRight
	}

	# add script method to schema object
	try {
		Add-Member -InputObject $Schema -Force -MemberType ScriptMethod -Name 'FindControlAccessRight' -Value $ScriptBlock
	}
	catch {
		<#Do this if a terminating exception happens#>
	}

	# if preset provided...
	if ($PSBoundParameters.ContainsKey('Preset')) {
		# process the requested delegation type
		switch ($Preset) {
			'Department' {
				# define ACE: deny 'WriteProperty' on the 'ou' attribute on 'this object only'
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'WriteProperty'
					type                = 'Deny'
					objectType          = $Schema.FindProperty('ou').SchemaGuid
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
					inheritedObjectType = $Schema.FindClass('organizationalUnit').SchemaGuid
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: deny 'CreateChild','DeleteChild' of 'user' objects on 'this object and all child objects'
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'CreateChild', 'DeleteChild'
					type                = 'Deny'
					objectType          = $Schema.FindClass('user').SchemaGuid
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
					objectType          = $Schema.FindClass('inetOrgPerson').SchemaGuid
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
					objectType          = $Schema.FindClass('account').SchemaGuid
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
					objectType          = $Schema.FindClass('computer').SchemaGuid
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
					inheritedObjectType = $Schema.FindClass('computer').SchemaGuid
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
					inheritedObjectType = $Schema.FindClass('msFVE-RecoveryInformation').SchemaGuid
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
					objectType          = $Schema.FindClass('computer').SchemaGuid
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
					objectType          = $Schema.FindClass('computer').SchemaGuid
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
					objectType          = $Schema.FindClass('computer').SchemaGuid
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
					objectType          = $Schema.FindProperty('ms-Mcs-AdmPwd').SchemaGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('computer').SchemaGuid
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
					objectType          = $Schema.FindProperty('msLAPS-Password').SchemaGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('computer').SchemaGuid
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'ReadProperty','ExtendedRight' on the 'msLAPS-EncryptedPassword' attribute on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'ReadProperty', 'ExtendedRight'
					type                = 'Allow'
					objectType          = $Schema.FindProperty('msLAPS-EncryptedPassword').SchemaGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('computer').SchemaGuid
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'ReadProperty','ExtendedRight' on the 'msLAPS-EncryptedPasswordHistory' attribute on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'ReadProperty', 'ExtendedRight'
					type                = 'Allow'
					objectType          = $Schema.FindProperty('msLAPS-EncryptedPasswordHistory').SchemaGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('computer').SchemaGuid
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'ReadProperty' on the 'msLAPS-PasswordExpirationTime' attribute on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'ReadProperty'
					type                = 'Allow'
					objectType          = $Schema.FindProperty('msLAPS-PasswordExpirationTime').SchemaGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('computer').SchemaGuid
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
					inheritedObjectType = $Schema.FindClass('msFVE-RecoveryInformation').SchemaGuid
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
					objectType          = $Schema.FindControlAccessRight('User-Account-Restrictions').RightsGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('computer').SchemaGuid
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'Reset Password' on descendent 'computer' objects"
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'ExtendedRight'
					type                = 'Allow'
					objectType          = $Schema.FindControlAccessRight('User-Force-Change-Password').RightsGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('computer').SchemaGuid
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'Validated write to computer attributes' rights on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'Self'
					type                = 'Allow'
					objectType          = $Schema.FindControlAccessRight('DS-Validated-Write-Computer').RightsGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('computer').SchemaGuid
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'Validated write to DNS host name' rights on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'Self'
					type                = 'Allow'
					objectType          = $Schema.FindControlAccessRight('Validated-DNS-Host-Name').RightsGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('computer').SchemaGuid
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'Validated write to service principal name' rights on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'Self'
					type                = 'Allow'
					objectType          = $Schema.FindControlAccessRight('Validated-SPN').RightsGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('computer').SchemaGuid
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
					objectType          = $Schema.FindProperty('cn').SchemaGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('computer').SchemaGuid
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'ReadProperty','WriteProperty' on the 'sAMAccountName' attribute on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'WriteProperty'
					type                = 'Allow'
					objectType          = $Schema.FindProperty('sAMAccountName').SchemaGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('computer').SchemaGuid
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'WriteProperty' on the 'Account Restrictions' property set on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'WriteProperty'
					type                = 'Allow'
					objectType          = $Schema.FindControlAccessRight('User-Account-Restrictions').RightsGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('computer').SchemaGuid
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'Validated write to computer attributes' rights on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'Self'
					type                = 'Allow'
					objectType          = $Schema.FindControlAccessRight('DS-Validated-Write-Computer').RightsGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('computer').SchemaGuid
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'Validated write to DNS host name' rights on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'Self'
					type                = 'Allow'
					objectType          = $Schema.FindControlAccessRight('Validated-DNS-Host-Name').RightsGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('computer').SchemaGuid
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'Validated write to service principal name' rights on descendent 'computer' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'Self'
					type                = 'Allow'
					objectType          = $Schema.FindControlAccessRight('Validated-SPN').RightsGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('computer').SchemaGuid
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))
			}
			'Contact' {
				# define ACE: allow 'CreateChild','DeleteChild' of 'contact' objects on 'this object and all child objects'
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'CreateChild', 'DeleteChild'
					type                = 'Allow'
					objectType          = $Schema.FindClass('contact').SchemaGuid
					inheritanceType     = 'All'
					inheritedObjectType = [guid]::empty
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'GenericAll' on all descendent 'contact' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'GenericAll'
					type                = 'Allow'
					objectType          = [guid]::empty
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('contact').SchemaGuid
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
					objectType          = $Schema.FindClass('group').SchemaGuid
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
					inheritedObjectType = $Schema.FindClass('group').SchemaGuid
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
					objectType          = $Schema.FindProperty('member').SchemaGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('group').SchemaGuid
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
					objectType          = $Schema.FindProperty('gPLink').SchemaGuid
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
					objectType          = $Schema.FindProperty('gPOptions').SchemaGuid
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
					objectType          = $Schema.FindProperty('gPLink').SchemaGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('organizationalUnit').SchemaGuid
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'ReadProperty','WriteProperty' on the 'gPOptions' attribute on descendent 'organizationalUnit' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'ReadProperty', 'WriteProperty'
					type                = 'Allow'
					objectType          = $Schema.FindProperty('gPOptions').SchemaGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('organizationalUnit').SchemaGuid
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
					objectType          = $Schema.FindClass('organizationalUnit').SchemaGuid
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
					objectType          = $Schema.FindProperty('ou').SchemaGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('organizationalUnit').SchemaGuid
				}

				# create ACE and add to array
				$AccessRule.Add([System.DirectoryServices.ActiveDirectoryAccessRule]::new($Ace['objectSid'], $Ace['adrights'], $Ace['type'], $Ace['objectType'], $Ace['inheritanceType'], $Ace['inheritedObjectType']))

				# define ACE: allow 'WriteProperty' on the 'description' attribute on all descendent 'organizationalUnit' objects
				$Ace = @{
					objectSid           = $SecurityIdentifier
					adRights            = 'ReadProperty', 'WriteProperty'
					type                = 'Allow'
					objectType          = $Schema.FindProperty('description').SchemaGuid
					inheritanceType     = 'Descendents'
					inheritedObjectType = $Schema.FindClass('organizationalUnit').SchemaGuid
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
	else {
		# translate object name to GUID of schema class object, attribute object, or a control access right
		if ($PSBoundParameters.ContainsKey('ObjectName') -and -not [string]::IsNullOrEmpty($local:ObjectName)) {
			$objectType = Get-ADObjectTypeGuid -DisplayName $ObjectName
		}
		else {
			$objectType = [guid]::empty
		}

		# translate inheriting object name to GUID of schema class object
		if ($PSBoundParameters.ContainsKey('InheritingObjectName') -and -not [string]::IsNullOrEmpty($local:InheritingObjectName)) {
			$inheritedObjectType = Get-ADObjectTypeGuid -DisplayName $InheritingObjectName -LimitToSchemaClassObjects
		}
		else {
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
	return $AccessRule
}

function Remove-ADSecurity {
	<#
	.SYNOPSIS
	Remove one or more Active Directory access rules from one or more Active Directory objects.

	.DESCRIPTION
	Remove one or more Active Directory access rules from one or more Active Directory objects.

	.PARAMETER Identity
	One or more Active Directory objects. Each value must be a valid distinguished name for an Active Directory object or a Microsoft.ActiveDirectory.Management.ADObject object.

	.PARAMETER AccessRule
	One or more Active Directory access rules. Each value must be a valid System.DirectoryServices.ActiveDirectoryAccessRule object.

	.INPUTS
	System.Object.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Remove-ADSecurity -Identity 'CN=Computers,DC=example,DC=com' -AccessRule $AccessRules
	#>

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
	foreach ($ActiveDirectoryAccessRule in $AccessRule) {
		if ($ActiveDirectoryAccessRule -isnot [System.DirectoryServices.ActiveDirectoryAccessRule]) {
			Write-Warning -Message 'one or more values for the AccessRule parameter are not an ActiveDirectoryAccessRule object'
			return
		}
	}

	# create list for Active Directory objects
	$ADObjects = [System.Collections.Generic.List[Microsoft.ActiveDirectory.Management.ADObject]]::new()

	# retrieve Active Directory objects for each identity
	foreach ($Object in $Identity) {
		# if object is an ADObject...
		if ($Object -is [Microsoft.ActiveDirectory.Management.ADObject]) {
			# add object to list and continue
			$ADObjects.Add($Object)
		}
		# if object is a string...
		elseif ($Object -is [System.String]) {
			# get ADObject using object as identity
			try {
				$ADObject = Get-ADObject -Server $Server -Identity $Object -Properties 'nTSecurityDescriptor'
			}
			catch {
				Write-Warning -Message "could not retrieve object for input: '$Object'"
				return $_
			}
			# add ADObject to list and continue
			$ADObjects.Add($ADObject)
		}
		# if object is not an ADObject or a string...
		else {
			# warn and return
			Write-Warning -Message "could not process '[$($Object.GetType().FullName)]' object type for object: '$Object'"
			return
		}
	}

	# reset security descriptors for each object
	foreach ($ADObject in $ADObjects) {
		# check object for nTSecurityDescriptor property
		if ($null -eq $ADObject.nTSecurityDescriptor) {
			try {
				$ADObject = Get-ADObject -Server $Server -Identity $ADObject.DistinguishedName -Properties 'nTSecurityDescriptor'
			}
			catch {
				Write-Warning -Message "could not retrieve nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
				return $_
			}
		}

		# retrieve nTSecurityDescriptor from object
		$nTSecurityDescriptor = $ADObject.nTSecurityDescriptor

		# validate nTSecurityDescriptor object type
		if ($nTSecurityDescriptor -isnot [System.DirectoryServices.ActiveDirectorySecurity]) {
			Write-Warning -Message "found invalid '[$($nTSecurityDescriptor.GetType().FullName)]' object type for nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			return $_
		}

		# process each provided access rule
		foreach ($ActiveDirectoryAccessRule in $AccessRule) {
			# remove provided access rule
			try {
				$nTSecurityDescriptor.RemoveAccessRuleSpecific($ActiveDirectoryAccessRule)
			}
			catch {
				Write-Warning -Message "could not remove specific access rule from object: '$($ADObject.DistinguishedName)'"
				return $_
			}
		}

		# process each provided security identifier
		foreach ($IdentityReference in $SecurityIdentifier) {
			# remove access rule with identity reference matching security identifier
			try {
				$nTSecurityDescriptor.PurgeAccessRules($IdentityReference)
			}
			catch {
				Write-Warning -Message "could not remove access rule for '$IdentityReference' from object: '$($ADObject.DistinguishedName)'"
				return $_
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
		try {
			Set-ADObject @SetADObject
		}
		catch {
			Write-Warning -Message "could not update nTSecurityDescriptor on object: '$($ADObject.DistinguishedName)'"
			return $_
		}
	}
}

function Revoke-ADSecurity {
	<#
	.SYNOPSIS
	Remove Active Directory access rules containing the provided security identifiers from one or more Active Directory objects.

	.DESCRIPTION
	Remove Active Directory access rules containing the provided security identifiers from one or more Active Directory objects.

	.PARAMETER Identity
	One or more Active Directory objects. Each value must be a valid distinguished name for an Active Directory object or a Microsoft.ActiveDirectory.Management.ADObject object.

	.PARAMETER SecurityIdentifier
	One or more security identifiers. Each value must be a valid System.Security.Principal.SecurityIdentifier object.

	.INPUTS
	System.Object.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Revoke-ADSecurity -Identity 'CN=Computers,DC=example,DC=com' -SecurityIdentifier $SecurityIdentifier
	#>

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
	foreach ($Object in $SecurityIdentifier) {
		if ($Object -isnot [System.Security.Principal.SecurityIdentifier]) {
			Write-Warning -Message 'one or more values for the SecurityIdentifier parameter are not a SecurityIdentifier object'
			return
		}
	}

	# create list for Active Directory objects
	$ADObjects = [System.Collections.Generic.List[Microsoft.ActiveDirectory.Management.ADObject]]::new()

	# retrieve Active Directory objects for each identity
	foreach ($Object in $Identity) {
		# if object is an ADObject...
		if ($Object -is [Microsoft.ActiveDirectory.Management.ADObject]) {
			# add object to list and continue
			$ADObjects.Add($Object)
		}
		# if object is a string...
		elseif ($Object -is [System.String]) {
			# get ADObject using object as identity
			try {
				$ADObject = Get-ADObject -Server $Server -Identity $Object -Properties 'nTSecurityDescriptor'
			}
			catch {
				Write-Warning -Message "could not retrieve object for input: '$Object'"
				return $_
			}
			# add ADObject to list and continue
			$ADObjects.Add($ADObject)
		}
		# if object is not an ADObject or a string...
		else {
			# warn and return
			Write-Warning -Message "could not process '[$($Object.GetType().FullName)]' object type for object: '$Object'"
			return
		}
	}

	# reset security descriptors for each object
	foreach ($ADObject in $ADObjects) {
		# check object for nTSecurityDescriptor property
		if ($null -eq $ADObject.nTSecurityDescriptor) {
			try {
				$ADObject = Get-ADObject -Server $Server -Identity $ADObject.DistinguishedName -Properties 'nTSecurityDescriptor'
			}
			catch {
				Write-Warning -Message "could not retrieve nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
				return $_
			}
		}

		# retrieve nTSecurityDescriptor from object
		$nTSecurityDescriptor = $ADObject.nTSecurityDescriptor

		# validate nTSecurityDescriptor object type
		if ($nTSecurityDescriptor -isnot [System.DirectoryServices.ActiveDirectorySecurity]) {
			Write-Warning -Message "found invalid '[$($nTSecurityDescriptor.GetType().FullName)]' object type for nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			return $_
		}

		# process each provided security identifier
		foreach ($IdentityReference in $SecurityIdentifier) {
			# remove access rule with identity reference matching security identifier
			try {
				$nTSecurityDescriptor.PurgeAccessRules($IdentityReference)
			}
			catch {
				Write-Warning -Message "could not revoke access for '$IdentityReference' from object: '$($ADObject.DistinguishedName)'"
				return $_
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
		try {
			Set-ADObject @SetADObject
		}
		catch {
			Write-Warning -Message "could not update nTSecurityDescriptor on object: '$($ADObject.DistinguishedName)'"
			return $_
		}
	}
}

function Reset-ADSecurity {
	<#
	.SYNOPSIS
	Reset the Active Directory access rules on one or more Active Directory objects.

	.DESCRIPTION
	Replaces all explicitly defined access rules on the Active Directory object with the default access rules from the schema definition of the object type.

	.PARAMETER Identity
	One or more Active Directory objects. Each value must be a valid distinguished name for an Active Directory object or a Microsoft.ActiveDirectory.Management.ADObject object.

	.PARAMETER Owner
	Optional parameter to update the owner of the Active Directory objects. The caller must possess the SeSecurityPrivilege on domain controllers to update the owner of Active Directory objects.

	.PARAMETER Inheritance
	Optional parameter to update the inheritance of the Active Directory objects.

	.INPUTS
	System.Object.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Revoke-ADSecurity -Identity 'CN=Computers,DC=example,DC=com' -SecurityIdentifier $SecurityIdentifier
	#>

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
	if ($PSBoundParameters.ContainsKey('Owner') -and $Owner -isnot [System.Security.Principal.SecurityIdentifier]) {
		# get owner SID
		try {
			$Owner = Get-ADSecurityIdentifier -Principal $Owner
		}
		catch {
			Write-Warning -Message "could not retrieve SID for owner: '$Owner'"
			return $_
		}
	}

	# create list for Active Directory objects
	$ADObjects = [System.Collections.Generic.List[Microsoft.ActiveDirectory.Management.ADObject]]::new()

	# retrieve Active Directory objects for each identity
	foreach ($Object in $Identity) {
		# if object is an ADObject...
		if ($Object -is [Microsoft.ActiveDirectory.Management.ADObject]) {
			# add object to list and continue
			$ADObjects.Add($Object)
		}
		# if object is a string...
		elseif ($Object -is [System.String]) {
			# get ADObject using object as identity
			try {
				$ADObject = Get-ADObject -Server $Server -Identity $Object -Properties 'nTSecurityDescriptor'
			}
			catch {
				Write-Warning -Message "could not retrieve object for input: '$Object'"
				return $_
			}
			# add ADObject to list and continue
			$ADObjects.Add($ADObject)
		}
		# if object is not an ADObject or a string...
		else {
			# warn and return
			Write-Warning -Message "could not process '[$($Object.GetType().FullName)]' object type for object: '$Object'"
			return
		}
	}

	# create hashtable for default security descriptors
	$defaultSecurityDescriptors = @{}

	# retrieve default security descriptors for each object class
	foreach ($ADObject in $ADObjects) {
		# if object class not in hashtable for default security descriptors...
		if (!$defaultSecurityDescriptors.ContainsKey($ADObject.objectClass)) {
			# retrieve default security descriptor for object class
			try {
				$defaultSecurityDescriptors[$ADObject.objectClass] = Get-ADObjectTypeDefaultAccessRule -DisplayName $ADObject.objectClass
			}
			catch {
				Write-Warning -Message "could not retrieve default security descriptor for object class: '$($ADObject.objectClass)'"
				return $_
			}
		}
	}

	# reset security descriptors for each object
	foreach ($ADObject in $ADObjects) {
		# check object for nTSecurityDescriptor property
		if ($null -eq $ADObject.nTSecurityDescriptor) {
			try {
				$ADObject = Get-ADObject -Server $Server -Identity $ADObject.DistinguishedName -Properties 'nTSecurityDescriptor'
			}
			catch {
				Write-Warning -Message "could not retrieve nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
				return $_
			}
		}

		# retrieve nTSecurityDescriptor from object
		$nTSecurityDescriptor = $ADObject.nTSecurityDescriptor

		# validate nTSecurityDescriptor object type
		if ($nTSecurityDescriptor -isnot [System.DirectoryServices.ActiveDirectorySecurity]) {
			Write-Warning -Message "found invalid '[$($nTSecurityDescriptor.GetType().FullName)]' object type for nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			return $_
		}

		# if inheritance set...
		if ($PSBoundParameters.ContainsKey('Inheritance')) {
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
		else {
			# retrieve inheritance settings from security descriptor
			$IsProtected = $nTSecurityDescriptor.AreAccessRulesProtected
		}

		# disable inheritance and remove inherited access rules from object
		try {
			$nTSecurityDescriptor.SetAccessRuleProtection($true, $false)
		}
		catch {
			Write-Warning -Message "could not disable inheritance on nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			return $_
		}

		# process each existing access rule
		foreach ($AccessRule in $nTSecurityDescriptor.Access) {
			# remove existing access rule from security descriptor
			try {
				$nTSecurityDescriptor.RemoveAccessRuleSpecific($AccessRule)
			}
			catch {
				Write-Warning -Message "could not remove access rule on nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
				return $_
			}
		}

		# set security descriptor to default value for object class
		try {
			$nTSecurityDescriptor.SetSecurityDescriptorSddlForm($defaultSecurityDescriptors[$ADObject.objectClass])
		}
		catch {
			Write-Warning -Message "could not copy default security descriptor to nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			return $_
		}

		# set inheritance on security descriptor and copy inherited rules if inheritance enabled
		try {
			$nTSecurityDescriptor.SetAccessRuleProtection($IsProtected, $true)
		}
		catch {
			Write-Warning -Message "could not configure inheritance on nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			return $_
		}

		# if owner provided...
		if ($PSBoundParameters.ContainsKey('Owner')) {
			# set owner on security descriptor
			try {
				$nTSecurityDescriptor.SetOwner($OwnerSid)
			}
			catch {
				Write-Warning -Message "could not set owner in nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
				return $_
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
		try {
			Set-ADObject @SetADObject
		}
		catch {
			Write-Warning -Message "could not update nTSecurityDescriptor on object: '$($ADObject.DistinguishedName)'"
			return $_
		}
	}
}

function Update-ADSecurity {
	<#
	.SYNOPSIS
	Updates the Active Directory access rules on one or more Active Directory objects.

	.DESCRIPTION
	Updates the Active Directory access rules on one or more Active Directory objects.

	.PARAMETER Identity
	One or more Active Directory objects. Each value must be a valid distinguished name for an Active Directory object or a Microsoft.ActiveDirectory.Management.ADObject object.

	.PARAMETER AccessRule
	One or more Active Directory access rules. Each value must be a valid System.DirectoryServices.ActiveDirectoryAccessRule object.

	.PARAMETER Inheritance
	Optional parameter to update the inheritance of the Active Directory objects. The supported values are:
	- Enable: enables inheritance on the object
	- Disable: disables inheritance on the object and converts all inherited access rules to explicit access rules
	- Remove: disables inheritance on the object and removes all inherited access rules from the object, this option will cause an error if no explicitly defined access rules exist

	.PARAMETER Reset
	Optional parameter to remove any existing access rules matching the identity reference in the provided access rules.

	.INPUTS
	System.Object.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Update-ADSecurity -Identity 'CN=Computers,DC=example,DC=com' -AccessRule $AccessRules

	.EXAMPLE
	PS> Update-ADSecurity -Identity 'CN=Computers,DC=example,DC=com' -AccessRule $AccessRules -Inheritance 'Enable'
	#>

	param (
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
	foreach ($ActiveDirectoryAccessRule in $AccessRule) {
		if ($ActiveDirectoryAccessRule -isnot [System.DirectoryServices.ActiveDirectoryAccessRule]) {
			Write-Warning -Message 'one or more values for the AccessRule parameter are not an ActiveDirectoryAccessRule'
			return
		}
	}

	# create list for Active Directory objects
	$ADObjects = [System.Collections.Generic.List[Microsoft.ActiveDirectory.Management.ADObject]]::new()

	# retrieve Active Directory objects for each identity
	foreach ($Object in $Identity) {
		# if object is an ADObject...
		if ($Object -is [Microsoft.ActiveDirectory.Management.ADObject]) {
			# add object to list and continue
			$ADObjects.Add($Object)
		}
		# if object is a string...
		elseif ($Object -is [System.String]) {
			# get ADObject using object as identity
			try {
				$ADObject = Get-ADObject -Server $Server -Identity $Object -Properties 'nTSecurityDescriptor'
			}
			catch {
				Write-Warning -Message "could not retrieve object for input: '$Object'"
				return $_
			}
			# add ADObject to list and continue
			$ADObjects.Add($ADObject)
		}
		# if object is not an ADObject or a string...
		else {
			# warn and return
			Write-Warning -Message "could not process '[$($Object.GetType().FullName)]' object type for object: '$Object'"
			return
		}
	}

	# update security descriptors for each object
	:NextObject foreach ($ADObject in $ADObjects) {
		# check object for nTSecurityDescriptor property
		if ($null -eq $ADObject.nTSecurityDescriptor) {
			try {
				$ADObject = Get-ADObject -Server $Server -Identity $ADObject.DistinguishedName -Properties 'nTSecurityDescriptor'
			}
			catch {
				Write-Warning -Message "could not retrieve nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
				return $_
			}
		}

		# retrieve nTSecurityDescriptor from object
		$nTSecurityDescriptor = $ADObject.nTSecurityDescriptor

		# validate nTSecurityDescriptor object type
		if ($nTSecurityDescriptor -isnot [System.DirectoryServices.ActiveDirectorySecurity]) {
			Write-Warning -Message "found invalid '[$($nTSecurityDescriptor.GetType().FullName)]' object type for nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			return $_
		}

		# if inheritance changes requested...
		if ($PSBoundParameters.ContainsKey('Inheritance')) {
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
			if ($Inheritance -eq 'Remove' -and -not $nTSecurityDescriptor.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) -and -not $PSBoundParameters.ContainsKey('AccessRule')) {
				Write-Warning -Message "cannot disable inheritance and remove inherited access rules when all existing access rules are inherited and AccessRule parameter is not set; could not remove inheritance for object: '$($ADObject.DistinguishedName)'"
				return
			}

			# update inheritance settings
			try {
				$nTSecurityDescriptor.SetAccessRuleProtection($IsProtected, $PreserveInheritance)
			}
			catch {
				Write-Warning -Message "could not modify inheritance of ACL on object: '$($ADObject.DistinguishedName)'"
				return $_
			}
		}

		# if reset requested...
		if ($local:Reset) {
			# retrieve unique identity references in provided access rules
			$IdentityReferences = $AccessRule.IdentityReference | Select-Object -Unique

			# retrieve existing access rules that are explicitly defined and not inherited for the unique identity references
			$ExistingAccessRules = $nTSecurityDescriptor.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]).Where({ $_.IdentityReference -in $IdentityReferences })

			# process each existing access rule
			foreach ($ExistingAccessRule in $ExistingAccessRules) {
				# remove existing access rule
				try {
					$nTSecurityDescriptor.RemoveAccessRuleSpecific($ExistingAccessRule)
				}
				catch {
					Write-Warning -Message "could not remove existing access rules for '$($ExistingAccessRule.IdentityReference)' from object: '$($ADObject.DistinguishedName)'"
					return $_
				}
			}
		}

		# process each provided access rule
		foreach ($ActiveDirectoryAccessRule in $AccessRule) {
			# add provided access rule
			try {
				$nTSecurityDescriptor.AddAccessRule($ActiveDirectoryAccessRule)
			}
			catch {
				Write-Warning -Message "could not add access rule to object: '$($ADObject.DistinguishedName)'"
				return $_
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
		try {
			Set-ADObject @SetADObject
		}
		catch {
			Write-Warning -Message "could not update nTSecurityDescriptor on object: '$($ADObject.DistinguishedName)'"
			return $_
		}
	}
}

# define functions to export
$FunctionsToExport = @(
	'Get-ADObjectTypeDefaultAccessRule'
	'Get-ADObjectTypeGuid'
	'Get-ADPrincipal'
	'Get-ADSecurityIdentifier'
	'Get-ADAccessRule'
	'New-ADAccessRule'
	'Remove-ADSecurity'
	'Revoke-ADSecurity'
	'Reset-ADSecurity'
	'Update-ADSecurity'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport