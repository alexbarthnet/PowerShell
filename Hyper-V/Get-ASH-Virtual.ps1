# set the file locations
$map_network = '.\ASH\ash-map-network.txt'

# clear arrays and create feature set
$log_vswitch = @()
$log_virtual = @()

# process the cluster mapping file
Import-Csv -Path $map_network | Sort-Object Host -Unique | ForEach-Object {
    # get base strings for this pass
    $vm_name = $_.Host

    # declare start
    Write-Host "======================== $vm_name ========================"

    # clear the DNS cache then resolve hostname
    Write-Host ($vm_name + ' - resolving host...')
    Do {
        Clear-DnsClientCache
        $dns_found = $null
        $dns_found = Resolve-DnsName -Name $vm_name -ErrorAction SilentlyContinue
    } Until ($dns_found)

    # verify connection to remote host
    Write-Host ($vm_name + ' - connecting to host...')
    Do {
        $vm_alive = $false
        $vm_alive = Test-NetConnection -ComputerName $vm_name -CommonTCPPort SMB -InformationLevel Quiet
    } Until ($vm_alive)

    # create and define remote directory
    Write-Host ($vm_name + ' - creating directory...')
    $vm_temp = Invoke-Command -ComputerName $vm_name -ScriptBlock { [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine') }
    $vm_make = Invoke-Command -ComputerName $vm_name -ScriptBlock { New-Item -Path $using:vm_temp -Name 'hv-setup' -ItemType Directory -Force }

    # run remote commands
    Write-Host ($vm_name + ' - running commands...')
    $log_vswitch += $out_vswitch = Invoke-Command -ComputerName $vm_name -ScriptBlock {
        Get-VMSwitch | Sort-Object Name | Select-Object Name, BandwidthReservationMode, EmbeddedTeamingEnabled, IOVEnabled, IOVSupport, IOVSupportReasons
    } 

    $log_virtual += $out_virtual = Invoke-Command -ComputerName $vm_name -ScriptBlock {
        $vnic_out = @()
        $vnic_client = Get-DnsClient
        $vnic_route = Get-NetRoute -AddressFamily IPv4
        $vnic_addr = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.SkipAsSource -eq $false }
        $vnic_list = Get-VMNetworkAdapter -ManagementOS | Sort-Object Name
        $vnic_prop = Get-NetAdapterAdvancedProperty
        $vnic_list | ForEach-Object { 
            $vnic = $_; 
            $vnic_iso = $vnic | Get-VMNetworkAdapterIsolation
            $vnic_out += [pscustomobject]@{
                Adapter      = $vnic.Name;
                SwitchName   = $vnic.SwitchName
                MacAddress   = $vnic.MacAddress
                VLAN         = $vnic_iso.DefaultIsolationID
                Isolation    = $vnic_iso.IsolationMode
                IPAddress    = ($vnic_addr | Where-Object { $_.InterfaceAlias -eq $vnic.Name }).IPv4Address
                Mask         = ($vnic_addr | Where-Object { $_.InterfaceAlias -eq $vnic.Name }).PrefixLength
                Gateway      = ($vnic_route | Where-Object { $_.InterfaceAlias -eq $vnic.Name -and $_.DestinationPrefix -eq '0.0.0.0/0' }).NextHop
                Register     = ($vnic_client | Where-Object { $_.InterfaceAlias -eq $vnic.Name }).RegisterThisConnectionsAddress
                Jumbo        = ($vnic_prop | Where-Object { $_.Name -eq $vnic.Name -and $_.RegistryKeyword -eq '*JumboPacket' }).DisplayValue
                Rdma         = ($vnic_prop | Where-Object { $_.Name -eq $vnic.Name -and $_.RegistryKeyword -eq '*NetworkDirect' }).DisplayValue
                IeeePriority = $vnic.IeeePriorityTag
            } 
        }
        $vnic_out | Sort-Object Adapter
    }
    # run the scripts
    Write-Host ($vm_name + ' - starting session...')
    $vm_options = New-PSSessionOption -OutputBufferingMode Drop
    $vm_session = Invoke-Command -ComputerName $vm_name -InDisconnectedSession -SessionOption $vm_options -ScriptBlock {
        $vm_review = ($using:vm_make.FullName + '.\ash-get-physical.txt')
        "======================== $(Get-Date -Format FileDateTime) ========================" | Out-File -FilePath $vm_review -Append
        $using:out_vswitch | Format-Table Name, @{Label = 'BandwidthMode'; Expression = { $_.BandwidthReservationMode } }, @{Label = 'SET'; Expression = { $_.EmbeddedTeamingEnabled } }, IOVEnabled, IOVSupport, IOVSupportReasons | Out-File -FilePath $vm_review -Append
        $using:out_virtual | Format-Table Adapter, SwitchName, MacAddress, VLAN, Isolation, IPAddress, Mask, Gateway, Register, Jumbo, Rdma, IeeePriority | Out-File -FilePath $vm_review -Append
    }

    # declare session name
    Write-Host ($vm_name + ' - started session: ' + $vm_session.Name)
}

# declare results
Write-Host ''
Write-Host '======================== Results ========================'
$log_vswitch | Format-Table PSComputerName, Name, @{Label = 'BandwidthMode'; Expression = { $_.BandwidthReservationMode } }, @{Label = 'SET'; Expression = { $_.EmbeddedTeamingEnabled } }, IOVEnabled, IOVSupport, IOVSupportReasons
$log_virtual | Format-Table PSComputerName, Adapter, SwitchName, MacAddress, VLAN, Isolation, IPAddress, Mask, Gateway, Register, Jumbo, Rdma, IeeePriority
