<#
.SYNOPSIS
Rebuilds one or more "VM template" virtual machines using a mounted ISO image then copies the VHD to a defined folder on each local cluster shared volume.

.DESCRIPTION
Rebuilds one or more "VM template" virtual machines using a mounted ISO image. The existing VHD of the VM is replaced with a new VHD then the VM boots and installs the OS from the mounted ISO image. The VHD is then copied to a defined folder on each local cluster shared volume

.PARAMETER VMName
The name(s) of the VM(s) that will be rebuilt.

.PARAMETER Caveat
String for the "Caveat" for running the script. The caveats allow the script to be run by Scheduled Tasks or similar automation on a set schedule but only rebuild the VM template when specific conditions are met. The follow caveats are supported:
- 'DayAfterPatchTuesday' - the script will not run if the previous day was not the second Tuesday of the month (aka Patch Tuesday)
- 'Wednesday' - the script will not run if the current day is not Wednesday

.PARAMETER SkipRebuild
Switch parameter to skip rebuilding the VMs. This allows the first VHD of each VM template to be copied to the cluster shared volumes without rebuilding the VM.

.PARAMETER SkipCopy
Switch parameter to skip copying the first VHD of each VM template to a defined folder on the available cluster shared volume.

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

The first VHD of the "VM template" virtual machine first VHD can be copied to each cluster shared volume available on the hypervisor.

The copy of the VHD is intended to be leveraged by VHD-based deployment of new VMs on the same cluster shared volume. This enables ReFS block cloning to minimize I/O and storage consumption when deploying new VMs.

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
	[Parameter(Position = 3, Mandatory = $false)]
	[switch]$SkipRebuild,
	[Parameter(Position = 3, Mandatory = $false)]
	[switch]$SkipCopy,
	[Parameter(Position = 4, Mandatory = $false)]
	[string]$RelativePath = '.images'
)

# set error preference
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

# if caveat defined...
if ($PSBoundParameters.ContainsKey('Caveat')) {
	switch ($Caveat) {
		'DayAfterPatchTuesday' {
			if ($Yesterday.DayOfWeek -ne 'Tuesday' -and $Yesterday.Day -notin 8..14) {
				Write-Warning -Message "the 'DayAfterPatchTuesday' caveat was provided and yesterday is not the second Tuesday of the month (aka Patch Tuesday)"
				return
			}
		}
		'Wednesday' {
			if ($Today.DayOfWeek -ne 'Wednesday') {
				Write-Warning -Message "the 'Wednesday' caveat was provided and today is not 'Wednesday' but '$($Today.DayOfWeek)'"
				return
			}
		}
	}
}

# if skip rebuild set to false or not requested...
if ($SkipRebuild -eq $false -or -not $SkipRebuild.IsPresent) {
	# loop through VM names - start rebuild
	:NextNameForRebuild foreach ($Name in $VMName) {
		# report state
		Write-Host "Rebuilding VM from ISO: '$Name'"

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
			continue NextNameForRebuild
		}

		# if no VMs found...
		if ($null -eq $VM) {
			Write-Warning -Message "could not locate VM by name: '$Name'"
			continue NextNameForRebuild
		}

		# if VM is not powered off...
		if ($VM.State -ne 'Off') {
			Write-Warning -Message "found VM in invalid state: '$($VM.State)'"
			continue NextNameForRebuild
		}

		# if VM is missing a DVD drive...
		if ($VM.DvdDrives.Count -eq 0) {
			Write-Warning -Message 'found VM without DVD drive'
			continue NextNameForRebuild
		}

		# if VM is missing a hard drive...
		if ($VM.HardDrives.Count -eq 0) {
			Write-Warning -Message 'found VM without hard drive'
			continue NextNameForRebuild
		}

		# retrieve first DVD drive
		$VMDvdDrive = $VM.DvdDrives | Sort-Object -Property 'ControllerNumber', 'ControllerLocation' | Select-Object -First 1

		# if first DVD drive does not have an ISO mounted...
		if ([System.String]::IsNullOrEmpty($VMDvdDrive.Path)) {
			Write-Warning -Message 'first DVD drive does not have an ISO mounted'
			continue NextNameForRebuild
		}

		# update VM firmware to boot to first DVD drive
		try {
			Set-VMFirmware -VM $VM -FirstBootDevice $VMDvdDrive
		}
		catch {
			Write-Warning -Message "could not set DVD drive as first boot device on VM: $($_.Exception.Message)"
			continue NextNameForRebuild
		}

		# retrieve first hard drive
		$Path = $VM.HardDrives | Sort-Object -Property 'ControllerNumber', 'ControllerLocation' | Select-Object -First 1 -ExpandProperty 'Path'

		# get VHD
		try {
			$VHD = Get-VHD -Path $Path
		}
		catch {
			Write-Warning -Message "could not retrieve VHD: $($_.Exception.Message)"
			continue NextNameForRebuild
		}

		# remove VHD
		try {
			Remove-Item -Path $Path -Force
		}
		catch {
			Write-Warning -Message "could not remove VHD: $($_.Exception.Message)"
			continue NextNameForRebuild
		}

		# create VHD
		try {
			$null = New-VHD -Path $Path -Size $VHD.Size
		}
		catch {
			Write-Warning -Message "could not create VHD: $($_.Exception.Message)"
			continue NextNameForRebuild
		}

		# retrieve ACL
		try {
			$Acl = Get-Acl -Path $Path
		}
		catch {
			Write-Warning -Message "could not retrieve ACL: $($_.Exception.Message)"
			continue NextNameForRebuild
		}

		# define VM prinicpal
		try {
			$Principal = [System.Security.Principal.NTAccount]::new("NT VIRTUAL MACHINE\$($VM.Id)")
		}
		catch {
			Write-Warning -Message "could not create principal: $($_.Exception.Message)"
			continue NextNameForRebuild
		}

		# create access rule
		try {
			$AccessRule = [System.Security.AccessControl.FileSystemAccessRule]::new($Principal, @('Read', 'Write', 'Synchronize'), 'None', 'None', 'Allow')
		}
		catch {
			Write-Warning -Message "could not create access rule: $($_.Exception.Message)"
			continue NextNameForRebuild
		}

		# add access rule to ACL
		try {
			$Acl.AddAccessRule($AccessRule)
		}
		catch {
			Write-Warning -Message "could not add access rule to ACL: $($_.Exception.Message)"
			continue NextNameForRebuild
		}

		# update ACL
		try {
			$Acl | Set-Acl -Path $Path
		}
		catch {
			Write-Warning -Message "could not save ACL: $($_.Exception.Message)"
			continue NextNameForRebuild
		}

		# start VM
		try {
			$VM | Start-VM
		}
		catch {
			Write-Warning -Message "could not start VM: $($_.Exception.Message)"
			continue NextNameForRebuild
		}
	}
}

# if skip copy set to false or not requested...
if ($SkipCopy -eq $false -or -not $SkipCopy.IsPresent ) {
	# define counter
	$Counter = 0

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

		# if VM is powered off...
		if ($VM.State -eq 'Off') {
			Write-Host "Found VM powered off: '$Name'"
			continue NextNameForWait
		}

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
	$CSVPaths = Get-CimInstance -ClassName Win32_Volume | Where-Object { $_.FileSystem.StartsWith('CSVFS') } | Sort-Object -Property Name | Select-Object -ExpandProperty Name

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
					$null = New-Item -Path $FolderPath -ItemType Directory -Force -ErrorAction 'Stop'
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
					Remove-Item -Path $Destination -Force
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
}
