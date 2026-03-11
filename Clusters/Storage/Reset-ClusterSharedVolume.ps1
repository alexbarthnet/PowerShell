param(
	[Parameter(Mandatory)]
	[string]$FriendlyName,
	[uint64]$AllocatedSpace = 0,
	[switch]$WhatIf,
	[switch]$Force
)

# define Windows Dedupe boolean
$IsWindowsDedupeInstalled = (Get-WindowsFeature -Name 'FS-Data-Deduplication').Installed

# define Azure Local boolean
$IsAzureLocal = (Get-CimInstance -ClassName 'Win32_OperatingSystem').OperatingSystemSKU -eq 406

# retrieve shared volumes root
$SharedVolumesRoot = Get-Cluster | Select-Object -ExpandProperty 'SharedVolumesRoot'

# define path
$Path = '{0}\{1}' -f $SharedVolumesRoot, $FriendlyName

# retrieve child folders in immediate path skipping system directories (Recycle Bin and System Volume Information)
$ChildDirectories = Get-ChildItem -Path $Path -Directory -System:$false

# loop through child directories
foreach ($ChildDirectory in $ChildDirectories) {
	# retrieve child items in path
	$ChildItems = Get-ChildItem -Path $ChildDirectory -Files -Force -Recurse

	# if child items found...
	if ($ChildItems) {
		# update boolean
		$ChildItemsFound = $true

		# report directory
		Write-Warning -Message "Cannot reset volume; existing files found in folder: $($ChildDirectory.FullName)"
	}
}

# if child items found...
if ($ChildItemsFound) {
	Write-Warning -Message "Cannot reset volume; existing files found in volume: $Path"
	return
}

# retrieve node count
$NodeCount = Get-ClusterNode | Measure-Object | Select-Object -ExpandProperty Count

# define volume count to be 3 or node count, whichever is larger
$VolumeCount = if ($NodeCount -lt 3) { 3 } else { $NodeCount }

# retrieve clustered storage pools
$StoragePools = Get-StoragePool | Where-Object { $_.IsClustered -and -not $_.IsPrimordial }

# seleect first storage pools
$StoragePool = $StoragePools | Select-Object -First 1

# get data copies for mirror resiliency setting
$DataCopies = $StoragePool | Get-ResiliencySetting -Name 'Mirror' | Select-Object -ExpandProperty 'NumberOfDataCopiesDefault'

# get physical disks in storage pool
$PhysicalDisks = $StoragePool | Get-PhysicalDisk | Where-Object { $_.Usage -notin 'Journal', 'HotSpare' }

# get count of physical disk per node
$PhysicalDiskPerNode = $PhysicalDisks.Count / $NodeCount

# get size of largest physical disk in the cluster
$PhysicalDiskSizeMax = $PhysicalDisks | Measure-Object -Property Size -Maximum | Select-Object -ExpandProperty Maximum

# reserve one disk per node when node count meets or exceeds number of data copies and each node has more disks than number of data copies
$ReservedSpace = if ($NodeCount -ge $DataCopies -and $PhysicalDiskPerNode -gt $DataCopies) { $PhysicalDiskSizeMax * $NodeCount } else { 0 }

# get infrastructure virtual disks in storage pool
$VirtualDisks = $StoragePool | Get-VirtualDisk | Where-Object { $_.FriendlyName -eq 'ClusterPerformanceHistory' -or $_.FriendlyName -like 'Infrastructure_*' }

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

# retrieve virtual disk for volume
$VirtualDisk = Get-VirtualDisk -FriendlyName $FriendlyName

# remove virtual disk for volume
$VirtualDisk | Remove-VirtualDisk

# define volume parameters
$NewVolume = @{ FriendlyName = $FriendlyName; FileSystem = 'CSVFS_ReFS'; StoragePool = $StoragePool; Size = $VolumeSize; AllocationUnitSize = 4096; ProvisioningType = 'Thin' }

# create volume
$null = New-Volume @NewVolume

# retrieve Cluster Shared Volume
$ClusterSharedVolume = Get-ClusterSharedVolume | Where-Object { $_.SharedVolumeInfo.FriendlyVolumeName -eq $Path }

# move CSV to local host
$null = $ClusterSharedVolume | Move-ClusterSharedVolume -Node $env:COMPUTERNAME

# if Azure Local installation...
if ($IsAzureLocal) {
	# enable BitLocker for Azure Local
	$null = Enable-ASBitlocker -Cluster -VolumeType ClusterSharedVolume

	# declare waiting for BitLocker for Azure Local
	Write-Host "Waiting for volume to be configured for BitLocker"

	# retrieve mount point
	$MountPoint = $ClusterSharedVolume.SharedVolumeInfo.Partition.Name

	# wait for BitLocker for Azure Local
	while ((Get-BitLockerVolume -MountPoint $MountPoint -ErrorAction SilentlyContinue | Select-Object -ExpandProperty 'VolumeStatus') -ne 'FullyEncrypted') { Start-Sleep -Seconds 3 }

	# declare waiting for BitLocker for Azure Local
	Write-Host "BitLocker configured for volume: $Path"
}

# if Windows Deduplication installed...
if ($IsWindowsDedupeInstalled) {
	# define exclude path
	$ExcludeFolder = Join-Path -Path $Path -ChildPath '.exclude'

	# create exclude folder on each volume BEFORE enabling deduplication
	$null = New-Item -Type Directory -Path $ExcludeFolder -Force

	# enable dedupe on each volume
	$null = Enable-DedupVolume -Volume $Path -UsageType HyperV

	# exclude folder from dedupe on each volume
	$null = Set-DedupVolume -Volume $Path -ExcludeFolder $ExcludeFolder -MinimumFileAgeDays 0 -NoCompress $true

	# declare waiting for BitLocker for Azure Local
	Write-Host "Windows Dedupliation configured for volume: $Path"
}
