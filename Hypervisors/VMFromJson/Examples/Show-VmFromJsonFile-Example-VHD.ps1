Write-Host "##### BEGIN EXAMPLE #####`n"; Get-Content -Path $PSCommandPath | Select-Object -Skip 3; Write-Host "`n##### END EXAMPLE #####"; Return
# content begins on the line after next

# define path to JSON file
$Json = '.\vm-test.json'

# define VMHardDiskDrive on first available controller with first available LUN number
$AddVMHardDiskDrive = @{
	VMName    = 'testvm1'
	Path      = 'E:\Hyper-V\testvm1\testvm1-0.vhdx'
	SizeBytes = 100GB
}

# define VMHardDiskDrive on first available controller with specific LUN number
$AddVMHardDiskDrive = @{
	VMName             = 'testvm1'
	Path               = 'E:\Hyper-V\testvm1\testvm1-1.vhdx'
	SizeBytes          = 100GB
	ControllerLocation = 1
}

# define VMHardDiskDrive on specific controller with first available LUN number
$AddVMHardDiskDrive = @{
	VMName           = 'testvm1'
	Path             = 'E:\Hyper-V\testvm1\testvm1-2.vhdx'
	SizeBytes        = 100GB
	ControllerNumber = 2
}

# define VMHardDiskDrive on specific controller with specific LUN number
$AddVMHardDiskDrive = @{
	VMName             = 'testvm1'
	Path               = 'E:\Hyper-V\testvm1\testvm1-3.vhdx'
	SizeBytes          = 100GB
	ControllerNumber   = 3
	ControllerLocation = 3
}

# add VMHardDiskDrive to JSON
.\Write-VMFromJsonFile.ps1 -Json $Json -AddVMHardDiskDrive @AddVMHardDiskDrive
