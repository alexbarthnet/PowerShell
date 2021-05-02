# set the file locations
$hostname_vm = [System.Net.Dns]::GetHostName().ToLower()
$folder_temp = [System.Environment]::GetEnvironmentVariable('TEMP','Machine')
$path_hv_log = Join-Path -Path $folder_temp -ChildPath 'hv-setup'
$log_feature = Join-Path -Path $path_hv_log -ChildPath 'ash-log-features.txt'

# check path
If (!(Test-Path -Path $path_hv_log)) {New-Item -ItemType Directory -Path $path_hv_log}

# start logging
Start-Transcript -Path $log_feature -Append -Force

# define required roles
$features_requested = @()
$features_requested += "BitLocker" # storage encryption of CSV
$features_requested += "Data-Center-Bridging" # enable network qos in cooperation with switches
$features_requested += "Failover-Clustering" # base feature for clustering
$features_requested += "FS-FileServer" # base feature for dedupe and bandwidth limits
$features_requested += "FS-Data-Deduplication" # de-duplicate blocks on the CSV
$features_requested += "FS-SMBBW" # limit live migration bandwidth
$features_requested += "GPMC" # console for handling group policy
$features_requested += "Hyper-V" # virtualization
$features_requested += "Hyper-V-PowerShell" # powershell for hyper-v
$features_requested += "RSAT-AD-Powershell" # powershell for AD
$features_requested += "RSAT-Clustering-PowerShell" # powershell for clustering
$features_requested += "Storage-Replica" # enable stretch clusters

# clear variable
$features_installed = Get-WindowsFeature | Where-Object {$_.Installed}
$features_required = @()

# run through feature map
$features_requested | ForEach-Object {
    # check if feature is installed
    If ($features_installed.Name -match $_){
        # declare and skip
        Write-Host ($hostname_vm + " - found feature: " + $_)
    }
    Else {
        # declare and add
        Write-Host ($hostname_vm + " - added feature: " + $_)
        $features_required += $_
    }
}

# install the roles
If ($features_required) {
    Write-Host ($hostname_vm + " - installing features...")
    Install-WindowsFeature -Name $features_required -IncludeAllSubFeature -IncludeManagementTools
}

# stop logging
Stop-Transcript