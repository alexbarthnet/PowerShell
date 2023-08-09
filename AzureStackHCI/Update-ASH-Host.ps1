# set the file locations
$hostname_vm = [System.Net.Dns]::GetHostName().ToLower()
$folder_temp = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')
$log_aliases = ($folder_temp + '\hv-setup\ash-log-host.txt')

# start logging
Start-Transcript -Path $log_aliases -Append -Force

# get the adapters that are a hardware device to exclude virtual adapters
Get-NetAdapter | Where-Object { $_.HardwareInterface } | Sort-Object InterfaceAlias | ForEach-Object {
    # set base names
    $nic_old = ($_).Name
    $nic_new = $null

    # try to build the name from slot and port information
    $nic_hwi = ($_ | Get-NetAdapterHardwareInfo -ErrorAction SilentlyContinue)
    If ($nic_hwi.SlotNumber) {
        $nic_new = ('SLOT ' + $nic_hwi.SlotNumber + ' Port ' + ($nic_hwi.FunctionNumber + 1))
        $nic_new_via = 'slot/port number'
    }
 
    # try to build the name from PCI device label
    $nic_pci = ($_ | Get-NetAdapterHardwareInfo -ErrorAction SilentlyContinue).PciDeviceLabelString
    If ($nic_pci) {
        $nic_new = $nic_pci
        $nic_new_via = 'PCI device label'
    }
 
    # try to build the name from Hyper-V 
    $nic_adv = ($_ | Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue | Where-Object { $_.RegistryKeyword -eq 'HyperVNetworkAdapterName' }).DisplayValue
    If ($nic_adv) {
        $nic_new = $nic_adv
        $nic_new_via = 'Hyper-V'
    }

    # if the new name was generated...
    If ($nic_new) {
        If ($nic_new -ne $nic_old) {
            # if new is different from old, set the NIC and declare the source
            Write-Host ($hostname_vm + " - '" + $nic_old + "' renamed to '" + $nic_new + "' via " + $nic_new_via)
            Rename-NetAdapter -Name $nic_old -NewName $nic_new
        }
        Else {
            # if new is the same as old, declare and move on
            Write-Host ($hostname_vm + " - '" + $nic_old + "' NOT renamed; generated name matches current name")
        }
    }
    Else {
        # if new name was not generated...
        Write-Host ($hostname_vm + " - '" + $nic_old + "' NOT renamed; could not generate name")
    }
}

# configure Live Migration to use SMB
Write-Host ($hostname_vm + ' - enabling Live Migration')
Enable-VMMigration

# configure Live Migration to use SMB
Write-Host ($hostname_vm + ' - setting Live Migration authentication: Kerberos')
Set-VMHost -VirtualMachineMigrationAuthenticationType Kerberos

# configure Live Migration to use SMB
Write-Host ($hostname_vm + ' - setting Live Migration transfer type: SMB')
Set-VMHost -VirtualMachineMigrationPerformanceOption SMB

# configure SMB limits
# .. storage NICs have 25Gb/s total bandwidth
# .. QoS guarantees 50% for storage: 12.5Gb/s or 1.5625GB/s
# .. QoS guarantees 1% for cluster: 0.25Gb/s or 31.25MB/s
# .. This leaves 49% for migration: 12.25Gb/s or 1.53125GB/s
# setting to static 750MB to satisfy Validate-DCB
Write-Host ($hostname_vm + ' - setting Live Migration bandwidth limit: 750MB/s')
Set-SmbBandwidthLimit -Category LiveMigration -BytesPerSecond 750MB

# disable DCBx
Write-Host ($hostname_vm + ' - setting QoS DCBx Willing mode: Disabled')
Set-NetQosDcbxSetting -Willing $False -Confirm:$false

# check for SMBDirect QoS policy
Write-Host ($hostname_vm + ' - checking QoS policy for Storage traffic')
$qos_policy_storage = Get-NetQosPolicy | Where-Object { $_.Name -eq 'SMBDirect' -and $_.PriorityValue -eq 3 -and $_.NetDirectPort -eq 445 }
If ($qos_policy_storage) {
    Write-Host ($hostname_vm + ' - verified QoS policy for Storage traffic')
}
Else {
    $qos_policy_storage = Get-NetQosPolicy | Where-Object { $_.Name -eq 'SMBDirect' -or $_.PriorityValue -eq 3 -or $_.NetDirectPort -eq 445 }
    If ($qos_policy_storage) {
        $qos_policy_storage | ForEach-Object {
            If ($_.Name -ne 'SMBDirect' -or $_.PriorityValue -ne 3 -or $_.NetDirectPort -ne 445 ) {
                Write-Host ($hostname_vm + ' - removing incorrect QoS policy for Storage traffic:' + $_.Name)
                $_ | Remove-NetQosPolicy -Confirm:$false
            }
        }
        Write-Host ($hostname_vm + ' - resetting QoS policy for Storage traffic')
        New-NetQosPolicy -Name 'SMBDirect' -PriorityValue8021Action 3 -NetDirectPortMatchCondition 445
    }
    Else {
        Write-Host ($hostname_vm + ' - creating QoS policy for Storage traffic')
        New-NetQosPolicy -Name 'SMBDirect' -PriorityValue8021Action 3 -NetDirectPortMatchCondition 445    
    }
}

# check for Cluster QoS policy
Write-Host ($hostname_vm + ' - checking QoS policy for Cluster traffic')
$qos_policy_cluster = Get-NetQosPolicy | Where-Object { $_.Name -eq 'Cluster' -and $_.PriorityValue -and '7' -or $_.Template -and 'Cluster' }
If ($qos_policy_cluster) {
    Write-Host ($hostname_vm + ' - verified QoS policy for Cluster traffic')
}
Else {
    $qos_policy_cluster = Get-NetQosPolicy | Where-Object { $_.Name -eq 'Cluster' -or $_.PriorityValue -eq '7' -or $_.Template -eq 'Cluster' }
    If ($qos_policy_cluster) {
        $qos_policy_cluster | ForEach-Object {
            If ($_.Name -ne 'Cluster' -or $_.PriorityValue -ne 7 -or $_.Template -ne 'Cluster') {
                Write-Host ($hostname_vm + ' - removing incorrect QoS policy for Cluster traffic:' + $_.Name)
                $_ | Remove-NetQosPolicy -Confirm:$false
            }
        }
        Write-Host ($hostname_vm + ' - resetting QoS policy for Cluster traffic')
        New-NetQosPolicy -Name 'Cluster' -PriorityValue8021Action 7 -Cluster
    }
    Else {
        Write-Host ($hostname_vm + ' - creating QoS policy for Cluster traffic')
        New-NetQosPolicy -Name 'Cluster' -PriorityValue8021Action 7 -Cluster
    }    
}

# check for SMBDirect QoS traffic class
Write-Host ($hostname_vm + ' - checking QoS traffic class for Storage traffic')
$qos_traffic_storage = Get-NetQosTrafficClass | Where-Object { $_.Name -eq 'SMBDirect' -and $_.Priority -eq 3 -and $_.Bandwidth -eq 50 -and $_.Algorithm -eq 'ETS' }
If ($qos_traffic_storage) {
    Write-Host ($hostname_vm + ' - verified QoS traffic class for Storage traffic')
}
Else {
    $qos_traffic_storage = Get-NetQosTrafficClass | Where-Object { $_.Name -eq 'SMBDirect' -or $_.Priority -eq 3 }
    If ($qos_traffic_storage) {
        $qos_traffic_storage | ForEach-Object {
            If ($_.Name -ne 'SMBDirect' -or $_.Priority -ne 3 -or $_.Bandwidth -ne 50 -or $_.Algorithm -ne 'ETS') {
                Write-Host ($hostname_vm + ' - removing incorrect QoS traffic class for Storage traffic:' + $_.Name)
                $_ | Remove-NetQosTrafficClass -Confirm:$false
            }
        }
        Write-Host ($hostname_vm + ' - resetting QoS traffic class for Storage traffic')
        New-NetQosTrafficClass -Name 'SMBDirect' -Priority 3 -BandwidthPercentage 50 -Algorithm ETS
    }
    Else {
        Write-Host ($hostname_vm + ' - creating QoS traffic class for Storage traffic')
        New-NetQosTrafficClass -Name 'SMBDirect' -Priority 3 -BandwidthPercentage 50 -Algorithm ETS
    }    
}

# check for Cluster QoS traffic class
Write-Host ($hostname_vm + ' - checking QoS traffic class for Cluster traffic')
$qos_traffic_cluster = Get-NetQosTrafficClass | Where-Object { $_.Name -eq 'Cluster' -and $_.Priority -eq 7 -and $_.Bandwidth -eq 1 -and $_.Algorithm -eq 'ETS'}
If ($qos_traffic_cluster) {
    Write-Host ($hostname_vm + ' - verified QoS traffic class for Cluster traffic')
}
Else {
    $qos_traffic_cluster = Get-NetQosTrafficClass | Where-Object { $_.Name -eq 'Cluster' -or $_.Priority -eq 7 }
    If ($qos_traffic_cluster) {
        $qos_traffic_cluster | ForEach-Object {
            If ($_.Name -ne 'Cluster' -or $_.Priority -ne 7 -or $_.Bandwidth -ne 1 -or $_.Algorithm -ne 'ETS') {
                Write-Host ($hostname_vm + ' - removing incorrect QoS traffic class for Cluster traffic:' + $_.Name)
                $_ | Remove-NetQosTrafficClass -Confirm:$false
            }
        }
        Write-Host ($hostname_vm + ' - resetting QoS traffic class for Cluster traffic')
        New-NetQosTrafficClass -Name 'Cluster' -Priority 7 -BandwidthPercentage 1 -Algorithm ETS
    }
    Else {
        Write-Host ($hostname_vm + ' - creating QoS traffic class for Cluster traffic')
        New-NetQosTrafficClass -Name 'Cluster' -Priority 7 -BandwidthPercentage 1 -Algorithm ETS
    }    
}

# enable QoS classes 3 (SMB) and 7 (Cluster)
Write-Host ($hostname_vm + ' - setting QoS flow control enabled priorities: 3,7')
Enable-NetQosFlowControl -Priority 3, 7
Disable-NetQosFlowControl -Priority 0, 1, 2, 4, 5, 6

# stop logging
Stop-Transcript