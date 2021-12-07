Param(  
    [switch]$Self
)

# get local server name
$server_name = [System.Environment]::MachineName.ToLower()
 
# get DNS zones in AD from self if DC or from PDC if not DC
$domain_role = (Get-WmiObject Win32_ComputerSystem).DomainRole
If (($domain_role -ge 4) -or ($Self)) {
    # server is DC or Self flag is set
    $zones_domain = Get-DnsServerZone -Computer $server_name
}
Else {
    # get the current PDC without requiring the ActiveDirectory powershell module
    $domain_pdce = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
    # server is not DC and Self flag is not set
    $zones_domain = Get-DnsServerZone -Computer $domain_pdce
}
 
# get all primary DNS zones stored in AD
$zones_object = $zones_domain | Where-Object { $_.ZoneType -eq 'Primary' -and $_.ZoneName -match '\.' -and !($_.IsAutoCreated) }
$zones_edited = $zones_object | Sort-Object IsReverseLookupZone, ZoneName | ForEach-Object { $_.ZoneName.Insert(0, '*.') }
$zones_joined = $zones_edited -join ','
 
# create strings for policy commands
$policy_name = ($server_name + '-default')
$policy_fqdn = ('NE,' + $zones_joined)
$policy_nets = ('NE,' + $server_name + '-subnets')
 
# update policy to block resolution of non-authoritative names from subnets not defined in the policy
Set-DnsServerQueryResolutionPolicy -Name $policy_name -ProcessingOrder 1 -Fqdn $policy_fqdn -ClientSubnet $policy_nets -Condition AND
