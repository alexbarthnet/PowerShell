#requires -Modules ActiveDirectory

<#
.SYNOPSIS
Add principals from a CSV file to an Active Directory group.

.DESCRIPTION
Add principals from a CSV file to an Active Directory group.

.PARAMETER Identity
The identity of the Active Directory group. Required.

.PARAMETER Path
The path of the CSV file containing the principals to be added to the group. Principals can be users, groups, or computers. Required.

.PARAMETER Column
The name of the column in the CSV file containing the SAM Account Name of the principals to be added to the group. Required.

.PARAMETER Header
The header for the data imported from the CSV file when the header is not present in the CSV file. Optional.

.INPUTS
None.

.OUTPUTS
None.

#>

[CmdletBinding(SupportsShouldProcess)]
Param(
	# get distinguished name of domain
	[Parameter(DontShow)]
	[string]$DomainComponent = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().GetDirectoryEntry().DistinguishedName,
	# get pdc role owner of domain
	[Parameter(DontShow)]
	[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().PdcRoleOwner.Name,
	# identity of group to process
	[Parameter(Position = 0, Mandatory, ValueFromPipeline = $true)]
	[object]$Identity,
	# path to CSV file
	[Parameter(Position = 1, Mandatory)]
	[string]$Path,
	# column in CSV file
	[Parameter(Position = 2, Mandatory)]
	[string]$Column,
	# optional headers for CSV object
	[Parameter(Position = 3)]
	[string[]]$Header
)

# define boolean
$RefreshGroup = $false
	
# if identity is not an AD group object...
If ($Identity -isnot [Microsoft.ActiveDirectory.Management.ADGroup]) {
	$RefreshGroup = $true
}

# if identity is an AD group object but missing the Member property...
If ($Identity -is [Microsoft.ActiveDirectory.Management.ADGroup] -and -not $Identity.PSObject.Properties.Name.Contains('Member')) {
	$RefreshGroup = $true
}

# if identity needs to be refreshed...
If ($RefreshGroup) {
	# define parameters
	$GetADGroup = @{
		Server      = $Server
		Identity    = $Identity
		Properties  = 'Member'
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# retrieve group
	try {
		$Identity = Get-ADGroup @GetADGroup
	}
	catch {
		Write-Warning -Message "could not retrieve group with '$Identity' identity on '$Server' server: $($_.Exception.Message)"
		Throw $_
	}
}

# define required parameters
$ImportCsv = @{
	Path = $Path
}

# define optional parameters
If ($PSBoundParameters.ContainsKey('Header')) {
	$ImportCsv.Add('Header', $Header)
}

# import CSV to object
Try {
	$CSV = Import-Csv @ImportCsv
}
Catch {
	Write-Warning -Message "could not retrieve group with '$Identity' identity on '$Server' server: $($_.Exception.Message)"
	Throw $_
}

# if CSV does not have the required column...
If (!$CSV[0].PSObject.Properties.Name.Contains($Column)) {
	Write-Warning -Message "could not locate '$Column' column in '$Path' CSV file"
	Return
}

# define row counter
$Row = 0

# loop through rows in CSV
:NextEntryInCsv ForEach ($Entry in $CSV) {
	# increment row counter
	$Row++

	# if value in column is null or empty...
	If ([string]::IsNullOrEmpty($Entry.$Column)) {
		Write-Warning -Message "found empty string in '$Column' property on '$Row' row in '$Path' CSV file"
		Continue NextEntryInCsv
	}
	Else {
		# extract SAM account name from row
		$SamAccountName = $Entry.$Column
	}

	# define filter
	$Filter = "(objectCategory -eq 'person' -and SamAccountName -eq '$SamAccountName') -or (objectCategory -eq 'group' -and SamAccountName -eq '$SamAccountName') -or (objectCategory -eq 'computer' -and SamAccountName -eq '$SamAccountName$')"

	# define parameters
	$GetADObject = @{
		Server      = $Server
		SearchBase  = $DomainComponent
		SearchScope = 'Subtree'
		Filter      = $Filter
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# retrieve object from AD
	try {
		$ADObject = Get-ADObject @GetADObject
	}
	catch {
		Write-Warning -Message "could not query for object with '$SamAccountName' SAM account name on '$Server' server: $($_.Exception.Message)"
		Continue NextEntryInCsv
	}

	# if object not found...
	If (!$ADObject) {
		Write-Warning -Message "could not locate object with '$SamAccountName' SAM account name on '$Server' server: $($_.Exception.Message)"
		Continue NextEntryInCsv
	}

	# if object already member of group...
	If ($ADObject.DistinguishedName -in $Identity.Member) {
		Write-Host "found '$SamAccountName' already member of '$($Identity.SamAccountName)' group on '$Server' server with DN: $($ADObject.DistinguishedName)"
		Continue NextEntryInCsv
	}

	# define parameters
	$AddADGroupMember = @{
		Server      = $Server
		Identity    = $Identity
		Members     = $ADObject.DistinguishedName
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# define ShouldProcess components
	$ShouldProcessMessage = "added '$SamAccountName' to '$($Identity.SamAccountName)' group on '$Server' server with DN: $($ADObject.DistinguishedName)"

	# if should process...
	If ($PSCmdlet.ShouldProcess($ShouldProcessMessage, $ShouldProcessTarget, $ShouldProcessAction)) {
		# add user to group
		try {
			Add-ADGroupMember @AddADGroupMember
		}
		catch {
			Write-Warning -Message "could not add '$SamAccountName' ($($ADObject.DistinguishedName)) to '$($Identity.SamAccountName)' group on '$Server' server : $($_.Exception.Message)"
			Return $_
		}

		# declare add
		Write-Host "added '$SamAccountName' to '$($Identity.SamAccountName)' group on '$Server' server with DN: $($ADObject.DistinguishedName)"
	}
}
