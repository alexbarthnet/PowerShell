Write-Host "##### BEGIN EXAMPLE #####`n"; Get-Content -Path $PSCommandPath | Select-Object -Skip 3; Write-Host "`n##### END EXAMPLE #####"; Return
# content begins on the line after next

# define path to JSON file
$Json = '.\vm-test.json'

# define OS deployment via ISO
$AddOSD = @{
	VMName           = 'testvm1'
	DeploymentMethod = 'ISO'
	DeploymentPath   = 'F:\storage\images\microsoft\en-us_windows_server_2022_x64_dvd.iso'
}

# define OS deployment via WDS
$AddOSD = @{
	VMName           = 'testvm1'
	DeploymentMethod = 'WDS'
	DeploymentServer = 'wds1'
	DeploymentPath   = 'WdsClientUnattend\Unattend-1-Prestaged-WindowsServer2022.xml'
}

# define OS deployment via SCCM
$AddOSD = @{
	VMName                = 'testvm1'
	DeploymentMethod      = 'SCCM'
	DeploymentPath        = 'OU=Container2,OU=Container1,DC=example,DC=com'
	DeploymentServer      = 'sccm1'
	DeploymentDomain      = 'EXAMPLE'
	DeploymentCollection  = 'OSD Deploy - Server 2022'
	MaintenanceCollection = 'MW - Every Tuesday 2000-0000'
}

# add OS deployement to JSON file
.\Write-VMFromJsonFile.ps1 -Json $Json -AddOSD @AddOSD
