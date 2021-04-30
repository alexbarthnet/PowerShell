# set the file locations
$map_network = '.\ASH\ash-map-network.txt'
$map_feature = '.\ASH\ash-map-feature.txt'

# clear arrays and create feature set
$log_feature = @()
$feature_set = (Import-Csv -Path $map_feature).Feature

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
    $log_feature += $out_feature = Invoke-Command -ComputerName $vm_name -ScriptBlock {
        Get-WindowsFeature -Name $using:feature_set | Sort-Object Name
    } 

    # run the scripts
    Write-Host ($vm_name + ' - starting session...')
    $vm_options = New-PSSessionOption -OutputBufferingMode Drop
    $vm_session = Invoke-Command -ComputerName $vm_name -InDisconnectedSession -SessionOption $vm_options -ScriptBlock {
        $vm_review = ($using:vm_make.FullName + '.\ash-get-feature.txt')
        "======================== $(Get-Date -Format FileDateTime) ========================" | Out-File -FilePath $vm_review -Append
        $using:out_feature | Format-Table Name, InstallState | Out-File -FilePath $vm_review -Append
    }

    # declare session name
    Write-Host ($vm_name + ' - started session: ' + $vm_session.Name)
}

# declare results
Write-Host ''
Write-Host '======================== Results ========================'
$log_feature | Format-Table PSComputerName, Name, InstallState
