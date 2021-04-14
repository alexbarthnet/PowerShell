# set the file locations
$map_network = '.\ASH\ash-map-network.txt'

# clear arrays and create feature set
$log_adapters = @()
$log_vmhost = @()
$log_qospolicy = @()
$log_qostraffic = @()

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
    $log_adapters += $out_adapters = Invoke-Command -ComputerName $vm_name -ScriptBlock {
        Get-NetAdapter -Physical | Sort-Object Name
    } 
    $log_vmhost += $out_vmhost = Invoke-Command -ComputerName $vm_name -ScriptBlock {
        Get-VMHost
    }
    $log_qospolicy += $out_qospolicy = Invoke-Command -ComputerName $vm_name -ScriptBlock {
        Get-NetQosPolicy | Sort-Object PriorityValue
    } 
    $log_qostraffic += $out_qostraffic = Invoke-Command -ComputerName $vm_name -ScriptBlock {
        Get-NetQosTrafficClass
    }
    # run the scripts
    Write-Host ($vm_name + ' - starting session...')
    $vm_options = New-PSSessionOption -OutputBufferingMode Drop
    $vm_session = Invoke-Command -ComputerName $vm_name -InDisconnectedSession -SessionOption $vm_options -ScriptBlock {
        Set-Location $using:vm_make.PSPath
        "======================== $(Get-Date -Format FileDateTime) ========================" | Out-File -FilePath '.\ash-net-review.txt' -Append
        $using:out_adapters | Format-Table Name, DisplayName, DisplayValue | Out-File -FilePath '.\ash-net-review.txt' -Append
        $using:out_vmhost | Format-Table Name, @{Label = 'LiveMigrate'; Expression = { $_.VirtualMachineMigrationEnabled } }, @{Label = 'LiveMigrate Auth'; Expression = { $_.VirtualMachineMigrationAuthenticationType } }, @{Label = 'LiveMigrate Type'; Expression = { $_.VirtualMachineMigrationPerformanceOption } }
        $using:out_qospolicy | Format-Table Name, Owner, NetworkProfile, Template, PriorityValue, NetDirectPort | Out-File -FilePath '.\ash-net-review.txt' -Append
        $using:out_qostraffic | Format-Table Name, PriorityFriendly, Bandwidth, Algorithm, PolicySet | Out-File -FilePath '.\ash-net-review.txt' -Append
    }

    # declare session name
    Write-Host ($vm_name + ' - started session: ' + $vm_session.Name)
}

# declare results
Write-Host ''
Write-Host '======================== Results ========================'
$log_adapters | Format-Table PSComputerName, Name, InterfaceDescription, ifIndex, Status, MacAddress, LinkSpeed
$log_vmhost | Format-Table PSComputerName, @{Label = 'LM Enabled'; Expression = { $_.VirtualMachineMigrationEnabled } }, @{Label = 'LM Auth'; Expression = { $_.VirtualMachineMigrationAuthenticationType } }, @{Label = 'LM Type'; Expression = { $_.VirtualMachineMigrationPerformanceOption } }
$log_qospolicy | Format-Table PSComputerName, Name, Owner, Template, PriorityValue, NetDirectPort
$log_qostraffic | Format-Table PSComputerName, Name, PriorityFriendly, Bandwidth, Algorithm, PolicySet
