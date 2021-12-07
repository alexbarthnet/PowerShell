#Requires -Modules ActiveDirectory
[CmdletBinding()]
Param (
    [string]$Attribute = 'utexasEduAustinSingle1',
    [string]$Container,
    [string]$Department
)

# get the domain naming context
$ad_nc_domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName

# set the search base for the OU query
$ad_ou_searchbase = ('OU=Departments,' + $ad_nc_domain)

# check for a filtering department
If ([string]::IsNullOrEmpty($Department)) { 
    # get the OUs at the root of search base
    $ad_ou_containers = Get-ADObject -SearchBase $ad_ou_searchbase -SearchScope OneLevel -Filter { objectClass -eq 'organizationalUnit' }
}
Else {
    # get the OUs at the root of search base
    $ad_ou_containers = Get-ADObject -SearchBase $ad_ou_searchbase -SearchScope OneLevel -Filter { objectClass -eq 'organizationalUnit' -and 'ou' -eq $Department }
}

# loop through the OUs
ForEach ($ad_ou_container in $ad_ou_containers) {
    # check for a filtering container
    If ([string]::IsNullOrEmpty($Container)) {
        # get all computers in the OU
        $ad_ou_computers = Get-ADComputer -SearchBase $ad_ou_container -SearchScope Subtree -Properties $Attribute -Filter { $Attribute -notlike '*' }
    }
    Else {
        # get computers in the OU that match the OU input
        $ad_ou_computers = Get-ADComputer -SearchBase $ad_ou_container -SearchScope Subtree -Properties $Attribute -Filter { $Attribute -notlike '*' -and 'distinguishedName' -match "$Container$" }
    }
    
    # loop through the computers
    ForEach ($ad_computer in $ad_ou_computers) {
        # get computer DN
        $ad_dn = $ad_computer.DistinguishedName

        # check each DN in computer DN for populated attribute
        Do { $ad_dn = $ad_dn.Split(',', 2)[1] } 
        Until ((Get-ADObject -Identity $ad_dn -Properties $Attribute).$($Attribute) -or ((Get-ADObject -Identity $ad_dn).distinguishedName -eq $ad_ou_container))

        # get dept code from DN that previous loop stopped at
        $ad_dept_code = $null
        $ad_dept_code = (Get-ADObject -Identity $ad_dn -Properties $Attribute).$($Attribute)

        # set dept code on computer if it exists
        If ($ad_dept_code) {
            Set-ADObject -Identity $ad_computer -Replace @{$Attribute = $ad_dept_code }
            Write-Host "$($ad_computer.SamAccountName) - set dept code to '$ad_dept_code' from '$ad_dn'"
        }
        Else {
            Write-Host "$($ad_computer.SamAccountName) - WARNING: no dept code on '$ad_dn'"
        }
    }
}
