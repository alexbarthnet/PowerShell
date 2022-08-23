#Requires -Modules ActiveDirectory

Function Get-ADSecurityIdentifier {
	[CmdletBinding()]
	param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[object]$Principal
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
			{ ($_ -eq 'Windows Authorization Access Group') -or ($_ -eq "$([System.Environment]::UserDomainName)\Windows Authorization Access Group") } {
				Return [System.Security.Principal.SecurityIdentifier]('S-1-5-32-560')
			}
			# a SID in string format
			{ ($_ -match 'S-1-\d{1,2}-\d+') } {
				Return [System.Security.Principal.SecurityIdentifier]($Principal)
			}
			# a principal with domain prefix or suffix
			{ ($_ -match '^[\w\s\.-]+\\[\w\s\.-]+$') -or ($_ -match '^[\w\.-]+@[\w\.-]+$') } {
				Return ([System.Security.Principal.NTAccount]($Principal)).Translate([System.Security.Principal.SecurityIdentifier])
			}
			# a principal without domain prefix or suffix
			Default {
				Return ([System.Security.Principal.NTAccount]("$([System.Environment]::UserDomainName)\$Principal")).Translate([System.Security.Principal.SecurityIdentifier])
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

Function New-ADCustomPSDrive {
	Param(
		[Parameter(Position = 0)]
		[string]$Name = 'ADCustom',
		[Parameter(Position = 1)]
		[string]$Server = $ad_dc_pdc,
		[Parameter(Position = 2)]
		[switch]$Force,
		[Parameter(Position = 3)]
		[switch]$Passthru
	)

	Try {
		# check for PSDrive with with matching Name
		$ad_custom_psdrive = $null
		$ad_custom_psdrive = Get-PSDrive -Scope 'Global' | Where-Object { $_.Name -eq $Name }

		# set Force if found PSDrive has incorrect values
		If ($ad_custom_psdrive.Server -ne $Server -or $ad_custom_psdrive.Root -ne '//RootDSE/' -or -not $ad_custom_psdrive.Provider -match 'ActiveDirectory$') {
			$Force = $true
		}

		# remove found PSDrive if Force set
		If ($Force) {
			$ad_custom_psdrive | Remove-PSDrive -Force -ErrorAction 'SilentlyContinue' -Scope 'Global'
			$ad_custom_psdrive = $null
		}

		# create PSdrive with correct values
		If ($null -eq $ad_custom_psdrive) {
			$ad_custom_psdrive = New-PSDrive -Name $Name -Server $Server -PSProvider 'ActiveDirectory' -Root '//RootDSE/' -Scope 'Global'
		}

		# return object if requested
		If ($Passthru) {
			$ad_custom_psdrive
		}
	}
	Catch {
		$_
	}
}

Function Remove-ADCustomPSDrive {
	Param(
		[Parameter(Position = 0)]
		[string]$Name = 'ADCustom'
	)

	Try {
		# check for PSDrive with with matching Name
		$ad_custom_psdrive = $null
		$ad_custom_psdrive = Get-PSDrive -Scope 'Global' | Where-Object { $_.Name -eq $Name }

		# check for PSdrive with matching Name
		If ($ad_custom_psdrive) {
			# remove any PSdrive with with matching Name
			$ad_custom_psdrive | Remove-PSDrive -Force -Scope 'Global'
		}
	}
	Catch {
		$_
	}
}

Function Reset-ADSecurity {
	[CmdletBinding()]
	param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[object[]]$Identity,
		[Parameter(Position = 1)]
		[string]$Owner,
		[Parameter(Position = 2)]
		[string]$Server = $ad_dc_pdc
	)

	# create custom PSdrive if requested
	If ($null -ne $Server) {
		Try {
			$ad_psdrive = (New-ADCustomPSDrive -Server $Server -Passthru).Name
		}
		Catch {
			Write-Host "ERROR: creating custom PSDrive for server: '$Server'"
			Return
		}
	}
	Else {
		$ad_psdrive = 'AD'
	}

	# create empty objects
	$ad_owner = $null
	$ad_objects = @()
	$ad_defaultsddl = @{}

	# retrieve owner SID if requested
	If ([string]::IsNullOrEmpty($Owner)) {
		Try {
			$ad_owner = ([System.Security.Principal.NTAccount]($Owner)).Translate([System.Security.Principal.SecurityIdentifier])
		}
		Catch {
			Write-Host "ERROR: could not retrieve SID for owner: '$Owner'"
		}
	}

	# retrieve objects from input
	:ad_identity ForEach ($ad_identity in $Identity) {
		If ($ad_identity -is [Microsoft.ActiveDirectory.Management.ADObject]) {
			# if an ADObject, retrieve the DN
			$ad_objects += $ad_identity
		}
		ElseIf ($ad_object -is [System.String]) {
			# if a string, assume value is the object DN
			Try {
				$ad_objects += Get-ADObject -Identity $ad_identity
			}
			Catch {
				Write-Host "ERROR: could not retrieve object for '$ad_identity'"
			}
		}
		Default {
			# if any other object type, continue to next iteration of foreeach loop
			Write-Host "ERROR: could not process object type: '[$($ad_identity.GetType().FullName)]'"
		}
	}

	# process objects retrieved from input
	:ad_object ForEach ($ad_object in $ad_objects) {
		# retrieve object class
		Try {
			$ad_class = $ad_object.objectClass
		}
		Catch {
			Write-Host "ERROR: could not retrieve object class for: '$($ad_object.DistinguishedName)'"
		}
		

		# check hashtable for default security descriptor of object class
		If ([string]::IsNullOrEmpty($ad_defaultsddl[$ad_class])) {
			Try {
				$ad_defaultsddl[$ad_class] = (Get-ADObject -Filter "ldapDisplayName -eq '$ad_class'" -SearchBase $ad_nc_schema -Properties 'defaultSecurityDescriptor').defaultSecurityDescriptor
			}
			Catch {
				Write-Host "ERROR: could not retrieve default security descriptor for object class: '$ad_class'"
				Continue ad_object
			}
		}

		# get ACL for object
		$ad_path = $ad_psdrive, $ad_object.DistinguishedName -join ':\'
		$ad_acl = Get-Acl -Path $ad_path

		# remove inheritance from object
		$ad_acl.SetAccessRuleProtection($true, $false)

		# remove existing ACEs from object
		$ad_acl.Access | ForEach-Object { $ad_acl.RemoveAccessRule($_) } | Out-Null
		
		# add default SDDL to ACL
		$ad_acl.SetSecurityDescriptorSddlForm($ad_sddl)
		
		# enable inheritance on object
		$ad_acl.SetAccessRuleProtection($false, $false)

		# set owner on ACL if provided
		If ($null -ne $ad_owner) { $ad_acl.SetOwner($ad_owner) }
		
		# set ACL for object
		$ad_acl | Set-Acl -Path $ad_path
	}

	# remove custom PSdrive if created
	If ($null -ne $Server) {
		Try {
			Remove-ADCustomPSDrive
		}
		Catch {
			Write-Host 'ERROR: removing custom PSDrive'
		}
	}
}

Function Update-ADSecurity {
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[object[]]$Objects,
		[Parameter(Position = 1)]
		[object[]]$Permissions,
		[Parameter(Position = 2)][ValidateScript({ $_ -is [System.Security.Principal.SecurityIdentifier] })]
		[object]$SID,
		[Parameter(Position = 3)][ValidateSet('Enable', 'Disable', 'Remove')]
		[string]$Inheritance,
		[Parameter(Position = 4)]
		[string]$Server = $ad_dc_pdc,
		[Parameter(Position = 5)]
		[switch]$Reset
	)

	# create custom PSdrive if requested
	If ($null -ne $Server) {
		Try {
			$ad_psdrive = (New-ADCustomPSDrive -Server $Server -Passthru).Name
		}
		Catch {
			Write-Host "ERROR: creating 'ADCustom' PSDrive for server: '$Server'"
			Break
		}
	}
	Else {
		$ad_psdrive = 'AD'
	}

	# create empty array
	$ad_object_fqdns = @()

	# retrieve DNs of objects
	ForEach ($ad_object in $Objects) {
		switch ($true) {
			{ $ad_object -is [Microsoft.ActiveDirectory.Management.ADObject] } {
				# if an ADObject, retrieve the DN
				$ad_object_fqdns += $ad_object.DistinguishedName
			}
			{ $ad_object -is [System.String] } {
				# if a string, assume value is the object DN
				$ad_object_fqdns += $ad_object
			}
			Default {
				# if any other object type, continue to next iteration of foreeach loop
				Write-Host "ERROR: cannot process object type: '[$($ad_object.GetType().FullName)]'"
			}
		}
	}

	# process DNs
	:ad_object_dn ForEach ($ad_object_dn in $ad_object_fqdns) {
		# define path for AD filesystem provider
		$ad_object_path = ($ad_psdrive + ':\' + $ad_object_dn)
		# validate the AD file system provider can retrieve the object
		If (Test-Path -Path $ad_object_path) {
			# retrieve ACL
			$ad_object_acl = $null
			Try {
				$ad_object_acl = Get-Acl -Path $ad_object_path
			}
			Catch {
				Write-Host "ERROR: could not retrieve ACL for: '$ad_object_dn'"
				Continue ad_object_dn
			}
			# retrieve inheritance settings
			# $ad_object_acl.IsProtected
			# $ad_object_acl.preserveInheritance
			# check inheritance settings
			Try {
				switch ($Inheritance) {
					'Enable' {
						# enable inheritance
						$ad_object_acl.SetAccessRuleProtection($false, $false)
					}
					'Disable' {
						# disable inheritance and copy inherited permissions
						$ad_object_acl.SetAccessRuleProtection($true, $true)
					}
					'Remove' {
						# remove inheritance if possible, disable otherwise
						If ($Permissions.Count -ge 1) {
							# disable inheritance and do not copy inherited permissions
							$ad_object_acl.SetAccessRuleProtection($true, $false)
						}
						Else {
							# disable inheritance and copy inherited permissions
							$ad_object_acl.SetAccessRuleProtection($true, $true)
							Write-Host 'WARNING: inherited access cannot be removed without replacement ACEs, inheritance disabled instead'
						}
					}
					Default {
						# leave inheritance as is
					}
				}
			}
			Catch {
				Write-Host "ERROR: could set inheritance on ACL for: '$ad_object_dn'"
				Continue ad_object_dn
			}
			# remove existing ACEs for any IdentityReference found in provided ACEs
			If ($Reset -and $Permissions.Count -gt 0) {
				ForEach ($ad_object_ace in $Permissions) {
					$ad_object_acl.PurgeAccessRules($ad_object_ace.IdentityReference)
				}
				Write-Host "Removed existing access for principals in requested ACEs on object: '$ad_object_dn'"
			}
			# remove existing ACEs for any provided SID
			If ($Reset -and $SID -is [System.Security.Principal.SecurityIdentifier]) {
				ForEach ($ad_object_ace in $Permissions) {
					$ad_object_acl.PurgeAccessRules($SID)
				}
				Write-Host "Removed existing access for principals in requested ACEs on object: '$ad_object_dn'"
			}
			# add defined ACEs
			ForEach ($ad_object_ace in $Permissions) {
				$ad_object_acl.AddAccessRule($ad_object_ace)
			}
			# update ACL
			Try {
				Set-Acl -AclObject $ad_object_acl -Path $ad_object_path
				Write-Host "Updated ACL on object: '$ad_object_dn'"	
			}
			Catch {
				Write-Host "ERROR: could set inheritance on ACL for: '$ad_object_dn'"
				Continue ad_object_dn
			}
		}
		Else {
			Write-Host "WARNING: object not found: '$ad_object_dn'"
		}
	}

	# remove custom PSdrive if created
	If ($null -ne $Server) {
		Try {
			Remove-ADCustomPSDrive
		}
		Catch {
			Write-Host 'ERROR: removing custom PSDrive'
			Break
		}
	}
}

# load the AD security objects on module load
Get-ADSecurityObjects -Force

# define functions to export
$functions_to_export = @()
$functions_to_export += 'Get-ADSecurityIdentifier'
$functions_to_export += 'Get-ADSecurityObjects'
$functions_to_export += 'New-ADCustomPSDrive'
$functions_to_export += 'Remove-ADCustomPSDrive'
$functions_to_export += 'Reset-ADSecurity'
$functions_to_export += 'Update-ADSecurity'

# export module members
Export-ModuleMember -Function $functions_to_export