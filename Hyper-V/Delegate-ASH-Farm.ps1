# get the WAC computer
$computer_wac = (Get-ADComputer -Identity $env:computername)

# clear the list of SPNs
$cluster_spns = @()

# get the short name of the hypervisors
$cluster_farm = (Import-Csv -Path .\ash\ash-map-hypervisors.txt).Hypervisor | Get-ADComputer

# create the list of SPNs
ForEach ($computer in $cluster_farm) {$cluster_spns += ('cifs/' + $computer.DNSHostName.ToLower())}
ForEach ($computer in $cluster_farm) {$cluster_spns += ('Microsoft Virtual System Migration Service/' + $computer.DNSHostName.ToLower())}

# update each hypervisor object
ForEach ($computer in $cluster_farm) {
    # enable Kerberos delegation from WAC
    Write-Host ($computer.DNSHostName + " - enabling Kerberos delegation to WAC host")
    Set-ADComputer -Identity $computer -PrincipalsAllowedToDelegateToAccount $computer_wac

    # enable Kerberos constrained delegation for hypervisors
    Write-Host ($computer.DNSHostName + " - enabling Kerberos constrained delegation")
    Set-ADAccountControl -Identity $computer -TrustedToAuthForDelegation $true
    
    # enable Kerberos constrained delegation for hypervisors
    Write-Host ($computer.DNSHostName + " - clearing delegated SPNs")
    Set-ADObject -Identity $computer -Clear 'msDS-AllowedToDelegateTo'

    # add SPNs to each hypervisor
    ForEach ($spn in $cluster_spns) {
        If ($spn -notmatch $computer.DNSHostname){
            Write-Host ($computer.DNSHostName + " - adding delegated SPN: " + $spn)
            Set-ADObject -Identity $computer -Add @{'msDS-AllowedToDelegateTo' = $spn}
        }
    }
}
