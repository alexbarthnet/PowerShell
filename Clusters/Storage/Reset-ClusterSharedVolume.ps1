[CmdletBinding(DefaultParameterSetName = 'Default')]
param(
	[Parameter(Mandatory, ParameterSetName = 'Default')]
	[string]$Path,
	[Parameter(Mandatory, ParameterSetName = 'FriendlyName')]
	[string]$FriendlyName,
	[ValidateSet('Off', 'ReFS', 'Windows')]
	[string]$DeduplicationMode = 'Off',
	[uint64]$StoragePoolIndex = 0,
	[switch]$WhatIf,
	[switch]$Force
)

function Format-Bytes {
	param (
		[Parameter(Position = 0, Mandatory = $true)]
		[uint64]$Size,
		[Parameter(Position = 1)]
		[int32]$RoundTo = 2
	)
	switch ($Size) {
		{ $_ -ge 1PB } { "$([math]::Round($Size / 1PB,$RoundTo)) PB"; break }
		{ $_ -ge 1TB } { "$([math]::Round($Size / 1TB,$RoundTo)) TB"; break }
		{ $_ -ge 1GB } { "$([math]::Round($Size / 1GB,$RoundTo)) GB"; break }
		{ $_ -ge 1MB } { "$([math]::Round($Size / 1MB,$RoundTo)) MB"; break }
		{ $_ -ge 1KB } { "$([math]::Round($Size / 1KB,$RoundTo)) KB"; break }
		default { "$([math]::Round($Size,$RoundTo)) B" }
	}
}

function Get-ClusterSharedVolumeSize {
	param(
		[switch]$GetReserve
	)

	# retrieve clustered storage pools
	$StoragePool = Get-StoragePool -ErrorAction 'Stop' | Where-Object { $_.IsClustered -and -not $_.IsPrimordial } | Select-Object -First 1

	# retrieve node count
	$NodeCount = Get-ClusterNode -ErrorAction 'Stop' | Measure-Object | Select-Object -ExpandProperty Count

	# get data copies for mirror resiliency setting
	$DataCopies = $StoragePool | Get-ResiliencySetting -Name 'Mirror' -ErrorAction 'Stop' | Select-Object -ExpandProperty 'NumberOfDataCopiesDefault'

	# get physical disks in storage pool
	$PhysicalDisks = $StoragePool | Get-PhysicalDisk -ErrorAction 'Stop' | Where-Object { $_.Usage -notin 'Journal', 'HotSpare' }

	# get count of physical disk per node
	$PhysicalDiskPerNode = $PhysicalDisks.Count / $NodeCount

	# get size of largest physical disk in the cluster
	$PhysicalDiskSizeMax = $PhysicalDisks | Measure-Object -Property Size -Maximum | Select-Object -ExpandProperty Maximum

	# if get reserve...
	if ($GetReserve.IsPresent) {
		# define volume count to be 1
		$VolumeCount = 1

		# get all virtual disks in storage pool
		$VirtualDisks = $StoragePool | Get-VirtualDisk -ErrorAction 'Stop'

		# do not reserve space when retrieving reserve
		$ReservedSpace = 0
	}
	else {
		# define volume count to be 3 or node count, whichever is larger
		$VolumeCount = if ($NodeCount -lt 3) { 3 } else { $NodeCount }

		# get infrastructure virtual disks in storage pool
		$VirtualDisks = $StoragePool | Get-VirtualDisk -ErrorAction 'Stop' | Where-Object { $_.FriendlyName -eq 'ClusterPerformanceHistory' -or $_.FriendlyName -like 'Infrastructure_*' }

		# reserve one disk per node when node count meets or exceeds number of data copies and each node has more disks than number of data copies
		$ReservedSpace = if ($NodeCount -ge $DataCopies -and $PhysicalDiskPerNode -gt $DataCopies) { $PhysicalDiskSizeMax * $NodeCount } else { 0 }
	}

	# define initial allocated space
	$AllocatedSpace = 0

	# loop through virtual disks and add size of each copy of virtual disk storage and metadata to allocated space
	foreach ($VirtualDisk in $VirtualDisks) { 
		# virtual disk size per copy is virtual disk size plus size of metadata required by storage pool
		$VirtualDiskSizePerCopy = $VirtualDisk.Size + $StoragePool.MetadataLength

		# virtual disk footprint is virtual disk size per copy multiplied by count of virtual disk copies
		$VirtuaDiskFootprint = $VirtualDiskSizePerCopy * $VirtualDisk.NumberOfDataCopies
	
		# update allocated space with virtual disk footprint
		$AllocatedSpace += $VirtuaDiskFootprint
	}

	# available space for volumes is storage pool size less total allocated space
	$AvailableSpace = $StoragePool.Size - $AllocatedSpace

	# assignable space is available space less reserved space
	$AssignableSpace = $AvailableSpace - $ReservedSpace

	# virtual disk size is assignable space divided by volume count divided by count of data copies
	$VirtualDiskSize = [System.Math]::Floor($AssignableSpace / $VolumeCount / $DataCopies)

	# metadata reserve is size of metadata reserved for each copy of a volume multiplied by count of data copies
	$MetadataReserve = $StoragePool.MetadataLength * $DataCopies

	# unbound volume size is virtual disk size less metadata reserve
	$UnboundVolumeSize = $VirtualDiskSize - $MetadataReserve

	# volume size is unbound volume size less modulo of unbound volume size and 2GB (source: testing, documentation missing)
	$VolumeSize = $UnboundVolumeSize - $UnboundVolumeSize % 2GB

	# return volume size
	return $VolumeSize
}

# define Azure Local boolean
$IsAzureLocal = (Get-CimInstance -ClassName 'Win32_OperatingSystem').OperatingSystemSKU -eq 406

# define Windows Dedupe boolean
$IsWindowsDedupeInstalled = (Get-WindowsFeature -Name 'FS-Data-Deduplication').Installed

# if Windows dedupe requested but not present...
if ($DeduplicationMode -eq 'Windows' -and -not $IsWindowsDedupeInstalled) {
	Write-Warning -Message "found Windows Deduplication requested but the required feature is not installed; please run 'Install-WindowsFeature -Name FS-Data-Deduplication' to install the required feature"
	return
}

# retrieve cluster
try {
	$Cluster = Get-Cluster -ErrorAction 'Stop'
}
catch {
	Write-Warning -Message "could not retrieve cluster object: $($_.Exception.Message)"
	return
}

# retrieve cluster shared volumes
try {
	$ClusterSharedVolumes = Get-ClusterSharedVolume -Cluster $Cluster
}
catch {
	Write-Warning -Message "could not retrieve cluster shared volumes: $($_.Exception.Message)"
	return
}

# switch on parameter set
switch ($PSCmdlet.ParameterSetName) {
	'Path' {
		# if path not in CSV root...
		if (!$Path.StartsWith($Cluster.SharedVolumesRoot, [System.StringComparison]::InvariantCultureIgnoreCase)) {
			# report and return
			Write-Warning -Message "provided path not under cluster shared volumes root: $($Cluster.SharedVolumesRoot)"
			return
		}

		# extract friendly name from path
		$FriendlyName = $Path.Split('\')[-1]
	}
	'FriendlyName' {
		# define path
		$Path = Join-Path -Path $Cluster.SharedVolumesRoot -ChildPath $FriendlyName
	}
}

# if path is not an existing CSV...
if ($Path -notin $ClusterSharedVolumes.SharedVolumeInfo.FriendlyVolumeName) {
	# report and return
	Write-Warning -Message "could not find an existing cluster shared volume with path: $Path"
	return
}

# retrieve child folders in immediate path skipping system directories (Recycle Bin and System Volume Information)
$ChildDirectories = Get-ChildItem -Path $Path -Directory -System:$false

# loop through child directories
foreach ($ChildDirectory in $ChildDirectories) {
	# retrieve child items in path
	$ChildItems = Get-ChildItem -Path $ChildDirectory.FullName -File -Force -Recurse

	# if child items found...
	if ($ChildItems) {
		# update boolean
		$ChildItemsFound = $true

		# report directory
		Write-Warning -Message "cannot reset volume; found existing files in folder: $($ChildDirectory.FullName)"
	}
}

# if child items found...
if ($ChildItemsFound) {
	Write-Warning -Message "cannot reset volume; existing files found in volume: $Path"
	return
}

# retrieve clustered storage pools
try {
	$StoragePool = Get-StoragePool | Where-Object { $_.IsClustered -and -not $_.IsPrimordial }
}
catch {
	Write-Warning -Message "could not retrieve storage pool: $($_.Exception.Message)"
	return
}

# if multiple storage pools found...
if ($StoragePool.Count) {
	# select storage pool by index
	$StoragePool = $StoragePool[$StoragePoolIndex]
}

# retrieve virtual disk for volume
$VirtualDisk = Get-VirtualDisk -StoragePool $StoragePool | Where-Object { $_.FriendlyName -eq $FriendlyName }

# if virtual disk not found...
if ($null -eq $VirtualDisk) {
	Write-Warning -Message "could not locate virtual disk with friendly name: $FriendlyName"
	return
}

# retrieve volume size
try {
	$Size = Get-ClusterSharedVolumeSize
}
catch {
	Write-Warning -Message "could not retrieve CSV size: $($_.Exception.Message)"
	return
}

# format volume size
$FormattedVolumeSize = Format-Bytes -Size $Size

# report volume
Write-Host "Computed volume size from available space less computed reserve: $FormattedVolumeSize ($Size bytes)"

# if WhatIf present...
if ($WhatIf.IsPresent) {
	return
}

# if force not present...
if (!$Force.IsPresent) {
	Write-Warning -Message "This will destroy and recreate the '$FriendlyName' volume in the '$($StoragePool.FriendlyName)' storage pool"
	Write-Warning -Message 'This action will remove any data remaining on the volume and is unrecoverable' -WarningAction Inquire
}

# remove virtual disk for volume
try {
	$VirtualDisk | Remove-VirtualDisk
}
catch {
	Write-Warning -Message "could not remove virtual disk for volume: $($VirtualDisk.FriendlyName)"
	return
}

# declare volume removed
Write-Host "Removed volume: $Path"

# define volume parameters
$NewVolume = @{ FriendlyName = $FriendlyName; FileSystem = 'CSVFS_ReFS'; StoragePool = $StoragePool; Size = $Size; AllocationUnitSize = 4096; ProvisioningType = 'Thin' }

# create volume
try {
	$null = New-Volume @NewVolume
}
catch {
	Write-Warning -Message "could not create new volume: $($_.Exception.Message)"
	return
}

# declare volume created
Write-Host "Created volume: $Path"

# retrieve Cluster Shared Volume
$ClusterSharedVolume = Get-ClusterSharedVolume | Where-Object { $_.SharedVolumeInfo.FriendlyVolumeName -eq $Path }

# move Cluster Shared Volume to local host
$ClusterSharedVolume = Move-ClusterSharedVolume -InputObject $ClusterSharedVolume -Node $env:COMPUTERNAME

# if Azure Local installation...
if ($IsAzureLocal) {
	# retrieve active action plans
	$ActionPlanInstances = Get-ActionPlanInstances | Where-Object { $_.LockType -eq 'ExclusiveLock' -and $_.Status -notin 'Cancelled', 'Completed', 'Failed' }

	# if active action plans found...
	if ($ActionPlanInstances) { 
		# declare waiting for active action plans to complete
		Write-Host 'Waiting for active action plans:'

		# loop through active action plans
		foreach ($ActionPlanInstance in ($ActionPlanInstances | Sort-Object StartDateTime)) {
			Write-Host " - $($ActionPlanInstance.InstanceId); $($ActionPlanInstance.ActionPlanName), Started: $($ActionPlanInstance.StartDateTime), Status: $($ActionPlanInstance.Status)"
		}

		# wait for active action plans to complete
		while ($null -ne $ActionPlanInstances) { 
			# update action plan instances
			$ActionPlanInstances = Get-ActionPlanInstances | Where-Object { $_.LockType -eq 'ExclusiveLock' -and $_.Status -notin 'Cancelled', 'Completed', 'Failed' }

			# sleep for 3 seconds
			Start-Sleep -Seconds 3
		}
	}

	# enable BitLocker for Azure Local
	$null = Enable-ASBitlocker -Cluster -VolumeType ClusterSharedVolume

	# declare waiting for BitLocker for Azure Local
	Write-Host "Waiting for BitLocker plan to configure and encrypt volume: $($ClusterSharedVolume.Name)"

	# set boolean
	$FullyEncrypted = $false

	# wait for BitLocker to encrypt the cluster shared volume
	while (!$FullyEncrypted) {
		# start sleep
		Start-Sleep -Seconds 3

		# retrieve cluster shared volume to ensure current mount point is available
		$ClusterSharedVolume = Get-ClusterSharedVolume -Name $ClusterSharedVolume.Name

		# if verbose...
		if ($VerbosePreference) {
			# report state of cluster shared volume
			$ClusterSharedVolume | Format-Table -Property FriendlyVolumeName, MaintenanceMode, RedirectedAccess
		}

		# retrieve current mount point
		$MountPoint = $ClusterSharedVolume.SharedVolumeInfo.Partition.Name

		# retrieve BitLocker volume
		$BitLockerVolume = Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction 'SilentlyContinue'

		# update boolean
		$FullyEncrypted = $BitLockerVolume.VolumeStatus -eq 'FullyEncrypted'

		# if verbose present...
		if ($VerbosePreference -eq 'Continue') {
			# create object with state of cluster shared volume
			$VolumeState = [PSCustomObject]@{
				FriendlyVolumeName = $ClusterSharedVolume.FriendlyVolumeName
				MaintenanceMode    = $ClusterSharedVolume.MaintenanceMode
				RedirectedAccess   = $ClusterSharedVolume.RedirectedAccess
				BitLockerStatus    = $BitLockerVolume.VolumeStatus
			}

			# report state of cluster shared volume
			$VolumeState | Format-Table
		}
	}

	# declare cluster shared volume encrypted
	Write-Host "BitLocker completed configuration and encryption of volume: $Name"
}

# switch on deduplication mode
switch ($DeduplicationMode) {
	'Windows' {
		# define exclude path
		$ExcludeFolder = Join-Path -Path $Path -ChildPath '.exclude'

		# create exclude folder on each volume BEFORE enabling deduplication
		$null = New-Item -Type Directory -Path $ExcludeFolder -Force

		# enable dedupe on each volume
		$null = Enable-DedupVolume -Volume $Path -UsageType HyperV

		# exclude folder from dedupe on each volume
		$null = Set-DedupVolume -Volume $Path -ExcludeFolder $ExcludeFolder -MinimumFileAgeDays 0 -NoCompress $true

		# declare Windows deduplication configured
		Write-Host "Windows Dedupliation configured for volume: $Path"
	}
	'ReFS' {
		# retrieve path from cluster shared volume
		$Volume = $ClusterSharedVolume.SharedVolumeInfo.FriendlyVolumeName

		# define exclude path
		$ExcludeFolder = Join-Path -Path $Volume -ChildPath '.exclude'

		# create exclude folder on each volume BEFORE enabling deduplication
		$null = New-Item -Type Directory -Path $ExcludeFolder -Force

		# enable dedupe on the volume
		$null = Enable-ReFSDedup -Volume $Volume -Type Dedup

		# declare ReFS deduplication configured
		Write-Host "ReFS Dedupliation configured for volume: $Path"
	}
	default {
		Write-Host "Deduplication not configured for volume: $Path"
	}
}
