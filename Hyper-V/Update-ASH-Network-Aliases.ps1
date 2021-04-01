# set the file locations
$hostname_vm = [System.Net.Dns]::GetHostName().ToLower()
$folder_temp = [System.Environment]::GetEnvironmentVariable('TEMP','Machine')
$log_aliases = ($folder_temp + '\hv-setup\ash-log-aliases.txt')

# start logging
Start-Transcript -Path $log_aliases -Append -Force

# get the adapters that are a hardware device to exclude virtual adapters
Get-NetAdapter | Where-Object {$_.HardwareInterface} | ForEach-Object {
    # set base names
    $nic_old = ($_).Name
    $nic_new = $null

     # try to build the name from slot and port information
     $nic_hwi = ($_ | Get-NetAdapterHardwareInfo -ErrorAction SilentlyContinue)
     If ($nic_hwi.SlotNumber) {
         $nic_new = ("SLOT " + $nic_hwi.SlotNumber + " Port " + ($nic_hwi.FunctionNumber + 1))
         $nic_new_via = "slot/port number"
     }
 
    # try to build the name from PCI device label
    $nic_pci = ($_ | Get-NetAdapterHardwareInfo -ErrorAction SilentlyContinue).PciDeviceLabelString
    If ($nic_pci) {
        $nic_new = $nic_pci
        $nic_new_via = "PCI device label"
    }
 
    # try to build the name from Hyper-V 
    $nic_adv = ($_ | Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue | Where-Object {$_.RegistryKeyword -eq "HyperVNetworkAdapterName"}).DisplayValue
    If ($nic_adv) {
        $nic_new = $nic_adv
        $nic_new_via = "Hyper-V"
    }

    # if the new name was generated...
    If ($nic_new) {
        If ($nic_new -ne $nic_old) {
            # if new is different from old, set the NIC and declare the source
            Write-Host ($hostname_vm + " - '" + $nic_old + "' renamed to '" + $nic_new + "' via " + $nic_new_via)
            Rename-NetAdapter -Name $nic_old -NewName $nic_new
        } Else {
            # if new is the same as old, declare and move on
            Write-Host ($hostname_vm + " - '" + $nic_old + "' NOT renamed; generated name matches current name")
        }
    } Else {
        # if new name was not generated...
        Write-Host ($hostname_vm + " - '" + $nic_old + "' NOT renamed; could not generate name")
    }
}

# stop logging
Stop-Transcript