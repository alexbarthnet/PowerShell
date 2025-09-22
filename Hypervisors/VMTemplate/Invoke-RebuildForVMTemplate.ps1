<#
.SYNOPSIS
Rebuilds one or more "VM template" virtual machines using a mounted ISO image.

.DESCRIPTION
Rebuilds one or more "VM template" virtual machines using a mounted ISO image. The existing VHD of the VM is replaced with a new VHD then the VM boots and installs the OS from the mounted ISO image.

.PARAMETER VMName
The name(s) of the VM(s) that will be rebuilt.

.PARAMETER Caveat
String for the "Caveat" for running the script. The caveats allow the script to be run by Scheduled Tasks or similar automation daily but only rebuild the VM template when specific conditions are met. The follow caveats are supported:
- 'DayAfterPatchTuesday' - the script will not run if the previous day was not the second Tuesday of the month (aka Patch Tuesday)
- 'Wednesday' - the script will not run if the current day is not Wednesday

.PARAMETER Copy
Switch parameter to copy the new VHD to a folder on each cluster shared volume. This allows new VMs to be created with a copy of VHD from the VM template and leveraging ReFS block cloning and deduplication to minimize storage consumption.

.PARAMETER RelativePath
String for the relative path of the directory on each cluster shared volume for the copy of the VHD. The default value is '.images'

.INPUTS
None.

.OUTPUTS
None. The function does not generate any actionable output.

.NOTES
The "VM template" virtual machine must adhere to the following requirements for this script to function as expected:
1. A bootable ISO image has been created which will install and update Windows on first boot
2. The VM has a DVD drive with the ISO image mounted
3. The VM has a hard disk drive defined

#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
	[Parameter(DontShow)]
	[datetime]$Today = [System.DateTime]::Today,
	[Parameter(DontShow)]
	[datetime]$Yesterday = [System.DateTime]::Today.AddDays(-1),
	[Parameter(Position = 0, Mandatory = $true)]
	[string[]]$VMName,
	[Parameter(Position = 1, Mandatory = $false)][ValidateSet('DayAfterPatchTuesday', 'Wednesday')]
	[string]$Caveat,
	[Parameter(Position = 2, Mandatory = $false)]
	[switch]$Copy,
	[Parameter(Position = 3, Mandatory = $false)]
	[string]$RelativePath = '.images'
)

# set error preference
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

# if caveat defined...
If ($PSBoundParameters.ContainsKey('Caveat')) {
	switch ($Caveat) {
		'DayAfterPatchTuesday' {
			If ($Yesterday.DayOfWeek -ne 'Tuesday' -and $Yesterday.Day -notin 8..14) {
				Write-Warning -Message "the 'DayAfterPatchTuesday' caveat was provided and yesterday is not the second Tuesday of the month (aka Patch Tuesday)"
				Return
			}
		}
		'Wednesday' {
			If ($Today.DayOfWeek -ne 'Wednesday') {
				Write-Warning -Message "the 'Wednesday' caveat was provided and today is not 'Wednesday' but '$($Today.DayOfWeek)'"
				Return
			}
		}
	}
}

:NextVM ForEach ($Name in $VMName) {
	# retrieve VMs on local system
	Try {
		$VM = Get-VM | Where-Object { $_.Name -eq $Name }
	}
	Catch {
		Write-Warning -Message "could not retrieve local VMs: $($_.Exception.Message)"
		Return $_
	}

	# if multiple VMs found...
	If ($VM.Count -gt 1) {
		Write-Warning -Message "multiple VMs found by name: '$Name'"
		Continue NextVM
	}

	# if no VMs found...
	If ($null -eq $VM) {
		Write-Warning -Message "could not locate VM by name: '$Name'"
		Continue NextVM
	}

	# if VM is not powered off...
	If ($VM.State -ne 'Off') {
		Write-Warning -Message "found VM in invalid state: '$($VM.State)'"
		Continue NextVM
	}

	# if VM is missing a DVD drive...
	If ($VM.DvdDrives.Count -eq 0) {
		Write-Warning -Message 'found VM without DVD drive'
		Continue NextVM
	}

	# if VM is missing a hard drive...
	If ($VM.HardDrives.Count -eq 0) {
		Write-Warning -Message 'found VM without hard drive'
		Continue NextVM
	}

	# retrieve first DVD drive
	$VMDvdDrive = $VM.DvdDrives | Sort-Object -Property 'ControllerNumber', 'ControllerLocation' | Select-Object -First 1

	# if first DVD drive does not have an ISO mounted...
	If ([System.String]::IsNullOrEmpty($VMDvdDrive.Path)) {
		Write-Warning -Message 'first DVD drive does not have an ISO mounted'
		Continue NextVM
	}

	# update VM firmware to boot to first DVD drive
	Try {
		Set-VMFirmware -VM $VM -FirstBootDevice $VMDvdDrive
	}
	Catch {
		Write-Warning -Message "could not set DVD drive as first boot device on VM: $($_.Exception.Message)"
		Continue NextVM
	}

	# retrieve first hard drive
	$Path = $VM.HardDrives | Sort-Object -Property 'ControllerNumber', 'ControllerLocation' | Select-Object -First 1 -ExpandProperty 'Path'

	# get VHD
	Try {
		$VHD = Get-VHD -Path $Path
	}
	Catch {
		Write-Warning -Message "could not retrieve VHD: $($_.Exception.Message)"
		Continue NextVM
	}

	# remove VHD
	Try {
		Remove-Item -Path $Path -Force
	}
	Catch {
		Write-Warning -Message "could not remove VHD: $($_.Exception.Message)"
		Continue NextVM
	}

	# create VHD
	Try {
		$null = New-VHD -Path $Path -Size $VHD.Size
	}
	Catch {
		Write-Warning -Message "could not create VHD: $($_.Exception.Message)"
		Continue NextVM
	}

	# retrieve ACL
	Try {
		$Acl = Get-Acl -Path $Path
	}
	Catch {
		Write-Warning -Message "could not retrieve ACL: $($_.Exception.Message)"
		Continue NextVM
	}

	# define VM prinicpal
	Try {
		$Principal = [System.Security.Principal.NTAccount]::new("NT VIRTUAL MACHINE\$($VM.Id)")
	}
	Catch {
		Write-Warning -Message "could not create principal: $($_.Exception.Message)"
		Continue NextVM
	}

	# create access rule
	Try {
		$AccessRule = [System.Security.AccessControl.FileSystemAccessRule]::new($Principal, @('Read', 'Write', 'Synchronize'), 'None', 'None', 'Allow')
	}
	Catch {
		Write-Warning -Message "could not create access rule: $($_.Exception.Message)"
		Continue NextVM
	}

	# add access rule to ACL
	Try {
		$Acl.AddAccessRule($AccessRule)
	}
	Catch {
		Write-Warning -Message "could not add access rule to ACL: $($_.Exception.Message)"
		Continue NextVM
	}

	# update ACL
	Try {
		$Acl | Set-Acl -Path $Path
	}
	Catch {
		Write-Warning -Message "could not save ACL: $($_.Exception.Message)"
		Continue NextVM
	}

	# start VM
	Try {
		$VM | Start-VM
	}
	Catch {
		Write-Warning -Message "could not start VM: $($_.Exception.Message)"
	}
}

# if copy set to false or not requested...
if ($Copy -eq $false -or -not $Copy.IsPresent ) {
	return
}

# report state
Write-Host "Waiting for VM(s) to rebuild before copy"

# loop through VM names - wait for rebuild to complete
:NextNameForWait foreach ($Name in $VMName) { 
	# retrieve VMs on local system
	try {
		$VM = Get-VM | Where-Object { $_.Name -eq $Name }
	}
	catch {
		Write-Warning -Message "could not retrieve local VMs: $($_.Exception.Message)"
		return $_
	}

	# if multiple VMs found...
	if ($VM.Count -gt 1) {
		Write-Warning -Message "multiple VMs found by name: '$Name'"
		continue NextNameForWait
	}

	# if no VMs found...
	if ($null -eq $VM) {
		Write-Warning -Message "could not locate VM by name: '$Name'"
		continue NextNameForWait
	}

	# define counter
	$Counter = 0

	# if VM is not powered off...
	while ($VM.State -ne 'Off') {
		# wait 1 minute
		Start-Sleep -Seconds 60

		# increment counter
		$Counter++

		#report state
		Write-Host "Waited $Counter minute(s) for VM to rebuild: '$Name'"
	}
}

# report state
Write-Host "Copying VHD(s) to '$RelativePath' folder in each CSV"

# retrieve CSVs
$CSVPaths = Get-CimInstance -ClassName Win32_Volume | Where-Object { $_.FileSystem.StartsWith('CSVFS') } | Select-Object -ExpandProperty Name

# loop through VM names - copy VHDs
:NextNameForCopy foreach ($Name in $VMName) {
	# report state
	Write-Host "Copying VHD from VM: '$Name'"

	# retrieve VMs on local system
	try {
		$VM = Get-VM | Where-Object { $_.Name -eq $Name }
	}
	catch {
		Write-Warning -Message "could not retrieve local VMs: $($_.Exception.Message)"
		return $_
	}

	# if multiple VMs found...
	if ($VM.Count -gt 1) {
		Write-Warning -Message "multiple VMs found by name: '$Name'"
		continue NextNameForCopy
	}

	# if no VMs found...
	if ($null -eq $VM) {
		Write-Warning -Message "could not locate VM by name: '$Name'"
		continue NextNameForCopy
	}

	# if VM is not powered off...
	if ($VM.State -ne 'Off') {
		Write-Warning -Message "found VM in invalid state: '$($VM.State)'"
		continue NextNameForCopy
	}

	# if VM is missing a hard drive...
	if ($VM.HardDrives.Count -eq 0) {
		Write-Warning -Message 'found VM without hard drive'
		continue NextNameForCopy
	}

	# retrieve first hard drive
	$Path = $VM.HardDrives | Sort-Object -Property 'ControllerNumber', 'ControllerLocation' | Select-Object -First 1 -ExpandProperty 'Path'

	# get VHD
	try {
		$VHD = Get-VHD -Path $Path
	}
	catch {
		Write-Warning -Message "could not retrieve VHD: $($_.Exception.Message)"
		continue NextNameForCopy
	}

	# get VHD as item
	try {
		$Item = Get-Item -Path $Path
	}
	catch {
		Write-Warning -Message "could not retrieve VHD: $($_.Exception.Message)"
		continue NextNameForCopy
	}

	# loop through CSV paths
	:NextCSVPath foreach ($CSVPath in $CSVPaths) { 
		# report state
		Write-Host "Copying '$Path' VHD to '$RelativePath' folder on CSV: '$CSVPath'"

		# build path to images folder
		$FolderPath = Join-Path -Path $CSVPath -ChildPath $RelativePath

		# if images folder not found...
		if (!(Test-Path -Path $FolderPath -PathType Container)) {
			# get images path
			try {
				New-Item -Path $FolderPath -ItemType Directory -Force -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message "could not create '$FolderPath' directory: $($_.Exception.Message)"
				continue NextCSVPath
			}
		}

		# define path to VHD in images folder
		$Destination = Join-Path -Path $FolderPath -ChildPath $Item.Name

		# if VHD in images folder found...
		if ((Test-Path -Path $Destination -PathType Leaf)) {
			# remove VHD from images folder
			try {
				Remove-Item -Destination $Destination -Force
			}
			catch {
				Write-Warning -Message "could not remove existing '$Destination' VHD: $($_.Exception.Message)"
				continue NextCSVPath
			}
		}
	
		# copy VHD to images folder
		try {
			Copy-Item -Path $Path -Destination $Destination -Force
		}
		catch {
			Write-Warning -Message "could not copy '$Path' source VHD to '$Destination' destination VHD: $($_.Exception.Message)"
			continue NextCSVPath
		}
	}
}