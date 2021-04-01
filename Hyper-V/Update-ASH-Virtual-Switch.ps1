# set the file locations
$hostname_vm = [System.Net.Dns]::GetHostName().ToLower()
$folder_temp = [System.Environment]::GetEnvironmentVariable('TEMP','Machine')
$map_network = ($folder_temp + '\hv-setup\ash-map-network.txt')
$log_vswitch = ($folder_temp + '\hv-setup\ash-log-vswitch.txt')

# start logging
Start-Transcript -Path $log_vswitch -Append -Force

# import CSVs
$csv_network = Import-Csv -Path $map_network | Where-Object {$_.Host -eq $hostname_vm}

# get the vswitch mapping file
$csv_network | Sort-Object Switch -Unique | ForEach-Object {
    # load variables
    $switch_name = $_.Switch
    $switch_type = $_.Type

    # declare start
    Write-Host ($hostname_vm + " - found switch from CSV: " + $switch_name)

    # get the array of requested NICs for the switch
    $p_nic_array = @()
    $p_nic_names = $null
    $p_nic_names = $csv_network | Where-Object {$_.Switch -eq $switch_name} | Sort-Object Adapter
    $p_nic_names | ForEach-Object {
        # get network adapters matching NIC names
        $p_nic_name = $_.Adapter
        Write-Host ($hostname_vm + "," + $switch_name + " - looking for physical NIC: " + $p_nic_name)
        $p_nic = $null
        $p_nic = Get-NetAdapter -Physical | Where-Object {$_.InterfaceAlias -eq $p_nic_name}
        If ($p_nic) {
            Write-Host ($hostname_vm + "," + $switch_name + " - found physical NIC: " + $p_nic_name)
            $p_nic_array += $p_nic
        } Else {
            Write-Host ($hostname_vm + "," + $switch_name + " - physical NIC was NOT found: " + $p_nic_name)
        }
    }

    # check for switch that matches name from CSV
    Write-Host ($hostname_vm + "," + $switch_name + " - checking for switch...")
    $vswitch = $null
    $vswitch = Get-VMSwitchTeam | Where-Object {$_.Name -eq $switch_name}
    If ($vswitch) {
        # if switch found, check NICs in switch
        Write-Host ($hostname_vm + "," + $switch_name + " - found switch: " + $vswitch.Name)
        $p_nic_array | ForEach-Object {
            $p_nic = $_
            Write-Host ($hostname_vm + "," + $vswitch.Name + " - found adapter: " + $p_nic.InterfaceAlias)
            # if the NIC exists, check if NIC is already in the switch team
            If ($vswitch.NetAdapterInterfaceGuid -match [guid]$p_nic.InterfaceGuid) {
                # if so, declare and move on
                Write-Host ($hostname_vm + "," + $vswitch.Name + " - adapter already in the switch team")
            } Else {
                # if not, add NIC to switch
                Write-Host ($hostname_vm + "," + $vswitch.Name + " - adapter not in the switch team, adding...")
                Add-VMSwitchTeamMember -SwitchName $switch_name -NetAdapterName $p_nic.InterfaceAlias
            }
        }
        # verify the management switch has a virtual NIC
        Write-Host ($hostname_vm + "," + $switch_name + " - checking for management adapter(s)...")
        $nic_mgmt = $null
        $nic_mgmt = Get-VMNetworkAdapter -ManagementOS | Where-Object {$_.SwitchName -eq $switch_name}
        # look for network adapters attached to the management switch...
        If ($nic_mgmt) {
            Write-Host ($hostname_vm + "," + $switch_name + " - found " + $nic_mgmt.Count + " management adapter(s)")
        } Else {
            # if no, create a network adapter
            Write-Host ($hostname_vm + "," + $switch_name + " - no management adapters found, creating initial management adapater...")
            $nic_mgmt = Add-VMNetworkAdapter -ManagementOS -SwitchName $switch_name -Name $switch_name
        }
    } Else {
        # if switch NOT found and we SHOULD make the virtual network adapater, create switch with NICs
        Write-Host ($hostname_vm + "," + $switch_name + " - switch not found, checking switch type...")
        If ($switch_type -eq "Management") {
            # if switch NOT found and we SHOULD make the virtual network adapater, create switch with NICs
            Write-Host ($hostname_vm + "," + $switch_name + " - switch type is management, creating switch and default adapter with: " + $p_nic_array[0].Name)
            $vswitch = New-VMSwitch -Name $switch_name -AllowManagementOS $true -NetAdapterName $p_nic_array[0].Name -EnableEmbeddedTeaming $true -EnableIov $true
            For ($i = 1; $i -lt $p_nic_array.Count; $i++) {
                Write-Host ($hostname_vm + "," + $switch_name + " - expanding management switch with: " + $p_nic_array[$i].Name)
                Add-VMSwitchTeamMember -SwitchName $switch_name -NetAdapterName $p_nic_array[$i].Name
            }
        } Else {
            # if switch NOT found and we should NOT make the virtual network adapater, declare and move on
            Write-Host ($hostname_vm + "," + $switch_name + " - switch type is not management, skipping switch creation")
        }
    }
}

# get the virtual NICs from the file
$csv_network | Where-Object {$_.vNIC} | ForEach-Object {
    # load variables
    $switch_name = $_.Switch
    $adapter_name = $_.Adapter
    $virtual_name = $_.vNIC

    # verify that any storage virtual NICs have a preference set
    Write-Host ($hostname_vm + "," + $switch_name + "," + $virtual_name + " - checking for storage adapter(s)...")
    $nic_smb = $null
    $nic_smb = Get-VMNetworkAdapter -ManagementOS | Where-Object {$_.Name -eq $virtual_name}
    # look for network adapters attached to the storage switch...
    If ($nic_smb) {
        Write-Host ($hostname_vm + "," + $switch_name + "," + $virtual_name + " - found storage adapter, setting team mapping...")
        $nic_smb | Set-VMNetworkAdapterTeamMapping -ManagementOS -VMNetworkAdapterName $virtual_name -PhysicalNetAdapterName $adapter_name
    } Else {
        # if no, create a network adapter
        Write-Host ($hostname_vm + "," + $switch_name + "," + $virtual_name + " - no storage adapter found, skipping...")
    }
}

# stop logging
Stop-Transcript
