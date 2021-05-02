# set the file locations
$hostname_vm = [System.Net.Dns]::GetHostName().ToLower()
$folder_temp = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')
$path_hv_log = Join-Path -Path $folder_temp -ChildPath 'hv-setup'
$log_vswitch = Join-Path -Path $path_hv_log -ChildPath 'ash-log-virtual.txt'
$map_network = Join-Path -Path $path_hv_log -ChildPath 'ash-map-network.txt'

# check path
If (!(Test-Path -Path $path_hv_log)) { New-Item -ItemType Directory -Path $path_hv_log }

# start logging
Start-Transcript -Path $log_vswitch -Append -Force

# import CSVs
$csv_network = Import-Csv -Path $map_network | Where-Object { $_.Host -eq $hostname_vm }

# check for the cluster
$cluster = $null
$cluster = Get-Cluster
If ($cluster) {
    Write-Host ("$hostname_vm - cluster found, will create management switch and virtual adapters")
}
Else {
    Write-Host ("$hostname_vm - cluster not found, create management switch and skip virtual adapters")
}

# get the unique switches from the mapping file
$csv_network | Sort-Object Switch -Unique | ForEach-Object {
    # load variables
    $switch_name = $_.Switch

    # declare start
    Write-Host ($hostname_vm + ' - found switch from CSV: ' + $switch_name)

    # if the node is in a cluster or the switch type is management, 
    If ($cluster -or $switch_name -eq 'Management') {
        Write-Host ("$hostname_vm,$switch_name - host is clustered or switch is Management, checking virtual switch")
        # get the array of requested NICs for the switch
        $p_nic_array = @()
        $p_nic_names = $null
        $p_nic_names = $csv_network | Where-Object { $_.Switch -eq $switch_name } | Sort-Object Adapter
        $p_nic_names | ForEach-Object {
            # get network adapters matching NIC names
            $p_nic_name = $_.Adapter
            Write-Host ("$hostname_vm,$switch_name - checking physical NIC: " + $p_nic_name)
            $p_nic = $null
            $p_nic = Get-NetAdapter -Physical | Where-Object { $_.InterfaceAlias -eq $p_nic_name }
            If ($p_nic) {
                Write-Host ("$hostname_vm,$switch_name - found physical NIC: " + $p_nic_name)
                $p_nic_array += $p_nic
            }
            Else {
                Write-Host ("$hostname_vm,$switch_name - physical NIC was NOT found: " + $p_nic_name)
            }
        }

        # check for switch that matches name from CSV
        Write-Host ("$hostname_vm,$switch_name - checking for switch...")
        $vswitch = $null
        $vswitch = Get-VMSwitchTeam | Where-Object { $_.Name -eq $switch_name }
        If ($vswitch) {
            # if switch found, check NICs in switch
            Write-Host ("$hostname_vm,$switch_name - found switch: $switch_name")
            $p_nic_array | ForEach-Object {
                $p_nic = $_
                Write-Host ("$hostname_vm,$switch_name - checking adapter: " + $p_nic.InterfaceAlias)
                # if the NIC exists, check if NIC is already in the switch team
                If ($vswitch.NetAdapterInterfaceGuid -match [guid]$p_nic.InterfaceGuid) {
                    # if so, declare and move on
                    Write-Host ("$hostname_vm,$switch_name - adapter already in the switch team")
                }
                Else {
                    # if not, add NIC to switch
                    Write-Host ("$hostname_vm,$switch_name - adapter not in the switch team, adding...")
                    Add-VMSwitchTeamMember -SwitchName $switch_name -NetAdapterName $p_nic.InterfaceAlias
                }
            }
            Write-Host ("$hostname_vm,$switch_name - adapters verified, checking switch type...")
            If ($switch_name -eq 'Management') {
                # verify the management switch has a virtual NIC
                Write-Host ("$hostname_vm,$switch_name - management switch found, checking for management adapter(s)...")
                $nic_mgmt = $null
                $nic_mgmt = Get-VMNetworkAdapter -ManagementOS | Where-Object { $_.SwitchName -eq $switch_name }
                # look for network adapters attached to the management switch...
                If ($nic_mgmt) {
                    Write-Host ("$hostname_vm,$switch_name - found " + $nic_mgmt.Count + " management adapter(s)")
                }
                Else {
                    # if no, create a network adapter
                    Write-Host ("$hostname_vm,$switch_name - no management adapters found, creating initial management adapater...")
                    $nic_mgmt = Add-VMNetworkAdapter -ManagementOS -SwitchName $switch_name -Name $switch_name
                }
            }
            Else {
                Write-Host ("$hostname_vm,$switch_name - non-management switch found, skipping management adapter check...")
            }
        }
        Else {
            # if switch NOT found check the type of switch and if the cluster exists
            Write-Host ("$hostname_vm,$switch_name - switch not found, checking switch type...")
            If ($switch_name -eq 'Management') {
                # if switch NOT found and we SHOULD make the virtual network adapater, create switch with NICs and default adapter
                Write-Host ("$hostname_vm,$switch_name - switch type is management, creating switch and virtual adapter with: " + $p_nic_array[0].Name)
                $vswitch = New-VMSwitch -Name $switch_name -NetAdapterName $p_nic_array[0].Name -EnableEmbeddedTeaming $true -MinimumBandwidthMode Weight -AllowManagementOS $true
                For ($i = 1; $i -lt $p_nic_array.Count; $i++) {
                    Write-Host ("$hostname_vm,$switch_name - expanding switch with: " + $p_nic_array[$i].Name)
                    Add-VMSwitchTeamMember -SwitchName $switch_name -NetAdapterName $p_nic_array[$i].Name
                }
            }
            ElseIf ($cluster) {
                # if switch NOT found and we should NOT make the virtual network adapater, create switch with NICs without adapter
                Write-Host ("$hostname_vm,$switch_name - switch type is not management and cluster exists, creating empty switch with: " + $p_nic_array[0].Name)
                $vswitch = New-VMSwitch -Name $switch_name -NetAdapterName $p_nic_array[0].Name -EnableEmbeddedTeaming $true -MinimumBandwidthMode Weight
                For ($i = 1; $i -lt $p_nic_array.Count; $i++) {
                    Write-Host ("$hostname_vm,$switch_name - expanding switch with: " + $p_nic_array[$i].Name)
                    Add-VMSwitchTeamMember -SwitchName $switch_name -NetAdapterName $p_nic_array[$i].Name
                }
            }
            Else {
                # if switch NOT found and we should NOT make the virtual network adapater, declare and move on
                Write-Host ("$hostname_vm,$switch_name - switch type is not management and no cluster exists, skipping switch creation")
            }
        }
    }
    Else {
        Write-Host ("$hostname_vm,$switch_name - host not clustered or switch is not Management, skipping virtual switch")
    }
}

# get the virtual NICs from the mapping file
$csv_network | Where-Object { $_.vNIC } | ForEach-Object {
    # load variables
    $switch_name = $_.Switch
    $adapter_name = $_.Adapter
    $virtual_name = $_.vNIC
    $virtual_addr = $_.Address
    $virtual_mask = $_.Mask
    $virtual_vlan = $_.VLAN

    # check the state of the node against the switch type
    If ($cluster -or $switch_name -eq 'Management') {
        # verify that any virtual NICs have a preference set
        Write-Host ("$hostname_vm,$switch_name,$virtual_name - host is clustered or switch is Management, checking for virtual adapter(s)...")
        $nic_virtual = $null
        $nic_virtual = Get-VMNetworkAdapter -ManagementOS | Where-Object { $_.Name -eq $virtual_name }
        # look for network adapters attached to the storage switch...
        If ($nic_virtual) {
            # declare virtual adapter exists
            Write-Host ("$hostname_vm,$switch_name,$virtual_name - virtual adapter found by name, moving on...")
        }
        Else {
            Write-Host ("$hostname_vm,$switch_name,$virtual_name - virtual adapter not found by name, checking for virtual adapter by switch...")
            $nic_virtual = Get-VMNetworkAdapter -ManagementOS | Where-Object { $_.Name -match $switch_name } | Select-Object -First 1
            If ($nic_virtual) {
                # update virtual adapter after being found by switch name
                Write-Host ("$hostname_vm,$switch_name,$virtual_name - virtual adapter found by switch, renaming network adapter...")
                $nic_virtual | Rename-VMNetworkAdapter -NewName $virtual_name
            }
            Else {
                # create virtual adapter after being found by switch name
                Write-Host ("$hostname_vm,$switch_name,$virtual_name - virtual adapter not found by switch, creating then renaming...")
                $nic_virtual = Add-VMNetworkAdapter -ManagementOS -SwitchName $switch_name -Name $switch_name -PassThru
                $nic_virtual | Rename-VMNetworkAdapter -NewName $virtual_name
            }
        }

        # set the virtual adapter VLAN modes
        Write-Host ("$hostname_vm,$switch_name,$virtual_name - force virtual adapter to Untagged VLAN mode")
        $nic_virtual | Set-VMNetworkAdapterVlan -Untagged
        If ($switch_name -ne 'Management') {
            Write-Host ("$hostname_vm,$switch_name,$virtual_name - set virtual adapter to pass VLAN tags to switch")
            $nic_virtual | Set-VMNetworkAdapter -IeeePriorityTag On
            Write-Host ("$hostname_vm,$switch_name,$virtual_name - set virtual adapter to VLAN isolation mode with VLAN ID")
            $nic_virtual | Set-VMNetworkAdapterIsolation -IsolationMode VLAN -AllowUntaggedTraffic $true -DefaultIsolationID $virtual_vlan
        }

        # update the name of the network adapter to remove the vEthernet nonsense
        $nic_network = $null
        $nic_network = Get-NetAdapter | Where-Object { $_.InterfaceAlias -match $virtual_name }
        If ($nic_network) {
            Write-Host ("$hostname_vm,$switch_name,$virtual_name - setting network adapter name")
            $nic_network | Rename-NetAdapter -NewName $virtual_name
            If ($switch_name -eq 'Management') {
                Write-Host ("$hostname_vm,$switch_name,$virtual_name - network adapter is management, enabling DNS registration")
                $nic_network | Set-DnsClient -RegisterThisConnectionsAddress $true
            }
            Else {
                Write-Host ("$hostname_vm,$switch_name,$virtual_name - network adapter not management, disabling DNS registration")
                $nic_network | Set-DnsClient -RegisterThisConnectionsAddress $false
                Write-Host ("$hostname_vm,$switch_name,$virtual_name - network adapter not management, setting Jumbo Packet size")
                $nic_network | Get-NetAdapterAdvancedProperty -RegistryKeyword '*JumboPacket' | Set-NetAdapterAdvancedProperty -RegistryValue 9014
            }
        }

        # enable RDMA on the network adapter
        $nic_rdma = $null
        $nic_rdma = Get-NetAdapterRdma | Where-Object { $_.Name -match $virtual_name }
        If ($nic_rdma) {
            If ($nic_rdma.Enabled) {
                Write-Host ("$hostname_vm,$switch_name,$virtual_name - network adapter is RDMA enabled")
            }
            Else {
                Write-Host ("$hostname_vm,$switch_name,$virtual_name - network adapter is not RDMA enabled, fixing...")
                $nic_rdma | Enable-NetAdapterRdma
                Start-Sleep -Seconds 15
            }
        }

        # enable QoS on the network adapter
        $nic_qos = $null
        $nic_qos = Get-NetAdapterQos | Where-Object { $_.Name -match $virtual_name }
        If ($nic_qos) {
            If ($nic_qos.Enabled) {
                Write-Host ("$hostname_vm,$switch_name,$virtual_name - network adapter is QoS enabled")
            }
            Else {
                Write-Host ("$hostname_vm,$switch_name,$virtual_name - network adapter is not QoS enabled, fixing...")
                $nic_qos | Enable-NetAdapterQos
                Start-Sleep -Seconds 15
            }
        }

        # check the IP address on the networkadapter
        $nic_address = $null
        $nic_address = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -match $virtual_name }).IPv4Address
        If ($nic_address -eq $virtual_addr) {
            Write-Host ("$hostname_vm,$switch_name,$virtual_name - correct network adapter address found, skipping...")
        }
        ElseIf ($nic_address) {
            Write-Host ("$hostname_vm,$switch_name,$virtual_name - wrong network adapter address found: " + $nic_address)
            $nic_address | Remove-NetIPAddress -Confirm:$false
            Write-Host ("$hostname_vm,$switch_name,$virtual_name - resetting network adapter address...")
            $nic_network | New-NetIPAddress -AddressFamily IPv4 -IPAddress $virtual_addr -PrefixLength $virtual_mask | Out-Null
        }
        Else {
            Write-Host ("$hostname_vm,$switch_name,$virtual_name - network adapter address not found, setting...")
            $nic_network | New-NetIPAddress -AddressFamily IPv4 -IPAddress $virtual_addr -PrefixLength $virtual_mask | Out-Null
        }

        # force set the team mapping
        Write-Host ("$hostname_vm,$switch_name,$virtual_name - setting team mapping...")
        Set-VMNetworkAdapterTeamMapping -ManagementOS -VMNetworkAdapterName $virtual_name -PhysicalNetAdapterName $adapter_name
    }
    Else {
        Write-Host ("$hostname_vm,$switch_name,$virtual_name - host not clustered or switch is not Management, skipping virtual adapter(s)...")
    }
}

# stop logging
Stop-Transcript
