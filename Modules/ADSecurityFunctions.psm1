#Requires -Modules ActiveDirectory

Function Get-ADDCDrive {
	Param(
		[Parameter(Position = 0)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
		[Parameter(Position = 1)]
		[switch]$Force
	)

	Try {
		# check for PSDrive with correct settings
		$psdrive = $null
		$psdrive = Get-PSDrive | Where-Object {($_.Name -eq 'ADDC') -and ($_.Server -eq $Server) -and ($_.Provider -eq 'ActiveDirectory') -and ($_.Root -eq '//RootDSE/')}

		# check for PSdrive with the 'ADDC' name
		If ($Force -or $null -eq $psdrive) {
			# remove any PSdrive with the 'ADDC' name
			Get-PSDrive | Where-Object {$_.Name -eq "ADDC"} | Remove-PSDrive -Force
			# create PSdrive with correct values
			$null = New-PSDrive -Name 'ADDC' -Server $Server -PSProvider 'ActiveDirectory' -Root '//RootDSE/' -Scope Global	
		}
	}
	Catch {
		$_
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
		# retrieve naming contexts
		If ($Force -or $null -eq $ad_nc_domain) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_nc_domain' -Value ([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName) }
		If ($Force -or $null -eq $ad_nc_schema) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_nc_schema' -Value ([System.DirectoryServices.ActiveDirectory.ActiveDirectorySchema]::GetCurrentSchema().Name) }
		If ($Force -or $null -eq $ad_nc_config) { New-Variable -Force -Scope 'Global' -Option 'ReadOnly' -Name 'ad_nc_config' -Value $ad_nc_schema.Split(',', 2)[1] }

		# retrieve guids
		If ($Force -or $null -eq $ad_guids_schema) { New-Variable -Force -Scope 'Private' -Option 'ReadOnly' -Name 'ad_guids_schema' -Value (Get-ADObject -SearchBase $ad_nc_schema -LDAPFilter "(schemaidguid=*)" -Properties 'lDAPDisplayName', 'schemaIDGUID') }
		If ($Force -or $null -eq $ad_guids_rights) { New-Variable -Force -Scope 'Private' -Option 'ReadOnly' -Name 'ad_guids_rights' -Value (Get-ADObject -SearchBase $ad_nc_config -LDAPFilter "(&(objectclass=controlAccessRight)(rightsguid=*))" -Properties 'displayName', 'rightsGuid') }
 
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
		[Parameter(Position = 0, Mandatory = $true)]
		[string]$Identity,
		[Parameter(Position = 1)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
	)
	
	# retrieve PSdrive
	Try {
		Get-ADDCDrive -Server $Server
	}
	Catch {
		Write-Host "ERROR: creating 'ADDC' PSDrive for server: '$Server'"
		Break
	}

	# verify the AD object
	$ad_class = $null
	Try {
		$ad_class = (Get-ADObject -Identity $Identity -Properties 'objectClass').objectClass
	}
	Catch {
		Write-Host "WARNING: object not found: '$Identity'"
	}

	If ($null -ne $ad_class) {
		# retrieve default SDDL for objectClass
		$ad_sddl = (Get-ADObject -Filter "Name -eq '$ad_class'" -SearchBase $ad_nc_schema -Properties 'defaultSecurityDescriptor').defaultSecurityDescriptor

		# get the ACL for the object
		$ad_path = ("ADDC:\$Identity")
		$ad_acl = Get-Acl -Path $ad_path
		$ad_acl.SetAccessRuleProtection($true, $false)
		$ad_acl.Access | ForEach-Object { $ad_acl.RemoveAccessRule($_) } | Out-Null
		$ad_acl.SetSecurityDescriptorSddlForm($ad_sddl)
		$ad_acl.SetAccessRuleProtection($false, $false)
		$ad_acl | Set-Acl -Path $ad_path
	}
}

Function Update-ADSecurity {
	Param (
		[Parameter(Position = 0, Mandatory = $true)]
		[object[]]$Objects,
		[Parameter(Position = 1)]
		[object[]]$Permissions,
		[Parameter(Position = 1)][ValidateScript({$_ -is [System.Security.Principal.SecurityIdentifier]})]
		[object]$SID,
		[Parameter(Position = 2)][ValidateSet("Enable", "Disable", "Remove")]
		[string]$Inheritance,
		[Parameter(Position = 3)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
		[Parameter(Position = 4)]
		[switch]$Reset
	)

	# retrieve PSdrive
	Try {
		Get-ADDCDrive -Server $Server
	}
	Catch {
		Write-Host "ERROR: creating 'ADDC' PSDrive for server: '$Server'"
		Break
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
	ForEach ($ad_object_dn in $ad_object_fqdns) {
		# define path for AD filesystem provider
		$ad_object_path = ("ADDC:\" + $ad_object_dn)
		# validate the AD file system provider can retrieve the object
		If (Test-Path -Path $ad_object_path) {
			# retrieve ACL
			$ad_object_acl = $null
			Try {
				$ad_object_acl = Get-Acl -Path $ad_object_path
			}
			Catch {
				Write-Host "ERROR: could not retrieve ACL for: '$ad_object_dn'"
				Continue ad_object
			}
			# check inheritance settings
			switch ($Inheritance) {
				"Enable" {
					# enable inheritance
					$ad_object_acl.SetAccessRuleProtection($false, $false) 
				}
				"Disable" {
					# disable inheritance and copy inherited permissions
					$ad_object_acl.SetAccessRuleProtection($true, $true) 
				}
				"Remove" { 
					If ($Permissions.Count -ge 1) {
						# disable inheritance and do not copy inherited permissions
						$ad_object_acl.SetAccessRuleProtection($true, $false)
					}
					Else {
						# disable inheritance and copy inherited permissions
						$ad_object_acl.SetAccessRuleProtection($true, $true) 
						Write-Host "WARNING: inherited access cannot be removed without replacement ACEs, inheritance disabled instead"
					}
				}
			}
			# remove existing ACEs where IdentityReference found in provided ACEs
			If ($Reset -and $Permissions.Count -gt 0) {
				ForEach ($ad_object_ace in $Permissions) {
					$ad_object_acl.PurgeAccessRules($ad_object_ace.IdentityReference)
				}
				Write-Host "Removed existing access for principals in requested ACEs on object: '$ad_object_dn'"
			}
			# remove existing ACEs where IdentityReference found in provided ACEs
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
			Set-ACL -ACLObject $ad_object_acl -Path $ad_object_path
			Write-Host "Updated ACL on object: '$ad_object_dn'"
		}
		Else {
			Write-Host "WARNING: object not found: '$ad_object_dn'"
		}
	}
}

# define functions to export
$functions_to_export = @()
$functions_to_export += 'Get-ADDCDrive'
$functions_to_export += 'Get-ADSecurityObjects'
$functions_to_export += 'Reset-ADSecurity'
$functions_to_export += 'Update-ADSecurity'

# export module members
Export-ModuleMember -Function $functions_to_export