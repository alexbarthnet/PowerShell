# strings
$switch_name = "ConvergedSwitch"
$switch_nic1 = "Port 1"
$switch_nic2 = "Port 2"

# load switch
$vswitch = $null
$vswitch = Get-VMSwitch -Name $switch_name
If ($vswitch) {
    Write-Host "ConvergedSwitch found"
}
Else {
    Write-Host "ConvergedSwitch not found, creating..."
    # create the switch
    New-VMSwitch -Name $switch_name -NetAdapterName $switch_nic1 -EnableEmbeddedTeaming $true -MinimumBandwidthMode Weight -AllowManagementOS $true
    Add-VMSwitchTeamMember -SwitchName $switch_name -NetAdapterName $switch_nic2
    # expand the switch
    Add-VMNetworkAdapter -ManagementOS -Name vSMB1 -SwitchName $switch_name -PassTru | Set-VMNetworkAdapterIsolation -IsolationMode Vlan -DefaultIsolationID 41 -AllowUntaggedTraffic $true
    Add-VMNetworkAdapter -ManagementOS -Name vSMB2 -SwitchName $switch_name -PassTru | Set-VMNetworkAdapterIsolation -IsolationMode Vlan -DefaultIsolationID 42 -AllowUntaggedTraffic $true
}
