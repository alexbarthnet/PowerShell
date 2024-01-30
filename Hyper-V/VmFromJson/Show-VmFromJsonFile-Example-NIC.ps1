Write-Host 'This file contains example hashtables for splatting Write-VMFromJsonFile.ps1'
Get-Content -Path $PSCommandPath
Return

$Json = '.\vm-test.json'

.\Write-VMFromJsonFile.ps1 -Json $Json -Clear

# add VMNetworkAdapter with next MAC address on host

$AddVMNetworkAdapter = @{
	VMName              = 'testvm1'
	NetworkAdapterName  = 'Private1'
	SwitchName          = 'ConvergedSwitch'
}

# add VMNetworkAdapter with fixed MAC address

$AddVMNetworkAdapter = @{
	VMName              = 'testvm1'
	NetworkAdapterName  = 'Private1'
	SwitchName          = 'ConvergedSwitch'
	VlanId              = 11
	MacAddress          = '0ABCDE123456'
}

# add VMNetworkAdapter with MAC address constructed from prefix and known IP address 

$AddVMNetworkAdapter = @{
	VMName              = 'testvm1'
	NetworkAdapterName  = 'Private1'
	SwitchName          = 'ConvergedSwitch'
	VlanId              = 10
	MacAddressPrefix    = '0ABC'
	IPAddress           = '192.168.10.252'
}

# add VMNetworkAdapter and DHCP reservation with fixed MAC address

$AddVMNetworkAdapter = @{
	VMName              = 'testvm1'
	NetworkAdapterName  = 'Private1'
	SwitchName          = 'ConvergedSwitch'
	VlanId              = 11
	MacAddress          = '0ABCDE123456'
	IPAddress           = '192.168.10.253'
	DhcpServer          = 'dhcp1'
	DhcpScope           = '192.168.10.0'
}

# add VMNetworkAdapter and DHCP reservation with MAC address constructed from prefix and known IP address 

$AddVMNetworkAdapter = @{
	VMName              = 'testvm1'
	NetworkAdapterName  = 'Private1'
	SwitchName          = 'ConvergedSwitch'
	VlanId              = 10
	MacAddressPrefix    = '0ABC'
	IPAddress           = '192.168.10.253'
	DhcpServer          = 'dhcp1'
	DhcpScope           = '192.168.10.0'
}

.\Write-VMFromJsonFile.ps1 -Json $Json -AddVMNetworkAdapter @AddVMNetworkAdapter
