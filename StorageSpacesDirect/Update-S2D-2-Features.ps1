<#
.SYNOPSIS
Configures the Windows features on a Hyper-V host that will be or is running Storage Spaces Direct (S2D).

.DESCRIPTION
Configures the Windows features on a Hyper-V host that will be or is running Storage Spaces Direct (S2D) with information from a set of host-specific configuration files.

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

	# define required roles
	$features = @()
	$features += 'BitLocker' # storage encryption of cluster shared volumes
	$features += 'Data-Center-Bridging' # enable network qos in cooperation with switches
	$features += 'Failover-Clustering' # enable failover clustering
	$features += 'FS-FileServer' # base feature for dedupe and bandwidth limits
	$features += 'FS-Data-Deduplication' # deduplicate cluster shared volumes
	$features += 'FS-SMBBW' # limit live migration bandwidth
	$features += 'GPMC' # console for handling group policy
	$features += 'Hyper-V' # enable virtualization
	$features += 'Hyper-V-PowerShell' # powershell for hyper-v
	$features += 'NetworkVirtualization' # network virtualization for SDN and SCVMM
	$features += 'RSAT-AD-Powershell' # powershell for AD
	$features += 'RSAT-Clustering-PowerShell' # powershell for failover clustering
	$features += 'Storage-Replica' # enable stretch clusters

	# check if part of a cluster
	Write-Host "$Hostname - checking if Cluster service is running..."
	$cluster = $null
	$cluster = Get-Service | Where-Object { $_.Name -eq 'ClusSvc' -and $_.Status -eq 'Running' }
	If ($cluster) {
		Write-Host "$Hostname - ...cluster service is running, installing features without restarting..."
		Install-WindowsFeature -Name $features -IncludeAllSubFeature -IncludeManagementTools
	}
	Else {
		Write-Host "$Hostname - ...cluster service is not running, installing features and restarting if required..."
		Install-WindowsFeature -Name $features -IncludeAllSubFeature -IncludeManagementTools -Restart
	}
}
Finally {
	# stop logging
	Stop-Transcript
}
