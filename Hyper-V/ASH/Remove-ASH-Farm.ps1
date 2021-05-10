# set the file locations
$ash_map_cluster = '.\ash-map-cluster.txt'

# get AD objects
$ad = Get-ADDomain

# set VM strings
$vm_cluster = 'cl2'

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
        Write-Host ($env:computername.ToLower() + ",$vm_name - removing cluster resource...")
        $vm_cl | Remove-ClusterGroup -RemoveResources -Force
    }
    Else {
        Write-Host ($env:computername.ToLower() + ",$vm_name - ...cluster resource not found")
        $hv_host = $hv_name
    }
    
    # find the VM via the host
    Write-Host ($env:computername.ToLower() + ",$vm_name - checking for VM on host: " + $hv_host)
    $vm = Get-VM -ComputerName $hv_host | Where-Object {$_.Name -eq $vm_name}
    If ($vm) {
        # stop and remove the VM from the host
        Write-Host ($env:computername.ToLower() + ",$vm_name - removing VM from host...")
        If ($vm.State -ne "Off") {
            $vm | Stop-VM -TurnOff
        }
        $vm | Get-VMHardDiskDrive | Remove-VMHardDiskDrive
        $vm | Remove-VM -Force -Confirm:$false
    }
    Else {
        Write-Host ($env:computername.ToLower() + ",$vm_name - ...VM not found")
    }

    # rotate CSVs to clear any locks
    Write-Host ($env:computername.ToLower() + ",$vm_name - moving CSVs to unlock VM files...")
    Get-ClusterSharedVolume -Cluster $hv_cluster | Move-ClusterSharedVolume | Out-Null
    Write-Host ($env:computername.ToLower() + ",$vm_name - ...CSVs moved")

    # clean up hard drives
    Write-Host ($env:computername.ToLower() + ",$vm_name - checking for VM files on host")
    $hd_path = ("\\" + $hv_host + "\" + (Get-VMHost -ComputerName $hv_host).VirtualHardDiskPath -replace '\:','$')
    $vm_file = Get-ChildItem -Path $hd_path -Filter ($vm_name + "*") 
    If ($vm_file) {
        Write-Host ($env:computername.ToLower() + ",$vm_name - removing VM files...")
        $vm_file | Remove-Item -Force -Confirm:$false
    }
    Else {
        Write-Host ($env:computername.ToLower() + ",$vm_name - ...VM files not found")
    }

    # remove AD object
    Write-Host ($env:computername.ToLower() + ",$vm_name - checking for VM in AD")
    $vm_ad = Get-ADObject -Filter "Name -eq '$($vm_name)'"
    If ($vm_ad) {
        Write-Host ($env:computername.ToLower() + ",$vm_name - removing AD objects...")
        $vm_ad | Remove-ADObject -Recursive -Confirm:$false
    }
    Else {
        Write-Host ($env:computername.ToLower() + ",$vm_name - ...AD objects not found")
    }

    # remove node DNS objects
    Write-Host ($env:computername.ToLower() + ",$vm_name - checking for VM in DNS")
    $vm_dns = Get-DnsServerResourceRecord -ZoneName $ad.DnsRoot -ComputerName $ad.PDCEmulator -RRType A | Where-Object {$_.HostName -like $vm_name}
    If ($vm_dns) {
        Write-Host ($env:computername.ToLower() + ",$vm_name - removing DNS records...")
        $vm_dns | Remove-DnsServerResourceRecord -ZoneName $ad.DNSRoot -ComputerName $ad.PDCEmulator -Force
    }
    Else {
        Write-Host ($env:computername.ToLower() + ",$vm_name - ...DNS records not found")
    }
}

# reset cluster AD object
$ad_newpass = -join ((1..64) | ForEach-Object {Get-Random -Minimum 33 -Maximum 126 | ForEach-Object {[char]$_}})
$ad_cluster = Get-ADComputer -Identity $vm_cluster
$ad_cluster | Disable-ADAccount
$ad_cluster | Set-ADAccountPassword -Reset -NewPassword (ConvertTo-SecureString -String $ad_newpass -AsPlainText -Force)
