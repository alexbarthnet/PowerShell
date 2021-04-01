# set the file locations
$map_network = '.\ASH\ash-map-network.txt'

# clear arrays and create feature set
$log_address = @()
$log_adapter = @()
$log_gateway = @()
$nic_advprop = "VlanID","*JumboPacket","*NetworkDirect","*NetworkDirectTechnology"

# process the cluster mapping file
Import-Csv -Path $map_network | Sort-Object Host -Unique | ForEach-Object {
    # get base strings for this pass
    $vm_name = $_.Host

    # declare start
    Write-Host "======================== $vm_name ========================"

    # clear the DNS cache then resolve hostname
    Write-Host ($vm_name + " - resolving host...")
    Do {
        Clear-DnsClientCache
        $dns_found = $null
        $dns_found = Resolve-DnsName -Name $vm_name -ErrorAction SilentlyContinue
    } Until ($dns_found)

    # verify connection to remote host
    Write-Host ($vm_name + " - connecting to host...")
    Do {
        $vm_alive = $false
        $vm_alive = Test-NetConnection -ComputerName $vm_name -CommonTCPPort SMB -InformationLevel Quiet
    } Until ($vm_alive)

    # create and define remote directory
    Write-Host ($vm_name + " - creating directory...")
    $vm_temp = Invoke-Command -ComputerName $vm_name -ScriptBlock {[System.Environment]::GetEnvironmentVariable('TEMP','Machine')}
    $vm_make = Invoke-Command -ComputerName $vm_name -ScriptBlock {New-Item -Path $using:vm_temp -Name "hv-setup" -ItemType Directory -Force}

    # run remote commands
    Write-Host ($vm_name + " - running commands...")
    $log_adapter += $out_adapter = Invoke-Command -ComputerName $vm_name -ScriptBlock {
        Get-NetAdapter -Physical | Get-NetAdapterAdvancedProperty | Where-Object {$using:nic_advprop -contains $_.RegistryKeyword} | Sort-Object DisplayName,Name
    } 
    $log_address += $out_address = Invoke-Command -ComputerName $vm_name -ScriptBlock {
        Get-NetAdapterBinding | Where-Object {$_.ComponentID -eq "ms_tcpip"-and $_.Enabled} | Get-NetIPAddress -AddressFamily IPv4 | Sort-Object InterfaceAlias
    } 
    $log_gateway += $out_gateway = Invoke-Command -ComputerName $vm_name -ScriptBlock {
        Get-NetRoute -AddressFamily IPv4 -DestinationPrefix 0.0.0.0/0
    }
    # run the scripts
    Write-Host ($vm_name + " - starting session...")
    $vm_options = New-PSSessionOption -OutputBufferingMode Drop
    $vm_session = Invoke-Command -ComputerName $vm_name -InDisconnectedSession -SessionOption $vm_options -ScriptBlock {
        Set-Location $using:vm_make.PSPath
        "======================== $(Get-Date -Format FileDateTime) ========================" | Out-File -FilePath ".\ash-net-review.txt" -Append
        $using:out_adapter | Format-Table Name,DisplayName,DisplayValue | Out-File -FilePath ".\ash-net-review.txt" -Append
        $using:out_address | Format-Table IPAddress,InterfaceAlias,InterfaceIndex,PrefixLength,PrefixOrigin,SkipAsSource | Out-File -FilePath ".\ash-net-review.txt" -Append
        $using:out_gateway | Format-Table NextHop,DestinationPrefix,InterfaceIndex | Out-File -FilePath ".\ash-net-review.txt" -Append
    }

    # declare session name
    Write-Host ($vm_name + " - started session: " + $vm_session.Name)
}

# declare results
Write-Host ""
Write-Host "======================== Results ========================"
$log_adapter | Format-Table PSComputerName,Name,DisplayName,DisplayValue
$log_address | Format-Table PSComputerName,IPAddress,InterfaceAlias,InterfaceIndex,PrefixLength,PrefixOrigin,SkipAsSource
$log_gateway | Format-Table PSComputerName,NextHop,DestinationPrefix,InterfaceIndex
