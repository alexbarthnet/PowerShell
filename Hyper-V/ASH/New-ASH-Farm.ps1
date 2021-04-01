# set the file locations
$ash_map_cluster = '.\ash-map-cluster.txt'
$ash_map_network = '.\ash-map-network.txt'

# process the cluster mapping file
Import-Csv -Path $ash_map_cluster | ForEach-Object {
    # get strings from CSV
    $hv_cluster = $_.Cluster
    $hv_switch = $_.Switch
    $hv_name = $_.Node
    $vm_name = $_.Host
    $nic_1st = $_.FirstNic
    
    # get numbers from CSV
    $vm_ram = [int]$_.MemoryGB * 1GB
    $hd_size_os = [int]$_.OsDiskGB * 1GB
    $hd_size_cl = [int]$_.ClDiskGB * 1GB
    $hd_count = [int]$_.ClDiskCount
    $hd_array = @()
 
    # declare start
    Write-Host ("======================== $vm_name ========================")

    # get VHD root and set VHD path
    $hd_root = (Get-VMHost -ComputerName $hv_name).VirtualHardDiskPath
    $hd_path_os = ($hd_root + '\' + $vm_name + '.vhdx')

    # try to make the first VHD
    Try {
        Write-Host ($env:computername.ToLower() + ",$vm_name - creating VHDs")
        New-VHD -Computer $hv_name -SizeBytes $hd_size_os -Path $hd_path_os | Out-Null
        For ($i = 1;$i -le $hd_count; $i++) {
            # define path to new VHD
            $hd_path_cl = ($hd_root + '\' + $vm_name + '-' + $i + '.vhdx')
            $hd_array += New-VHD -Computer $hv_name -SizeBytes $hd_size_cl -Path $hd_path_cl
        }
    } Catch {
        Write-Host ($env:computername.ToLower() + ",$vm_name - creating VHDs - ERROR")
        Exit
    }

    # make the VM and get base objects
    Try {
        Write-Host ($env:computername.ToLower() + ",$vm_name - creating VM")
        $vm = New-VM -Computer $hv_name -VMName $vm_name -Generation 2 -MemoryStartupBytes $vm_ram -VHDPath $hd_path_os -SwitchName $hv_switch
        $vm | Set-VMProcessor -Count 4 -ExposeVirtualizationExtensions $true
 
    } Catch {
        Write-Host ($env:computername.ToLower() + ",$vm_name - creating VM - ERROR")
        Exit
    }
 
    # run through network CSV to configure network adapaters
    Import-Csv -Path $ash_map_network | Where-Object {$_.Host -eq $vm_name} | ForEach-Object {
        # get values from CSV
        $nic_name = $_.Name
        $nic_mode = $_.Mode
        $nic_vlan = $_.Vlan

        # NICs with no gateway are added
        If ($nic_name -eq $nic_1st) {
            Write-Host ($env:computername.ToLower() + ",$vm_name - updating original NIC: " + $nic_name)
            # find the original (untagged) adapter
            $vm_nic = (Get-VMNetworkAdapterVlan -VM $vm | Where-Object {$_.OperationMode -eq "Untagged"}).ParentAdapter
            # rename the original adapter
            Rename-VMNetworkAdapter -VMNetworkAdapter $vm_nic -NewName $nic_name
            # update the original adapter with the VLAN 
            Set-VMNetworkAdapterVlan -VMNetworkAdapter $vm_nic -Access -VlanId $nic_vlan
            # set the original adapter as the first boot device for the VM
            Set-VMFirmware -VM $vm -FirstBootdevice $vm_nic
        }
        # NICs with a gateway map to the original NIC and are updated
        Else {
            # set the NIC port mode
            If ($nic_mode -eq "Trunk") {
                Write-Host ($env:computername.ToLower() + ",$vm_name - adding trunked NIC: " + $nic_name)
                $vm | Add-VMNetworkAdapter -Name $nic_name -SwitchName $hv_switch -PassThru | Set-VMNetworkAdapterVlan -Trunk -NativeVlanId 1 -AllowedVlanIdList 1-4094
            }
            Else {
                Write-Host ($env:computername.ToLower() + ",$vm_name - adding access NIC: " + $nic_name)
                $vm | Add-VMNetworkAdapter -Name $nic_name -SwitchName $hv_switch -PassThru | Set-VMNetworkAdapterVlan -Access -VlanId $nic_vlan
            }
        }
    }
    
    # update all NICs
    Write-Host ($env:computername.ToLower() + ",$vm_name - updating all NICs")
    $vm_nic_all = $vm | Get-VMNetworkAdapter
    $vm_nic_all | Set-VMNetworkAdapter -AllowTeaming On -DeviceNaming On -MacAddressSpoofing On
 
    # set up storage
    Write-Host ($env:computername.ToLower() + ",$vm_name - adding SCSI controller")
    $vm_scsi = Add-VMScsiController -VM $vm -Passthru
    $hd_array | ForEach-Object {
        $hd_path_cl = $_.Path
        Write-Host ($env:computername.ToLower() + ",$vm_name - adding VHD: " + $hd_path_cl)
        # create new VHD and attach to VM
        $vm_scsi | Add-VMHardDiskDrive -Path $hd_path_cl
    }
 
    # add VM to cluster and start VM
    Write-Host ($env:computername.ToLower() + ",$vm_name - adding VM to cluster: " + $hv_cluster)
    $cl_group = Add-ClusterVirtualMachineRole -Cluster $hv_cluster -VMName $vm_name 
    Write-Host ($env:computername.ToLower() + ",$vm_name - setting default cluster node")
    $cl_group | Set-ClusterOwnerNode -Owners $hv_name  
    Write-Host ($env:computername.ToLower() + ",$vm_name - starting VM")
    $cl_group | Start-ClusterGroup | Out-Null
}
