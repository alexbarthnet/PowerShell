# set the file locations
$hostname_vm = [System.Net.Dns]::GetHostName().ToLower()
$folder_temp = [System.Environment]::GetEnvironmentVariable('TEMP','Machine')
$path_hv_log = Join-Path -Path $folder_temp -ChildPath 'hv-setup'
$map_feature = Join-Path -Path $path_hv_log -ChildPath 'ash-map-feature.txt'
$log_feature = Join-Path -Path $path_hv_log -ChildPath 'ash-log-features.txt'

# check path
If (!(Test-Path -Path $path_hv_log)) {New-Item -ItemType Directory -Path $path_hv_log}

# start logging
Start-Transcript -Path $log_feature -Append -Force

# clear variable
$features = Get-WindowsFeature | Where-Object {$_.Installed}
$add_role = @()

# run through feature map
Import-Csv -Path $map_feature | ForEach-Object {
    $feature = $_.Feature
    # check if feature is installed
    If ($features.Name -match $feature){
        # declare and skip
        Write-Host ($hostname_vm + " - found feature:" + $feature)
    }
    Else {
        # declare and add
        Write-Host ($hostname_vm + " - added feature:" + $feature)
        $add_role += $feature
    }
}

# install the roles
If ($add_role) {
    Write-Host ($hostname_vm + " - installing features...")
    Install-WindowsFeature -Name $add_role -IncludeAllSubFeature -IncludeManagementTools
}

# stop logging
Stop-Transcript