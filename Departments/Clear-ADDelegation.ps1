#Requires -Modules ActiveDirectory,ADPermissions

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Default')]
	[string]$Group,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Self')]
	[switch]$Self,
	[Parameter(Position = 1, Mandatory = $True)]
	[string[]]$Container,
	[Parameter(Position = 2)]
	[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
	[Parameter(Position = 3)]
	[switch]$Reset
)

# create global objects
$env_comp_name = [System.Environment]::MachineName.ToLowerInvariant()

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

# update permissions
Update-ADPermissions -Objects $ad_paths -SID $ad_sid -Reset:$Reset
