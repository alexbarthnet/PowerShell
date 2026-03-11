param(
	[string]$FriendlyName = 'Hyper-V-Reserve',
	[uint64]$AllocatedSpace = 0,
	[uint64]$ReservedSpace = 0,
	[uint64]$VolumeCount = 1,
	[switch]$WhatIf,
	[switch]$Force
)

# define format-bytes function for reporting
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

# define Windows Dedupe boolean
$IsWindowsDedupeInstalled = (Get-WindowsFeature -Name 'FS-Data-Deduplication').Installed

# define Azure Local boolean
$IsAzureLocal = (Get-CimInstance -ClassName 'Win32_OperatingSystem').OperatingSystemSKU -eq 406

# retrieve clustered storage pools
$StoragePools = Get-StoragePool | Where-Object { $_.IsClustered -and -not $_.IsPrimordial }

# seleect first storage pools
$StoragePool = $StoragePools | Select-Object -First 1

# get data copies for mirror resiliency setting
$DataCopies = $StoragePool | Get-ResiliencySetting -Name 'Mirror' | Select-Object -ExpandProperty 'NumberOfDataCopiesDefault'

# get all virtual disks in storage pool
$VirtualDisks = $StoragePool | Get-VirtualDisk

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

# format volume size
$FormattedVolumeSize = Format-Bytes -Size $VolumeSize

# report volume
Write-Host "Maximum volume size from unallocated space: $FormattedVolumeSize ($VolumeSize bytes)"

# if WhatIf present...
if ($WhatIf.IsPresent) {
	return
}

# if force not present...
if (!$Force.IsPresent) {
	Write-Warning -Message "This will create the '$FriendlyName' volume that consumes all unallocated space in the '$($StoragePool.FriendlyName)' storage pool"
	Write-Warning -Message "This action will remove any space reserved for automatic storage recovery actions" -WarningAction Inquire
}

# define volume parameters
$NewVolume = @{ FileSystem = 'CSVFS_ReFS'; StoragePool = $StoragePool; Size = $VolumeSize; AllocationUnitSize = 4096; ProvisioningType = 'Thin' }

# create volumes for each node
$null = New-Volume @NewVolume -FriendlyName $FriendlyName

# retrieve shared volumes root
$SharedVolumesRoot = Get-Cluster | Select-Object -ExpandProperty 'SharedVolumesRoot'

# define volume path
$Path = '{0}\{1}' -f $SharedVolumesRoot, $FriendlyName

# retrieve Cluster Shared Volume
$ClusterSharedVolume = Get-ClusterSharedVolume | Where-Object { $_.SharedVolumeInfo.FriendlyVolumeName -eq $Path }

# move CSV to local host
$ClusterSharedVolume | Move-ClusterSharedVolume -Node $env:COMPUTERNAME

# if Azure Local installation...
if ($IsAzureLocal) { 
	# enable BitLocker for Azure Local
	Enable-ASBitlocker -Cluster -VolumeType ClusterSharedVolume

	# declare waiting for BitLocker for Azure Local
	Write-Host "Waiting for volume to be configured for BitLocker"

	# retrieve mount point
	$MountPoint = $ClusterSharedVolume.SharedVolumeInfo.Partition.Name

	# wait for BitLocker for Azure Local
	while ((Get-BitLockerVolume | Where-Object { $_.MountPoint -eq $MountPoint } | Select-Object -ExpandProperty 'VolumeStatus') -ne 'FullyEncrypted') { Start-Sleep -Seconds 1 }

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
