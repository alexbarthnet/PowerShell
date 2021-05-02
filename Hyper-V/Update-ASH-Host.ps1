# set the file locations
$hostname_vm = [System.Net.Dns]::GetHostName().ToLower()
$folder_temp = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')
$path_hv_log = Join-Path -Path $folder_temp -ChildPath 'hv-setup'
$log_hv_host = Join-Path -Path $path_hv_log -ChildPath 'ash-log-host.txt'

# check path
If (!(Test-Path -Path $path_hv_log)) { New-Item -ItemType Directory -Path $path_hv_log }

# start logging
Start-Transcript -Path $log_hv_host -Append -Force

# get the adapters that are a hardware device to exclude virtual adapters
Get-NetAdapter | Where-Object { $_.HardwareInterface } | Sort-Object InterfaceAlias | ForEach-Object {
    # set base names
    $nic_old = ($_).Name
    $nic_new = $null

    # try to build the name from slot and port information
    $nic_hwi = ($_ | Get-NetAdapterHardwareInfo -ErrorAction SilentlyContinue)
    If ($nic_hwi.SlotNumber) {
        $nic_new = ('Slot ' + $nic_hwi.SlotNumber + ' Port ' + ($nic_hwi.FunctionNumber + 1))
        $nic_new_via = 'slot/port number'
    } Else {
        $nic_new = ('Port ' + ($nic_hwi.FunctionNumber + 1))
        $nic_new_via = 'port number'
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

# determine live migration bandwidth limit
$nic_speed = $null
$nic_speed = (Get-NetAdapter -Physical | Sort-Object Speed | Select-Object -Last 1).Speed
If ($nic_speed -le [Math]::Pow(10, 10)) {
    # at 10Gb and below, set SMB bandwidth limit to 30% of the link speed in MB
    # the math: take linkspeed, divide by 1 million (convert bit to megabits), divide by 8 (convert megabits to megabytes), multiply by 0.3 (30%)
    $smb_limit = $nic_speed/[Math]::Pow(10,6)/8*0.3
}
Else {
    # above 10Gb, set SMB bandwidth limit to 750MB
    # the math above applied to 25Gb adapters would be 937.5MB/s
    $smb_limit = 750
}

# set live migration bandwidth limit
Write-Host ($hostname_vm + ' - setting Live Migration bandwidth limit: ' + $smb_limit.ToString() + 'MB/s')
Set-SmbBandwidthLimit -Category LiveMigration -BytesPerSecond ($smb_limit * 1MB)

# configure Live Migration to allow 4 concurrent Live Migrations
Write-Host ($hostname_vm + ' - setting Live Migration concurrence: 4')
Set-VMHost -MaximumVirtualMachineMigrations 4

# configure Live Migration to use Kerberos
Write-Host ($hostname_vm + ' - setting Live Migration authentication: Kerberos')
Set-VMHost -VirtualMachineMigrationAuthenticationType Kerberos

# configure Live Migration to use SMB
Write-Host ($hostname_vm + ' - setting Live Migration transfer type: SMB')
Set-VMHost -VirtualMachineMigrationPerformanceOption SMB

# enable Live Migration
Write-Host ($hostname_vm + ' - enabling Live Migration')
Enable-VMMigration

# disable numa spanning
Write-Host ($hostname_vm + ' - disabling NUMA Spanning')
Set-VMHost -NumaSpanningEnabled $false

# disable enhanced session mode
Write-Host ($hostname_vm + ' - disabling Enhanced Session Mode')
Set-VMHost -EnableEnhancedSessionMode $false

# disable DCBx
Write-Host ($hostname_vm + ' - disabling QoS DCBx Willing mode')
Set-NetQosDcbxSetting -Willing $False -Confirm:$false

# check for SMBDirect QoS policy
Write-Host ($hostname_vm + ' - checking SMBDirect QoS policy')
$qos_policy_storage = Get-NetQosPolicy | Where-Object { $_.Name -eq 'SMBDirect' -and $_.PriorityValue -eq 3 -and $_.NetDirectPort -eq 445 }
If ($qos_policy_storage) {
    Write-Host ($hostname_vm + ' - verified SMBDirect QoS policy')
}
Else {
    $qos_policy_storage = Get-NetQosPolicy | Where-Object { $_.Name -eq 'SMBDirect' -or $_.PriorityValue -eq 3 -or $_.NetDirectPort -eq 445 }
    If ($qos_policy_storage) {
        $qos_policy_storage | ForEach-Object {
            If ($_.Name -ne 'SMBDirect' -or $_.PriorityValue -ne 3 -or $_.NetDirectPort -ne 445 ) {
                Write-Host ($hostname_vm + ' - removing errant SMBDirect QoS policy:' + $_.Name)
                $_ | Remove-NetQosPolicy -Confirm:$false
            }
        }
        Write-Host ($hostname_vm + ' - resetting SMBDirect QoS policy')
        New-NetQosPolicy -Name 'SMBDirect' -PriorityValue8021Action 3 -NetDirectPortMatchCondition 445
    }
    Else {
        Write-Host ($hostname_vm + ' - creating SMBDirect QoS policy')
        New-NetQosPolicy -Name 'SMBDirect' -PriorityValue8021Action 3 -NetDirectPortMatchCondition 445    
    }
}

# check for Cluster QoS policy
Write-Host ($hostname_vm + ' - checking Cluster QoS policy')
$qos_policy_cluster = Get-NetQosPolicy | Where-Object { $_.Name -eq 'Cluster' -and $_.PriorityValue -and 7 -or $_.Template -and 'Cluster' }
If ($qos_policy_cluster) {
    Write-Host ($hostname_vm + ' - verified Cluster QoS policy')
}
Else {
    $qos_policy_cluster = Get-NetQosPolicy | Where-Object { $_.Name -eq 'Cluster' -or $_.PriorityValue -eq 7 -or $_.Template -eq 'Cluster' }
    If ($qos_policy_cluster) {
        $qos_policy_cluster | ForEach-Object {
            If ($_.Name -ne 'Cluster' -or $_.PriorityValue -ne 7 -or $_.Template -ne 'Cluster') {
                Write-Host ($hostname_vm + ' - removing incorrect Cluster QoS policy:' + $_.Name)
                $_ | Remove-NetQosPolicy -Confirm:$false
            }
        }
        Write-Host ($hostname_vm + ' - resetting Cluster QoS policy')
        New-NetQosPolicy -Name 'Cluster' -PriorityValue8021Action 7 -Cluster
    }
    Else {
        Write-Host ($hostname_vm + ' - creating Cluster QoS policy')
        New-NetQosPolicy -Name 'Cluster' -PriorityValue8021Action 7 -Cluster
    }    
}

# check for Default QoS policy
Write-Host ($hostname_vm + ' - checking Default QoS policy')
$qos_policy_default = Get-NetQosPolicy | Where-Object { $_.Name -eq 'Default' -and $_.PriorityValue -eq 0 -and $_.Template -eq 'Default' }
If ($qos_policy_default) {
    Write-Host ($hostname_vm + ' - verified Default QoS policy')
}
Else {
    $qos_policy_default = Get-NetQosPolicy | Where-Object { $_.Name -eq 'Default' -or $_.PriorityValue -eq 0 -or $_.Template -eq 'Default' }
    If ($qos_policy_default) {
        $qos_policy_default | ForEach-Object {
            If ($_.Name -ne 'Default' -or $_.PriorityValue -ne 0 -or $_.Template -ne 'Default') {
                Write-Host ($hostname_vm + ' - removing incorrect Default QoS policy:' + $_.Name)
                $_ | Remove-NetQosPolicy -Confirm:$false
            }
        }
        Write-Host ($hostname_vm + ' - resetting Default QoS policy')
        New-NetQosPolicy -Name 'Default' -PriorityValue8021Action 0 -Default
    }
    Else {
        Write-Host ($hostname_vm + ' - creating Default QoS policy')
        New-NetQosPolicy -Name 'Default' -PriorityValue8021Action 0 -Default
    }    
}

# check for SMBDirect QoS traffic class
Write-Host ($hostname_vm + ' - checking SMBDirect QoS traffic class')
$qos_traffic_storage = Get-NetQosTrafficClass | Where-Object { $_.Name -eq 'SMBDirect' -and $_.Priority -eq 3 -and $_.Bandwidth -eq 50 -and $_.Algorithm -eq 'ETS' }
If ($qos_traffic_storage) {
    Write-Host ($hostname_vm + ' - verified SMBDirect QoS traffic class')
}
Else {
    $qos_traffic_storage = Get-NetQosTrafficClass | Where-Object { $_.Name -eq 'SMBDirect' -or $_.Priority -eq 3 }
    If ($qos_traffic_storage) {
        $qos_traffic_storage | ForEach-Object {
            If ($_.Name -ne 'SMBDirect' -or $_.Priority -ne 3 -or $_.Bandwidth -ne 50 -or $_.Algorithm -ne 'ETS') {
                Write-Host ($hostname_vm + ' - removing errant SMBDirect QoS traffic class:' + $_.Name)
                $_ | Remove-NetQosTrafficClass -Confirm:$false
            }
        }
        Write-Host ($hostname_vm + ' - resetting SMBDirect QoS traffic class')
        New-NetQosTrafficClass -Name 'SMBDirect' -Priority 3 -BandwidthPercentage 50 -Algorithm ETS
    }
    Else {
        Write-Host ($hostname_vm + ' - creating SMBDirect QoS traffic class')
        New-NetQosTrafficClass -Name 'SMBDirect' -Priority 3 -BandwidthPercentage 50 -Algorithm ETS
    }    
}

# check for Cluster QoS traffic class
Write-Host ($hostname_vm + ' - checking Cluster QoS traffic class')
$qos_traffic_cluster = Get-NetQosTrafficClass | Where-Object { $_.Name -eq 'Cluster' -and $_.Priority -eq 7 -and $_.Bandwidth -eq 1 -and $_.Algorithm -eq 'ETS' }
If ($qos_traffic_cluster) {
    Write-Host ($hostname_vm + ' - verified Cluster QoS traffic class')
}
Else {
    $qos_traffic_cluster = Get-NetQosTrafficClass | Where-Object { $_.Name -eq 'Cluster' -or $_.Priority -eq 7 }
    If ($qos_traffic_cluster) {
        $qos_traffic_cluster | ForEach-Object {
            If ($_.Name -ne 'Cluster' -or $_.Priority -ne 7 -or $_.Bandwidth -ne 1 -or $_.Algorithm -ne 'ETS') {
                Write-Host ($hostname_vm + ' - removing errant Cluster QoS traffic class:' + $_.Name)
                $_ | Remove-NetQosTrafficClass -Confirm:$false
            }
        }
        Write-Host ($hostname_vm + ' - resetting Cluster QoS traffic class')
        New-NetQosTrafficClass -Name 'Cluster' -Priority 7 -BandwidthPercentage 1 -Algorithm ETS
    }
    Else {
        Write-Host ($hostname_vm + ' - creating Cluster QoS traffic class')
        New-NetQosTrafficClass -Name 'Cluster' -Priority 7 -BandwidthPercentage 1 -Algorithm ETS
    }    
}

# check for Default QoS traffic class
Write-Host ($hostname_vm + ' - checking Default QoS traffic class')
$qos_traffic_default = Get-NetQosTrafficClass | Where-Object { $_.Name -match 'Default' -and $_.Priority -contains 0 -and $_.Bandwidth -eq 49 -and $_.Algorithm -eq 'ETS' }
If ($qos_traffic_default) {
    Write-Host ($hostname_vm + ' - verified Default QoS traffic class')
}
Else {
    $qos_traffic_default = Get-NetQosTrafficClass | Where-Object { $_.Name -match 'Default' -and $_.Priority -contains 0 -and $_.Bandwidth -lt 49 -and $_.Algorithm -eq 'ETS' }
    If ($qos_traffic_default) {
        Write-Host ($hostname_vm + ' - found Default QoS traffic class with unexpected bandwidth reservation: ' + $qos_traffic_default.Bandwidth)
        Write-Host ($hostname_vm + ' - ... the default QoS configuration for S2D should reserve 49% of bandwidth')
        Write-Host ($hostname_vm + ' - ... review other QoS traffic classes on the system to determine if correct')
    }
    Else {
        Write-Host ($hostname_vm + ' - unable to verify the default QoS traffic class...')
        Write-Host ($hostname_vm + ' - ... review and correct the QoS configuration before continuing')
    }
}


# enable QoS classes 3 (SMB) and 7 (Cluster)
Write-Host ($hostname_vm + ' - setting QoS flow control enabled priorities: 3,7')
Enable-NetQosFlowControl -Priority 3, 7
Disable-NetQosFlowControl -Priority 0, 1, 2, 4, 5, 6

# stop logging
Stop-Transcript