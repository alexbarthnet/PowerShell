# set the file locations
$ash_map_cluster = '.\ash-map-cluster.txt'

# empty the array
$log_vm = @()
$log_vmnic = @()

# process the cluster mapping file
Import-Csv -Path $ash_map_cluster | ForEach-Object {
    # get base strings for this pass
    $hv_cluster = $_.Cluster
    $hv_name = $_.Node
    $vm_name = $_.Host

    # declare start
    Write-Host ("======================== $vm_name ========================")

    # find the VM via the cluster
    Write-Host ($env:computername.ToLower() + ",$vm_name - checking for VM in cluster: " + $hv_cluster)
    $vm_cl = Get-ClusterGroup -Cluster $hv_cluster | Where-Object {$_.Name -eq $vm_name -and $_.GroupType -eq "VirtualMachine"}
    If ($vm_cl) {
        # stop and remove the resource group from the cluster
        $hv_host = $vm_cl.OwnerNode
        Write-Host ($env:computername.ToLower() + ",$vm_name - VM found in cluster, host set to current node...")
    }
    Else {
        Write-Host ($env:computername.ToLower() + ",$vm_name - VM not in cluster, host set to default")
        $hv_host = $hv_name
    }
    
    # find the VM via the host
    Write-Host ($env:computername.ToLower() + ",$vm_name - checking for VM on host: " + $hv_host)
    $vm = Get-VM -ComputerName $hv_host | Where-Object {$_.Name -eq $vm_name}
    If ($vm) {
        # get vm
        Write-Host ($env:computername.ToLower() + ",$vm_name - VM found, getting VM information")
        
        # get VM information
        Write-Host ($env:computername.ToLower() + ",$vm_name - Retrieving VM information")
        $out_vm = $out_vmnic = Invoke-Command -ComputerName $hv_host -ScriptBlock {
            Get-VM -Name $using:vm_name
        }
        $log_vm += $out_vm

        # get VM network information
        Write-Host ($env:computername.ToLower() + ",$vm_name - Retrieving VM networking")
        $out_vm = $out_vmnic = Invoke-Command -ComputerName $hv_host -ScriptBlock {
            $vm_object = @()
            $vm = Get-VM -Name $using:vm_name
            $vm_nic = $vm | Get-VMNetworkAdapter
            $vm_nic | ForEach-Object { 
                $nic = $_; 
                $vlan = $nic | Get-VMNetworkAdapterVlan
                If ($vlan.OperationMode -eq "Trunk"){
                    $vm_vlans = $vlan.NativeVlanId.ToString() + "," + $vlan.AllowedVlanIdListString
                } Else {
                    $vm_vlans = $vlan.AccessVlanId.ToString()
                }
                $vm_object += [pscustomobject]@{
                    VMName = $nic.VMName
                    Adapter = $nic.Name;
                    SwitchName = $nic.SwitchName
                    Mode = $vlan.OperationMode
                    Vlans = $vm_vlans
                    MacAddress = $nic.MacAddress
                    IPAddresses = $nic.IPAddresses | Where-Object {$_ -notmatch ":"}
                } 
            }
            $vm_object
        }
        $log_vmnic += $out_vmnic
    }
    Else {
        Write-Host ($env:computername.ToLower() + ",$vm_name - ...VM not found")
    }
}

# declare results
Write-Host ""
Write-Host "======================== Results ========================"
$log_vm | Format-Table PSComputerName,Name,State,@{Label = 'CPU %';Expression = {$_.CPUUsage}},@{Label = 'Memory';Expression = {$_.MemoryAssigned/1MB}},@{Label = 'Uptime';Expression = {$_.Uptime.ToString()}},Status,Version
$log_vmnic | Format-Table PSComputerName,VMName,Adapter,SwitchName,Mode,VlanList,MacAddress,IPAddresses