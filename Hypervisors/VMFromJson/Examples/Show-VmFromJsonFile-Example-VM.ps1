Write-Host "##### BEGIN EXAMPLE #####`n"; Get-Content -Path $PSCommandPath | Select-Object -Skip 3; Write-Host "`n##### END EXAMPLE #####"; Return
# content begins on the line after next

# define path to JSON file
$Json = '.\vm-test.json'

# define stand-alone VM
$AddVM = @{
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
}

# define clustered VM
$AddVM = @{
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
}

# add VM to JSON file
.\Write-VMFromJsonFile.ps1 -Json $Json -Add @AddVM

# define default VMNetworkAdapter for VM
$AddDefaultVMNetworkAdapter = @{
	SwitchName       = 'ConvergedSwitch'
	VlanId           = 10
	MacAddressPrefix = '0ABC'
	IPAddress        = '192.168.10.251'
	DhcpScope        = '192.168.10.0'
	DhcpServer       = 'dhcp1'
}

# add VM with default VMNetworkAdapter to JSON file
.\Write-VMFromJsonFile.ps1 -Json $Json -Add @AddVM @AddDefaultVMNetworkAdapter
