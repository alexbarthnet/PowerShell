<#
.SYNOPSIS
Configures the devices on a Hyper-V host that will be or is running Storage Spaces Direct (S2D).

.DESCRIPTION
Configures the devices on a Hyper-V host that will be or is running Storage Spaces Direct (S2D) with information from a set of host-specific configuration files. 

A parent script pushes this script and the configuration files to each Hyper-V host then starts the script using PowerShell Remoting.

.LINK
https://github.com/alexbarthnet/PowerShell/
#>

[CmdletBinding()]
param (
	[Parameter()]
	[string]$Hostname = [System.Net.Dns]::GetHostName().ToLower(),
	[Parameter()][ValidateScript({ Test-Path -Path $_ })]
	[string]$TempPath = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine'),
	[Parameter()][ValidateScript({ Test-Path -Path $_ })]
	[string]$FilePath = (Join-Path -Path $TempPath -ChildPath 'hv-setup'),
	[Parameter()][ValidateScript({ Test-Path -Path $_ })]
	[string]$LogFile = $PSCommandPath.Replace('.ps1', "-$(Get-Date -Format FileDateTime).txt")
)

Try {
	# start logging
	Start-Transcript -Path $LogFile -Append -Force

	# check for the cluster
	$cluster = $null
	$cluster = Get-Service | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -ne 'Disabled' }
	If ($cluster) {
		Write-Host ("$Hostname - Cluster found, clearing unclaimed devices")
	}
	Else {
		Write-Host ("$Hostname - Cluster not found, clearing all non-boot storage")
	}

	# force update of host view of storage
	Update-StorageProviderCache

	# remove existing storage pools
	If (-not $cluster) {
		Get-StoragePool -IsPrimordial $false | Set-StoragePool -IsReadOnly:$false -ErrorAction 'SilentlyContinue'
		Get-StoragePool -IsPrimordial $false | Get-VirtualDisk | Remove-VirtualDisk -Confirm:$false -ErrorAction 'SilentlyContinue'
		Get-StoragePool -IsPrimordial $false | Remove-StoragePool -Confirm:$false -ErrorAction 'SilentlyContinue'
		Write-Host ("$Hostname - Storage pools removed")
	}

	# reset physical disks
	Get-PhysicalDisk -CanPool $true | Reset-PhysicalDisk -ErrorAction 'SilentlyContinue'
	Write-Host ("$Hostname - Physical disks cleared")

	# remove existing storage pools
	$disks = Get-Disk | Where-Object { $_.Number -ne $null -and $_.IsBoot -ne $true -and $_.IsSystem -ne $true -and $_.PartitionStyle -ne 'RAW' } | Sort-Object -Property 'Number'
	ForEach ($disk in $disks) {
		$disk | Set-Disk -IsOffline:$false
		$disk | Set-Disk -IsReadOnly:$false
		$disk | Clear-Disk -RemoveData -RemoveOEM -Confirm:$false
		$disk | Set-Disk -IsReadOnly:$true
		$disk | Set-Disk -IsOffline:$true
		Write-Host ("$Hostname - Cleared disk $($disk.Number)")
	}
}
Finally {
	# stop logging
	Stop-Transcript
}
