Write-Host 'This file contains example hashtables for splatting Write-VMFromJsonFile.ps1'
Get-Content -Path $PSCommandPath
Return

$Json = '..\..\..\Personal\HyperV\vm-test.json'

.\Write-VMFromJsonFile.ps1 -Json $Json -Clear

# ISO

$WriteVMFromJsonFile_AddOSD = @{
	AddOSD           = $true
	VMName           = 'testvm1'
	DeploymentMethod = 'ISO'
	DeploymentPath   = 'F:\\storage\\images\\microsoft\\technet\\en-us_windows_server_2022_x64_dvd_620d7eac.iso'
}

# WDS

$WriteVMFromJsonFile_AddOSD = @{
	AddOSD           = $true
	VMName           = 'testvm1'
	DeploymentMethod = 'WDS'
	DeploymentServer = 'wds1'
	DeploymentPath   = 'WdsClientUnattend\\Unattend-1-Prestaged-WindowsServer2022.xml'
}

# SCCM

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
