[CmdletBinding()]
Param(
	[Parameter(Mandatory = $True)]
	[string]$Department
)

Function New-ADContainerFromDN {
	[CmdletBinding()]
	param (
		[Parameter(Position = 0)]
		[string]$ContainerDN
	)

	# create strings
	$ad_filter = "distinguishedName -eq '$ContainerDN'"

	# check OU
	$ad_object = $null
	$ad_object = Get-ADObject -Server $ad_pdc -Filter $ad_filter
	If ($ad_object) {
		Write-Host ("$env_comp_name,$ad_pdc - ...found OU: $ContainerDN")
	}
	Else {
		# create OU
		$ad_ou_split = $ContainerDN -split ('OU=', 2) -split (',', 2)
		If ($ad_ou_split.Count -eq 3) {
			$ad_name = $ad_ou_split[1]
			$ad_path = $ad_ou_split[2]
			Try {
				New-ADOrganizationalUnit -Server $ad_pdc -Name $ad_name -Path $ad_path -ProtectedFromAccidentalDeletion $false
				Write-Host ("$env_comp_name,$ad_pdc - ...created OU: $ContainerDN")
			}
			Catch {
				Write-Host ("$env_comp_name,$ad_pdc - ERROR: could not create OU: $ContainerDN")
				Return
			}
		}
		Else {
			Write-Host ("$env_comp_name,$ad_pdc - ERROR: could not process object: $ContainerDN")
		}    
	}
}

Function New-ADGroupFromDN {
	[CmdletBinding()]
	param (
		[Parameter(Position = 0)]
		[string]$GroupDN,
		[Parameter(Position = 1)]
		[string]$GroupType = 'Universal'
	)

	# create strings
	$ad_filter = "distinguishedName -eq '$GroupDN'"

	# check group
	$ad_object = $null
	$ad_object = Get-ADObject -Server $ad_pdc -Filter $ad_filter
	If ($ad_object) {
		Write-Host ("$env_comp_name,$ad_pdc - ...found existing object: $($ad_object.Name)")
	}
	Else {
		# create group
		$ad_cn_split = $GroupDN -split ('CN=', 2) -split (',', 2)
		If ($ad_cn_split.Count -eq 3) {
			$ad_name = $ad_cn_split[1]
			$ad_path = $ad_cn_split[2]
			Try {
				New-ADGroup -Server $ad_pdc -Name $ad_name -Path $ad_path -GroupScope $GroupType
				Write-Host ("$env_comp_name,$ad_pdc - ...created group: $ad_name")    
			}
			Catch {
				Write-Host ("$env_comp_name,$ad_pdc - ERROR: could not create group: $ad_name")
			}
		}
		Else {
			Write-Host ("$env_comp_name,$ad_pdc - ERROR: could not process object: " + $GroupDN)
		}    
	}
}

# create global objects
$env_comp_name = $env:computername.ToLower()

# validate input
Write-Host ("$env_comp_name - Checking input...")
If ($Department.Contains(',')) {
	Write-Host ("$env_comp_name - ERROR: found invalid character ',' in Department: " + $Department)
	Return
}

# connect to AD
Write-Host ("$env_comp_name - Connecting to AD...")
$ad_domain = $null
$ad_domain = Get-ADDomain
If ($ad_domain) {
	$ad_pdc = $ad_Domain.PDCEmulator
	$ad_nc_domain = $ad_domain.DistinguishedName
	Write-Host ("$env_comp_name - ...found domain distinguished name: " + $ad_nc_domain)
	Write-Host ("$env_comp_name - ...found primary domain controller: " + $ad_pdc)
}
Else {
	Write-Host ("$env_comp_name - ...could not connect to AD, exiting!")
	Return
}

# add department OUs by full DN
$ad_deptou = @()
$ad_deptou += ('OU=' + $Department + ',OU=Departments,OU=Administrative,' + $ad_nc_domain)
$ad_deptou += ('OU=' + $Department + ',OU=Departments,' + $ad_nc_domain)
$ad_deptou += ('OU=' + $Department + ',OU=Cloud,OU=Groups,' + $ad_nc_domain)
$ad_deptou += ('OU=' + $Department + ',OU=Managed,OU=Groups,' + $ad_nc_domain)

# define domain local groups by full DN
$ad_locals = @()
$ad_locals += ('CN=' + $Department + '-Permissions,OU=Departments,OU=Administrative,' + $ad_nc_domain)

# define domain global groups by full DN
$ad_globals = @()
$ad_globals += ('CN=' + $Department + '-Owners,OU=Departments,OU=Administrative,' + $ad_nc_domain)
$ad_globals += ('CN=' + $Department + '-Administrators,OU=' + $Department + ',OU=Departments,OU=Administrative,' + $ad_nc_domain)
$ad_globals += ('CN=' + $Department + '-PowerUsers,OU=' + $Department + ',OU=Departments,OU=Administrative,' + $ad_nc_domain)
$ad_globals += ('CN=' + $Department + '-Services,OU=' + $Department + ',OU=Departments,OU=Administrative,' + $ad_nc_domain)
$ad_globals += ('CN=' + $Department + '-DeptGroupAdministrators,OU=' + $Department + ',OU=Departments,OU=Administrative,' + $ad_nc_domain)
$ad_globals += ('CN=' + $Department + '-DeptGpoAdministrators,OU=' + $Department + ',OU=Departments,OU=Administrative,' + $ad_nc_domain)
$ad_globals += ('CN=' + $Department + '-GPO Editors,OU=' + $Department + ',OU=Departments,OU=Administrative,' + $ad_nc_domain)

# check for OUs
Write-Host ("$env_comp_name,$ad_pdc - Creating OUs...")
ForEach ($ad_dnpath in $ad_deptou) {
	New-ADContainerFromDN -ContainerDN $ad_dnpath
}

# create local groups
Write-Host ("$env_comp_name,$ad_pdc - Creating local groups...")
ForEach ($ad_dnpath in $ad_locals) {
	New-ADGroupFromDN -GroupDN $ad_dnpath -GroupType 'DomainLocal'
}

# create global groups
Write-Host ("$env_comp_name,$ad_pdc - Creating global groups...")
ForEach ($ad_dnpath in $ad_globals) { 
	New-ADGroupFromDN -GroupDN $ad_dnpath -GroupType 'Global'    
}

# define group names for membership
$ad_permissions = ($Department + '-Permissions')
$ad_gpo_editors = ($Department + '-GPO Editors')
$ad_administrators = ($Department + '-Administrators')
$ad_powerusers = ($Department + '-PowerUsers')
$ad_services = ($Department + '-Services')

# add department administrators to department groups
Write-Host ("$env_comp_name,$ad_pdc - Adding department administrators to department Permissions and GPO Editors...")
Add-ADGroupMember -Server $ad_pdc -Identity $ad_permissions -Members $ad_administrators
Add-ADGroupMember -Server $ad_pdc -Identity $ad_gpo_editors -Members $ad_administrators

# add department groups to domain groups
Write-Host ("$env_comp_name,$ad_pdc - Adding department account groups to domain account groups...")
Add-ADGroupMember -Server $ad_pdc -Identity 'DEPT-Administrators' -Members $ad_administrators
Add-ADGroupMember -Server $ad_pdc -Identity 'DEPT-PowerUsers' -Members $ad_powerusers
Add-ADGroupMember -Server $ad_pdc -Identity 'DEPT-Services' -Members $ad_services

# declare complete
Write-Output "`nCreated new department: $Department `n`nRun the 'New-ADDelegation.ps1' script to delegate the OU to the department's administrators group`n"
