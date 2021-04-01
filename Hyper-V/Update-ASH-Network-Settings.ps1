# set the file locations
$hostname_vm = [System.Net.Dns]::GetHostName().ToLower()
$folder_temp = [System.Environment]::GetEnvironmentVariable('TEMP','Machine')
$log_setting = ($folder_temp + '\hv-setup\ash-log-settings.txt')

# start logging
Start-Transcript -Path $log_setting -Append -Force

# configure Live Migration to use SMB
Write-Host ($hostname_vm + " - setting Live Migration transfer type: SMB")
Set-VMHost –VirtualMachineMigrationPerformanceOption SMB

# configure SMB limits
# .. storage NICs have 25Gb/s total bandwidth
# .. QoS guarantees 50% for storage: 12.5Gb/s or 1.5625GB/s
# .. QoS guarantees 1% for cluster: 0.25Gb/s or 31.25MB/s
# .. This leaves 49% for migration: 12.25Gb/s or 1.53125GB/s
Write-Host ($hostname_vm + " - setting Live Migration bandwidth limit: 1.5GB")
Set-SmbBandwidthLimit -Category LiveMigration -BytesPerSecond 1.5GB

# disable DCBx
Write-Host ($hostname_vm + " - disabling DCBx")
Set-NetQosDcbxSetting -Willing $False

# check for SMB QoS policy
Write-Host ($hostname_vm + " - checking QoS policy for SMB")
$qos_policy_smb = Get-NetQosPolicy -Name 'SMB'
If ($qos_policy_smb) {
    Write-Host ($hostname_vm + " - creating QoS policy for SMB")
    Set-NetQosPolicy -Name 'SMB' –PriorityValue8021Action 3 –NetDirectPortMatchCondition 445    
} Else {
    Write-Host ($hostname_vm + " - setting QoS policy for SMB")
    New-NetQosPolicy -Name 'SMB' –PriorityValue8021Action 3 –NetDirectPortMatchCondition 445    
}

# check for Cluster QoS policy
Write-Host ($hostname_vm + " - checking QoS policy for Cluster")
$qos_policy_smb = Get-NetQosPolicy -Name 'Cluster'
If ($qos_policy_smb) {
    Write-Host ($hostname_vm + " - creating QoS policy for Cluster")
    Set-NetQosPolicy -Name 'Cluster' -PriorityValue8021Action 5 -Cluster
} Else {
    Write-Host ($hostname_vm + " - setting QoS policy for Cluster")
    New-NetQosPolicy -Name 'Cluster' -PriorityValue8021Action 5 -Cluster
}

# check for SMB QoS traffic class
Write-Host ($hostname_vm + " - checking QoS traffic class for SMB")
$qos_traffic_smb = Get-NetQosTrafficClass -Name 'SMB'
If ($qos_traffic_smb) {
    Write-Host ($hostname_vm + " - updating QoS traffic class for Storage traffic")
    Set-NetQosTrafficClass -Name 'SMB' –Priority 3 –BandwidthPercentage 50 –Algorithm ETS
} Else {
    Write-Host ($hostname_vm + " - creating QoS traffic class for Storage traffic")
    New-NetQosTrafficClass -Name 'SMB' –Priority 3 –BandwidthPercentage 50 –Algorithm ETS
}

# check for Cluster QoS traffic class
Write-Host ($hostname_vm + " - checking QoS traffic class for Cluster traffic")
$qos_traffic_clu = Get-NetQosTrafficClass -Name 'Cluster'
If ($qos_traffic_clu) {
    Write-Host ($hostname_vm + " - updating QoS traffic class for Cluster traffic")
    Set-NetQosTrafficClass -Name 'Cluster' –Priority 7 –BandwidthPercentage 1 –Algorithm ETS
} Else {
    Write-Host ($hostname_vm + " - creating QoS traffic class for Cluster traffic")
    New-NetQosTrafficClass -Name 'Cluster' –Priority 7 –BandwidthPercentage 1 –Algorithm ETS
}

# enable QoS classes 3 (SMB) and 7 (Cluster)
Write-Host ($hostname_vm + " - setting QoS flow control")
Enable-NetQosFlowControl -Priority 3,7
Disable-NetQosFlowControl -Priority 0,1,2,4,5,6

# stop logging
Stop-Transcript