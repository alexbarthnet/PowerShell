Write-Host 'This file contains example hashtables for splatting Write-VMFromJsonFile.ps1'
Get-Content -Path $PSCommandPath
Return

$Json = '..\..\..\Personal\HyperV\vm-test.json'

.\Write-VMFromJsonFile.ps1 -Json $Json -Clear


$WriteVMFromJsonFile_AddVMHardDiskDrive = @{
	AddVMHardDiskDrive = $true
	VMName             = 'testvm1'
	Path               = 'E:\Hyper-V\testvm1\testvm1-1.vhdx'
	SizeBytes          = 100GB
	ControllerLocation = 1
}

$WriteVMFromJsonFile_AddVMHardDiskDrive = @{
	AddVMHardDiskDrive = $true
	VMName             = 'testvm1'
	Path               = 'E:\Hyper-V\testvm1\testvm1-2.vhdx'
	SizeBytes          = 100GB
	ControllerNumber   = 2
	ControllerLocation = 2
}

$WriteVMFromJsonFile_AddVMHardDiskDrive = @{
	AddVMHardDiskDrive = $true
	VMName             = 'testvm1'
	Path               = 'E:\Hyper-V\testvm1\testvm1-3.vhdx'
	SizeBytes          = 100GB
	ControllerNumber   = 3
}

.\Write-VMFromJsonFile.ps1 -Json $Json @WriteVMFromJsonFile_AddVMHardDiskDrive

$WriteVMFromJsonFile_AddVMNetworkAdapter = @{
	AddVMNetworkAdapter = $true
	VMName              = 'testvm1'
	NetworkAdapterName  = 'Default1'
	SwitchName          = 'ConvergedSwitch'
}

$WriteVMFromJsonFile_AddVMNetworkAdapter = @{
	AddVMNetworkAdapter = $true
	VMName              = 'testvm1'
	NetworkAdapterName  = 'Private1'
	SwitchName          = 'ConvergedSwitch'
	VlanId              = 11
	MacAddress          = '0ABCDE123456'
}


$WriteVMFromJsonFile_AddVMNetworkAdapter = @{
	AddVMNetworkAdapter = $true
	VMName              = 'testvm1'
	NetworkAdapterName  = 'Private1'
	SwitchName          = 'ConvergedSwitch'
	VlanId              = 11
	MacAddressPrefix    = '0ABC'
	IPAddress           = '192.168.11.99'
	DhcpServer          = 'dc3'
	DhcpScope           = '192.168.11.0'
}

.\Write-VMFromJsonFile.ps1 -Json $Json @WriteVMFromJsonFile_AddVMNetworkAdapter

$WriteVMFromJsonFile_AddOSD = @{
	AddOSD           = $true
	VMName           = 'testvm1'
	DeploymentMethod = 'ISO'
	DeploymentPath   = 'F:\\storage\\images\\microsoft\\technet\\en-us_windows_server_2022_x64_dvd_620d7eac.iso'
}

$WriteVMFromJsonFile_AddOSD = @{
	AddOSD           = $true
	VMName           = 'testvm1'
	DeploymentMethod = 'WDS'
	DeploymentServer = 'wds1'
	DeploymentPath   = 'WdsClientUnattend\\Unattend-1-Prestaged-WindowsServer2022.xml'
}

$WriteVMFromJsonFile_AddOSD = @{
	AddOSD                = $true
	VMName                = 'testvm1'
	DeploymentMethod      = 'SCCM'
	DeploymentPath        = 'OU=Container2,OU=Container1,DC=example,DC=com'
	DeploymentServer      = 'sccm1'
	DeploymentDomain      = 'EXAMPLE'
	DeploymentCollection  = 'OSD Deploy - Server 2022'
	MaintenanceCollection = 'MW - Every Tuesday 2000-0000'
}

.\Write-VMFromJsonFile.ps1 -Json $Json @WriteVMFromJsonFile_AddOSD
