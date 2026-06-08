#Requires -Modules "Hyper-V","FailoverClusters","Deduplication"

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'VM')]
param (
	# VM object(s)
	[Parameter(ParameterSetName = 'VM', ValueFromPipeline = $true)]
	[Microsoft.HyperV.PowerShell.VirtualMachine]$VM,
	# VM name(s)
	[Parameter(ParameterSetName = 'Name')]
	[string]$Name,
	# source cluster storage volume
	[Parameter(Mandatory = $true)]
	[string]$Path,
	# target cluster storage volume
	[Parameter(Mandatory = $true)]
	[string]$Destination,
	# regular expression to positively filter VM names, default includes VM names starting with any alphanumeric character
	[string]$Match = '^[0-9A-Za-z]',
	# regular expression to negatively filter VM names, default excludes VM names starting with 'sysprep'
	[string]$NotMatch = '^sysprep',
	# switch to skip VM name matching
	[switch]$SkipNameMatching,
	# switch to skip CSV storage check
	[switch]$SkipClusteredStorageCheck,
	# switch to skip deduplication check
	[switch]$SkipDeduplicationCheck,
	# switch to skip garbage collection job
	[switch]$SkipGarbageCollectionJob,
	# switch to skip volume space check
	[switch]$SkipVolumeSpaceCheck,
	# switch to force volume moves
	[switch]$ForceVolumeMove,
	# define shared parameters for dedup jobs
	[hashtable]$DedupJobParameters = @{
		Wait               = $true # start the job and wait for the job to finish
		Full               = $true # perform a full pass of the requested job type
		Preempt            = $true # stop any existing job for this job
		StopWhenSystemBusy = $false # do not pause for existing IO
		Cores              = 100 # use all required CPU resources
		Memory             = 100 # use all required RAM resources
		ErrorAction        = [System.Management.Automation.ActionPreference]::Stop
	}
)

begin {
	function Move-VMStorageToVolume {
		[CmdletBinding(SupportsShouldProcess)]
		param (
			[Parameter(Mandatory)]
			[Microsoft.HyperV.PowerShell.VirtualMachine]$VM,
			[Parameter(Mandatory)]
			[string]$SourceVolume,
			[Parameter(Mandatory)]
			[string]$TargetVolume
		)

		# retrieve VM name
		$VMName = '{0}{1}' -f $VM.Name, $script:Message

		# retrieve target volume item
		try {
			$TargetVolumeItem = Get-Item -Path $TargetVolume
		}
		catch {
			throw $_
		}

		# define target volume friendly name from base name
		$TargetVolumeFriendlyName = $TargetVolumeItem.BaseName

		# define sorted set for paths on source volume
		$PathsOnSourceVolume = [System.Collections.Generic.SortedSet[string]]::new()

		################
		# VM paths
		################

		# record original virtual machine path
		$OriginalVirtualMachinePath = $VM.Path

		# report state
		Write-Host "$VMName; VirtualMachinePath; retrieved source path: $OriginalVirtualMachinePath"

		# define virtual machine path on target volume
		$VirtualMachinePath = $OriginalVirtualMachinePath.Replace($SourceVolume, $TargetVolume)

		# if virtual machine path on target volume matches original virtual machine path...
		if ($VirtualMachinePath -eq $OriginalVirtualMachinePath) {
			# report state
			Write-Host "$VMName; VirtualMachinePath; already in target path: $VirtualMachinePath"
		}
		# if virtual machine path on target volume does not match original virtual machine path...
		else {
			# add original virtual machine path to sorted set
			$null = $PathsOnSourceVolume.Add($OriginalVirtualMachinePath)

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

		# snapshot file path

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
			# add original snapshot file path to sorted set
			$null = $PathsOnSourceVolume.Add($OriginalSnapshotFilePath)

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

		# smart paging file path

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
			# add original smart paging file path to sorted set
			$null = $PathsOnSourceVolume.Add($OriginalSmartPagingFilePath)

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
			# define VHD identity
			$VHDIdentity = '{0}:{1}:{2}' -f $VMHardDiskDrive.ControllerType.ToString().ToLower(), $VMHardDiskDrive.ControllerNumber, $VMHardDiskDrive.ControllerLocation

			# record original VHD file path
			$OriginalVhdFilePath = $VMHardDiskDrive.Path

			# report state
			Write-Host "$VMName; $VHDIdentity; retrieved source path: $OriginalVhdFilePath"

			# define VHD file path on target volume
			$DestinationFilePath = $VMHardDiskDrive.Path.Replace($SourceVolume, $TargetVolume)

			# if VHD destination file path on target volume matches VHD original file path...
			if ($DestinationFilePath -eq $OriginalVhdFilePath) {
				# report state
				Write-Host "$VMName; $VHDIdentity; already in target path: $DestinationFilePath"
			}
			# if VHD destination file path on target volume does not match VHD original file path...
			else {
				# if skip volume space check not present...
				if (!$SkipVolumeSpaceCheck.IsPresent) {
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

					# retrieve VHD item
					try {
						$VHD = Get-Item -Path $OriginalVhdFilePath -ErrorAction 'Stop'
					}
					catch {
						throw $_
					}

					# if parent directory of VHD not in sorted set...
					if (!$PathsOnSourceVolume.Contains($VHD.Directory.Parent.FullName)) {
						# add path of directory of VHD to sorted set
						$null = $PathsOnSourceVolume.Add($VHD.Directory.FullName)
					}

					# define projected percentage of volume remaining after move
					$VolumeSizeRemainingAfterMovePercentage = [System.Math]::Round(($Volume.SizeRemaining - $VHD.SizeBytes) / $Volume.Size * 100, 1)

					# if projected percentage of volume remaining after move is not more than 25%...
					if ($VolumeSizeRemainingAfterMovePercentage -le 25) {
						Write-Warning -Message "$VMName; $VHDIdentity; stopped VM migration: target volume would have $VolumeSizeRemainingAfterMovePercentage% remaining after move (must be more than 25%)"
						return
					}
				}

				# define hash table for VHD move
				$Vhds = @{
					SourceFilePath      = $OriginalVhdFilePath
					DestinationFilePath = $DestinationFilePath
				}

				# define should process elements
				$ShouldProcessCaption = "$VMName; $VHDIdentity; migrate to target path: $DestinationFilePath"
				$ShouldProcessWarning = "$ShouldProcessCaption?"
				$ShouldProcessVerbose = "$ShouldProcessCaption"

				# handle should process
				if ($PSCmdlet.ShouldProcess($ShouldProcessVerbose, $ShouldProcessWarning, $ShouldProcessCaption)) {
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

					# update VM storage moved boolean
					$script:VMStorageMoved = $true
				}

				# define should process elements
				$ShouldProcessCaption = "$VMName; $VHDIdentity; start deduplication job on target volume: $TargetVolume"
				$ShouldProcessWarning = "$ShouldProcessCaption?"
				$ShouldProcessVerbose = "$ShouldProcessCaption"

				# if target volume is dedup enabled...
				if ($IsTargetVolumeEnabledForDedup -and $PSCmdlet.ShouldProcess($ShouldProcessVerbose, $ShouldProcessWarning, $ShouldProcessCaption)) {
					# report state
					Write-Host "$VMName; $VHDIdentity; starting deduplication job on target volume: $TargetVolume"

					# define stopwatch
					$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

					# optimize target volume
					try {
						$null = Start-DedupJob -Volume $TargetVolume -Type Optimization @DedupJobParameters
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
		# remove paths
		################

		# loop through paths on source volume
		foreach ($PathOnSourceVolume in $PathsOnSourceVolume) {
			# test path on source volume
			$TestPathOnSourceVolume = Test-Path -Path $PathOnSourceVolume -PathType Container

			# if path on source volume was not found...
			if (!$TestPathOnSourceVolume) {
				# report state
				Write-Host "$VMName; path on source volume not found: $PathOnSourceVolume"
				return
			}

			# get files in path on source volume
			try {
				$Files = Get-ChildItem -Path $PathOnSourceVolume -File -Recurse -Force -ErrorAction 'Stop'
			}
			catch {
				throw $_
			}

			# get count of files
			$Count = $Files | Measure-Object | Select-Object -ExpandProperty Count

			# if files found...
			if ($Files) {
				Write-Warning -Message "skipped removing path on source volume; found $Count file(s) in path on source volume: $PathOnSourceVolume "
				return
			}
			# if files not found...
			else {
				# remove folder
				try {
					Remove-Item -Path $PathOnSourceVolume -Recurse -Confirm:$false -ErrorAction 'Stop'
				}
				catch {
					throw $_
				}

				# report state
				Write-Host "$VMName; removed path on source volume: $PathOnSourceVolume"
			}
		}
	}
}

process {
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

	# define VM storage moved boolean
	$VMStorageMoved = $false

	# if skip clustered storage check not requested...
	if (!$SkipClusteredStorageCheck.IsPresent) {
		# retrieve cluster shared volumes
		try {
			$ClusterSharedVolumes = Get-ClusterSharedVolume -ErrorAction 'Stop'
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

		# retrieve cluster shared volume for source volume
		try {
			$SourceClusterSharedVolume = $ClusterSharedVolumes | Where-Object { $_.SharedVolumeInfo.FriendlyVolumeName -eq $SourceVolume }
		}
		catch {
			throw $_
		}

		# if cluster shared volume
		if ($env:COMPUTERNAME -ne $SourceClusterSharedVolume.OwnerNode.NodeName) {
			# if force volume move present...
			if ($ForceVolumeMove) {
				# warn before move
				Write-Warning -Message "The '$SourceVolume' volume will be moved from the '$($SourceClusterSharedVolume.OwnerNode.Name)' node to the current cluster node" -WarningAction Inquire

				# move volume
				try {
					$null = Move-ClusterSharedVolume -Name $SourceClusterSharedVolume.Name -Node $env:COMPUTERNAME
				}
				catch {
					throw $_
				}
			}
			else {
				# warn and set boolean
				Write-Warning -Message "The '$SourceVolume' volume is owned by the '$($SourceClusterSharedVolume.OwnerNode.Name)' and must be moved the current cluster node"
				Write-Warning -Message "Run the following command to move the volume: Move-ClusterSharedVolume -Name '$($SourceClusterSharedVolume.Name)' -Node $env:COMPUTERNAME"
				$VolumeOnOtherNode = $true
			}
		}

		# retrieve cluster shared volume for target volume
		try {
			$TargetClusterSharedVolume = $ClusterSharedVolumes | Where-Object { $_.SharedVolumeInfo.FriendlyVolumeName -eq $TargetVolume }
		}
		catch {
			throw $_
		}

		# if cluster shared volume
		if ($env:COMPUTERNAME -ne $TargetClusterSharedVolume.OwnerNode.NodeName) {
			# if force volume move present...
			if ($ForceVolumeMove) {
				# warn before move
				Write-Warning -Message "The '$TargetVolume' volume will be moved from the '$($TargetClusterSharedVolume.OwnerNode.Name)' node to the current cluster node" -WarningAction Inquire

				# move volume
				try {
					$null = Move-ClusterSharedVolume -Name $TargetClusterSharedVolume.Name -Node $env:COMPUTERNAME
				}
				catch {
					throw $_
				}
			}
			else {
				# warn and set boolean
				Write-Warning -Message "The '$TargetVolume' volume is owned by the '$($TargetClusterSharedVolume.OwnerNode.Name)' and must be moved the current cluster node"
				Write-Warning -Message "Run the following command to move the volume: Move-ClusterSharedVolume -Name '$($TargetClusterSharedVolume.Name)' -Node $env:COMPUTERNAME"
				$VolumeOnOtherNode = $true
			}
		}

		# if volumes are not on the local node...
		if ($VolumeOnOtherNode) {
			return
		}
	}

	# if skip deduplication check not requested...
	if (!$SkipDeduplicationCheck.IsPresent) {
		# retrieve deduplication volumes
		try {
			$DedupVolumes = Get-DedupVolume -ErrorAction 'Stop'
		}
		catch {
			throw $_
		}

		# get deduplication state of source volume
		$IsSourceVolumeEnabledForDedup = $DedupVolumes.Volume.Contains($SourceVolume)

		# get deduplication state of target volume
		$IsTargetVolumeEnabledForDedup = $DedupVolumes.Volume.Contains($TargetVolume)
	}

	# define initial parameters
	$MoveVMStorageToVolume = @{
		SourceVolume = $SourceVolume
		TargetVolume = $TargetVolume
		ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
	}

	# define optional parameters
	if ($WhatIfPreference -eq 'Continue') {
		$MoveVMStorageToVolume['WhatIf'] = $true
	}

	# if VM object exists (VM would be retrieved from name parameter or directly provided with VM parameter)...
	if ($script:VM) {
		# migrate individual VM
		try {
			Move-VMStorageToVolume -VM $VM @MoveVMStorageToVolume
		}
		catch {
			throw $_
		}

		# return after moving single VM
		return
	}
	# if VM object does not exist...
	else {
		# define initial parameters for Get-VM
		$GetVM = @{
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# define optional parameters for Get-VM
		if ($PSBoundParameters.ContainsKey('Name')) {
			$GetVM['Name'] = $Name
		}

		# retrieve all VMs
		try {
			$VMs = Get-VM @GetVM
		}
		catch {
			throw $_
		}

		# if Name parameter not provided and skip name matching not present...
		if (!$PSBoundParameters.ContainsKey('Name') -and !$SkipNameMatching.IsPresent) {
			# filter VMs by name
			$VMs = $VMs | Where-Object { $_.Name -match $Match -and $_.Name -notmatch $NotMatch }
			# define message
			$MessageSuffixWhenNoVMsFound = ";use the '-SkipNameMatching' parameter to disable default Match and NotMatch parameter values"
		}

		# if VMs is null...
		if ($null -eq $VMs) {
			Write-Warning -Message "no VMs found$MessageSuffixWhenNoVMsFound"
			return
		}
		# if VMs is an array...
		elseif ($VMs -is [array]) {
			# retrieve count of VMs
			$VMCount = $VMs.Count
			# retrieve length of count of VMs as string
			$VMCountLength = $VMCount.ToString().Length
		}
		else {
			# define count of VMs
			$VMCount = 1
			# define length of count of VMs as string
			$VMCountLength = 1
		}

		# define VM counter
		$VMCounter = 0

		# loop through VMs
		foreach ($VM in $VMs) {
			# increment VM counter
			$VMCounter++

			# if multiple VMs...
			if ($VMCount -gt 1) {
				# define message
				$Message = '; VM {0} of {1}' -f $VMCounter.ToString().PadLeft($VMCountLength, '0'), $VMCount
			}

			# migrate individual VM
			try {
				Move-VMStorageToVolume -VM $VM @MoveVMStorageToVolume
			}
			catch {
				throw $_
			}
		}
	}
}

end {
	# if source volume is dedup enabled and moves happened and skip not present...
	if ($IsSourceVolumeEnabledForDedup -and $VMStorageMoved -and -not $SkipGarbageCollectionJob.IsPresent) {
		# report state
		Write-Host "starting garbage collection job on source volume: $SourceVolume"

		# define stopwatch
		$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

		# optimize target volume
		try {
			$null = Start-DedupJob -Volume $SourceVolume -Type GarbageCollection @DedupJobParameters
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