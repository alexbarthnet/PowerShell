#Requires -Modules ActiveDirectory

Function Get-ADUsersFromAttribute {
	[CmdletBinding()]
	param (
		# require Active Director object or string and permit value via pipeline
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ $_ -is [Microsoft.ActiveDirectory.Management.ADObject] -or $_ -is [System.String] })]
		[object]$Identity,
		# default to member transitive attribute for retrieving group members from a group
		[Parameter(Position = 1)]
		[string]$Attribute = 'msds-membertransitive',
		# default to returning distinguished name of user
		[Parameter(Position = 2)][ValidateSet('Name', 'DistinguishedName', 'SamAccountName')]
		[string]$Property = 'DistinguishedName',
		# default to PDC role holder for server
		[Parameter(Position = 3)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
	)

	# retrieve group with requested attribute
	Try {
		$ADObject = Get-ADObject -Server $Server -Identity $PSBoundParameters['Identity'] -Properties $Attribute
	}
	Catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
		# report not found and return exception
		Write-Warning -Message "could not find object with identity: '$Identity'"
		Return $_
	}
	Catch [System.UnauthorizedAccessException] {
		# report no access and return exception
		Write-Warning -Message "could not access object with identity: '$Identity'"
		Return $_
	}
	Catch {
		# report unhandled and return exception
		Write-Warning -Message "could not retrieve object with identity: $Identity"
		Return $_
	}

	# create list for user
	$ADUsers = [System.Collections.Generic.List[object]]::new()

	# process values in attribute
	ForEach ($Identity in $ADObject.$Attribute) {
		# retrieve object from value
		Try {
			$ADObject = Get-ADObject -Server $Server -Identity $Identity -Properties $Property
		}
		Catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
			# report not found and continue
			Write-Warning -Message "could not find object with identity: '$Identity'"
			Continue
		}
		Catch [System.UnauthorizedAccessException] {
			# report no access and continue
			Write-Warning -Message "could not access object with identity: '$Identity'"
			Return $_
		}
		Catch {
			# report unhandled and return exception
			Write-Warning -Message "could not retrieve object with identity: $Identity"
			Return $_
		}

		# if object is a user...
		If ($ADObject.ObjectClass -eq 'user') {
			# ...add object to groups list
			$ADUsers.Add($ADObject)
		}
	}

	# create list for results
	$Results = [System.Collections.Generic.List[string]]::new()

	# process groups in list
	ForEach ($ADUser in $ADUsers) {
		# if object not already in results list...
		If ($ADUser.$Property -notin $Results) {
			# ...add object to results list
			$Results.Add($ADUser.$Property)
		}
	}

	# return list to caller
	Return $Results
}

Function Get-ADUsersFromQuery {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	param (
		# require LDAP filter
		[Parameter(Position = 0, ParameterSetName = 'Default', Mandatory = $true)]
		[string]$LDAPFilter,
		# require PowerShell filter
		[Parameter(Position = 0, ParameterSetName = 'Filter', Mandatory = $true)]
		[string]$Filter,
		# default to domain root for search base
		[Parameter(Position = 1)]
		[string]$SearchBase = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName,
		# default to returning distinguished name of user
		[Parameter(Position = 2)][ValidateSet('Name', 'DistinguishedName', 'SamAccountName')]
		[string]$Property = 'DistinguishedName',
		# default to PDC role holder for server
		[Parameter(Position = 3)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
	)

	# if filter provided...
	If ($PSCmdlet.ParameterSetName -eq 'Filter') {
		Try {
			# retrieve users matching filter
			$ADUsers = Get-ADUser -Server $Server -SearchBase $SearchBase -Filter $Filter
		}
		Catch {
			# report unhandled and return exception
			Write-Warning -Message "could not query with filter: '$Filter'"
			Return $_
		}
	}
	# if LDAP filter provided...
	Else {
		Try {
			# retrieve users matching LDAP filter
			$ADUsers = Get-ADUser -Server $Server -SearchBase $SearchBase -LDAPFilter $LDAPFilter
		}
		Catch {
			# report unhandled and return exception
			Write-Warning -Message "could not query with LDAP filter: '$LDAPFilter'"
			Return $_
		}
	}

	# create list for results
	$Results = [System.Collections.Generic.List[string]]::new()

	# process groups from query
	ForEach ($ADUser in $ADUsers) {
		# if object not already in results list...
		If ($ADUser.$Property -notin $Results) {
			# ...add object to results list
			$Results.Add($ADUser.$Property)
		}
	}

	# return list to caller
	Return $Results
}

Function Set-ADUserMemberOf {
	[CmdletBinding(SupportsShouldProcess)]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ $_ -is [Microsoft.ActiveDirectory.Management.ADObject] -or $_ -is [System.String] })]
		[object]$Identity,
		[Parameter(Position = 1, Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()][Alias('MemberOf')]
		[object[]]$MemberOf,
		[Parameter(Position = 2)][AllowEmptyCollection()][AllowEmptyString()][AllowNull()][Alias('MemberOfToExclude')]
		[object[]]$MemberOfToExclude,
		[Parameter(Position = 3)]
		[string]$Filter = '^CN=',
		[Parameter(Position = 4)]
		[string[]]$Properties = ('MemberOf', 'SamAccountName', 'WhenChanged', 'WhenCreated'),
		[Parameter(Position = 5)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
		[Parameter(Position = 6)]
		[switch]$PassThru
	)

	# check requested property values
	If ($Properties -contains '*') {
		$Properties = '*'
	}
	Else {
		If ('MemberOf' -notin $Properties) { $Properties += 'MemberOf' }
		If ('SamAccountName' -notin $Properties) { $Properties += 'SamAccountName' }
		If ('WhenChanged' -notin $Properties) { $Properties += 'WhenChanged' }
		If ('WhenCreated' -notin $Properties) { $Properties += 'WhenCreated' }
	}

	# retrieve group before changes
	Try {
		$ADUser = Get-ADUser -Server $Server -Identity $Identity -Properties $Properties
	}
	Catch {
		Return $_
	}

	# create generic current membership
	$MemberOfCurrent = [System.Collections.Generic.List[string]]::new($ADUser.MemberOf.Count)

	# update list with current membership
	ForEach ($MemberOf in $ADUser.MemberOf) {
		$MemberOfCurrent.Add($MemberOf)
	}

	# create list for desired membership
	$MemberOfDesired = [System.Collections.Generic.List[string]]::new($MemberOf.Count)

	# update list with desired membership
	ForEach ($MemberOf in $MemberOf) {
		If ($MemberOf -is [Microsoft.ActiveDirectory.Management.ADObject]) {
			$MemberOfDesired.Add($MemberOf.DistinguishedName)
		}
		ElseIf ($MemberOf -match $Filter -and -not [string]::IsNullOrEmpty($MemberOf)) {
			$MemberOfDesired.Add($MemberOf)
		}
		Else {
			Write-Warning -Message "found invalid value for memberOf: '$MemberOf'"
		}
	}

	# create list for membership to exclude
	$MemberOfOmitted = [System.Collections.Generic.List[string]]::new($MemberOfToExclude.Count)

	# update list with membership to exclude
	ForEach ($MemberOf in $MemberOfToExclude) {
		If ($MemberOf -is [Microsoft.ActiveDirectory.Management.ADObject]) {
			$MemberOfOmitted.Add($MemberOf.DistinguishedName)
		}
		ElseIf ($MemberOf -match $Filter -and -not [string]::IsNullOrEmpty($MemberOf)) {
			$MemberOfOmitted.Add($MemberOf)
		}
		Else {
			Write-Warning -Message "found invalid value for memberOf: '$MemberOf'"
		}
	}

	# retrieve missing memberships less any memberships to exclude
	$MemberOfTrimmed = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($MemberOfDesired, $MemberOfOmitted))

	# retrieve missing memberships, linq will ensure that the output is of unique values
	$MemberOfMissing = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($MemberOfTrimmed, $MemberOfCurrent))

	# retrieve invalid memberships, linq will ensure that the output is of unique values
	$MemberOfInvalid = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($MemberOfCurrent, $MemberOfTrimmed))

	# report current, desired, missing, and extra memberships
	If ($VerbosePreference -eq 'Continue') {
		ForEach ($MemberOf in $MemberOfCurrent) { Write-Verbose "Current MemberOf: $MemberOf" }
		ForEach ($MemberOf in $MemberOfDesired) { Write-Verbose "Desired MemberOf: $MemberOf" }
		ForEach ($MemberOf in $MemberOfOmitted) { Write-Verbose "Omitted MemberOf: $MemberOf" }
		ForEach ($MemberOf in $MemberOfMissing) { Write-Verbose "Will Join: $MemberOf" }
		ForEach ($MemberOf in $MemberOfInvalid) { Write-Verbose "Will Exit: $MemberOf" }
	}

	# add missing memberships
	If ($MemberOfMissing.Count -ge 1) {
		If ($PSCmdlet.ShouldProcess(($MemberOfMissing -join ','), "Join '$($MemberOfMissing.Count)' group(s) for '$($ADUser.SamAccountName)'")) {
			Try {
				Add-ADPrincipalGroupMembership -Server $Server -Identity $ADUser -MemberOf $MemberOfMissing
			}
			Catch {
				Return $_
			}
		}
	}

	# remove extra memberships
	If ($MemberOfInvalid.Count -ge 1) {
		If ($PSCmdlet.ShouldProcess(($MemberOfInvalid -join ','), "Exit '$($MemberOfMissing.Count)' group(s) for '$($ADUser.SamAccountName)'")) {
			Try {
				Remove-ADPrincipalGroupMembership -Server $Server -Identity $ADUser -MemberOf $MemberOfInvalid -Confirm:$false
			}
			Catch {
				Return $_
			}
		}
	}

	# return the group if passthru
	If ($PassThru) {
		# retrieve object after changes
		Try {
			# retreive updated object
			$ADUser = Get-ADUser -Server $Server -Identity $Identity -Properties $Properties
			# define note properties for object
			$NotePropertyMembers = @{ MemberOfAdded = $MemberOfMissing; MemberOfRemoved = $MemberOfInvalid }
			# attach note properties to updated object
			Add-Member -InputObject $ADUser -NotePropertyMembers $NotePropertyMembers -Force
			# return notated object
			Return $ADUser
		}
		Catch {
			Return $_
		}
	}
}

# define functions to export
$FunctionsToExport = @(
	'Get-ADUsersFromAttribute'
	'Get-ADUsersFromQuery'
	'Set-ADUserMemberOf'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport
