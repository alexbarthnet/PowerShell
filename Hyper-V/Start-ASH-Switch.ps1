# set the file locations
$map_network = '.\ASH\ash-map-network.txt'
$ps1_vswitch = '.\Update-ASH-Virtual-Switch.ps1'

# process the cluster mapping file
Import-Csv -Path $map_network | Sort-Object Host -Unique | ForEach-Object {
    # get base strings for this pass
    $vm_name = $_.Host

    # declare start
    Write-Host ("======================== $vm_name ========================")

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
    $vm_path = ("\\" + $vm_name + "\" + ($vm_temp -replace '\:','$') + "\" + $vm_make.Name)

    # copy files for address and switch configuration
    Write-Host ($vm_name + " - copying files...")
    Copy-Item -Path $map_network -Destination $vm_path
    Copy-Item -Path $ps1_vswitch -Destination $vm_path

    # run the scripts
    Write-Host ($vm_name + " - starting session...")
    $vm_options = New-PSSessionOption -OutputBufferingMode Drop
    $vm_session = Invoke-Command -ComputerName $vm_name -InDisconnectedSession -SessionOption $vm_options -ScriptBlock {
        Set-Location $using:vm_make.PSPath
        Invoke-Expression $using:ps1_vswitch
    }

    # declare session name
    Write-Host ($vm_name + " - started session: " + $vm_session.Name)
}
