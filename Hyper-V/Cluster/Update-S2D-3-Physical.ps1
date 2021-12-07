# define the folders
$host_name = [System.Net.Dns]::GetHostName().ToLower()
$path_temp = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')
$path_logs = Join-Path -Path $path_temp -ChildPath 'hv-setup'

# verify the folders
If (!(Test-Path -Path $path_logs)) { New-Item -ItemType Directory -Path $path_logs }

# define the files
$log_network = Join-Path -Path $path_logs -ChildPath ('log-update-s2d-3-physical-' + (Get-Date -Format FileDateTime) + '.txt')
$csv_network = Join-Path -Path $path_logs -ChildPath ($host_name + '-net.csv')
$dns_servers = Join-Path -Path $path_logs -ChildPath ($host_name + '-dns.txt')

# start logging
Start-Transcript -Path $log_network -Append -Force

# verify the files
Write-Host ('Checking required files...')
$file_names = @($csv_network, $dns_servers)
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

# check if the host is clustered
$cluster = $null
$cluster = Get-Service | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -ne 'Disabled' }
If ($cluster) {
    Write-Host ("$host_name - Cluster found, will not modify NIC QoS settings")
}
Else {
    Write-Host ("$host_name - Cluster not found, will enable NIC QoS if required")
}

# disable NetBT on all adapters
Write-Host ("$host_name - Retrieving all NICs...")
$nic_not_usb = $null
$nic_not_usb = Get-NetAdapter | Where-Object { $_.ComponentID -notmatch 'usb' } | Sort-Object InterfaceAlias
$nic_not_usb | ForEach-Object {
    $nic_change = $false
    $nic_object = $_
    $nic_alias = $nic_object.InterfaceAlias
    # disable NBT on NIC
    $nic_nbt_on = $null
    $nic_nbt_on = Get-ChildItem 'HKLM:SYSTEM\CurrentControlSet\services\NetBT\Parameters\Interfaces' | Where-Object { $_.Name -match $nic_object.InterfaceGuid }
    If ($nic_nbt_on.GetValue('NetbiosOptions') -ne 2) {
        Write-Host ("$host_name, $nic_alias - Disabling NBT")
        $nic_nbt_on | Set-ItemProperty -Name NetbiosOptions -Value 2
        $nic_change = $true
    }
    # disable DHCP on NIC
    $nic_dhcpv4 = $null
    $nic_dhcpv4 = $nic_object | Get-NetIPInterface | Where-Object { $_.AddressFamily -eq 'IPv4' -and $_.DHCP -and $_.ConnectionState }
    If ($nic_dhcpv4) {
        Write-Host ("$host_name, $nic_alias - Disabling DHCP v4")
        $nic_dhcpv4 | Set-NetIPInterface -Dhcp Disabled
        $nic_change = $true
    }
    # restart adapter if necessary
    If ($nic_change) {
        Write-Host ("$host_name, $nic_alias - Restarting NIC")
        $nic_object | Restart-NetAdapter
        Start-Sleep -Seconds 5
    }
    Else {
        Write-Host ("$host_name, $nic_alias - Found NBT and DHCPv4 disabled")
    }
}

# import CSV
$map_network = Import-Csv -Path $csv_network | Where-Object { $_.Host -eq $host_name -and $_.Adapter }

# process the network mapping file - add phase
Write-Host ("$host_name - Checking physical NIC settings...")
$map_network | ForEach-Object {
    # assign CSV values to objects
    $nic_name = $_.Adapter
    $nic_addr = $_.Address
    $nic_mask = $_.Mask
    $nic_gway = $_.Gateway
    $nic_vnic = $_.vNIC

    # check for IP addresses
    # IP not found on NIC, check if requested NIC exists    
    Write-Host ("$host_name, $nic_name, $nic_addr - Checking for nic...")
    $nic_exists = $null
    $nic_exists = Get-NetAdapter -Physical | Where-Object { $_.InterfaceAlias -eq $nic_name } 
    If ($nic_exists) {
        # requested NIC found, check if requested NIC has IPv4 enabled
        Write-Host ("$host_name, $nic_name, $nic_addr - NIC found, checking for IP bindings...")
        $nic_bound = $null
        $nic_bound = $nic_exists | Get-NetAdapterBinding | Where-Object { $_.ComponentID -eq 'ms_tcpip' -and $_.Enabled }
        If ($nic_bound) {
            # requested NIC has IPv4 bound, check IP addresses
            Write-Host ("$host_name, $nic_name, $nic_addr - IPv4 bound, checking addresses and gateway...")
            # check for wrong address on current NIC
            $nic_addr_on_nic = $null
            $nic_addr_on_nic = Get-NetIPAddress | Where-Object { $_.IPv4Address -ne $nic_addr -and $_.AddressFamily -eq 'IPv4' -and $_.InterfaceAlias -eq $nic_name -and $_.InterfaceAlias -ne $nic_vnic }
            If ($nic_addr_on_nic) {
                Write-Host ("$host_name, $nic_name, $nic_addr - ...wrong address found on current NIC, removing address: " + $nic_addr_on_nic.IPv4Address)
                $nic_addr_on_nic | Remove-NetIPAddress -Confirm:$false
            }
            # check for requested address on other NICs
            $nic_addr_on_sys = $null
            $nic_addr_on_sys = Get-NetIPAddress | Where-Object { $_.IPv4Address -eq $nic_addr -and $_.AddressFamily -eq 'IPv4' -and $_.InterfaceAlias -ne $nic_name -and $_.InterfaceAlias -ne $nic_vnic }
            If ($nic_addr_on_sys) {
                Write-Host ("$host_name, $nic_name, $nic_addr - ...current address found on other NIC, removing address from: " + $nic_addr_on_sys.InterfaceAlias)
                $nic_addr_on_sys | Remove-NetIPAddress -Confirm:$false
            }

            # check for requested address on current NIC
            $nic_correct_ip = $null
            $nic_correct_ip = Get-NetIPAddress | Where-Object { $_.IPv4Address -eq $nic_addr -and $_.AddressFamily -eq 'IPv4' -and ($_.InterfaceAlias -eq $nic_name -or $_.InterfaceAlias -eq $nic_vnic) }
            If ($nic_correct_ip) {
                # IP address found
                Write-Host ("$host_name, $nic_name, $nic_addr - ...IP address found on correct physical or virtual NIC")
            }
            Else {
                Write-Host ("$host_name, $nic_name, $nic_addr - ...setting IP address")
                $nic_exists | New-NetIPAddress -AddressFamily IPv4 -IPAddress $nic_addr -PrefixLength $nic_mask | Out-Null
            }

            # check for gateway
            If ($nic_gway -eq '0') {
                # check for default route on current NIC
                $nic_wrong_gw = $null
                $nic_wrong_gw = Get-NetRoute | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and ($_.InterfaceAlias -eq $nic_name -or $_.InterfaceAlias -eq $nic_vnic) }
                If ($nic_wrong_gw) {
                    Write-Host ("$host_name, $nic_name, $nic_addr - ...gateway found on current (wrong) NIC, removing route")
                    $nic_wrong_gw | Remove-NetRoute -Confirm:$false
                }
                Else {
                    Write-Host ("$host_name, $nic_name, $nic_addr - ...gateway not found on current NIC")
                }

                # current NIC lacks gateway, clear the DNS servers
                Write-Host ("$host_name, $nic_name, $nic_addr - ...clearing DNS servers")
                $nic_exists | Set-DnsClientServerAddress -ServerAddress $null
                # current NIC lacks gateway, disable DNS registration
                Write-Host ("$host_name, $nic_name, $nic_addr - ...disabling DNS registration")
                $nic_exists | Set-DnsClient -RegisterThisConnectionsAddress $false
                
            }
            Else {
                # check for default route on other physical and virtual NICs
                $nic_route = $null
                $nic_route = Get-NetRoute | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.InterfaceAlias -ne $nic_name -and $_.InterfaceAlias -ne $nic_vnic }
                $nic_route | ForEach-Object {
                    Write-Host ("$host_name, $nic_name, $nic_addr - ...gateway found on other NIC, removing route from: " + $_.InterfaceAlias)
                    $_ | Remove-NetRoute -Confirm:$false
                }

                # check for default route on current NIC
                $nic_correct_gw = $null
                $nic_correct_gw = Get-NetRoute | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and ($_.InterfaceAlias -eq $nic_name -or $_.InterfaceAlias -eq $nic_vnic) }
                If ($nic_correct_gw) {
                    Write-Host ("$host_name, $nic_name, $nic_addr - ...default gateway found on current physical or virtual NIC")
                }
                Else {
                    Write-Host ("$host_name, $nic_name, $nic_addr - ...default gateway not found, adding to physical NIC")
                    New-NetRoute -DestinationPrefix '0.0.0.0/0' -NextHop $nic_gway -InterfaceAlias $nic_name
                }

                # current NIC has gateway, set the DNS servers
                Write-Host ("$host_name, $nic_name, $nic_addr - ...setting DNS servers")
                $nic_exists | Set-DnsClientServerAddress -ServerAddress $(Get-Content($dns_servers))
                # requested NIC has gateway, enable DNS registration
                Write-Host ("$host_name, $nic_name, $nic_addr - ...enabling DNS registration")
                $nic_exists | Set-DnsClient -RegisterThisConnectionsAddress $true
            }
        }
        Else {
            # requested NIC does not have IPv4 bound and likely a virtual NIC, exit loop
            Write-Host ("$host_name, $nic_name, $nic_addr - IPv4 not bound, skipping IP configuration...")
        }

        # check encapsulation overhead
        $nic_over = $null
        $nic_over = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*EncapOverhead' }
        If ($nic_over) {
            Write-Host ("$host_name, $nic_name, $nic_addr - Encapsulation Overhead settings found: " + $nic_over.DisplayValue)
            If ($nic_name -notmatch 'Manage' -and $nic_name -notmatch 'Port 0') {
                If ($nic_over.RegistryValue -ne 160) {
                    Write-Host ("$host_name, $nic_name, $nic_addr - Encapsulation Overhead on non-Management NIC not set to '160', fixing...")
                    Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*EncapOverhead' -RegistryValue 160
                }
            }
            Else {
                If ($nic_over.RegistryValue -ne 0) {
                    Write-Host ("$host_name, $nic_name, $nic_addr - Encapsulation Overhead on Management NIC not set to '0', fixing...")
                    Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*EncapOverhead' -RegistryValue 0
                }
            }
        }
        Else {
            Write-Host ("$host_name, $nic_name, $nic_addr - Encapsulation Overhead settings not found")
        }

        # check jumbo packet settings
        $nic_size = $null
        $nic_size = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*JumboPacket' }
        If ($nic_size) {
            Write-Host ("$host_name, $nic_name, $nic_addr - Jumbo Packet settings found: " + $nic_size.DisplayValue)
            If ($nic_name -notmatch 'Manage' -and $nic_name -notmatch 'Port 0') {
                If ($nic_size.RegistryValue -ne 9014) {
                    Write-Host ("$host_name, $nic_name, $nic_addr - Jumbo Packet on non-Management NIC not set to '9014', fixing...")
                    Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*JumboPacket' -RegistryValue 9014    
                }
            } 
            Else {
                If ($nic_size.RegistryValue -ne 1514) {
                    Write-Host ("$host_name, $nic_name, $nic_addr - Jumbo Packet on Management NIC not set to '1514', fixing...")
                    Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*JumboPacket' -RegistryValue 1514
                }
            }
        }
        Else {
            Write-Host ("$host_name, $nic_name, $nic_addr - Jumbo Packet settings not found")
        }

        # check RDMA technology
        $nic_tech = $null
        $nic_tech = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*NetworkDirectTechnology' }
        If ($nic_tech) {
            $nic_rdma_on = $true
            Write-Host ("$host_name, $nic_name, $nic_addr - RDMA Technology found: " + $nic_tech.DisplayValue)
            # check for iWARP
            If ($nic_tech.RegistryValue -ne 1) {
                Write-Host ("$host_name, $nic_name, $nic_addr - RDMA Technology not set to 'iWARP', fixing...")
                Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*NetworkDirectTechnology' -RegistryValue 1
            }
        }
        Else {
            $nic_rdma_on = $false
            Write-Host ("$host_name, $nic_name, $nic_addr - RDMA Technology not found")
        }

        # check RDMA state on NIC
        $nic_rdma = $null
        $nic_rdma = Get-NetAdapterRdma | Where-Object { $_.Name -match $nic_name }
        If ($nic_rdma) {
            If ($nic_rdma.Enabled -and $nic_rdma_on) {
                Write-Host ("$host_name, $nic_name, $nic_addr - RDMA enabled")
            }
            ElseIf ($nic_rdma_on) {
                Write-Host ("$host_name, $nic_name, $nic_addr - RDMA supported and not enabled, fixing...")
                $nic_rdma | Enable-NetAdapterRdma
                Start-Sleep -Seconds 15
            }
            ElseIf ($nic_rdma.Enabled) {
                Write-Host ("$host_name, $nic_name, $nic_addr - RDMA not supported and enabled, fixing...")
                $nic_rdma | Disable-NetAdapterRdma
                Start-Sleep -Seconds 15
            }
            Else {
                Write-Host ("$host_name, $nic_name, $nic_addr - RDMA not enabled")
            }
        }
        Else {
            Write-Host ("$host_name, $nic_name, $nic_addr - RDMA not found")
        }

        # enable QoS on the network adapter
        $nic_qos = $null
        $nic_qos = Get-NetAdapterQos | Where-Object { $_.Name -match $nic_name }
        If ($nic_qos) {
            If ($nic_qos.Enabled) {
                Write-Host ("$host_name, $nic_name, $nic_addr - QoS enabled")
            }
            ElseIf ($cluster) {
                Write-Host ("$host_name, $nic_name, $nic_addr - QoS not enabled and host is clustered, cannot enable QoS...")
            }
            Else {
                Write-Host ("$host_name, $nic_name, $nic_addr - QoS not enabled and host is not clustered, enabling QoS...")
                $nic_qos | Enable-NetAdapterQos
                Start-Sleep -Seconds 15
            }
        }
        Else {
            Write-Host ("$host_name, $nic_name, $nic_addr - QoS not found")
        }
    }
    Else {
        # requested NIC was NOT found, exit loop
        Write-Host ("$host_name, $nic_name, $nic_addr - NIC was NOT found, skipping...")
    }
}

# stop logging
Stop-Transcript
