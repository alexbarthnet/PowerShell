Param(  
    [switch]$Self,
    [boolean]$LimitToAD = $false,
    [boolean]$LimitToCampus = $true
)

# get local server name
$server_name = [System.Environment]::MachineName.ToLower()
 
# if standalone create empty arrays for subnets
If ($self) {
    $networks_v4 = @()
    $networks_v6 = @()
}
Else {
    switch ($true) {
        # filter for permitting recursion from all subnets but "Other" subnets
        $LimitToAD { $filter = "Location -like '*-AD'" }

        # filter for permitting recursion from only AD subnets
        $LimitToCampus { $filter = "Location -notlike 'Other'" }
    }
 
    # get all AD subnets that match filter
    $networks = Get-ADReplicationSubnet -Server $server_name -Filter $filter
    $networks_v4 = ($networks | Where-Object { $_.Name -match '\.' } | Sort-Object Name).Name
    $networks_v6 = ($networks | Where-Object { $_.Name -match '\:' } | Sort-Object Name).Name
}
  
# append AD subnet objects with loopback addresses
$networks_v4 += '127.0.0.0/8'
$networks_v6 += '::1/128'
 
# create string for subnet commands
$subnet_name = ($server_name + '-subnets')

# update the DNS subnet object with the AD subnet object
Set-DnsServerClientSubnet -Name $subnet_name -IPv4Subnet $networks_v4 -Action 'REPLACE'
Set-DnsServerClientSubnet -Name $subnet_name -IPv6Subnet $networks_v6 -Action 'REPLACE'
