# set the file locations
$hostname_vm = [System.Net.Dns]::GetHostName().ToLower()
$folder_temp = [System.Environment]::GetEnvironmentVariable('TEMP','Machine')
$path_hv_log = Join-Path -Path $folder_temp -ChildPath 'hv-setup'
$log_network = Join-Path -Path $path_hv_log -ChildPath 'ash-log-physical.txt'
$map_network = Join-Path -Path $path_hv_log -ChildPath 'ash-map-network.txt'
$dns_servers = Join-Path -Path $path_hv_log -ChildPath 'ash-dns-servers.txt'

# start logging
Start-Transcript -Path $log_network -Append -Force

# import CSVs
$csv_network = Import-Csv -Path $map_network | Where-Object { $_.Host -eq $hostname_vm }

# disable NetBT from all adapters
Write-Host ("$hostname_vm - disabling NBT on all adapters")
Get-ChildItem "HKLM:SYSTEM\CurrentControlSet\services\NetBT\Parameters\Interfaces" | ForEach-Object {Set-ItemProperty -Path $_.PSPath -Name NetbiosOptions -Value 2 -Verbose}

# get all physical NICs with IPv4 bound
$nic_ipv4 = Get-NetAdapter -Physical | Where-Object {$_.MediaConnectionState} | Get-NetIPInterface | Where-Object {$_.AddressFamily -eq "IPv4" -and $_.ConnectionState -eq "Connected"}

# set all NICs to manual
Write-Host ("$hostname_vm - disabling DHCP on all adapters")
$nic_ipv4 | Set-NetIPInterface -Dhcp Disabled

# remove all manually configured IP address on physical adapters
Write-Host ("$hostname_vm - clearing manually configured IP addresses on all adapters")
$nic_ipv4 | Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.PrefixOrigin -eq "Manual"} | Remove-NetIPAddress -Confirm:$false

# disable DNS registration on all DNS clients
Write-Host ("$hostname_vm - disabling DNS registration on all adapters")
$nic_ipv4 | Set-DnsClient -RegisterThisConnectionsAddress $false

# clear all routes
Write-Host ("$hostname_vm - removing default routes from physical adapters")
$nic_ipv4 | Get-NetRoute | Where-Object {$_.DestinationPrefix -eq "0.0.0.0/0"} | Remove-NetRoute -Confirm:$false

# process the network mapping file - add phase
Write-Host ("$hostname_vm - looping through intended IP addresses")
$csv_network | ForEach-Object {
    $nic_name = $_.Adapter
    $nic_mode = $_.Mode
    $nic_addr = $_.Address
    $nic_mask = $_.Mask
    $nic_gway = $_.Gateway

    # check for IP addresses
    $ip_already_set = $null
    $ip_already_set = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -eq $nic_addr}
    If ($ip_already_set) {
        # IP found on NIC after IPs removed from physical NICs, IP likely on virtual NIC, exit loop
        Write-Host ("$hostname_vm, $nic_name, $nic_addr - IP already configured on: " + $ip_already_set.InterfaceAlias)
    } Else {
        # IP not found on NIC, check if requested NIC exists    
        Write-Host ("$hostname_vm, $nic_name, $nic_addr - checking for nic...")
        $nic_exists = $null
        $nic_exists = Get-NetAdapter -Physical | Where-Object {$_.InterfaceAlias -eq $nic_name} 
        If ($nic_exists) {
            # requested NIC found, check if requested NIC has IPv4 enabled
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - NIC found, checking for IP bindings...")
            $nic_bound = $null
            $nic_bound = $nic_exists | Get-NetAdapterBinding | Where-Object {$_.ComponentID -eq "ms_tcpip" -and $_.Enabled}
            If ($nic_bound) {
                # requested NIC has IPv4 bound, set the IP address
                Write-Host ("$hostname_vm, $nic_name, $nic_addr - IPv4 bound, checking gateway...")
                If ($nic_gway -ne "0") {
                    # requested NIC has gateway, set the IP address with default gateway
                    Write-Host ("$hostname_vm, $nic_name, $nic_addr - gateway found, setting IP address with default gateway...")
                    $nic_exists | New-NetIPAddress -AddressFamily IPv4 -IPAddress $nic_addr -PrefixLength $nic_mask -DefaultGateway $nic_gway | Out-Null
                    # requested NIC has gateway, set the DNS servers
                    Write-Host ("$hostname_vm, $nic_name, $nic_addr - gateway found, setting DNS servers...")
                    $nic_exists | Set-DnsClientServerAddress -ServerAddress $(Get-Content($dns_servers))
                    # requested NIC has gateway, enable DNS registration
                    Write-Host ("$hostname_vm, $nic_name, $nic_addr - gateway found, enabling DNS registration...")
                    $nic_exists | Set-DnsClient -RegisterThisConnectionsAddress $true
                } Else {
                    # requested NIC does not have gateway, set the IP address only
                    Write-Host ("$hostname_vm, $nic_name, $nic_addr - gateway not found, setting IP address...")
                    $nic_exists | New-NetIPAddress -AddressFamily IPv4 -IPAddress $nic_addr -PrefixLength $nic_mask | Out-Null
                }   
            } Else {
                Write-Host ("$hostname_vm, $nic_name, $nic_addr - IPv4 not bound, skipping address configuration...")
            }
        } Else {
            # requested NIC was NOT found, exit loop
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - NIC was NOT found, skipping...")
        }
    }

    # update jumbo packet settings
    $nic_size = $null
    $nic_size = Get-NetAdapterAdvancedProperty -Name $nic_name | Where-Object {$_.RegistryKeyword -eq '*JumboPacket'}
    If ($nic_size -and $nic_mode -eq "Trunk") {
        Write-Host ("$hostname_vm, $nic_name, $nic_addr - Jumbo Packet found: " + $nic_size.DisplayValue)
        If ($nic_size.RegistryValue -ne 9014) {
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - Jumbo Packet not set to '9014', fixing...")
            Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*JumboPacket' -RegistryValue 9014    
        } Else {
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - Jumbo Packet set to '9014'")
        }
    } Else {
        Write-Host ("$hostname_vm, $nic_name, $nic_addr - Jumbo Packet not found")
    }

    # update RDMA settings
    $nic_tech = $null
    $nic_tech = Get-NetAdapterAdvancedProperty -Name $nic_name | Where-Object {$_.RegistryKeyword -eq '*NetworkDirectTechnology'}
    If ($nic_tech) {
        # check for VLAN settings on NIC
        Write-Host ("$hostname_vm, $nic_name, $nic_addr - RDMA found: " + $nic_tech.DisplayValue)
        If ($nic_tech.RegistryValue -ne 1) {
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - RDMA not set to 'iWARP', fixing...")
            Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*NetworkDirectTechnology' -RegistryValue 1
        } Else {
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - RDMA set to 'iWARP'")
        }
    } Else {
        Write-Host ("$hostname_vm, $nic_name, $nic_addr - RDMA not found")
    }

    # enable RDMA on the network adapter
    $nic_rdma = $null
    $nic_rdma = Get-NetAdapterRdma | Where-Object { $_.Name -match $nic_name }
    If ($nic_rdma) {
        If ($nic_rdma.Enabled) {
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - RDMA enabled")
        }
        Else {
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - RDMA not enabled, fixing...")
            $nic_rdma | Enable-NetAdapterRdma
            Start-Sleep -Seconds 15
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
