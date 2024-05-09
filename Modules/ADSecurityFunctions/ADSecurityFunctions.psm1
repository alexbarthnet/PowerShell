#Requires -Modules ActiveDirectory

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

Function Get-ADSecurityObjects {
	[CmdletBinding()]
	Param(
		[Parameter(Position = 0)]
		[switch]$Force
	)

	# try catch for error handling
	Try {
		# retrieve servers
		If ($Force -or $null -eq $ad_dc_pdc) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_dc_pdc' -Value ([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name) }
		If ($Force -or $null -eq $ad_dc_rid) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_dc_rid' -Value ([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().RidRoleOwner.Name) }
		If ($Force -or $null -eq $ad_dc_ism) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_dc_ism' -Value ([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().InfrastructureRoleOwner.Name) }
		If ($Force -or $null -eq $ad_dc_schema) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_dc_schema' -Value ([System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().SchemaRoleOwner.Name) }
		If ($Force -or $null -eq $ad_dc_naming) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_dc_naming' -Value ([System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().NamingRoleOwner.Name) }
		If ($Force -or $null -eq $ad_dc_active) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_dc_active' -Value ([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().FindDomainController().Name) }

		# retrieve naming contexts
		If ($Force -or $null -eq $ad_nc_domain) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_nc_domain' -Value ([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName) }
		If ($Force -or $null -eq $ad_nc_schema) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_nc_schema' -Value ([System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema().Name) }
		If ($Force -or $null -eq $ad_nc_config) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_nc_config' -Value $ad_nc_schema.Split(',', 2)[1] }

		# retrieve guids
		If ($Force -or $null -eq $ad_guids_schema) { New-Variable -Force -Scope 'Private' -Option 'ReadOnly' -Name 'ad_guids_schema' -Value (Get-ADObject -SearchBase $ad_nc_schema -LDAPFilter '(schemaidguid=*)' -Properties 'lDAPDisplayName', 'schemaIDGUID') }
		If ($Force -or $null -eq $ad_guids_rights) { New-Variable -Force -Scope 'Private' -Option 'ReadOnly' -Name 'ad_guids_rights' -Value (Get-ADObject -SearchBase $ad_nc_config -LDAPFilter '(&(objectclass=controlAccessRight)(rightsguid=*))' -Properties 'displayName', 'rightsGuid') }

		# create and populate hash tables
		If ($Force -or $null -eq $ad_map_rights) {
			New-Variable -Force -Scope 'Private' -Name 'ad_map_rights_to_guid' -Value @{}
			ForEach ($guid in $ad_guids_rights) { $ad_map_rights_to_guid[$guid.displayName] = $guid.rightsGuid }
			New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_map_rights' -Value $ad_map_rights_to_guid
		}
		If ($Force -or $null -eq $ad_map_schema) {
			New-Variable -Force -Scope 'Private' -Name 'ad_map_schema_to_guid' -Value @{}
			ForEach ($guid in $ad_guids_schema) { $ad_map_schema_to_guid[$guid.lDAPDisplayName] = [guid]$guid.schemaIDGUID }
			New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_map_schema' -Value $ad_map_schema_to_guid
		}
		If ($Force -or $null -eq $ad_map_rights_reverse) {
			New-Variable -Force -Scope 'Private' -Name 'ad_map_guid_to_rights' -Value @{}
			ForEach ($guid in $ad_guids_rights) { $ad_map_guid_to_rights[$guid.rightsGuid] = $guid.displayName }
			New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_map_rights_reverse' -Value $ad_map_guid_to_rights
		}
		If ($Force -or $null -eq $ad_map_schema_reverse) {
			New-Variable -Force -Scope 'Private' -Name 'ad_map_guid_to_schema' -Value @{}
			ForEach ($guid in $ad_guids_schema) { $ad_map_guid_to_schema[[guid]$guid.schemaIDGUID] = $guid.lDAPDisplayName }
			New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_map_schema_reverse' -Value $ad_map_guid_to_schema
		}

		# create strings for access control types
		# see reference at https://docs.microsoft.com/en-us/dotnet/api/system.security.accesscontrol.accesscontroltype
		If ($Force -or $null -eq $ad_accesstype_allow) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_accesstype_allow' -Value 'Allow' } #right(s) will be allowed
		If ($Force -or $null -eq $ad_accesstype_deny) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_accesstype_deny' -Value 'Deny' } #right(s) will be denied

		# create strings for active directory rights
		# see reference at https://docs.microsoft.com/en-us/dotnet/api/system.directoryservices.activedirectoryrights
		If ($Force -or $null -eq $ad_rights_ga) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_rights_ga' -Value 'GenericAll' }
		If ($Force -or $null -eq $ad_rights_gr) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_rights_gr' -Value 'GenericRead' }
		If ($Force -or $null -eq $ad_rights_gw) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_rights_gw' -Value 'GenericWrite' }
		If ($Force -or $null -eq $ad_rights_rp) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_rights_rp' -Value 'ReadProperty' }
		If ($Force -or $null -eq $ad_rights_wp) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_rights_wp' -Value 'WriteProperty' }
		If ($Force -or $null -eq $ad_rights_rd) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_rights_rd' -Value 'ReadDacl' }
		If ($Force -or $null -eq $ad_rights_wd) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_rights_wd' -Value 'WriteDacl' }
		If ($Force -or $null -eq $ad_rights_cc) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_rights_cc' -Value 'CreateChild' }
		If ($Force -or $null -eq $ad_rights_dc) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_rights_dc' -Value 'DeleteChild' }
		If ($Force -or $null -eq $ad_rights_ca) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_rights_ca' -Value 'ExtendedRight' }
		If ($Force -or $null -eq $ad_rights_sw) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_rights_sw' -Value 'Self' }

		# create strings for active directory inheritances
		# note: the spelling of "descendents" below is intentional by Microsoft
		# see reference at https://docs.microsoft.com/en-us/dotnet/api/system.directoryservices.activedirectorysecurityinheritance
		If ($Force -or $null -eq $ad_inherit_all) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_inherit_all' -Value 'All' } #self and all descendents
		If ($Force -or $null -eq $ad_inherit_desc) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_inherit_desc' -Value 'Descendents' } #all descendents without self
		If ($Force -or $null -eq $ad_inherit_none) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_inherit_none' -Value 'None' } #self only
		If ($Force -or $null -eq $ad_inherit_children) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_inherit_children' -Value 'Children' } # immediate descendents only
		If ($Force -or $null -eq $ad_inherit_selfandchildren) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_inherit_selfandchildren' -Value 'SelfAndChildren' } # self and immediate descendents only

		# create SIDs for well-known objects
		# see reference at https://docs.microsoft.com/en-us/dotnet/api/system.directoryservices.activedirectorysecurityinheritance
		If ($Force -or $null -eq $ad_sid_ownerrights) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_sid_ownerrights' -Value ([System.Security.Principal.SecurityIdentifier]('S-1-3-4')) }
		If ($Force -or $null -eq $ad_sid_system) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_sid_system' -Value ([System.Security.Principal.SecurityIdentifier]('S-1-5-18')) }
		If ($Force -or $null -eq $ad_sid_administrators) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_sid_administrators' -Value ([System.Security.Principal.SecurityIdentifier]('S-1-5-32-544')) }
	}
	Catch {
		# return the error
		$_
	}
}

Function Reset-ADSecurity {
	[CmdletBinding()]
	param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[object[]]$Identity,
		[Parameter(Position = 1)]
		[object]$Owner,
		[Parameter(Position = 1)]
		[switch]$ForceInheritance,
		[Parameter(Position = 2)]
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
		# check hashtable for default security descriptor of object class
		If (!$defaultSecurityDescriptors.ContainsKey($ADObject.objectClass)) {
			# define parameters for Get-ADObject
			$GetADObject = @{
				Filter      = "ldapDisplayName -eq '$($ADObject.objectClass)'"
				Properties  = 'defaultSecurityDescriptor'
				SearchBase  = [System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema().Name
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			Try {
				$defaultSecurityDescriptors[$ADObject.objectClass] = (Get-ADObject @GetADObject).defaultSecurityDescriptor
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

		# retrieve inheritance settings
		$InheritanceEnabled = $nTSecurityDescriptor.AreAccessRulesProtected

		# remove inheritance from object
		try {
			$nTSecurityDescriptor.SetAccessRuleProtection($true, $false)
		}
		catch {
			Write-Warning -Message "could not remove inheritance from nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			Continue NextObject
		}

		# remove existing ACEs from object
		$nTSecurityDescriptor.Access | ForEach-Object { $nTSecurityDescriptor.RemoveAccessRuleSpecific($_) }

		# add default SDDL to ACL
		try {
			$nTSecurityDescriptor.SetSecurityDescriptorSddlForm($defaultSecurityDescriptors[$ADObject.objectClass])
		}
		catch {
			Write-Warning -Message "could not copy default security descriptor to nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
			Continue NextObject
		}

		# if inheritance is required or was previously enabled...
		If ($ForceInheritance -or $InheritanceEnabled) {
			# enable inheritance on object
			try {
				$nTSecurityDescriptor.SetAccessRuleProtection($false, $false)
			}
			catch {
				Write-Warning -Message "could not restore inheritance from nTSecurityDescriptor for object: '$($ADObject.DistinguishedName)'"
				Continue NextObject
			}
		}

		# if owner provided...
		If ($PSBoundParameters.ContainsKey('Owner')) { 
			try {
				$nTSecurityDescriptor.SetOwner($OwnerSid)
			}
			catch {
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
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[object[]]$Identity,
		[Parameter(Position = 1)]
		[object[]]$AccessRules,
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
	ForEach ($ActiveDirectoryAccessRule in $AccessRules) {
		If ($ActiveDirectoryAccessRule -isnot [System.DirectoryServices.ActiveDirectoryAccessRule]) {
			Write-Warning -Message 'one or more values for the AccessRules parameter are not an ActiveDirectoryAccessRules'
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
			If ($Inheritance -eq 'Remove' -and -not $nTSecurityDescriptor.Access.Where({ !$_.IsInherited }) -and -not $KeepInheritedRulesForEmptyACL -and -not $PSBoundParameters.ContainsKey('AccessRules')) {
				# ...and keep inherited rules for empty ACL was set...
				If ($KeepInheritedRulesForEmptyACL) {
					# retain inherited permissions
					$KeepInheritedRules = $true
				}
				# ...and no access rules provided to fill otherwise empty ACL...
				ElseIf (-not $PSBoundParameters.ContainsKey('AccessRules')) {
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
			If ($PSBoundParameters.ContainsKey('AccessRules')) {
				# process each provided access rule...
				ForEach ($AccessRule in $AccessRules) {
					# ...and remove existing access rules matching the identity in the provided access rule
					Try {
						$nTSecurityDescriptor.PurgeAccessRules($AccessRule.IdentityReference)
						Write-Warning "removed existing access rules for '$($AccessRule.IdentityReference)' from object: '$($ADObject.DistinguishedName)'"
					}
					Catch {
						Write-Warning -Message "could not remove existing access rules for '$($AccessRule.IdentityReference)' from object: '$($ADObject.DistinguishedName)'"
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
		ForEach ($AccessRule in $AccessRules) {
			Try {
				$nTSecurityDescriptor.AddAccessRule($AccessRule)
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

# load the AD security objects on module load
Get-ADSecurityObjects -Force

# define functions to export
$FunctionsToExport = @(
	'Get-ADSecurityIdentifier'
	'Get-ADSecurityObjects'
	'Reset-ADSecurity'
	'Update-ADSecurity'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport