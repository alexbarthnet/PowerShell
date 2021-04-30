# set the file locations
$map_network = '.\ASH\ash-map-network.txt'

# clear arrays and create feature set
$log_physical = @()

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
    $log_physical += $out_physical = Invoke-Command -ComputerName $vm_name -ScriptBlock {
        $nic_out = @()
        $nic_client = Get-DnsClient
        $nic_route = Get-NetRoute -AddressFamily IPv4
        $nic_addr = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.SkipAsSource -eq $false }
        $nic_prop = Get-NetAdapterAdvancedProperty
        $nic_rdma = Get-NetAdapterRdma
        $nic_list = Get-NetAdapter -Physical
        $nic_list | ForEach-Object { 
            $nic = $_; 
            $nic_out += [pscustomobject]@{
                Adapter   = $nic.Name;
                VLAN      = ($nic_prop | Where-Object { $_.Name -eq $nic.Name -and $_.RegistryKeyword -eq 'VlanID' }).DisplayValue;
                IPAddress = ($nic_addr | Where-Object { $_.InterfaceIndex -eq $nic.ifIndex }).IPv4Address
                Mask      = ($nic_addr | Where-Object { $_.InterfaceIndex -eq $nic.ifIndex }).PrefixLength
                Gateway   = ($nic_route | Where-Object { $_.InterfaceIndex -eq $nic.ifIndex -and $_.DestinationPrefix -eq '0.0.0.0/0' }).NextHop
                Register  = ($nic_client | Where-Object { $_.InterfaceIndex -eq $nic.ifIndex }).RegisterThisConnectionsAddress
                Jumbo     = ($nic_prop | Where-Object { $_.Name -eq $nic.Name -and $_.RegistryKeyword -eq '*JumboPacket' }).DisplayValue
                Rdma      = ($nic_prop | Where-Object { $_.Name -eq $nic.Name -and $_.RegistryKeyword -eq '*NetworkDirect' }).DisplayValue
                RdmaType  = ($nic_prop | Where-Object { $_.Name -eq $nic.Name -and $_.RegistryKeyword -eq '*NetworkDirectTechnology' }).DisplayValue
                PFC       = ($nic_rdma | Where-Object { $_.Name -eq $nic.Name }).PFC
                ETS       = ($nic_rdma | Where-Object { $_.Name -eq $nic.Name }).ETS
            } 
        }
        $nic_out | Sort-Object Adapter
    }
    # run the scripts
    Write-Host ($vm_name + ' - starting session...')
    $vm_options = New-PSSessionOption -OutputBufferingMode Drop
    $vm_session = Invoke-Command -ComputerName $vm_name -InDisconnectedSession -SessionOption $vm_options -ScriptBlock {
        $vm_review = ($using:vm_make.FullName + '.\ash-get-physical.txt')
        "======================== $(Get-Date -Format FileDateTime) ========================" | Out-File -FilePath $vm_review -Append
        $using:out_physical | Format-Table Adapter, VLAN, IPAddress, Mask, Gateway, Register, Jumbo, Rdma, RdmaType, PFC, ETS | Out-File -FilePath $vm_review -Append
    }

    # declare session name
    Write-Host ($vm_name + ' - started session: ' + $vm_session.Name)
}

# declare results
Write-Host ''
Write-Host '======================== Results ========================'
$log_physical | Format-Table PSComputerName, Adapter, VLAN, IPAddress, Mask, Gateway, Register, Jumbo, Rdma, RdmaType, PFC, ETS
