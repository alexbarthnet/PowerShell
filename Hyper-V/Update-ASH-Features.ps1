# set the file locations
$hostname_vm = [System.Net.Dns]::GetHostName().ToLower()
$folder_temp = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')
$path_hv_log = Join-Path -Path $folder_temp -ChildPath 'hv-setup'
$log_feature = Join-Path -Path $path_hv_log -ChildPath 'ash-log-features.txt'

# check path
If (!(Test-Path -Path $path_hv_log)) { New-Item -ItemType Directory -Path $path_hv_log }

# start logging
Start-Transcript -Path $log_feature -Append -Force

# cluster check
$cluster = Get-Service | Where-Object { $_.Name -eq 'ClusSvc' }

# define required roles
$features = @()
$features += 'BitLocker' # storage encryption of CSV
$features += 'Data-Center-Bridging' # enable network qos in cooperation with switches
$features += 'Failover-Clustering' # base feature for clustering
$features += 'FS-FileServer' # base feature for dedupe and bandwidth limits
$features += 'FS-Data-Deduplication' # de-duplicate blocks on the CSV
$features += 'FS-SMBBW' # limit live migration bandwidth
$features += 'GPMC' # console for handling group policy
$features += 'Hyper-V' # virtualization
$features += 'Hyper-V-PowerShell' # powershell for hyper-v
$features += 'RSAT-AD-Powershell' # powershell for AD
$features += 'RSAT-Clustering-PowerShell' # powershell for clustering
$features += 'Storage-Replica' # enable stretch clusters

# install the roles
Write-Host ($hostname_vm + ' - installing features...')
If ($cluster) {
    Write-Host ($hostname_vm + ' - installing features without any restart...')
    Install-WindowsFeature -Name $features -IncludeAllSubFeature -IncludeManagementTools
}
Else {
    Write-Host ($hostname_vm + ' - installing features with restart if required...')
    Install-WindowsFeature -Name $features -IncludeAllSubFeature -IncludeManagementTools -Restart
}

# stop logging
Stop-Transcript