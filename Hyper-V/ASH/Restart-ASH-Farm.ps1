# set the file locations
$ash_map_cluster = '.\ash-map-cluster.txt'

# process the cluster mapping file
Import-Csv -Path $ash_map_cluster | ForEach-Object {
    # get base strings for this pass
    $hv_cluster = $_.Cluster
    $vm_name = $_.Host

    # declare start
    Write-Host ("======================== $vm_name ========================")
    
    # get cluster 
    $vm_group = (Get-ClusterGroup -Cluster $hv_cluster -Name $vm_name) | Where-Object {$_.GroupType -eq "VirtualMachine"}

    # get the VM and owner
    Write-Host ($env:computername.ToLower() + "," + $vm_group.OwnerNode + ",$vm_name - found host: " + $vm_group.OwnerNode)
    $vm = Get-VM -ComputerName $vm_group.OwnerNode -Name $vm_name
    
    # check the VM state
    Write-Host ($env:computername.ToLower() + "," + $vm_group.OwnerNode + ",$vm_name - found VM state: " + $vm.State)
    switch ($vm.state) {
        # skip turning off vm
        "Off" {
            Write-Host ($env:computername.ToLower() + "," + $vm_group.OwnerNode + ",$vm_name - VM already off?")
        }
        # turn off vm
        Default {
            Write-Host ($env:computername.ToLower() + "," + $vm_group.OwnerNode + ",$vm_name - stopping VM")
            $vm | Stop-VM -TurnOff -Force
        }
    }

    # restore the VM to previous snapshot
    Write-Host ($env:computername.ToLower() + "," + $vm_group.OwnerNode + ",$vm_name - restoring VM snapshot")
    $vm | Get-VMSnapshot | Select-Object -Last 1 | Restore-VMSnapshot -Confirm:$false
    
    # turn on the VM
    Write-Host ($env:computername.ToLower() + "," + $vm_group.OwnerNode + ",$vm_name - starting VM")
    $vm | Start-VM
}