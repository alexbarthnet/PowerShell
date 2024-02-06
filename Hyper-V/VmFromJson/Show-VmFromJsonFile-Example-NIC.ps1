Write-Host 'This file contains example hashtables for splatting Write-VMFromJsonFile.ps1'
Get-Content -Path $PSCommandPath | Select-Object -Skip 4
Return
# content below this line

# define path to JSON file
$Json = '.\vm-test.json'

# add VMNetworkAdapter to defined switch with default VLAN ID and next MAC address on host
$AddVMNetworkAdapter = @{
	VMName             = 'testvm1'
	NetworkAdapterName = 'Private1'
	SwitchName         = 'ConvergedSwitch'
}

# add VMNetworkAdapter to defined switch with defined VLAN ID and next MAC address on host
$AddVMNetworkAdapter = @{
	VMName             = 'testvm1'
	NetworkAdapterName = 'Private1'
	SwitchName         = 'ConvergedSwitch'
	VlanId             = 10
}

# add VMNetworkAdapter with defined VLAN ID and defined MAC address
$AddVMNetworkAdapter = @{
	VMName             = 'testvm1'
	NetworkAdapterName = 'Private1'
	SwitchName         = 'ConvergedSwitch'
	VlanId             = 11
	MacAddress         = '0ABCDE123456'
}

# add VMNetworkAdapter with defined VLAN ID and MAC address constructed from prefix and defined IP address 
$AddVMNetworkAdapter = @{
	VMName             = 'testvm1'
	NetworkAdapterName = 'Private1'
	SwitchName         = 'ConvergedSwitch'
	VlanId             = 10
	MacAddressPrefix   = '0ABC'
	IPAddress          = '192.168.10.252'
}

# add VMNetworkAdapter with defined VLAN ID and DHCP reservation with fixed MAC address
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

# add VMNetworkAdapter with defined VLAN ID and DHCP reservation with MAC address constructed from prefix and defined IP address 
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

# call Write-VMFromJson.ps1 and add VMNetworkAdapter to VM
.\Write-VMFromJsonFile.ps1 -Json $Json -AddVMNetworkAdapter @AddVMNetworkAdapter
