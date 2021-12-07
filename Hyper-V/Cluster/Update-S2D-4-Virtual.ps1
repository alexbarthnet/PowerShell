# define the folders
$host_name = [System.Net.Dns]::GetHostName().ToLower()
$path_temp = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')
$path_logs = Join-Path -Path $path_temp -ChildPath 'hv-setup'

# verify the folders
If (!(Test-Path -Path $path_logs)) { New-Item -ItemType Directory -Path $path_logs }

# define the files
$log_virtual = Join-Path -Path $path_logs -ChildPath ('log-update-s2d-4-virtual-' + (Get-Date -Format FileDateTime) + '.txt')
$csv_network = Join-Path -Path $path_logs -ChildPath ($host_name + '-net.csv')

# start logging
Start-Transcript -Path $log_virtual -Append -Force

# verify the files
Write-Host ('Checking required files...')
$file_names = @($csv_network)
$file_names | ForEach-Object {
    If (Test-Path $_) {
        Write-Host ('...found required file: ' + $_)
    }
    Else {
        Write-Host ('...could not find required file: ' + $_)
        Write-Host ('...exiting!')
        Exit
    }
}

# check for the cluster
$cluster = $null
$cluster = Get-Service | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -ne 'Disabled' }
If ($cluster) {
    Write-Host ("$host_name - Cluster found, will create management switch and virtual adapters")
}
Else {
    Write-Host ("$host_name - Cluster not found, will create management switch and skip virtual adapters")
}

# import CSV
$map_network = Import-Csv -Path $csv_network | Where-Object { $_.Host -eq $host_name }

# get the VM paths from the network CSV
Write-Host ("$host_name - Processing VM storage settings...")
$map_network | Where-Object { $_.VmPath -and $_.VhdPath } | ForEach-Object {
    If ($cluster) {
        Write-Host ("$host_name - Host is clustered, configuring Hyper-V paths...")
        $host_vmpath = $_.VmPath
        $host_vhdpath = $_.VhdPath
        Write-Host ("$host_name - Setting Virtual Machine Path: " + $host_vmpath)
        Set-VMHost -VirtualMachinePath $host_vmpath
        Write-Host ("$host_name - Setting Virtual Hard Disk Path: " + $host_vhdpath)
        Set-VMHost -VirtualHardDiskPath $host_vhdpath
    }
    Else {
        Write-Host ("$host_name - Host is not clustered, skipping Hyper-V paths")
    }
}

# get the virtual switches from the network CSV
Write-Host ("$host_name - Processing virtual switch settings...")
$map_network | Sort-Object Switch -Unique | ForEach-Object {
    # load variables
    $vswitch_name = $_.Switch
    $cluster_name = $_.Cluster

    # check for cluster override
    If ($host_name -eq $cluster_name) {
        Write-Host ("$host_name - Host and cluster names match, treating host as clustered")
        $cluster = $cluster_name
    }

    # if the node is in a cluster or the switch type is management, 
    If ($cluster -or $vswitch_name -eq 'Management') {
        Write-Host ("$host_name,$vswitch_name - Switch is Management or host is clustered, checking virtual switch...")
        # get the array of requested NICs for the switch
        $pnic_array = @()
        $pnic_names = $null
        $pnic_names = $map_network | Where-Object { $_.Switch -eq $vswitch_name } | Sort-Object Adapter
        $pnic_names | ForEach-Object {
            # get network adapters matching NIC names
            $pnic_name = $_.Adapter
            Write-Host ("$host_name,$vswitch_name - Checking physical NIC: " + $pnic_name)
            $pnic = $null
            $pnic = Get-NetAdapter -Physical | Where-Object { $_.InterfaceAlias -eq $pnic_name }
            If ($pnic) {
                Write-Host ("$host_name,$vswitch_name - Found physical NIC: " + $pnic_name)
                $pnic_array += $pnic
            }
            Else {
                Write-Host ("$host_name,$vswitch_name - Physical NIC was NOT found: " + $pnic_name)
            }
        }

        # check for switch that matches name from CSV
        Write-Host ("$host_name,$vswitch_name - Checking for switch...")
        $vswitch = $null
        $vswitch = Get-VMSwitchTeam | Where-Object { $_.Name -eq $vswitch_name }
        If ($vswitch) {
            # if switch found, check NICs in switch
            Write-Host ("$host_name,$vswitch_name - Found switch: $vswitch_name")
            $pnic_array | ForEach-Object {
                $pnic = $_
                Write-Host ("$host_name,$vswitch_name - Checking adapter: " + $pnic.InterfaceAlias)
                # if the NIC exists, check if NIC is already in the switch team
                If ($vswitch.NetAdapterInterfaceGuid -match [guid]$pnic.InterfaceGuid) {
                    # if so, declare and move on
                    Write-Host ("$host_name,$vswitch_name - Adapter already in the switch team")
                }
                Else {
                    # if not, add NIC to switch
                    Write-Host ("$host_name,$vswitch_name - Adapter not in the switch team, adding...")
                    Add-VMSwitchTeamMember -SwitchName $vswitch_name -NetAdapterName $pnic.InterfaceAlias
                }
            }
            Write-Host ("$host_name,$vswitch_name - Adapters verified, checking switch type...")
            If ($vswitch_name -eq 'Management') {
                # verify the management switch has a virtual NIC
                Write-Host ("$host_name,$vswitch_name - Management switch found, checking for management adapter(s)...")
                $nic_mgmt = $null
                $nic_mgmt = Get-VMNetworkAdapter -ManagementOS | Where-Object { $_.SwitchName -eq $vswitch_name }
                # look for network adapters attached to the management switch...
                If ($nic_mgmt) {
                    Write-Host ("$host_name,$vswitch_name - Found " + $nic_mgmt.Count + ' management adapter(s)')
                }
                Else {
                    # if no, create a network adapter
                    Write-Host ("$host_name,$vswitch_name - No management adapters found, creating initial management adapater...")
                    $nic_mgmt = Add-VMNetworkAdapter -ManagementOS -SwitchName $vswitch_name -Name $vswitch_name
                }
            }
            Else {
                Write-Host ("$host_name,$vswitch_name - Non-management switch found, skipping management adapter check...")
            }
        }
        Else {
            # if switch NOT found check the type of switch and if the cluster exists
            Write-Host ("$host_name,$vswitch_name - Switch not found, checking switch type...")
            If ($pnic_array.Count -le 1) {
                # if only one physical NIC is defined to be in the switch, don't make a switch!
                Write-Host ("$host_name,$vswitch_name - Switch defined with only one physical NIC, skipping switch creation: " + $pnic_array[0].Name)
            }
            ElseIf ($vswitch_name -eq 'Management') {
                # if switch NOT found and we SHOULD make the virtual network adapater, create switch with NICs and default adapter
                Write-Host ("$host_name,$vswitch_name - Switch is Management, creating switch and virtual adapter with: " + $pnic_array[0].Name)
                $vswitch = New-VMSwitch -Name $vswitch_name -NetAdapterName $pnic_array[0].Name -EnableEmbeddedTeaming $true -MinimumBandwidthMode Weight -AllowManagementOS $true
                For ($i = 1; $i -lt $pnic_array.Count; $i++) {
                    Write-Host ("$host_name,$vswitch_name - Expanding switch with: " + $pnic_array[$i].Name)
                    Add-VMSwitchTeamMember -SwitchName $vswitch_name -NetAdapterName $pnic_array[$i].Name
                }
            }
            ElseIf ($cluster) {
                # if switch NOT found and we should NOT make the virtual network adapater, create switch with NICs without adapter
                Write-Host ("$host_name,$vswitch_name - Switch is not Management and host is clustered, creating empty switch with: " + $pnic_array[0].Name)
                $vswitch = New-VMSwitch -Name $vswitch_name -NetAdapterName $pnic_array[0].Name -EnableEmbeddedTeaming $true -MinimumBandwidthMode Weight -AllowManagementOS $false
                For ($i = 1; $i -lt $pnic_array.Count; $i++) {
                    Write-Host ("$host_name,$vswitch_name - Expanding switch with: " + $pnic_array[$i].Name)
                    Add-VMSwitchTeamMember -SwitchName $vswitch_name -NetAdapterName $pnic_array[$i].Name
                }
            }
            Else {
                # if switch NOT found and we should NOT make the virtual network adapater, declare and move on
                Write-Host ("$host_name,$vswitch_name - Switch is not Management and host is not clustered, skipping switch creation")
            }
        }
    }
    Else {
        Write-Host ("$host_name,$vswitch_name - Switch is not Management and host is not clustered, skipping virtual switch")
    }
}

# get the virtual NICs from the network CSV
Write-Host ("$host_name - Processing virtual NIC settings...")
$map_network | Where-Object { $_.vNIC } | ForEach-Object {
    # load variables
    $pnic_name = $_.Adapter
    $vnic_name = $_.vNIC
    $vnic_addr = $_.Address
    $vnic_mask = $_.Mask
    $vnic_gway = $_.Gateway
    $vnic_vlan = $_.VLAN
    $vswitch_name = $_.Switch

    # check the state of the node against the switch type
    If ($cluster -or $vnic_name -eq 'Management') {
        # verify that the vswitch exists
        Write-Host ("$host_name,$vswitch_name,$vnic_name - Switch is Management or host is clustered, checking for virtual switch ...")
        $vswitch = $null
        $vswitch = Get-VMSwitchTeam | Where-Object { $_.Name -eq $vswitch_name }
        If ($vswitch) {
            # verify that any virtual NICs have a preference set
            Write-Host ("$host_name,$vswitch_name,$vnic_name - Switch found by name, checking for virtual adapter(s)...")
            $nic_virtual = $null
            $nic_virtual = Get-VMNetworkAdapter -ManagementOS | Where-Object { $_.Name -match $vnic_name }
            # look for network adapters attached to the storage switch...
            If ($nic_virtual) {
                # declare virtual adapter exists
                Write-Host ("$host_name,$vswitch_name,$vnic_name - Virtual adapter found by name, moving on...")
            }
            Else {
                # create virtual adapter after being found by switch name
                Write-Host ("$host_name,$vswitch_name,$vnic_name - Virtual adapter not found by name, creating then renaming...")
                $nic_virtual = Add-VMNetworkAdapter -ManagementOS -SwitchName $vswitch_name -Name $vnic_name -PassThru
                $nic_virtual = $nic_virtual | Rename-VMNetworkAdapter -NewName $vnic_name -PassThru
            }

            # set the virtual adapter VLAN modes
            Write-Host ("$host_name,$vswitch_name,$vnic_name - Virtual adapter configured to permit QoS tagging")
            $nic_virtual | Set-VMNetworkAdapter -IeeePriorityTag On
            Write-Host ("$host_name,$vswitch_name,$vnic_name - Virtual adapter VLAN mode set to Untagged")
            $nic_virtual | Set-VMNetworkAdapterVlan -Untagged
            If ($vnic_name -ne 'Management') {
                Write-Host ("$host_name,$vswitch_name,$vnic_name - Virtual adapter isolation mode set to VLAN and default ID set to VLAN ID")
                $nic_virtual | Set-VMNetworkAdapterIsolation -IsolationMode VLAN -AllowUntaggedTraffic $true -DefaultIsolationID $vnic_vlan
            }

            # update the name of the network adapter to remove the vEthernet nonsense
            $nic_network = $null
            $nic_network = Get-NetAdapter | Where-Object { $_.InterfaceAlias -match $vnic_name }
            If ($nic_network) {
                # check complete name of network adapter
                If ($nic_network.InterfaceAlias -eq $vnic_name) {
                    Write-Host ("$host_name,$vswitch_name,$vnic_name - Network adapter name is correct")
                }
                Else {
                    Write-Host ("$host_name,$vswitch_name,$vnic_name - Network adapter name is almost correct, fixing...")
                    $nic_network = $nic_network | Rename-NetAdapter -NewName $vnic_name -PassThru
                }
                # check for DNS registration
                If ($vnic_name -match 'Manage') {
                    Write-Host ("$host_name,$vswitch_name,$vnic_name - DNS registration enabled for management NIC")
                    $nic_network | Set-DnsClient -RegisterThisConnectionsAddress $true
                }
                Else {
                    Write-Host ("$host_name,$vswitch_name,$vnic_name - DNS registration disabled for non-management NIC")
                    $nic_network | Set-DnsClient -RegisterThisConnectionsAddress $false
                }
            }

            # check jumbo packet settings
            $nic_size = $null
            $nic_size = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $vnic_name -and $_.RegistryKeyword -eq '*JumboPacket' }
            If ($nic_size) {
                Write-Host ("$host_name,$vswitch_name,$vnic_name - Jumbo Packet found: " + $nic_size.DisplayValue)
                If ($vnic_name -match 'Manage') {
                    If ($nic_size.RegistryValue -ne 1514) {
                        Write-Host ("$host_name,$vswitch_name,$vnic_name - Jumbo Packet on Management NIC not set to '1514', fixing...")
                        Set-NetAdapterAdvancedProperty -Name $vnic_name -RegistryKeyword '*JumboPacket' -RegistryValue 1514    
                    }
                }
                Else {
                    If ($nic_size.RegistryValue -ne 9014) {
                        Write-Host ("$host_name,$vswitch_name,$vnic_name - Jumbo Packet on non-Management NIC not set to '9014', fixing...")
                        Set-NetAdapterAdvancedProperty -Name $vnic_name -RegistryKeyword '*JumboPacket' -RegistryValue 9014    
                    }
                }
            }
            Else {
                Write-Host ("$host_name,$vswitch_name,$vnic_name - Jumbo Packet not found")
            }

            # check RDMA technology
            $nic_tech = $null
            $nic_tech = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $vnic_name -and $_.RegistryKeyword -eq '*NetworkDirectTechnology' }
            If ($nic_tech) {
                $nic_rdma_on = $true
                Write-Host ("$host_name,$vswitch_name,$vnic_name - RDMA Technology found: " + $nic_tech.DisplayValue)
                # check for iWARP
                If ($nic_tech.RegistryValue -ne 1) {
                    Write-Host ("$host_name,$vswitch_name,$vnic_name - RDMA Technology not set to 'iWARP', fixing...")
                    Set-NetAdapterAdvancedProperty -Name $vnic_name -RegistryKeyword '*NetworkDirectTechnology' -RegistryValue 1
                }
            }
            Else {
                $nic_rdma_on = $false
                Write-Host ("$host_name,$vswitch_name,$vnic_name - RDMA Technology not found")
            }

            # check RDMA state on NIC
            $nic_rdma = $null
            $nic_rdma = Get-NetAdapterRdma | Where-Object { $_.Name -match $vnic_name }
            If ($nic_rdma) {
                If ($nic_rdma.Enabled -and $nic_rdma_on) {
                    Write-Host ("$host_name,$vswitch_name,$vnic_name - RDMA enabled")
                }
                ElseIf ($nic_rdma_on) {
                    Write-Host ("$host_name,$vswitch_name,$vnic_name - RDMA supported and not enabled, fixing...")
                    $nic_rdma | Enable-NetAdapterRdma
                    Start-Sleep -Seconds 15
                }
                ElseIf ($nic_rdma.Enabled) {
                    Write-Host ("$host_name,$vswitch_name,$vnic_name - RDMA not supported and enabled, fixing...")
                    $nic_rdma | Disable-NetAdapterRdma
                    Start-Sleep -Seconds 15
                }
                Else {
                    Write-Host ("$host_name,$vswitch_name,$vnic_name - RDMA not enabled")
                }
            }    

            # enable QoS on the network adapter
            $nic_qos = $null
            $nic_qos = Get-NetAdapterQos | Where-Object { $_.Name -match $vnic_name }
            If ($nic_qos) {
                If ($nic_qos.Enabled) {
                    Write-Host ("$host_name,$vswitch_name,$vnic_name - QoS enabled")
                }
                Else {
                    Write-Host ("$host_name,$vswitch_name,$vnic_name - QoS disabled, fixing...")
                    $nic_qos | Enable-NetAdapterQos
                    Start-Sleep -Seconds 15
                }
            }
            Else {
                Write-Host ("$host_name,$vswitch_name,$vnic_name - QoS not found")
            }

            # check the IP address on the networkadapter
            $nic_address = $null
            $nic_address = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -match $vnic_name }).IPv4Address
            If ($nic_address -eq $vnic_addr) {
                Write-Host ("$host_name,$vswitch_name,$vnic_name - IP address correct, skipping...")
            }
            ElseIf ($nic_address) {
                Write-Host ("$host_name,$vswitch_name,$vnic_name - IP address incorrect, fixing...")
                $nic_address | Remove-NetIPAddress -Confirm:$false
                $nic_network | New-NetIPAddress -AddressFamily IPv4 -IPAddress $vnic_addr -PrefixLength $vnic_mask | Out-Null
            }
            Else {
                Write-Host ("$host_name,$vswitch_name,$vnic_name - IP address missing, setting...")
                $nic_network | New-NetIPAddress -AddressFamily IPv4 -IPAddress $vnic_addr -PrefixLength $vnic_mask | Out-Null
            }

            # check the default route on the networkadapter
            If ($vnic_gway -eq 0) {
                Write-Host ("$host_name,$vswitch_name,$vnic_name - No gateway defined for NIC")
            }
            Else {
                $nic_gateway = $null
                $nic_gateway = Get-NetRoute | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' }
                If ($nic_gateway.NextHop -eq $vnic_gway) {
                    Write-Host ("$host_name,$vswitch_name,$vnic_name - Default gateway correct")
                }
                ElseIf ($nic_gateway) {
                    Write-Host ("$host_name,$vswitch_name,$vnic_name - Default gateway incorrect, fixing...")
                    $nic_gateway | Remove-NetRoute -Confirm:$false
                    $nic_network | New-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -NextHop $vnic_gway | Out-Null
                }
                Else {
                    Write-Host ("$host_name,$vswitch_name,$vnic_name - Default gateway missing, creating...")
                    $nic_network | New-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -NextHop $vnic_gway | Out-Null
                }
            }

            # add VNIC as a migration network source
            Write-Host ("$host_name,$vswitch_name,$vnic_name - Adding VNIC as VM migration network")
            Add-VMMigrationNetwork -Subnet ($vnic_addr + '/32')

            # pause for network adapter changes to complete
            Write-Host ("$host_name,$vswitch_name,$vnic_name - Pausing before team mapping")
            Start-Sleep -Seconds 5

            # force set the team mapping
            Write-Host ("$host_name,$vswitch_name,$vnic_name - Team mapping configured")
            Set-VMNetworkAdapterTeamMapping -ManagementOS -VMNetworkAdapterName $vnic_name -PhysicalNetAdapterName $pnic_name
        }
        Else {

        }
    }
    Else {
        Write-Host ("$host_name,$vswitch_name,$vnic_name - Switch is not Management and host is not clustered, skipping virtual adapter(s)...")
    }
}

# stop logging
Stop-Transcript
