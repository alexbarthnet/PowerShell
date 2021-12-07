# set the folder locations
$host_name = [System.Net.Dns]::GetHostName().ToLower()
$path_temp = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')
$path_logs = Join-Path -Path $path_temp -ChildPath 'hv-setup'

# create the logs folder if necessary
If (!(Test-Path -Path $path_logs)) { New-Item -ItemType Directory -Path $path_logs }

# set the file locations
$log_feature = Join-Path -Path $path_logs -ChildPath ('log-update-s2d-1-features-' + (Get-Date -Format FileDateTime) + '.txt')

# start logging
Start-Transcript -Path $log_feature -Append -Force

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
Write-Host ($host_name + ' - checking if Cluster service is running...')
$cluster = $null
$cluster = Get-Service | Where-Object { $_.Name -eq 'ClusSvc' -and $_.Status -eq 'Running'}
If ($cluster) {
    Write-Host ($host_name + ' - ...cluster service is running, installing features without restarting...')
    Install-WindowsFeature -Name $features -IncludeAllSubFeature -IncludeManagementTools
}
Else {
    Write-Host ($host_name + ' - ...cluster service is not running, installing features and restarting if required...')
    Install-WindowsFeature -Name $features -IncludeAllSubFeature -IncludeManagementTools -Restart
}

# stop logging
Stop-Transcript