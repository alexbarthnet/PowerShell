Write-Host 'This file contains example hashtables for splatting Write-VMFromJsonFile.ps1'
Get-Content -Path $PSCommandPath
Return

$Json = '..\..\..\Personal\HyperV\vm-test.json'

.\Write-VMFromJsonFile.ps1 -Json $Json -Clear

# standalone

$WriteVMFromJsonFile_Add = @{
	Add                           = $true
	VMName                        = 'testvm0'
	Path                          = 'E:\Hyper-V'
	ComputerName                  = 'hv1'
	ProcessorCount                = 2
	MemoryStartupBytes            = 2GB
	MemoryMinimumBytes            = 1GB
	MemoryMaximumBytes            = 4GB
	DoNotCluster                  = $true
	EnableVMTPM                   = $true
	CreateDefaultVMHardDiskDrive  = $true
	CreateDefaultVMNetworkAdapter = $true
	PreserveVMParameters          = $true
	SwitchName                    = 'ConvergedSwitch'
	VlanId                        = 10
	MacAddressPrefix              = '0AAB'
	IPAddress                     = '192.168.10.250'
	DhcpServer                    = 'dhcp1'
	DhcpScope                     = '192.168.10.0'
}

.\Write-VMFromJsonFile.ps1 -Json $Json @WriteVMFromJsonFile_Add

# clustered

$WriteVMFromJsonFile_Add = @{
	Add                           = $true
	VMName                        = 'testvm1'
	Path                          = 'C:\ClusterStorage\Hyper-V-1'
	ComputerName                  = 'hv1'
	ProcessorCount                = 2
	MemoryStartupBytes            = 4GB
	MemoryMinimumBytes            = 1GB
	MemoryMaximumBytes            = 8GB
	ClusterPriority               = 2000
	EnableVMTPM                   = $true
	CreateDefaultVMHardDiskDrive  = $true
	CreateDefaultVMNetworkAdapter = $true
	PreserveVMParameters          = $true
	SwitchName                    = 'ConvergedSwitch'
	VlanId                        = 10
	MacAddressPrefix              = '0AAB'
	IPAddress                     = '192.168.10.251'
	DhcpServer                    = 'dhcp1'
	DhcpScope                     = '192.168.10.0'
}

.\Write-VMFromJsonFile.ps1 -Json $Json @WriteVMFromJsonFile_Add
