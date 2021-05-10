# set the file locations
$hostname_vm = [System.Net.Dns]::GetHostName().ToLower()
$folder_temp = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')
$path_hvperv = Join-Path -Path $folder_temp -ChildPath 'hv-setup'
$log_network = Join-Path -Path $path_hvperv -ChildPath 'ash-log-physical.txt'
$map_network = Join-Path -Path $path_hvperv -ChildPath 'ash-map-network.txt'
$dns_servers = Join-Path -Path $path_hvperv -ChildPath 'ash-dns-servers.txt'

# start logging
Start-Transcript -Path $log_network -Append -Force

# import CSVs
$csv_network = Import-Csv -Path $map_network | Where-Object { $_.Host -eq $hostname_vm }

# disable NetBT from all adapters
Write-Host ("$hostname_vm - disabling NBT on all adapters")
Get-ChildItem 'HKLM:SYSTEM\CurrentControlSet\services\NetBT\Parameters\Interfaces' | ForEach-Object { Set-ItemProperty -Path $_.PSPath -Name NetbiosOptions -Value 2 -Verbose }

# set all NICs to manual
Write-Host ("$hostname_vm - disabling DHCP on all adapters")
Get-NetAdapter -Physical | Where-Object {$_.ComponentID -notmatch "usb"} | Get-NetIPInterface | Where-Object {$_.AddressFamily -eq "IPv4"} | Set-NetIPInterface -Dhcp Disabled

# process the network mapping file - add phase
Write-Host ("$hostname_vm - looping through requested NIC settings")
$csv_network | ForEach-Object {
    $nic_name = $_.Adapter
    $nic_addr = $_.Address
    $nic_mask = $_.Mask
    $nic_gway = $_.Gateway
    $nic_vnic = $_.vNIC

    # check for IP addresses
    # IP not found on NIC, check if requested NIC exists    
    Write-Host ("$hostname_vm, $nic_name, $nic_addr - checking for nic...")
    $nic_exists = $null
    $nic_exists = Get-NetAdapter -Physical | Where-Object { $_.InterfaceAlias -eq $nic_name } 
    If ($nic_exists) {
        # requested NIC found, check if requested NIC has IPv4 enabled
        Write-Host ("$hostname_vm, $nic_name, $nic_addr - NIC found, checking for IP bindings...")
        $nic_bound = $null
        $nic_bound = $nic_exists | Get-NetAdapterBinding | Where-Object { $_.ComponentID -eq 'ms_tcpip' -and $_.Enabled }
        If ($nic_bound) {
            # requested NIC has IPv4 bound, check IP addresses
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - IPv4 bound, checking addresses and gateway...")
            # check for wrong address on requested physical NIC
            $nic_addr_on_nic = $null
            $nic_addr_on_nic = Get-NetIPAddress | Where-Object { $_.IPv4Address -ne $nic_addr -and $_.InterfaceAlias -eq $nic_name -and $_.InterfaceAlias -ne $nic_vnic }
            If ($nic_addr_on_nic) {
                Write-Host ("$hostname_vm, $nic_name, $nic_addr - ...wrong address found on current NIC, removing address: " + $nic_addr_on_nic.IPv4Address)
                $nic_addr_on_nic | Remove-NetIPAddress -Confirm:$false
            }
            # check for requested address on other physical and virtual NICs
            $nic_addr_on_sys = $null
            $nic_addr_on_sys = Get-NetIPAddress | Where-Object { $_.IPv4Address -eq $nic_addr -and $_.InterfaceAlias -ne $nic_name -and $_.InterfaceAlias -ne $nic_vnic }
            If ($nic_addr_on_sys) {
                Write-Host ("$hostname_vm, $nic_name, $nic_addr - ...right address found on other NIC, removing address from: " + $nic_addr_on_sys.InterfaceAlias)
                $nic_addr_on_sys | Remove-NetIPAddress -Confirm:$false
            }
            If ($nic_gway -ne '0') {
                # requested NIC has gateway, set the IP address with default gateway
                $nic_route = $null
                $nic_route = Get-NetRoute | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.InterfaceAlias -ne $nic_name -and $_.InterfaceAlias -ne $nic_vnic }
                If ($nic_route) {
                    Write-Host ("$hostname_vm, $nic_name, $nic_addr - ...gateway found on other NIC, removing from: " + $nic_route.InterfaceAlias)
                    $nic_route | Remove-NetRoute -Confirm:$false
                }
                Write-Host ("$hostname_vm, $nic_name, $nic_addr - ...setting IP address with default gateway")
                $nic_exists | New-NetIPAddress -AddressFamily IPv4 -IPAddress $nic_addr -PrefixLength $nic_mask -DefaultGateway $nic_gway | Out-Null
                # requested NIC has gateway, set the DNS servers
                Write-Host ("$hostname_vm, $nic_name, $nic_addr - ...setting DNS servers")
                $nic_exists | Set-DnsClientServerAddress -ServerAddress $(Get-Content($dns_servers))
                # requested NIC has gateway, enable DNS registration
                Write-Host ("$hostname_vm, $nic_name, $nic_addr - ...enabling DNS registration")
                $nic_exists | Set-DnsClient -RegisterThisConnectionsAddress $true
            }
            Else {
                # requested NIC does not have gateway, set the IP address only
                Write-Host ("$hostname_vm, $nic_name, $nic_addr - gateway not found, setting IP address...")
                $nic_exists | New-NetIPAddress -AddressFamily IPv4 -IPAddress $nic_addr -PrefixLength $nic_mask | Out-Null
            }
        }
        Else {
            # requested NIC does not have IPv4 bound and likely a virtual NIC, exit loop
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - IPv4 not bound, skipping address configuration...")
        }
    }
    Else {
        # requested NIC was NOT found, exit loop
        Write-Host ("$hostname_vm, $nic_name, $nic_addr - NIC was NOT found, skipping...")
    }

    # check jumbo packet settings
    $nic_size = $null
    $nic_size = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*JumboPacket' }
    If ($nic_size) {
        Write-Host ("$hostname_vm, $nic_name, $nic_addr - Jumbo Packet settings found: " + $nic_size.DisplayValue)
        If ($nic_size.RegistryValue -ne 9014 -and $nic_name -notmatch 'Manage') {
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - Jumbo Packet on non-Management NIC not set to '9014', fixing...")
            Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*JumboPacket' -RegistryValue 9014    
        } 
        Else {
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - Jumbo Packet on Management NIC not set to '1514', fixing...")
            Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*JumboPacket' -RegistryValue 1514    
        }
    }
    Else {
        Write-Host ("$hostname_vm, $nic_name, $nic_addr - Jumbo Packet settings not found")
    }

    # check RDMA technology
    $nic_tech = $null
    $nic_tech = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*NetworkDirectTechnology' }
    If ($nic_tech) {
        $nic_rdma_on = $true
        Write-Host ("$hostname_vm, $nic_name, $nic_addr - RDMA Technology found: " + $nic_tech.DisplayValue)
        # check for iWARP
        If ($nic_tech.RegistryValue -ne 1) {
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - RDMA Technology not set to 'iWARP', fixing...")
            Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*NetworkDirectTechnology' -RegistryValue 1
        }
    }
    Else {
        $nic_rdma_on = $false
        Write-Host ("$hostname_vm, $nic_name, $nic_addr - RDMA Technology not found")
    }

    # check RDMA state on NIC
    $nic_rdma = $null
    $nic_rdma = Get-NetAdapterRdma | Where-Object { $_.Name -match $nic_name }
    If ($nic_rdma) {
        If ($nic_rdma.Enabled -and $nic_rdma_on) {
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - RDMA enabled")
        }
        ElseIf ($nic_rdma_on) {
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - RDMA supported and not enabled, fixing...")
            $nic_rdma | Enable-NetAdapterRdma
            Start-Sleep -Seconds 15
        }
        ElseIf ($nic_rdma.Enabled) {
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - RDMA not supported and enabled, fixing...")
            $nic_rdma | Disable-NetAdapterRdma
            Start-Sleep -Seconds 15
        }
        Else {
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - RDMA not enabled")
        }
    }    

    # enable QoS on the network adapter
    $nic_qos = $null
    $nic_qos = Get-NetAdapterQos | Where-Object { $_.Name -match $virtual_name }
    If ($nic_qos) {
        If ($nic_qos.Enabled) {
            Write-Host ("$hostname_vm,$switch_name,$virtual_name - QoS enabled")
        }
        Else {
            Write-Host ("$hostname_vm,$switch_name,$virtual_name - QoS not enabled, fixing...")
            $nic_qos | Enable-NetAdapterQos
            Start-Sleep -Seconds 15
        }
    }
}

# stop logging
Stop-Transcript
