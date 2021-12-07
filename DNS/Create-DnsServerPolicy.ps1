# get local server name
$server_name = [System.Environment]::MachineName.ToLower()
 
# create base client subnet
$subnet_name = ($server_name + "-subnets")
$subnet_exist = Get-DnsServerClientSubnet | Where-Object {$_.Name -eq $subnet_name}
If (!($subnet_exist)) { Add-DnsServerClientSubnet -Name $subnet_name -IPv4Subnet '127.0.0.1/8' }
 
# create base server-level Deny policy
$policy_name = ($server_name + "-default")
$policy_fqdn = "EQ,domain.example"
$policy_nets = ("EQ," + $server_name + "-subnets")
$policy_exist = Get-DnsServerQueryResolutionPolicy | Where-Object {$_.Name -eq $policy_name}
If (!($policy_exist)) {Add-DnsServerQueryResolutionPolicy -Name $policy_name -Fqdn $policy_fqdn -ClientSubnet $policy_nets -Action DENY -Condition AND -ProcessingOrder 1 }
