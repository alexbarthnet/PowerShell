#Requires -Modules ActiveDirectory

Function Find-ADGroup {
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ $_ -is [Microsoft.ActiveDirectory.Management.ADObject] -or $_ -is [System.String] })]
		[object]$Identity,
		[Parameter(Position = 1)]
		[string[]]$Attributes = @('*'),
		[Parameter(Position = 2)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
	)

	# check attributes
	If ('*' -notin $Attributes) {
		If ('whenChanged' -notin $Attributes) { $Attributes += 'whenChanged' }
		If ('whenCreated' -notin $Attributes) { $Attributes += 'whenCreated' }
	}

	# check for group
	Try {
		# return group object to caller with the requested attributes
		Return (Get-ADGroup -Server $Server -Identity $Identity -Properties $Attributes)
	}
	Catch {
		# collect error before attempting to create group
		$group_error = $_
		# check whatif
		If ($Identity -is [System.String]) {
			$group_name = $Identity.Split(',', 2)[0].Replace('CN=', $null)
			$group_path = $Identity.Split(',', 2)[1]
			Try {
				# create the group then return the group with the requested attributes
				Return (New-ADGroup -Server $Server -Name $group_name -Path $group_path -GroupScope Global -Passthru | Get-ADGroup -Properties $Attributes)
			}
			Catch [Microsoft.ActiveDirectory.Management.ADIdentityAlreadyExistsException] {
				# report error if verbose
				Write-Verbose -Message 'ERROR: could not create group, resource with the same name already exists'
				# return error to caller
				Return $_
			}
			Catch {
				# report error if verbose
				Write-Verbose -Message 'ERROR: could not create group'
				# return error to caller
				Return $_
			}
		}
		Else {
			# report error if verbose
			Write-Verbose -Message 'ERROR: object passed but not found/'
			# return error to caller
			Return $group_error
		}
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
		[switch]$Report
	)

	# create empty arrays
	$ad_members_missing = @()
	$ad_members_invalid = @()
	$ad_members_changed = @()

	# retrieve object
	Try {
		$ad_members_object = Get-ADGroup -Server $Server -Identity $Identity -Properties @('Member', 'SamAccountName')
		$ad_members_error = $null
	}
	Catch {
		$ad_members_object = $null
		$ad_members_error = $_
	}

	# process changes
	If ($null -ne $ad_members_object) {
		# create empty arrays
		$ad_members_current = @()
		$ad_members_desired = @()
		$ad_members_exclude = @()
		$ad_members_trimmed = @()

		# retrieve current members
		ForEach ($MemberDN in $ad_members_object.Member) {
			If ($MemberDN -match $Filter -and -not [string]::IsNullOrEmpty($MemberDN)) { $ad_members_current += $MemberDN }
		}

		# retrieve desired members
		ForEach ($MemberDN in $MemberDNs) {
			If ($MemberDN -match $Filter -and -not [string]::IsNullOrEmpty($MemberDN)) { $ad_members_desired += $MemberDN }
		}

		# retrieve excluded DNs
		ForEach ($MemberDN in $ExcludedDNs) {
			If ($MemberDN -match $Filter -and -not [string]::IsNullOrEmpty($MemberDN)) { $ad_members_exclude += $MemberDN }
		}

		# retrieve missing members less any excluded DNs
		$ad_members_trimmed += [array][System.Linq.Enumerable]::Except([string[]]$ad_members_desired, [string[]]$ad_members_exclude)

		# retrieve missing members, linq will ensure that the output is of unique values
		$ad_members_missing += [array][System.Linq.Enumerable]::Except([string[]]$ad_members_trimmed, [string[]]$ad_members_current)

		# retrieve extra members, linq will ensure that the output is of unique values
		$ad_members_invalid += [array][System.Linq.Enumerable]::Except([string[]]$ad_members_current, [string[]]$ad_members_trimmed)

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
				Add-ADGroupMember -Server $Server -Identity $ad_members_object -Members $ad_members_missing
				# if report requested...
				If ($Report) {
					# sort added members
					$ad_members_changed += $ad_members_missing
				}
			}
		}

		# remove any extra members
		If ( $ad_members_invalid.Count -ge 1 ) {
			if ($PSCmdlet.ShouldProcess(($ad_members_invalid -join ','), "Remove members from $($ad_members_object.SamAccountName)")) {
				Remove-ADGroupMember -Server $Server -Identity $ad_members_object -Members $ad_members_invalid -Confirm:$false
				# if report requested...
				If ($Report) {
					# sort removed members
					$ad_members_changed += $ad_members_invalid
				}
			}
		}
	}

	# return the report if requested
	If ($Report) {
		[PSCustomObject]@{
			Error             = $ad_members_error
			DistinguishedName = $ad_members_object.DistinguishedName
			SamAccountName    = $ad_members_object.SamAccountName
			Added             = [array][Linq.Enumerable]::OrderBy($ad_members_missing, [Func[object, string]] { $args[0] })
			Removed           = [array][Linq.Enumerable]::OrderBy($ad_members_invalid, [Func[object, string]] { $args[0] })
			Changed           = [array][Linq.Enumerable]::OrderBy($ad_members_changed, [Func[object, string]] { $args[0] })
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