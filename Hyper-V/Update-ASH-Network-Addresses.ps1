# set the file locations
$hostname_vm = [System.Net.Dns]::GetHostName().ToLower()
$folder_temp = [System.Environment]::GetEnvironmentVariable('TEMP','Machine')
$map_network = ($folder_temp + '\hv-setup\ash-map-network.txt')
$log_address = ($folder_temp + '\hv-setup\ash-log-address.txt')
$dns_servers = ($folder_temp + '\hv-setup\ash-dns-servers.txt')

# start logging
Start-Transcript -Path $log_address -Append -Force
$csv_imported = Import-Csv -Path $map_network

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
$csv_imported | Where-Object {$_.Host -eq $hostname_vm} | ForEach-Object {
    $nic_name = $_.Adapter
    $nic_mode = $_.Mode
    $nic_vlan = $_.Vlan
    $nic_addr = $_.Address
    $nic_mask = $_.Mask
    $nic_gway = $_.Gateway
    $nic_rdma = $_.RDMA

    # clear variables
    $ip_already_set = $null
    $nic_netdirect = $null
    $nic_exists = $null
    $nic_bound = $null

    # check for IP addresses
    $ip_already_set = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -eq $nic_addr}
    If ($ip_already_set) {
        # IP found on NIC after IPs removed from physical NICs, IP likely on virtual NIC, exit loop
        Write-Host ("$hostname_vm, $nic_name, $nic_addr - IP already configured on: " + $ip_already_set.InterfaceAlias)
    } Else {
        # IP not found on NIC, check if requested NIC exists    
        Write-Host ("$hostname_vm, $nic_name, $nic_addr - checking for nic...")
        $nic_exists = Get-NetAdapter -Physical | Where-Object {$_.InterfaceAlias -eq $nic_name} 
        If ($nic_exists) {
            # requested NIC found, check if requested NIC has IPv4 enabled
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - NIC found, checking for bindings...")
            $nic_bound = $nic_exists | Get-NetAdapterBinding | Where-Object {$_.ComponentID -eq "ms_tcpip" -and $_.Enabled}
            If ($nic_bound) {
                # requested NIC has IPv4 bound, set the IP address
                Write-Host ("$hostname_vm, $nic_name, $nic_addr - NIC bound, checking gateway...")
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
            }
        } Else {
            # requested NIC was NOT found, exit loop
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - NIC was NOT found, skipping...")
        }
    }

    # update VLAN settings LAST as it disrupts the network
    If ($nic_mode -eq "Trunk") {
        # check for VLAN settings on NIC
        $nic_prop = Get-NetAdapterAdvancedProperty | Where-Object {$_.Name -eq $nic_name -and $_.RegistryKeyword -eq "VlanId"}
        If ($nic_prop) {
            # VLAN settings found, check if current value matches requested VLAN ID
            If ($nic_prop.RegistryValue -eq $nic_vlan) {
                # current value matches requested VLAN ID, report and exit loop
                Write-Host ("$hostname_vm, $nic_name, $nic_addr - found native VLAN: " + $nic_prop.RegistryValue)
            } Else {
                # current value does NOT match requested VLAN ID, set the VLAN ID
                $nic_prop | Set-NetAdapterAdvancedProperty -RegistryValue $nic_vlan
                Write-Host ("$hostname_vm, $nic_name, $nic_addr - set native VLAN to " + $nic_vlan)
            }
        }
    }

    # update RDMA settings
    If ($nic_rdma) {
        # check for VLAN settings on NIC
        Write-Host ("$hostname_vm, $nic_name, $nic_addr - RDMA requested: " + $nic_rdma)
        $nic_netdirect = Get-NetAdapterAdvancedProperty -Name $nic_name | Where-Object {$_.DisplayName -eq 'NetworkDirect Technology'}
        If ($nic_netdirect) {
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - RDMA options found, setting values...")
            Set-NetAdapterAdvancedProperty -Name $nic_name -DisplayName 'NetworkDirect Technology' -DisplayValue $nic_rdma
            Set-NetAdapterAdvancedProperty -Name $nic_name -DisplayName 'Jumbo Packet' -DisplayValue '9014'
        } Else {
            Write-Host ("$hostname_vm, $nic_name, $nic_addr - RDMA options not found, skipping...")
        }
    }
}

# stop logging
Stop-Transcript
