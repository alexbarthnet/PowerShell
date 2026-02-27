#Requires -Modules "Hyper-V","FailoverClusters","Deduplication"

[CmdletBinding(DefaultParameterSetName = 'All')]
param (
	# hostname of local computer
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant(),
	# VM object(s)
	[Parameter(Mandatory = $true, ParameterSetName = 'VM', ValueFromPipeline = $true)]
	[Microsoft.HyperV.PowerShell.VirtualMachine]$VM,
	# VM name(s)
	[Parameter(Mandatory = $true, ParameterSetName = 'Name')]
	[string]$Name,
	# source cluster storage volume
	[Parameter(Mandatory = $true)]
	[string]$Path,
	# target cluster storage volume
	[Parameter(Mandatory = $true)]
	[string]$Destination,
	# switch to skip CSV storage check
	[switch]$SkipClusteredStorageCheck,
	# switch to skip deduplication check
	[switch]$SkipDeduplicationCheck
	
)

begin {
	function Move-VMStorageToVolume {
		[CmdletBinding()]
		param (
			[Parameter(Mandatory)]
			[Microsoft.HyperV.PowerShell.VirtualMachine]$VM,
			[Parameter(Mandatory)]
			[string]$SourceVolume,
			[Parameter(Mandatory)]
			[string]$TargetVolume
		)

		# retrieve VM name
		$VMName = $VM.Name

		# retrieve target volume item
		try {
			$TargetVolumeItem = Get-Item -Path $TargetVolume
		}
		catch {
			throw $_
		}

		# define target volume friendly name from base name
		$TargetVolumeFriendlyName = $TargetVolumeItem.BaseName

		################
		# VM paths
		################

		# record original virtual machine path
		$OriginalVirtualMachinePath = $VM.Path

		# report state
		Write-Host "$VMName; VirtualMachinePath; retrieved source path: $OriginalVirtualMachinePath"

		# define virtual machine path on target volume
		$VirtualMachinePath = $OriginalVirtualMachinePath.Replace($SourceVolume, $TargetVolume)

		# ifvirtual machine path on target volume matches original virtual machine path...
		if ($VirtualMachinePath -eq $OriginalVirtualMachinePath) {
			# report state
			Write-Host "$VMName; VirtualMachinePath; already in target path: $VirtualMachinePath"
		}
		# if virtual machine path on target volume does not match original virtual machine path...
		else {
			# move virtual machine path to target volume
			try {
				Move-VMStorage -VM $VM -VirtualMachinePath $VirtualMachinePath -ErrorAction 'Stop'
			}
			catch {
				throw $_
			}

			# report state
			Write-Host "$VMName; VirtualMachinePath; migrated to target path: $VirtualMachinePath"
		}

		# record original snapshot file path
		$OriginalSnapshotFilePath = $VM.SnapshotFileLocation

		# report state
		Write-Host "$VMName; SnapshotFilePath; retrieved source path: $OriginalSnapshotFilePath"

		# define snapshot file path on target volume
		$SnapshotFilePath = $OriginalSnapshotFilePath.Replace($SourceVolume, $TargetVolume)

		# if snapshot file path on target volume matches original snapshot file path...
		if ($SnapshotFilePath -eq $OriginalSnapshotFilePath) {
			# report state
			Write-Host "$VMName; SnapshotFilePath; already in target path: $SnapshotFilePath"
		}
		# if snapshot file path on target volume does not match original snapshot file path...
		else {
			# move snapshot file path to target volume
			try {
				Move-VMStorage -VM $VM -SnapshotFilePath $SnapshotFilePath -ErrorAction 'Stop'
			}
			catch {
				throw $_
			}

			# report state
			Write-Host "$VMName; SnapshotFilePath; migrated to target path: $SnapshotFilePath"
		}

		# record original smart paging file path
		$OriginalSmartPagingFilePath = $VM.SmartPagingFilePath

		# report state
		Write-Host "$VMName; SmartPagingFilePath; retrieved source path: $OriginalSmartPagingFilePath"

		# define smart paging file path on target volume
		$SmartPagingFilePath = $OriginalSmartPagingFilePath.Replace($SourceVolume, $TargetVolume)

		# if smart paging file path on target volume matches original smart paging file path...
		if ($SmartPagingFilePath -eq $OriginalSmartPagingFilePath) {
			# report state
			Write-Host "$VMName; SmartPagingFilePath; already in target path: $SmartPagingFilePath"
		}
		# if smart paging file path on target volume does not match original smart paging file path...
		else {
			# move smart paging file path to target volume
			try {
				Move-VMStorage -VM $VM -SmartPagingFilePath $SmartPagingFilePath -ErrorAction 'Stop'
			}
			catch {
				throw $_
			}

			# report state
			Write-Host "$VMName; SmartPagingFilePath; migrated to target path: $SmartPagingFilePath"
		}

		################
		# VHD paths
		################

		# retrieve VM hard disk drives
		try {
			$VMHardDiskDrives = Get-VMHardDiskDrive -VM $VM -ErrorAction 'Stop'
		}
		catch {
			throw $_
		}

		# loop through VM hard disk drives
		:NextVMHardDiskDrive foreach ($VMHardDiskDrive in $VMHardDiskDrives) {
			# retrieve volume
			try {
				$Volume = Get-Volume -FriendlyName $TargetVolumeFriendlyName -ErrorAction 'Stop'
			}
			catch {
				throw $_
			}

			# define percentage of volume remaining
			$VolumeSizeRemainingBeforeMovePercentage = [System.Math]::Round($Volume.SizeRemaining / $Volume.Size * 100, 1)

			# if volume remaining percentage is not more than 25%...
			if ($VolumeSizeRemainingBeforeMovePercentage -le 25) {
				Write-Warning -Message "$VMName; $VHDIdentity; stopped VM migration: target volume has $VolumeSizeRemainingBeforeMovePercentage% remaining before move (must be more than 25%)"
				return
			}

			# define VHD identity
			$VHDIdentity = '{0}:{1}:{2}' -f $VMHardDiskDrive.ControllerType.ToString().ToLower(), $VMHardDiskDrive.ControllerNumber, $VMHardDiskDrive.ControllerLocation

			# retrieve VHD item
			try {
				$VHD = Get-Item -Path $VMHardDiskDrive.Path -ErrorAction 'Stop'
			}
			catch {
				throw $_
			}

			# define projected percentage of volume remaining after move
			$VolumeSizeRemainingAfterMovePercentage = [System.Math]::Round(($Volume.SizeRemaining - $VHD.SizeBytes) / $Volume.Size * 100, 1)

			# if projected percentage of volume remaining after move is not more than 25%...
			if ($VolumeSizeRemainingAfterMovePercentage -le 25) {
				Write-Warning -Message "$VMName; $VHDIdentity; stopped VM migration: target volume would have $VolumeSizeRemainingAfterMovePercentage% remaining after move (must be more than 25%)"
				return
			}

			# record original VHD file path
			$OriginalVhdFilePath = $VMHardDiskDrive.Path

			# report state
			Write-Host "$VMName; $VHDIdentity; retrieved source path: $OriginalVhdFilePath"

			# define VHD file path on target volume
			$DestinationFilePath = $VMHardDiskDrive.Path.Replace($SourceVolume, $TargetVolume)

			# if VHD destination file path on target volume matches VHD original file path...
			if ($DestinationFilePath -eq $VMHardDiskDrive.Path) {
				# report state
				Write-Host "$VMName; $VHDIdentity; already in target path: $DestinationFilePath"
			}
			# if VHD destination file path on target volume does not match VHD original file path...
			else {
				# define hash table for VHD move
				$Vhds = @{
					SourceFilePath      = $OriginalVhdFilePath
					DestinationFilePath = $DestinationFilePath
				}

				# report state
				Write-Host "$VMName; $VHDIdentity; migrating to target path: $DestinationFilePath"

				# define stopwatch
				$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

				# move VHD to target volume
				try {
					Move-VMStorage -VM $VM -Vhds $Vhds -ErrorAction 'Stop'
				}
				catch {
					Write-Warning -Message "$VMName; $VHDIdentity; could not move '$OriginalVhdFilePath' to target volume: $($_.Exception.Message)"
					continue NextVMHardDiskDrive
				}

				# stop stopwatch
				$Stopwatch.Stop()

				# define pretty timespan
				$TimespanString = [timespan]::FromTicks($Stopwatch.ElapsedTicks).ToString('hh\:mm\:ss')

				# report state
				Write-Host "$VMName; $VHDIdentity; migration complete; time taken: $TimespanString"

				# if target volume is dedup enabled...
				if ($IsTargetVolumeEnabledForDedup) {
					# report state
					Write-Host "$VMName; $VHDIdentity; starting deduplication job on target volume: $TargetVolume"

					# define stopwatch
					$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

					# optimize target volume
					try {
						$null = Start-DedupJob -Volume $TargetVolume -Type Optimization -Wait -Full -Preempt -StopWhenSystemBusy:$false -Cores 50 -Memory 50
					}
					catch {
						throw $_
					}

					# stop stopwatch
					$Stopwatch.Stop()

					# define pretty timespan
					$TimespanString = [timespan]::FromTicks($Stopwatch.ElapsedTicks).ToString('hh\:mm\:ss')

					# report state
					Write-Host "$VMName; $VHDIdentity; completed deduplication job; time taken: $TimespanString"
				}
			}
		}

		################
		# VM folder
		################

		# if original virtual machine path was not on source volume...
		if (!$OriginalVirtualMachinePath.Contains($SourceVolume)) {
			# report state
			Write-Host "$VMName; source volume ($SourceVolume) did not include original VM path: $OriginalVirtualMachinePath"
			return
		}

		# test path original virtual machine path
		$TestOriginalVirtualMachinePath = Test-Path -Path $OriginalVirtualMachinePath -PathType Container

		# if original virtual machine path was not found...
		if (!$TestOriginalVirtualMachinePath) {
			# report state
			Write-Host "$VMName; VM path not found on source volume: $OriginalVirtualMachinePath"
			return
		}

		# get files in VM folder
		try {
			$Files = Get-ChildItem -Path $OriginalVirtualMachinePath -File -Recurse -Force -ErrorAction 'Stop'
		}
		catch {
			throw $_
		}

		# get count of files
		$Count = $Files | Measure-Object | Select-Object -ExpandProperty Count

		# if files found...
		if ($Files) {
			Write-Warning -Message "skipped removing VM path; found $Count file(s) in VM path on source volume: $OriginalVirtualMachinePath "
			return
		}
		# if files not found...
		else {
			# remove folder
			try {
				Remove-Item -Path $OriginalVirtualMachinePath -Recurse -Confirm:$false -ErrorAction 'Stop'
			}
			catch {
				throw $_
			}

			# report state
			Write-Host "$VMName; removed VM path on source volume: $OriginalVirtualMachinePath"
		}
	}
}

process {
	# if skip clustered storage check not requested...
	if (!$SkipClusteredStorageCheck.IsPresent) {
		# retrieve cluster shared volumes
		try {
			$ClusterSharedVolumes = Get-ClusterSharedVolume -ErrorAction 'Stop'
		}
		catch {
			throw $_
		}

		# retrieve destination item
		try {
			$PathItem = Get-Item -Path $Path -ErrorAction 'Stop'
		}
		catch {
			throw $_
		}

		# retrieve destination item
		try {
			$DestinationItem = Get-Item -Path $Destination -ErrorAction 'Stop'
		}
		catch {
			throw $_
		}

		# define source volume from destination value
		try {
			$SourceVolume = $PathItem.FullName.TrimEnd('\')
		}
		catch {
			throw $_
		}

		# define target volume from destination value
		try {
			$TargetVolume = $DestinationItem.FullName.TrimEnd('\')
		}
		catch {
			throw $_
		}

		# if source volume is not in cluster shared volumes...
		if ($SourceVolume -notin $ClusterSharedVolumes.SharedVolumeInfo.FriendlyVolumeName) {
			Write-Warning "provided '$Path' path parameter does not appear to be a cluster shared volume (value not found in Get-ClusterSharedVolume output)"
			return
		}

		# if target volume is not in cluster shared volumes...
		if ($TargetVolume -notin $ClusterSharedVolumes.SharedVolumeInfo.FriendlyVolumeName) {
			Write-Warning "provided '$Destination' destination parameter does not appear to be a cluster shared volume (value not found in Get-ClusterSharedVolume output)"
			return
		}

		# retrieve cluster shared volume for targetvolume
		try {
			$ClusterSharedVolume = $ClusterSharedVolumes | Where-Object { $_.SharedVolumeInfo.FriendlyVolumeName -eq $TargetVolume }
		}
		catch {
			throw $_
		}

		# if cluster shared volume 
		if ($env:COMPUTERNAME -ne $ClusterSharedVolume.OwnerNode.NodeName) {
			Write-Warning -Message "The '$TargetVolume' volume is owned by the '$($ClusterSharedVolume.OwnerNode.Name)' and must be moved the current cluster node."
			Write-Warning -Message "Run the following command to move the cluster shared volume to the current cluster node:"
			Write-Host "Move-ClusterSharedVolume -Name '$($ClusterSharedVolume.Name)' -Node $env:COMPUTERNAME"
			return
		}
	}

	# if skip deduplication check not requested...
	if (!$SkipDeduplicationCheck.IsPresent) {
		# get deduplication state of source volume
		try {
			$IsSourceVolumeEnabledForDedup = Get-DedupVolume -Volume $SourceVolume | Select-Object -ExpandProperty Enabled
		}
		catch {
			throw $_
		}

		# get deduplication state of target volume
		try {
			$IsTargetVolumeEnabledForDedup = Get-DedupVolume -Volume $TargetVolume | Select-Object -ExpandProperty Enabled
		}
		catch {
			throw $_
		}
	}

	# switch on parameter set name
	switch ($PSCmdlet.ParameterSetName) {
		'All' {
			# retrieve all VMs
			try {
				$VMs = Get-VM -ErrorAction 'Stop'
			}
			catch {
				throw $_
			}

			# loop through VMs
			foreach ($VM in $VMs) {
				# migrate individual VM
				try {
					Move-VMStorageToVolume -VM $VM -SourceVolume $SourceVolume -TargetVolume $TargetVolume -ErrorAction 'Stop'
				}
				catch {
					throw $_
				}
			}
		}
		'Name' {
			# retrieve VM by name
			try {
				$VM = Get-VM -Name $Name -ErrorAction 'Stop'
			}
			catch {
				throw $_
			}

			# migrate individual VM
			try {
				Move-VMStorageToVolume -VM $VM -SourceVolume $SourceVolume -TargetVolume $TargetVolume -ErrorAction 'Stop'
			}
			catch {
				throw $_
			}
		}
		default {
			# migrate individual VM
			try {
				Move-VMStorageToVolume -VM $VM -SourceVolume $SourceVolume -TargetVolume $TargetVolume -ErrorAction 'Stop'
			}
			catch {
				throw $_
			}
		}
	}
}

end {
	# if source volume is dedup enabled...
	if ($IsSourceVolumeEnabledForDedup) {
		# report state
		Write-Host "starting garbage collection job on source volume: $SourceVolume"

		# define stopwatch
		$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

		# optimize target volume
		try {
			$null = Start-DedupJob -Volume $SourceVolume -Type GarbageCollection -Wait -Full -Preempt -StopWhenSystemBusy:$false -Cores 50 -Memory 50
		}
		catch {
			throw $_
		}

		# stop stopwatch
		$Stopwatch.Stop()

		# define pretty timespan
		$TimespanString = [timespan]::FromTicks($Stopwatch.ElapsedTicks).ToString('hh\:mm\:ss')

		# report state
		Write-Host "completed garbage collection job; time taken: $TimespanString"
	}
}