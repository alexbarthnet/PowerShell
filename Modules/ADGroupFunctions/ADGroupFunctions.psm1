#Requires -Modules ActiveDirectory

Function Find-ADGroup {
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ $_ -is [Microsoft.ActiveDirectory.Management.ADObject] -or $_ -is [System.String] })]
		[object]$Identity,
		[Parameter(Position = 1)][Alias('Property')]
		[string[]]$Properties,
		[Parameter(Position = 2)][ValidateSet('Distribution', 'Security')]
		[string]$GroupCategory = 'Security',
		[Parameter(Position = 3)][ValidateSet('DomainLocal', 'Global', 'Universal')]
		[string]$GroupScope = 'Universal',
		[Parameter(Position = 4)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
	)

	# check for group
	Try {
		# retrieve group with identity
		$ADGroup = Get-ADGroup -Server $Server -Identity $Identity -Properties $Properties
	}
	Catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
		# set boolean and continue
		$NotFound = $true
	}
	Catch [System.UnauthorizedAccessException] {
		# warn and contine on unauthorized
		Write-Warning -Message "unauthorized exception thrown when retrieving group with identity: '$Identity'"
		Return $_
	}
	Catch {
		# warn and contine on unauthorized
		Write-Warning -Message "unhandled exception thrown when retrieving group with identity: $Identity"
		Return $_
	}

	# if group not found...
	If ($NotFound) {
		# if identity is an ADObject...
		If ($PSBoundParameters['Identity'] -is [Microsoft.ActiveDirectory.Management.ADObject]) {
			# get distinguished name from object
			$DistinguishedName = $PSBoundParameters[$Identity].DistinguishedName
		}
		# if identity is an ADObject...
		Else {
			# set distinguished name to input
			$DistinguishedName = $PSBoundParameters[$Identity]
		}

		# define parameters for New-ADGroup from distinguished name
		$NewADGroup = @{
			Server         = $Server
			Path           = $DistinguishedName.Split(',', 2)[1]
			Name           = $DistinguishedName.Split(',', 2)[0].Replace('CN=', $null)
			SamAccountName = $DistinguishedName.Split(',', 2)[0].Replace('CN=', $null)
			GroupCategory  = $GroupCategory
			GroupScope     = $GroupScope
			PassThru       = $true
			ErrorAction    = [System.Management.Automation.ActionPreference]::Stop
		}

		# create group
		Try {
			# create group from identity
			$ADGroup = New-ADGroup @NewADGroup -PassThru
		}
		Catch [System.UnauthorizedAccessException] {
			# report no access and return exception
			Write-Warning -Message "unauthorized returned when creating group with identity: $Identity"
			Return $_
		}
		Catch [Microsoft.ActiveDirectory.Management.ADIdentityAlreadyExistsException] {
			# report already exists and return exception
			Write-Warning -Message "existing identity found when creating group with identity: $Identity"
			Return $_
		}
		Catch {
			# report unhandled and return exception
			Write-Warning -Message "unhandled exception thrown when creating group with identity: $Identity"
			Return $_
		}

		# if properties defined...
		If ($PSBoundParameters.ContainsKey('Properties')) {
			# retrieve requested properties
			Try {
				$ADGroup = Get-ADGroup -Server $Server -Identity $Identity -Properties $Properties
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
		}

		# define note properties for created object
		$NotePropertyMembers = @{ Created = $true; Found = $false }
	}
	# if group found...
	Else {
		# define note properties for found object
		$NotePropertyMembers = @{ Created = $false; Found = $true }
	}

	# attach note properties to group
	Add-Member -InputObject $ADGroup -NotePropertyMembers $NotePropertyMembers -Force

	# return group
	Return $ADGroup
}

Function Get-ADGroupsFromAttribute {
	[CmdletBinding()]
	param (
		# require Active Director object or string and permit value via pipeline
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ $_ -is [Microsoft.ActiveDirectory.Management.ADObject] -or $_ -is [System.String] })]
		[object]$Identity,
		# default to member transitive attribute for retrieving group members from an object
		[Parameter(Position = 1)]
		[string]$Attribute = 'msds-membertransitive',
		# default to returning distinguished name of group
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

	# create list for groups
	$ADGroups = [System.Collections.Generic.List[object]]::new()

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

		# if object is a group...
		If ($ADObject.ObjectClass -eq 'group') {
			# ...add object to groups list
			$ADGroups.Add($ADObject)
		}
	}

	# create list for results
	$Results = [System.Collections.Generic.List[string]]::new()

	# process groups in list
	ForEach ($ADGroup in $ADGroups) {
		# if object not already in results list...
		If ($ADGroup.$Property -notin $Results) {
			# ...add object to results list
			$Results.Add($ADGroup.$Property)
		}
	}

	# return list to caller
	Return $Results
}

Function Get-ADGroupsFromQuery {
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
		# default to returning distinguished name of group
		[Parameter(Position = 2)][ValidateSet('Name', 'DistinguishedName', 'SamAccountName')]
		[string]$Property = 'DistinguishedName',
		# default to PDC role holder for server
		[Parameter(Position = 3)]
		[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
	)

	# if filter provided...
	If ($PSCmdlet.ParameterSetName -eq 'Filter') {
		Try {
			# retrieve groups matching filter
			$ADGroups = Get-ADGroup -Server $Server -SearchBase $SearchBase -Filter $Filter
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
			# retrieve groups matching LDAP filter
			$ADGroups = Get-ADGroup -Server $Server -SearchBase $SearchBase -LDAPFilter $LDAPFilter
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
	ForEach ($ADGroup in $ADGroups) {
		# if object not already in results list...
		If ($ADGroup.$Property -notin $Results) {
			# ...add object to results list
			$Results.Add($ADGroup.$Property)
		}
	}

	# return list to caller
	Return $Results
}

Function Set-ADGroupMember {
	[CmdletBinding(SupportsShouldProcess)]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ $_ -is [Microsoft.ActiveDirectory.Management.ADObject] -or $_ -is [System.String] })]
		[object]$Identity,
		[Parameter(Position = 1, Mandatory = $true)][AllowEmptyCollection()][AllowNull()][Alias('MemberDNs')]
		[object[]]$Members,
		[Parameter(Position = 2)][AllowEmptyCollection()][AllowNull()][Alias('MemberOfToExclude')]
		[object[]]$MembersToExclude,
		[Parameter(Position = 3)]
		[string[]]$Properties = ('Member', 'SamAccountName', 'WhenChanged', 'WhenCreated'),
		[Parameter(Position = 4)]
		[string]$Filter = '^CN=',
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
		If ('Member' -notin $Properties) { $Properties += 'Member' }
		If ('SamAccountName' -notin $Properties) { $Properties += 'SamAccountName' }
		If ('WhenChanged' -notin $Properties) { $Properties += 'WhenChanged' }
		If ('WhenCreated' -notin $Properties) { $Properties += 'WhenCreated' }
	}

	# retrieve group before changes
	Try {
		$ADGroup = Get-ADGroup -Server $Server -Identity $Identity -Properties $Properties
	}
	Catch {
		Return $_
	}

	# create list for current members
	$MembersCurrent = [System.Collections.Generic.List[string]]::new($ADGroup.Member.Count)

	# update list with current members
	ForEach ($Member in $ADGroup.Member) {
		$MembersCurrent.Add($MemberDN)
	}

	# create list for desired members
	$MembersDesired = [System.Collections.Generic.List[string]]::new($Members.Count)

	# retrieve desired members
	ForEach ($Member in $Members) {
		If ($Member -is [Microsoft.ActiveDirectory.Management.ADObject]) {
			$MembersOmitted.Add($Member.DistinguishedName)
		}
		ElseIf ($Member -match $Filter -and -not [string]::IsNullOrEmpty($Member)) {
			$MembersDesired.Add($MemberDN)
		}
		Else {
			Write-Warning -Message "found invalid value for member: '$Member'"
		}
	}

	# create list for members to exclude
	$MembersOmitted = [System.Collections.Generic.List[string]]::New($MembersToExclude.Count)

	# update list with members to exclude
	ForEach ($Member in $MembersToExclude) {
		If ($Member -is [Microsoft.ActiveDirectory.Management.ADObject]) {
			$MembersOmitted.Add($Member.DistinguishedName)
		}
		ElseIf ($Member -match $Filter -and -not [string]::IsNullOrEmpty($Member)) {
			$MembersOmitted.Add($Member)
		}
		Else {
			Write-Warning -Message "found invalid value for member: '$Member'"
		}
	}

	# retrieve desired members less any members to exclude
	$MembersTrimmed = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($MembersDesired, $MembersOmitted))

	# retrieve missing members, linq will ensure that the output is of unique values
	$MembersMissing = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($MembersTrimmed, $MembersCurrent))

	# retrieve invalid members, linq will ensure that the output is of unique values
	$MembersInvalid = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($MembersCurrent, $MembersTrimmed))

	# report desired, current, missing, and extra members
	If ($VerbosePreference -eq 'Continue') {
		ForEach ($Member in $MembersCurrent) { Write-Verbose "Current Member: $Member" }
		ForEach ($Member in $MembersTrimmed) { Write-Verbose "Desired Member: $Member" }
		ForEach ($Member in $MembersOmitted) { Write-Verbose "Omitted Member: $Member" }
		ForEach ($Member in $MembersMissing) { Write-Verbose "Will Invite: $Member" }
		ForEach ($Member in $MembersInvalid) { Write-Verbose "Will Remove: $Member" }
	}

	# add any missing members
	If ($MembersMissing.Count -ge 1) {
		If ($PSCmdlet.ShouldProcess(($MembersMissing -join ','), "Invite '$($MembersMissing.Count)' member(s) to $($ADGroup.SamAccountName)")) {
			Try {
				Add-ADGroupMember -Server $Server -Identity $ADGroup -Members $MembersMissing
			}
			Catch {
				Return $_
			}
		}
	}

	# remove any extra members
	If ($MembersInvalid.Count -ge 1) {
		If ($PSCmdlet.ShouldProcess(($MembersInvalid -join ','), "Remove '$($MembersInvalid.Count)' member(s) from $($ADGroup.SamAccountName)")) {
			Try {
				Remove-ADGroupMember -Server $Server -Identity $ADGroup -Members $MembersInvalid -Confirm:$false
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
			$ADGroup = Get-ADGroup -Server $Server -Identity $Identity -Properties $Properties
			# define note properties for object
			$NotePropertyMembers = @{ MemberAdded = $MembersMissing; MemberRemoved = $MembersInvalid }
			# attach note properties to updated object
			Add-Member -InputObject $ADGroup -NotePropertyMembers $NotePropertyMembers -Force
			# return notated object
			Return $ADGroup
		}
		Catch {
			Return $_
		}
	}
}

Function Set-ADGroupMemberOf {
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
		$ADGroup = Get-ADGroup -Server $Server -Identity $Identity -Properties $Properties
	}
	Catch {
		Return $_
	}

	# create generic current membership
	$MemberOfCurrent = [System.Collections.Generic.List[string]]::new($ADGroup.MemberOf.Count)

	# update list with current membership
	ForEach ($MemberOf in $ADGroup.MemberOf) {
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
		If ($PSCmdlet.ShouldProcess(($MemberOfMissing -join ','), "Join '$($MemberOfMissing.Count)' group(s) for '$($ADGroup.SamAccountName)'")) {
			Try {
				Add-ADPrincipalGroupMembership -Server $Server -Identity $ADGroup -MemberOf $MemberOfMissing
			}
			Catch {
				Return $_
			}
		}
	}

	# remove extra memberships
	If ($MemberOfInvalid.Count -ge 1) {
		If ($PSCmdlet.ShouldProcess(($MemberOfInvalid -join ','), "Exit '$($MemberOfMissing.Count)' group(s) for '$($ADGroup.SamAccountName)'")) {
			Try {
				Remove-ADPrincipalGroupMembership -Server $Server -Identity $ADGroup -MemberOf $MemberOfInvalid -Confirm:$false
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
			$ADGroup = Get-ADGroup -Server $Server -Identity $Identity -Properties $Properties
			# define note properties for object
			$NotePropertyMembers = @{ MemberOfAdded = $MemberOfMissing; MemberOfRemoved = $MemberOfInvalid }
			# attach note properties to updated object
			Add-Member -InputObject $ADGroup -NotePropertyMembers $NotePropertyMembers -Force
			# return notated object
			Return $ADGroup
		}
		Catch {
			Return $_
		}
	}
}

# define functions to export
$FunctionsToExport = @(
	'Find-ADGroup'
	'Get-ADGroupsFromAttribute'
	'Get-ADGroupsFromQuery'
	'Set-ADGroupMember'
	'Set-ADGroupMemberOf'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport
