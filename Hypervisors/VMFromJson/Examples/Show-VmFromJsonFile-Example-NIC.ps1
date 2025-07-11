Write-Host "##### BEGIN EXAMPLE #####`n"; Get-Content -Path $PSCommandPath | Select-Object -Skip 3; Write-Host "`n##### END EXAMPLE #####"; Return
# content begins on the line after next

# define path to JSON file
$Json = '.\vm-test.json'

# define VMNetworkAdapter on defined switch with default VLAN ID and next MAC address on host
$AddVMNetworkAdapter = @{
	VMName             = 'testvm1'
	NetworkAdapterName = 'Private1'
	SwitchName         = 'ConvergedSwitch'
}

# define VMNetworkAdapter on defined switch with defined VLAN ID and next MAC address on host
$AddVMNetworkAdapter = @{
	VMName             = 'testvm1'
	NetworkAdapterName = 'Private1'
	SwitchName         = 'ConvergedSwitch'
	VlanId             = 10
}

# define VMNetworkAdapter with defined VLAN ID and defined MAC address
$AddVMNetworkAdapter = @{
	VMName             = 'testvm1'
	NetworkAdapterName = 'Private1'
	SwitchName         = 'ConvergedSwitch'
	VlanId             = 11
	MacAddress         = '0ABCDE123456'
}

# define VMNetworkAdapter with defined VLAN ID and MAC address constructed from prefix and defined IP address
$AddVMNetworkAdapter = @{
	VMName             = 'testvm1'
	NetworkAdapterName = 'Private1'
	SwitchName         = 'ConvergedSwitch'
	VlanId             = 10
	MacAddressPrefix   = '0ABC'
	IPAddress          = '192.168.10.252'
}

# define VMNetworkAdapter with defined VLAN ID and DHCP reservation with fixed MAC address
$AddVMNetworkAdapter = @{
	VMName             = 'testvm1'
	NetworkAdapterName = 'Private1'
	SwitchName         = 'ConvergedSwitch'
	VlanId             = 11
	MacAddress         = '0ABCDE123456'
	IPAddress          = '192.168.10.253'
	DhcpServer         = 'dhcp1'
	DhcpScope          = '192.168.10.0'
}

# define VMNetworkAdapter with defined VLAN ID and DHCP reservation with MAC address constructed from prefix and defined IP address
$AddVMNetworkAdapter = @{
	VMName             = 'testvm1'
	NetworkAdapterName = 'Private1'
	SwitchName         = 'ConvergedSwitch'
	VlanId             = 10
	MacAddressPrefix   = '0ABC'
	IPAddress          = '192.168.10.253'
	DhcpServer         = 'dhcp1'
	DhcpScope          = '192.168.10.0'
}

# add VMNetworkAdapter to JSON file
.\Write-VMFromJsonFile.ps1 -Json $Json -AddVMNetworkAdapter @AddVMNetworkAdapter
