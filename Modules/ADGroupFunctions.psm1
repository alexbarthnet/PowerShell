#Requires -Modules ActiveDirectory

Function Find-ADGroup {
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ $_ -is [Microsoft.ActiveDirectory.Management.ADObject] -or $_ -is [System.String] })]
		[object]$Identity,
		[Parameter(Position = 1)]
		[string[]]$Properties = @('*'),
		[Parameter(Position = 2)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
	)

	# check attributes
	If ('*' -notin $Properties) {
		If ('whenChanged' -notin $Properties) { $Properties += 'whenChanged' }
		If ('whenCreated' -notin $Properties) { $Properties += 'whenCreated' }
	}

	# check for group
	Try {
		# return group retrieved with properties via group retrieved from identity to enable retrieval of constructed attributes
		Return (Get-ADGroup -Server $Server -Identity $Identity | Get-ADGroup -Server $Server -Properties $Properties)
	}
	Catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
		# collect error before attempting to create group
		$group_error = $_
		# if string passed...
		If ($Identity -is [System.String]) {
			# define hash table for group creation
			$group_hash = @{
				Server         = $Server
				Path           = $Identity.Split(',', 2)[1]
				Name           = $Identity.Split(',', 2)[0].Replace('CN=', $null)
				SamAccountName = $Identity.Split(',', 2)[0].Replace('CN=', $null)
				GroupCategory  = 'Security'
				GroupScope     = 'Global'
			}
			Try {
				# create the group then return the group with the requested attributes
				Return (New-ADGroup @group_hash -PassThru | Get-ADGroup -Server $Server -Properties $Properties)
			}
			Catch [Microsoft.ActiveDirectory.Management.ADIdentityAlreadyExistsException] {
				# report error if verbose
				Write-Verbose -Message 'ERROR: could not create group, resource with the same name already exists'
				# return error to caller
				Return $_
			}
			Catch {
				# report error if verbose
				Write-Verbose -Message 'ERROR: could not create group, exception not resolved by Find-ADGroup'
				# return error to caller
				Return $_
			}
		}
		Else {
			# report error if verbose
			Write-Verbose -Message 'ERROR: could not retrieve group, ADObject passed but not found'
			# return error to caller
			Return $group_error
		}
	}
	Catch {
		# report error if verbose
		Write-Verbose -Message 'ERROR: could not retrieve group, exception not resolved by Find-ADGroup'
		# return error to caller
		Return $_
	}
}

Function Get-ADGroupsFromGroup {
	[CmdletBinding()]
	param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ $_ -is [Microsoft.ActiveDirectory.Management.ADObject] -or $_ -is [System.String] })]
		[object]$Identity,
		[Parameter(Position = 1)]
		[string]$Property = 'msds-membertransitive',
		[Parameter(Position = 2)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
	)

	# retrieve group
	Try {
		$ad_group = Get-ADGroup -Identity $Identity -Server $Server
	}
	Catch {
		# report error if verbose
		Write-Verbose -Message 'ERROR: could not retrieve group'
		# return error to caller
		Return $_
	}

	# validate values in property are groups
	Try {
		# create empty list
		$ad_results = New-Object System.Collections.Generic.List[string]
		# retrive property from object
		$ad_objects = [array](Get-ADObject -Identity $ad_group -Properties $Property -Server $Server | Select-Object -ExpandProperty $Property)
		# parse values in property
		ForEach ($fqdn in $ad_objects) {
			# retrieve object for member
			$ad_object = Get-ADObject -Identity $fqdn -Server $Server
			# if member is a group...
			If ($ad_object.ObjectClass -eq 'group') {
				# ...add name of member to desired list
				$ad_results.Add($ad_object.Name)
			}
		}
		# return list to caller
		Return $ad_results
	}
	Catch {
		# report error if verbose
		Write-Verbose -Message 'ERROR: could not retrieve one or more objects'
		# return error to caller
		Return $_
	}
}

Function Get-ADGroupsFromQuery {
	[CmdletBinding()]
	param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[string]$LDAPFilter,
		[Parameter(Position = 1)]
		[string]$SearchBase = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName,
		[Parameter(Position = 2)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
	)

	# retrieve objects from query
	Try {
		$ad_result = [array](Get-ADObject -LDAPFilter $LDAPFilter -SearchBase $SearchBase -Server $Server)
	}
	Catch {
		# report error if verbose
		Write-Verbose -Message 'ERROR: could not retrieve objects'
		# return error to caller
		Return $_
	}

	# validate objects are groups
	Try {
		# create empty list
		$ad_results = New-Object System.Collections.Generic.List[string]
		# retrive DNs from objects
		$ad_objects = [array]($ad_result | Select-Object -ExpandProperty 'DistinguishedName')
		# parse values in property
		ForEach ($fqdn in $ad_objects) {
			# retrieve object for member
			$ad_object = Get-ADObject -Identity $fqdn -Server $Server
			# if member is a group...
			If ($ad_object.ObjectClass -eq 'group') {
				# ...add name of member to desired list
				$ad_results.Add($ad_object.Name)
			}
		}
		# return list to caller
		Return $ad_results
	}
	Catch {
		# report error if verbose
		Write-Verbose -Message 'ERROR: could not retrieve one or more objects'
		# return error to the caller
		Return $_
	}
}

Function Update-ADMembers {
	[CmdletBinding(SupportsShouldProcess)]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ $_ -is [Microsoft.ActiveDirectory.Management.ADObject] -or $_ -is [System.String] })]
		[object]$Identity,
		[Parameter(Position = 1, Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()]
		[string[]]$MemberDNs,
		[Parameter(Position = 2)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()]
		[string[]]$ExcludedDNs,
		[Parameter(Position = 3)]
		[string[]]$Properties = @('*'),
		[Parameter(Position = 4)]
		[string]$Filter = '^CN=',
		[Parameter(Position = 5)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
		[Parameter(Position = 6)]
		[switch]$PassThru
	)

	# retrieve group before changes
	Try {
		$ad_members_group = Get-ADGroup -Server $Server -Identity $Identity -Properties 'Member'
	}
	Catch {
		Return $_
	}

	# create generic lists for members
	$ad_members_current = [System.Collections.Generic.List[string]]::New()
	$ad_members_desired = [System.Collections.Generic.List[string]]::New()
	$ad_members_exclude = [System.Collections.Generic.List[string]]::New()
	$ad_members_trimmed = [System.Collections.Generic.List[string]]::New()
	$ad_members_changed = [System.Collections.Generic.List[string]]::New()

	# retrieve current members
	ForEach ($MemberDN in $ad_members_group.Member) {
		If ($MemberDN -match $Filter -and -not [string]::IsNullOrEmpty($MemberDN)) {
			$ad_members_current.Add($MemberDN)
		}
	}

	# retrieve desired members
	ForEach ($MemberDN in $MemberDNs) {
		If ($MemberDN -match $Filter -and -not [string]::IsNullOrEmpty($MemberDN)) {
			$ad_members_desired.Add($MemberDN)
		}
	}

	# retrieve excluded DNs
	ForEach ($MemberDN in $ExcludedDNs) {
		If ($MemberDN -match $Filter -and -not [string]::IsNullOrEmpty($MemberDN)) {
			$ad_members_exclude.Add($MemberDN)
		}
	}

	# retrieve missing members less any excluded DNs
	$ad_members_trimmed = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($ad_members_desired, $ad_members_exclude))

	# retrieve missing members, linq will ensure that the output is of unique values
	$ad_members_missing = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($ad_members_trimmed, $ad_members_current))

	# retrieve extra members, linq will ensure that the output is of unique values
	$ad_members_invalid = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($ad_members_current, $ad_members_trimmed))

	# retrieve changed members, linq will combine the two lists
	$ad_members_changed = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Concat($ad_members_missing, $ad_members_invalid))

	# report desired, current, missing, and extra members
	If ($VerbosePreference -eq 'Continue') {
		ForEach ($ad_member_fqdn in $ad_members_current) { Write-Verbose "Current Member: $ad_member_fqdn" }
		ForEach ($ad_member_fqdn in $ad_members_trimmed) { Write-Verbose "Desired Member: $ad_member_fqdn" }
		ForEach ($ad_member_fqdn in $ad_members_exclude) { Write-Verbose "Exclude Member: $ad_member_fqdn" }
		ForEach ($ad_member_fqdn in $ad_members_missing) { Write-Verbose "Will Add: $ad_member_fqdn" }
		ForEach ($ad_member_fqdn in $ad_members_invalid) { Write-Verbose "Will Remove: $ad_member_fqdn" }
	}

	# add any missing members
	If ( $ad_members_missing.Count -ge 1 ) {
		if ($PSCmdlet.ShouldProcess(($ad_members_missing -join ','), "Add members to $($ad_members_group.SamAccountName)")) {
			Try {
				Add-ADGroupMember -Server $Server -Identity $ad_members_group -Members $ad_members_missing
			}
			Catch {
				Return $_
			}
		}
	}

	# remove any extra members
	If ( $ad_members_invalid.Count -ge 1 ) {
		if ($PSCmdlet.ShouldProcess(($ad_members_invalid -join ','), "Remove members from $($ad_members_group.SamAccountName)")) {
			Try {
				Remove-ADGroupMember -Server $Server -Identity $ad_members_group -Members $ad_members_invalid -Confirm:$false
			}
			Catch {
				Return $_
			}
		}
	}

	# return the group if passthru
	If ($PassThru) {
		# check attributes
		If ('*' -notin $Properties) {
			If ('whenChanged' -notin $Properties) { $Properties += 'whenChanged' }
			If ('whenCreated' -notin $Properties) { $Properties += 'whenCreated' }
			If ('Member' -notin $Properties) { $Properties += 'Member' }
		}
		# retrieve object after changes
		Try {
			# define additional properties for object
			$ad_members_notes = @{ MemberAdded = $ad_members_missing; MemberRemoved = $ad_members_invalid; MemberChanged = $ad_members_changed }
			# retreive object
			$ad_members_group = Get-ADGroup -Server $Server -Identity $Identity -Properties $Properties
			# expand object with
			$ad_members_group | Add-Member -NotePropertyMembers $ad_members_notes -Force
			# return expanded object
			Return $ad_members_group
		}
		Catch {
			Return $_
		}
	}
}

Function Update-ADMembersOf {
	[CmdletBinding(SupportsShouldProcess)]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ $_ -is [Microsoft.ActiveDirectory.Management.ADObject] -or $_ -is [System.String] })]
		[object]$Identity,
		[Parameter(Position = 1, Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()]
		[string[]]$MemberOfDNs,
		[Parameter(Position = 2)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()]
		[string[]]$ExcludedDNs,
		[Parameter(Position = 3)]
		[string]$Filter = '^CN=',
		[Parameter(Position = 4)]
		[string[]]$Properties = @('*'),
		[Parameter(Position = 5)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
		[Parameter(Position = 6)]
		[switch]$PassThru
	)

	# retrieve object before changes
	Try {
		$ad_memberof_object = Get-ADObject -Server $Server -Identity $Identity -Properties 'MemberOf'
	}
	Catch {
		Return $_
	}

	# define permitted classes
	$ad_memberof_classes = @()
	$ad_memberof_classes += 'Computer'
	$ad_memberof_classes += 'Group'
	$ad_memberof_classes += 'User'
	$ad_memberof_classes += 'msDS-GroupManagedServiceAccount'

	# check input object against permitted classes
	If ($ad_memberof_object.ObjectClass -notin $ad_memberof_classes) {
		Write-Error -Message 'Invalid Object Class' -ErrorAction 'Stop'
		Return $null
	}

	# create generic lists for members
	$ad_memberof_current = [System.Collections.Generic.List[string]]::New()
	$ad_memberof_desired = [System.Collections.Generic.List[string]]::New()
	$ad_memberof_exclude = [System.Collections.Generic.List[string]]::New()
	$ad_memberof_trimmed = [System.Collections.Generic.List[string]]::New()
	$ad_memberof_changed = [System.Collections.Generic.List[string]]::New()

	# retrieve current membership
	ForEach ($MemberOfDN in $ad_memberof_object.MemberOf) {
		If ($MemberOfDN -match $Filter -and -not [string]::IsNullOrEmpty($MemberOfDN)) {
			$ad_memberof_current.Add($MemberOfDN)
		}
	}

	# retrieve desired membership
	ForEach ($MemberOfDN in $MemberOfDNs) {
		If ($MemberOfDN -match $Filter -and -not [string]::IsNullOrEmpty($MemberOfDN)) {
			$ad_memberof_desired.Add($MemberOfDN)
		}
	}

	# retrieve excluded DNs
	ForEach ($MemberOfDN in $ExcludedDNs) {
		If ($MemberOfDN -match $Filter -and -not [string]::IsNullOrEmpty($MemberOfDN)) {
			$ad_memberof_exclude.Add($MemberOfDN)
		}
	}

	# retrieve missing members less any excluded DNs
	$ad_memberof_trimmed = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($ad_memberof_desired, $ad_memberof_exclude))

	# retrieve missing members, linq will ensure that the output is of unique values
	$ad_memberof_missing = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($ad_memberof_trimmed, $ad_memberof_current))

	# retrieve extra members, linq will ensure that the output is of unique values
	$ad_memberof_invalid = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($ad_memberof_current, $ad_memberof_trimmed))

	# retrieve changed members, linq will combine the two lists
	$ad_memberof_changed = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Concat($ad_memberof_missing, $ad_memberof_invalid))

	# report current, desired, missing, and extra memberships
	If ($VerbosePreference -eq 'Continue') {
		ForEach ($ad_memberof_fqdn in $ad_memberof_current) { Write-Verbose "Current MemberOf: $ad_memberof_fqdn" }
		ForEach ($ad_memberof_fqdn in $ad_memberof_desired) { Write-Verbose "Desired MemberOf: $ad_memberof_fqdn" }
		ForEach ($ad_memberof_fqdn in $ad_memberof_exclude) { Write-Verbose "Exclude Member: $ad_member_fqdn" }
		ForEach ($ad_memberof_fqdn in $ad_memberof_missing) { Write-Verbose "Will Join: $ad_memberof_fqdn" }
		ForEach ($ad_memberof_fqdn in $ad_memberof_invalid) { Write-Verbose "Will Leave: $ad_memberof_fqdn" }
	}

	# add missing memberships
	If ( $ad_memberof_missing.Count -ge 1 ) {
		if ($PSCmdlet.ShouldProcess(($ad_memberof_missing -join ','), "Add $($ad_memberof_object.SamAccountName) to groups")) {
			Add-ADPrincipalGroupMembership -Server $Server -Identity $ad_memberof_object -MemberOf $ad_memberof_missing
		}
	}

	# remove extra memberships
	If ( $ad_memberof_invalid.Count -ge 1 ) {
		if ($PSCmdlet.ShouldProcess(($ad_memberof_invalid -join ','), "Remove $($ad_memberof_object.SamAccountName) from groups")) {
			Remove-ADPrincipalGroupMembership -Server $Server -Identity $ad_memberof_object -MemberOf $ad_memberof_invalid -Confirm:$false
		}
	}

	# return the group if passthru
	If ($PassThru) {
		# check attributes
		If ('*' -notin $Properties) {
			If ('whenChanged' -notin $Properties) { $Properties += 'whenChanged' }
			If ('whenCreated' -notin $Properties) { $Properties += 'whenCreated' }
			If ('MemberOf' -notin $Properties) { $Properties += 'MemberOf' }
		}
		# retrieve object after changes
		Try {
			# define additional properties for object
			$ad_memberof_notes = @{ MemberOfAdded = $ad_memberof_missing; MemberOfRemoved = $ad_memberof_invalid; MemberOfChanged = $ad_memberof_changed }
			# retreive object
			$ad_memberof_object = Get-ADGroup -Server $Server -Identity $Identity -Properties $Properties
			# modify object
			$ad_memberof_object | Add-Member -NotePropertyMembers $ad_memberof_notes -Force
			# return expanded object
			Return $ad_memberof_object
		}
		Catch {
			Return $_
		}
	}
}

# define functions to export
$functions_to_export = @()
$functions_to_export += 'Find-ADGroup'
$functions_to_export += 'Get-ADGroupsFromGroup'
$functions_to_export += 'Get-ADGroupsFromQuery'
$functions_to_export += 'Update-ADMembers'
$functions_to_export += 'Update-ADMembersOf'

# export module members
Export-ModuleMember -Function $functions_to_export