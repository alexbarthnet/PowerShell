Write-Host 'This file contains example hashtables for splatting Write-VMFromJsonFile.ps1'
Get-Content -Path $PSCommandPath | Select-Object -Skip 4
Return
# content below this line

# define path to JSON file

$Json = '.\vm-test.json'

.\Write-VMFromJsonFile.ps1 -Json $Json -Clear

# add VMHardDiskDrive to first available controller with first available LUN number

$AddVMHardDiskDrive = @{
	VMName    = 'testvm1'
	Path      = 'E:\Hyper-V\testvm1\testvm1-0.vhdx'
	SizeBytes = 100GB
}

# add VMHardDiskDrive to first available controller with specific LUN number

$AddVMHardDiskDrive = @{
	VMName             = 'testvm1'
	Path               = 'E:\Hyper-V\testvm1\testvm1-1.vhdx'
	SizeBytes          = 100GB
	ControllerLocation = 1
}

# add VMHardDiskDrive to specific controller with first available LUN number

$AddVMHardDiskDrive = @{
	VMName           = 'testvm1'
	Path             = 'E:\Hyper-V\testvm1\testvm1-2.vhdx'
	SizeBytes        = 100GB
	ControllerNumber = 2
}

# add VMHardDiskDrive to specific controller with specific LUN number

$AddVMHardDiskDrive = @{
	VMName             = 'testvm1'
	Path               = 'E:\Hyper-V\testvm1\testvm1-3.vhdx'
	SizeBytes          = 100GB
	ControllerNumber   = 3
	ControllerLocation = 3
}

.\Write-VMFromJsonFile.ps1 -Json $Json -AddVMHardDiskDrive @AddVMHardDiskDrive
