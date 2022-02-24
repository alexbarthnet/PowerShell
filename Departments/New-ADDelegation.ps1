#Requires -Modules ActiveDirectory,ADSecurityFunctions

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(  
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Default')]
	[string]$Group,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Self')]
	[switch]$Self,
	[Parameter(Position = 1, Mandatory = $True)][ValidateSet('Department', 'FullControl', 'Computer', 'ComputerDelete', 'ComputerDenyCreate', 'ComputerLAPS', 'ComputerBitLocker', 'ComputerRename', 'Group', 'GroupMembership', 'GroupPolicy', 'OU')]
	[string[]]$Delegation,
	[Parameter(Position = 2, Mandatory = $True)]
	[string[]]$Container,
	[Parameter(Position = 3)][ValidateSet('Enable', 'Disable', 'Remove')]
	[string]$Inheritance = 'Enable',
	[Parameter(Position = 3)]
	[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
	[Parameter(Position = 4)]
	[switch]$Reset
)

# create global objects
$env_comp_name = $env:computername.ToLower()

# declare verification
Write-Output "$env_comp_name - verifying parameters..."

# retrieve SID for input
switch ($true) {
	$Self {
		$ad_sid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-10'
	}
	Default {
		Try {
			$ad_group_object = Get-ADGroup -Server $Server -Filter "objectClass -eq 'group' -and samaccountname -eq '$Group'"
			$ad_sid = New-Object System.Security.Principal.SecurityIdentifier ($ad_group_object).SID
		}
		Catch {
			Write-Output "$env_comp_name - ERROR: group not found: $Group"
			Return
		}
	}
}

# create empty array for paths
$ad_paths = @()

# verify OU parameter
ForEach ($ad_ou_string in $Container) {
	# retrieve object
	$ad_ou_object = $null
	$ad_ou_object = Get-ADObject -Server $Server -Filter "distinguishedName -eq '$ad_ou_string'"
	# check object
	If ($null -ne $ad_ou_object) {
		$ad_paths += $ad_ou_string
	}
	Else {
		Write-Output "$env_comp_name - ERROR: OU not found: $ad_ou_string"
		Return
	}
}

# import required objects
Write-Output "$env_comp_name - verifying required objects were loaded by ADSecurityFunctions module..."
Try {
	Get-ADSecurityObjects
}
Catch {
	Write-Output "$env_comp_name - ERROR: could not load required objects"
	Return
}

# create empty array for ACEs
$ad_aces_add = @()

# determine the type of delegation
If ($Delegation -contains 'FullControl') {
	# require 
	Write-Warning "The 'FullControl' delegation has been requested. This delegation should be granted only when necessary." -WarningAction 'Inquire' 

	# declare delegation type
	Write-Output "$env_comp_name - creating ACEs for $Delegation delegation"
	
	# define the values for the ACE
	$ad_rights = $ad_rights_ga
	$ad_permit = $ad_accesstype_allow
	$ad_scoped_to = [guid]::empty
	$ad_inheritance = $ad_inherit_all
	$ad_inherited_by = [guid]::empty
 
	# create ACE and add to array
	Write-Output "$env_comp_name - ...created ACE: allow full control on this object and all child objects"
	$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by
}
ElseIf ($Delegation -contains 'Department') {
	# declare delegation type
	Write-Output "$env_comp_name - creating ACEs for $Delegation delegation"

	# define the values for the ACE
	$ad_rights = $ad_rights_wp
	$ad_permit = $ad_accesstype_deny
	$ad_scoped_to = $ad_map_schema['ou']
	$ad_inheritance = $ad_inherit_none
	$ad_inherited_by = [guid]::empty
	# create ACE and add to array
	Write-Output "$env_comp_name - ...created ACE: deny write to the ou attribute on this object only"
	$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by

	# define the values for the ACE
	$ad_rights = $ad_rights_wd
	$ad_permit = $ad_accesstype_deny
	$ad_scoped_to = [guid]::empty
	$ad_inheritance = $ad_inherit_none
	$ad_inherited_by = [guid]::empty
	# create ACE and add to array
	Write-Output "$env_comp_name - ...created ACE: deny write security on this object only"
	$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by

	# define the values for the ACE
	$ad_rights = $ad_rights_wd
	$ad_permit = $ad_accesstype_deny
	$ad_scoped_to = [guid]::empty
	$ad_inheritance = $ad_inherit_desc
	$ad_inherited_by = $ad_map_schema['organizationalUnit']
	# create ACE and add to array
	Write-Output "$env_comp_name - ...created ACE: deny write security on descendent organizationalUnit objects"
	$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by

	# define the values for the ACE
	$ad_rights = $ad_rights_cc, $ad_rights_dc
	$ad_permit = $ad_accesstype_deny
	$ad_scoped_to = $ad_map_schema['user']
	$ad_inheritance = $ad_inherit_all
	$ad_inherited_by = [guid]::empty
	# create ACE and add to array
	Write-Output "$env_comp_name - ...created ACE: deny create/delete for user objects on this object and all child objects"
	$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by

	# define the values for the ACE
	$ad_rights = $ad_rights_cc, $ad_rights_dc
	$ad_permit = $ad_accesstype_deny
	$ad_scoped_to = $ad_map_schema['inetOrgPerson']
	$ad_inheritance = $ad_inherit_all
	$ad_inherited_by = [guid]::empty
	# create ACE and add to array
	Write-Output "$env_comp_name - ...created ACE: deny create/delete for inetOrgPerson objects on this object and all child objects"
	$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by

	# define the values for the ACE
	$ad_rights = $ad_rights_cc, $ad_rights_dc
	$ad_permit = $ad_accesstype_deny
	$ad_scoped_to = $ad_map_schema['account']
	$ad_inheritance = $ad_inherit_all
	$ad_inherited_by = [guid]::empty
	# create ACE and add to array
	Write-Output "$env_comp_name - ...created ACE: deny create/delete for account objects on this object and all child objects"
	$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by

	# define the values for the ACE
	$ad_rights = $ad_rights_ga
	$ad_permit = $ad_accesstype_allow
	$ad_scoped_to = [guid]::empty
	$ad_inheritance = $ad_inherit_all
	$ad_inherited_by = [guid]::empty
	# create ACE and add to array
	Write-Output "$env_comp_name - ...created ACE: allow full control on this object and all child objects"
	$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by
}
Else {
	# determine the type of delegation
	ForEach ($ad_delegation in $Delegation) {
		# declare delegation type
		Write-Output "$env_comp_name - creating ACEs for $ad_delegation delegation:"
		switch ($ad_delegation) {
			'Computer' {
				# define the values for the ACE
				$ad_rights = $ad_rights_cc, $ad_rights_dc
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_schema['computer']
				$ad_inheritance = $ad_inherit_all
				$ad_inherited_by = [guid]::empty
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow create/delete of computer objects on this object and all child objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by

				# define the values for the ACE
				$ad_rights = $ad_rights_ga
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = [guid]::empty
				$ad_inheritance = $ad_inherit_desc
				$ad_inherited_by = $ad_map_schema['computer']
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow full control on descendent computer objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by

				# define the values for the ACE
				$ad_rights = $ad_rights_ga
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = [guid]::empty
				$ad_inheritance = $ad_inherit_desc
				$ad_inherited_by = $ad_map_schema['msFVE-RecoveryInformation']
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow full control on descendent bitlocker objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by
			}
			'ComputerCreate' {
				# define the values for the ACE
				$ad_rights = $ad_rights_cc
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_schema['computer']
				$ad_inheritance = $ad_inherit_all
				$ad_inherited_by = [guid]::empty
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow create for computer objects on this object and all child objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by
			}
			'ComputerDelete' {
				# define the values for the ACE
				$ad_rights = $ad_rights_dc
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_schema['computer']
				$ad_inheritance = $ad_inherit_all
				$ad_inherited_by = [guid]::empty
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow delete for computer objects on this object and all child objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by
			}
			'ComputerDenyCreate' {
				# define the values for the ACE
				$ad_rights = $ad_rights_cc
				$ad_permit = $ad_accesstype_deny
				$ad_scoped_to = $ad_map_schema['computer']
				$ad_inheritance = $ad_inherit_all
				$ad_inherited_by = [guid]::empty
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: deny create for computer objects on this object and all child objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by
			}
			'ComputerLAPS' {
				# define the values for the ACE
				$ad_rights = $ad_rights_rp, $ad_rights_ca
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_schema['ms-Mcs-AdmPwd']
				$ad_inheritance = $ad_inherit_desc
				$ad_inherited_by = $ad_map_schema['computer']
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow read with control access for the ms-Mcs-AdmPwd attribute on descendent computer objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by
			}
			'ComputerBitLocker' {
				# define the values for the ACE
				$ad_rights = $ad_rights_ga
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = [guid]::empty
				$ad_inheritance = $ad_inherit_desc
				$ad_inherited_by = $ad_map_schema['msFVE-RecoveryInformation']
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow full control on descendent bitlocker objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by
			}
			'ComputerJoin' {
				# define the values for the ACE
				$ad_rights = $ad_rights_wp
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_rights['Account Restrictions']
				$ad_inheritance = $ad_inherit_desc
				$ad_inherited_by = $ad_map_schema['computer']
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow read/write for the 'Account Restrictions' property set on descendent computer objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by

				# define the values for the ACE
				$ad_rights = $ad_rights_sw
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_rights['Reset Password']
				$ad_inheritance = $ad_inherit_desc
				$ad_inherited_by = $ad_map_schema['computer']
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow 'Reset Password' on descendent computer objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by

				# define the values for the ACE
				$ad_rights = $ad_rights_sw
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_rights['Validated write to DNS host name']
				$ad_inheritance = $ad_inherit_desc
				$ad_inherited_by = $ad_map_schema['computer']
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow 'Validated write to DNS host name rights' on descendent computer objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by

				# define the values for the ACE
				$ad_rights = $ad_rights_sw
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_rights['Validated write to service principal name']
				$ad_inheritance = $ad_inherit_desc
				$ad_inherited_by = $ad_map_schema['computer']
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow 'Validated write to service principal name' rights on descendent computer objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by
			}
			'ComputerRename' {
				# define the values for the ACE
				$ad_rights = $ad_rights_wp
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_schema['cn']
				$ad_inheritance = $ad_inherit_desc
				$ad_inherited_by = $ad_map_schema['computer']
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow read/write for the cn attribute on descendent computer objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by
				
				# define the values for the ACE
				$ad_rights = $ad_rights_wp
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_schema['sAMAccountName']
				$ad_inheritance = $ad_inherit_desc
				$ad_inherited_by = $ad_map_schema['computer']
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow read/write for the sAMAccountName attribute on descendent computer objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by

				# define the values for the ACE
				$ad_rights = $ad_rights_wp
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_rights['Account Restrictions']
				$ad_inheritance = $ad_inherit_desc
				$ad_inherited_by = $ad_map_schema['computer']
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow read/write for the 'Account Restrictions' property set on descendent computer objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by

				# define the values for the ACE
				$ad_rights = $ad_rights_sw
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_rights['Validated write to DNS host name']
				$ad_inheritance = $ad_inherit_desc
				$ad_inherited_by = $ad_map_schema['computer']
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow 'Validated write to DNS host name rights' on descendent computer objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by

				# define the values for the ACE
				$ad_rights = $ad_rights_sw
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_rights['Validated write to service principal name']
				$ad_inheritance = $ad_inherit_desc
				$ad_inherited_by = $ad_map_schema['computer']
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow 'Validated write to service principal name' rights on descendent computer objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by
			}
			'Group' {
				# define the values for the ACE
				$ad_rights = $ad_rights_cc, $ad_rights_dc
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_schema['group']
				$ad_inheritance = $ad_inherit_all
				$ad_inherited_by = [guid]::empty
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow create/delete for group objects on this object and all child objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by

				# define the values for the ACE
				$ad_rights = $ad_rights_ga
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = [guid]::empty
				$ad_inheritance = $ad_inherit_desc
				$ad_inherited_by = $ad_map_schema['group']
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow full control on all descendent group objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by
			}
			'GroupMembership' {
				# define the values for the ACE
				$ad_rights = $ad_rights_rp, $ad_rights_wp
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_schema['member']
				$ad_inheritance = $ad_inherit_desc
				$ad_inherited_by = $ad_map_schema['group']
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow read/write for the member attribute on descendent group objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by
			}
			'GroupPolicy' {
				# define the values for the ACE
				$ad_rights = $ad_rights_rp, $ad_rights_wp
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_schema['gPLink']
				$ad_inheritance = $ad_inherit_none
				$ad_inherited_by = [guid]::empty
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow read/write for the gPLink attribute on this object only"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by

				# define the values for the ACE
				$ad_rights = $ad_rights_rp, $ad_rights_wp
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_schema['gPOptions']
				$ad_inheritance = $ad_inherit_none
				$ad_inherited_by = [guid]::empty
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow read/write for the gPOptions attribute on this object only"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by  

				# define the values for the ACE
				$ad_rights = $ad_rights_rp, $ad_rights_wp
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_schema['gPLink']
				$ad_inheritance = $ad_inherit_desc
				$ad_inherited_by = $ad_map_schema['organizationalUnit']
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow read/write for the gPLink attribute on descendent organizationalUnit objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by

				# define the values for the ACE
				$ad_rights = $ad_rights_rp, $ad_rights_wp
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_schema['gPOptions']
				$ad_inheritance = $ad_inherit_desc
				$ad_inherited_by = $ad_map_schema['organizationalUnit']
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow read/write for the gPOptions attribute on descendent organizationalUnit objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by
			}
			'OU' {
				# define the values for the ACE
				$ad_rights = $ad_rights_cc, $ad_rights_dc
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_schema['organizationalUnit']
				$ad_inheritance = $ad_inherit_all
				$ad_inherited_by = [guid]::empty
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow create/delete for organizationalUnit objects on this object and all child objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by

				# define the values for the ACE
				$ad_rights = $ad_rights_rp, $ad_rights_wp
				$ad_permit = $ad_accesstype_allow
				$ad_scoped_to = $ad_map_schema['ou']
				$ad_inheritance = $ad_inherit_desc
				$ad_inherited_by = $ad_map_schema['organizationalUnit']
				# create ACE and add to array
				Write-Output "$env_comp_name - ...created ACE: allow read/write for the OU attribute on all descendent organizationalUnit objects"
				$ad_aces_add += New-Object System.DirectoryServices.ActiveDirectoryAccessRule $ad_sid, $ad_rights, $ad_permit, $ad_scoped_to, $ad_inheritance, $ad_inherited_by
			}
			Default {
				Write-Output "$env_comp_name - ERROR: invalid Delegation specified!"
				Return
			}
		}
	}
}

# update permissions
Update-ADSecurity -Objects $ad_paths -Permissions $ad_aces_add -Inheritance $Inheritance -Reset:$Reset