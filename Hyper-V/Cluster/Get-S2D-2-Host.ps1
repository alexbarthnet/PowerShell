Param(  
    [Parameter(Mandatory = $True)]
    [string]$HostCsv,
    [string]$HostName
)

# verify the files
$file_names = @($HostCsv)
$file_names | ForEach-Object {
    If (Test-Path $_) {
        Write-Host ('Required file found: ' + $_)
    }
    Else {
        Write-Host ('Required file NOT found: ' + $_)
        Write-Host ('...exiting!')
        Exit
    }
}

# clear arrays
$log_adapter = @()
$log_vm_host = @()
$log_qospols = @()
$log_qostraf = @()

# import host information
$host_list = $null
If ($HostName) {
    # process single host
    $host_list = Import-Csv -Path $HostCsv | Where-Object { $_.Host -eq $HostName }
    If ($host_list.Count -lt 1) {
        Write-Host "...could not find" $HostName "in" $HostCsv
    }
} 
Else {
    # process all hosts
    $host_list = Import-Csv -Path $HostCsv
}

# process the cluster mapping file
$host_list | Sort-Object Host -Unique | ForEach-Object {
    # get base strings for this pass
    $host_name = $_.Host

    # declare start
    Write-Host "======================== $host_name ========================"

    # clear per-host objects
    $out_adapter = $null
    $out_vm_host = $null
    $out_qospols = $null
    $out_qostraf = $null

    # clear the DNS cache then resolve hostname
    Write-Host ($host_name + ' - resolving host...')
    Do {
        Clear-DnsClientCache
        $dns_found = $null
        $dns_found = Resolve-DnsName -Name $host_name -ErrorAction SilentlyContinue
    } Until ($dns_found)

    # verify connection to remote host
    Write-Host ($host_name + ' - checking host...')
    Do {
        $host_alive = $false
        $host_alive = Test-NetConnection -ComputerName $host_name -CommonTCPPort WINRM -InformationLevel Quiet
    } Until ($host_alive)

    # close existing sessions
    Write-Host ($host_name + ' - closing any existing sessions...')
    Get-PSSession -ComputerName $host_name | Remove-PSSession

    # start session for files
    Write-Host ($host_name + ' - starting main session...')
    $pss_main = New-PSSession -ComputerName $host_name

    # create and define remote directory
    Write-Host ($host_name + ' - creating directory...')
    $host_path = Invoke-Command -Session $pss_main -ScriptBlock {
        $host_temp = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')
        New-Item -Path $host_temp -Name 'hv-setup' -ItemType Directory -Force
    }

    # run remote commands
    Write-Host ($host_name + ' - running commands...')
    $log_adapter += $out_adapter = Invoke-Command -Session $pss_main -ScriptBlock { Get-NetAdapter -Physical | Sort-Object Name } 
    $log_vm_host += $out_vm_host = Invoke-Command -Session $pss_main -ScriptBlock { Get-VMHost }
    $log_qospols += $out_qospols = Invoke-Command -Session $pss_main -ScriptBlock { Get-NetQosPolicy | Sort-Object PriorityValue } 
    $log_qostraf += $out_qostraf = Invoke-Command -Session $pss_main -ScriptBlock { Get-NetQosTrafficClass }

    # save output to host
    Write-Host ($host_name + ' - saving output to host...')
    Invoke-Command -Session $pss_main -ScriptBlock {
        # define the file
        $host_review = Join-Path -Path $using:host_path.FullName -ChildPath ('ash-get-host-' + (Get-Date -Format FileDateTime) + '.txt')
        # build the file
        $file_headers = "======================== $(Get-Date -Format FileDateTime) ========================"
        $file_output1 = $using:out_adapter | Format-Table Name, InterfaceDescription, ifIndex, Status, MacAddress, LinkSpeed
        $file_output2 = $using:out_vm_host | Format-Table Name, @{Label = 'LiveMigrate'; Expression = { $_.VirtualMachineMigrationEnabled } }, @{Label = 'LiveMigrate Auth'; Expression = { $_.VirtualMachineMigrationAuthenticationType } }, @{Label = 'LiveMigrate Type'; Expression = { $_.VirtualMachineMigrationPerformanceOption } }
        $file_output3 = $using:out_qospols | Format-Table Name, Owner, NetworkProfile, Template, PriorityValue, NetDirectPort
        $file_output4 = $using:out_qostraf | Format-Table Name, PriorityFriendly, Bandwidth, Algorithm, PolicySet
        # write the file
        $file_headers | Out-File -FilePath $host_review -Append
        $file_output1 | Out-File -FilePath $host_review -Append
        $file_output2 | Out-File -FilePath $host_review -Append
        $file_output3 | Out-File -FilePath $host_review -Append
        $file_output4 | Out-File -FilePath $host_review -Append
    }

    # end session for files
    Write-Host ($host_name + ' - ending main session...')
    Remove-PSSession -Session $pss_main
}

# declare results
Write-Host ''
Write-Host '======================== Results ========================'
$log_adapter | Format-Table PSComputerName, Name, InterfaceDescription, ifIndex, Status, MacAddress, LinkSpeed
$log_vm_host | Format-Table PSComputerName, @{Label = 'LiveMigrate'; Expression = { $_.VirtualMachineMigrationEnabled } }, @{Label = 'LiveMigrate Auth'; Expression = { $_.VirtualMachineMigrationAuthenticationType } }, @{Label = 'LiveMigrate Type'; Expression = { $_.VirtualMachineMigrationPerformanceOption } }
$log_qospols | Format-Table PSComputerName, Name, Owner, Template, PriorityValue, NetDirectPort
$log_qostraf | Format-Table PSComputerName, Name, PriorityFriendly, Bandwidth, Algorithm, PolicySet
