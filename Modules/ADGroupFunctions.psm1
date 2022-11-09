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
	If ('*' -notin $Attributes) {
		If ('whenChanged' -notin $Attributes) { $Properties += 'whenChanged' }
		If ('whenCreated' -notin $Attributes) { $Properties += 'whenCreated' }
	}

	# check for group
	Try {
		# return group object to caller with the requested attributes
		Return (Get-ADGroup -Server $Server -Identity $Identity -Properties $Properties)
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
		[string]$Filter = '^CN=',
		[Parameter(Position = 4)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
		[Parameter(Position = 5)]
		[switch]$PassThru,
		[Parameter(Position = 6)]
		[switch]$Report
	)

	# create empty objects
	# $ad_members_missing = @()
	# $ad_members_invalid = @()
	# $ad_members_changed = @()
	$ad_members_object = $null
	$ad_members_errors = @()

	# retrieve object before changes
	Try {
		$ad_members_object = Get-ADGroup -Server $Server -Identity $Identity -Properties @('Member', 'SamAccountName')
	}
	Catch {
		$ad_members_errors += $_
	}

	# process changes
	If ($null -ne $ad_members_object) {
		# create generic lists for members
		$ad_members_current = [System.Collections.Generic.List[string]]::New()
		$ad_members_desired = [System.Collections.Generic.List[string]]::New()
		$ad_members_exclude = [System.Collections.Generic.List[string]]::New()
		$ad_members_trimmed = [System.Collections.Generic.List[string]]::New()
		$ad_members_changed = [System.Collections.Generic.List[string]]::New()

		# create empty arrays
		# $ad_members_current = @()
		# $ad_members_desired = @()
		# $ad_members_exclude = @()
		# $ad_members_trimmed = @()

		# retrieve current members
		ForEach ($MemberDN in $ad_members_object.Member) {
			If ($MemberDN -match $Filter -and -not [string]::IsNullOrEmpty($MemberDN)) {
				# $ad_members_current += $MemberDN
				$ad_members_current.Add($MemberDN)
			}
		}

		# retrieve desired members
		ForEach ($MemberDN in $MemberDNs) {
			If ($MemberDN -match $Filter -and -not [string]::IsNullOrEmpty($MemberDN)) {
				# $ad_members_desired += $MemberDN
				$ad_members_desired.Add($MemberDN)
			}
		}

		# retrieve excluded DNs
		ForEach ($MemberDN in $ExcludedDNs) {
			If ($MemberDN -match $Filter -and -not [string]::IsNullOrEmpty($MemberDN)) {
				# $ad_members_exclude += $MemberDN
				$ad_members_exclude.Add($MemberDN)
			}
		}

		# retrieve missing members less any excluded DNs
		# $ad_members_trimmed += [array][System.Linq.Enumerable]::Except([string[]]$ad_members_desired, [string[]]$ad_members_exclude)
		$ad_members_trimmed = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($ad_members_desired, $ad_members_exclude))

		# retrieve missing members, linq will ensure that the output is of unique values
		# $ad_members_missing += [array][System.Linq.Enumerable]::Except([string[]]$ad_members_trimmed, [string[]]$ad_members_current)
		$ad_members_missing = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($ad_members_trimmed, $ad_members_current))

		# retrieve extra members, linq will ensure that the output is of unique values
		# $ad_members_invalid += [array][System.Linq.Enumerable]::Except([string[]]$ad_members_current, [string[]]$ad_members_trimmed)
		$ad_members_invalid = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($ad_members_current, $ad_members_trimmed))

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
			if ($PSCmdlet.ShouldProcess(($ad_members_missing -join ','), "Add members to $($ad_members_object.SamAccountName)")) {
				# call native AD function
				Add-ADGroupMember -Server $Server -Identity $ad_members_object -Members $ad_members_missing
				# if report requested...
				If ($Report) { ForEach ($ad_member_fqdn in $ad_members_missing) { $ad_members_changed.Add($ad_member_fqdn) } }
			}
		}

		# remove any extra members
		If ( $ad_members_invalid.Count -ge 1 ) {
			if ($PSCmdlet.ShouldProcess(($ad_members_invalid -join ','), "Remove members from $($ad_members_object.SamAccountName)")) {
				# call native AD function
				Remove-ADGroupMember -Server $Server -Identity $ad_members_object -Members $ad_members_invalid -Confirm:$false
				# if report requested...
				If ($Report) { ForEach ($ad_member_fqdn in $ad_members_invalid) { $ad_members_changed.Add($ad_member_fqdn) } }
			}
		}
	}

	# return the group if passthru
	If ($PassThru) {
		# retrieve object after changes
		Try {
			$ad_members_object = Get-ADGroup -Server $Server -Identity $Identity -Properties @('SamAccountName', 'Member')
		}
		Catch {
			$ad_members_object = $_
		}
		Return $ad_members_object
	}

	# return the report if requested
	If ($Report) {
		Try {
			$ad_members_object = Get-ADGroup -Server $Server -Identity $Identity -Properties @('SamAccountName', 'Member')
		}
		Catch {
			$ad_members_object = $null
			$ad_members_errors += $_
		}

		[PSCustomObject]@{
			Error             = $ad_members_errors
			DistinguishedName = $ad_members_object.DistinguishedName
			SamAccountName    = $ad_members_object.SamAccountName
			Added             = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::OrderBy($ad_members_missing, [Func[string, string]] { $args[0] }))
			Removed           = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::OrderBy($ad_members_invalid, [Func[string, string]] { $args[0] }))
			Changed           = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::OrderBy($ad_members_changed, [Func[string, string]] { $args[0] }))
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
		[Parameter(Position = 2)]
		[string]$Filter = '^CN=',
		[Parameter(Position = 3)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
		[Parameter(Position = 4)]
		[switch]$Report
	)

	# create empty arrays
	$ad_membersof_missing = @()
	$ad_membersof_invalid = @()
	$ad_membersof_changed = @()

	# retrieve object with required attributes
	Try {
		$ad_membersof_object = Get-ADObject -Server $Server -Identity $Identity -Properties @('MemberOf', 'SamAccountName')
		$ad_membersof_error = $null
	}
	Catch {
		$ad_membersof_object = $null
		$ad_membersof_error = $_
	}

	# verify object class
	If ($null -ne $ad_membersof_object) {
		# define permitted classes
		$ad_membersof_classes = @()
		$ad_membersof_classes += 'Computer'
		$ad_membersof_classes += 'Group'
		$ad_membersof_classes += 'User'
		$ad_membersof_classes += 'msDS-GroupManagedServiceAccount'

		# check input object against permitted classes
		If ($ad_membersof_object.ObjectClass -notin $ad_membersof_classes) {
			$ad_membersof_object = $null
			Try { Write-Error -Message 'Invalid Object Class' -ErrorAction 'Stop' } Catch { $ad_membersof_error = $_ }
		}
	}

	# process changes
	If ($null -ne $ad_membersof_object) {
		# create empty arrays
		$ad_membersof_current = @()
		$ad_membersof_desired = @()

		# retrieve current membership
		ForEach ($MemberOfDN in $ad_membersof_object.MemberOf) {
			If ($MemberOfDN -match $Filter -and -not [string]::IsNullOrEmpty($MemberOfDN)) { $ad_membersof_current += $MemberOfDN }
		}

		# retrieve desired membership
		ForEach ($MemberOfDN in $MemberOfDNs) {
			If ($MemberOfDN -match $Filter -and -not [string]::IsNullOrEmpty($MemberOfDN)) { $ad_membersof_desired += $MemberOfDN }
		}

		# retrieve missing and extra memberships
		$ad_membersof_missing += [array][System.Linq.Enumerable]::Except([string[]]$ad_membersof_desired, [string[]]$ad_membersof_current)
		$ad_membersof_invalid += [array][System.Linq.Enumerable]::Except([string[]]$ad_membersof_current, [string[]]$ad_membersof_desired)

		# report current, desired, missing, and extra memberships
		If ($VerbosePreference -eq 'Continue') {
			ForEach ($ad_memberof_fqdn in $ad_membersof_current) { Write-Verbose "Current MemberOf: $ad_memberof_fqdn" }
			ForEach ($ad_memberof_fqdn in $ad_membersof_desired) { Write-Verbose "Desired MemberOf: $ad_memberof_fqdn" }
			ForEach ($ad_memberof_fqdn in $ad_membersof_missing) { Write-Verbose "Will Join: $ad_memberof_fqdn" }
			ForEach ($ad_memberof_fqdn in $ad_membersof_invalid) { Write-Verbose "Will Leave: $ad_memberof_fqdn" }
		}

		# add missing memberships
		If ( $ad_membersof_missing.Count -ge 1 ) {
			if ($PSCmdlet.ShouldProcess($ad_membersof_missing, "Add $($ad_membersof_object.SamAccountName) to groups")) {
				Add-ADPrincipalGroupMembership -Server $Server -Identity $ad_membersof_object -MemberOf $ad_membersof_missing
				$ad_membersof_changed += $ad_membersof_missing
			}
		}

		# remove extra memberships
		If ( $ad_membersof_invalid.Count -ge 1 ) {
			if ($PSCmdlet.ShouldProcess($ad_membersof_invalid, "Remove $($ad_membersof_object.SamAccountName) from groups")) {
				Remove-ADPrincipalGroupMembership -Server $Server -Identity $ad_membersof_object -MemberOf $ad_membersof_invalid -Confirm:$false
				$ad_membersof_changed += $ad_membersof_invalid
			}
		}
	}

	# return the report if requested
	If ($Report) {
		[PSCustomObject]@{
			Error             = $ad_membersof_error
			DistinguishedName = $ad_membersof_object.DistinguishedName
			SamAccountName    = $ad_membersof_object.SamAccountName
			Added             = [array][Linq.Enumerable]::OrderBy($ad_membersof_missing, [Func[object, string]] { $args[0] })
			Removed           = [array][Linq.Enumerable]::OrderBy($ad_membersof_invalid, [Func[object, string]] { $args[0] })
			Changed           = [array][Linq.Enumerable]::OrderBy($ad_membersof_changed, [Func[object, string]] { $args[0] })
		}
	}
}

# define functions to export
$functions_to_export = @()
$functions_to_export += 'Find-ADGroup'
$functions_to_export += 'Update-ADMembers'
$functions_to_export += 'Update-ADMembersOf'

# export module members
Export-ModuleMember -Function $functions_to_export