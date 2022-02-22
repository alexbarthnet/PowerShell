<#
.SYNOPSIS
Configures the virtual NICs, VM switches, and VM storage on a Hyper-V host that will be or is running Storage Spaces Direct (S2D).

.DESCRIPTION
Configures the virtual NICs, VM switches, and VM storage on a Hyper-V host that will be or is running Storage Spaces Direct (S2D) with information from a set of host-specific configuration files.

A parent script pushes this script and the configuration files to each Hyper-V host then starts the script using PowerShell Remoting.

.LINK
https://github.com/alexbarthnet/PowerShell/
#>

[CmdletBinding()]
param (
	[Parameter()]
	[string]$Hostname = [System.Net.Dns]::GetHostName().ToLower(),
	[Parameter()][ValidateScript({ Test-Path -Path $_ })]
	[string]$TempPath = [System.Environment]::GetEnvironmentVariable('TEMP', 'Machine'),
	[Parameter()][ValidateScript({ Test-Path -Path $_ })]
	[string]$FilePath = (Join-Path -Path $TempPath -ChildPath 'hv-setup'),
	[Parameter()][ValidateScript({ Test-Path -Path $_ })]
	[string]$LogFile = $PSCommandPath.Replace('.ps1', "-$(Get-Date -Format FileDateTime).txt"),
	[Parameter()][ValidateScript({ Test-Path -Path $_ })]
	[string]$NetworkCsv = (Join-Path -Path $FilePath -ChildPath "$($Hostname)-net.csv")
)

Try {
	# start logging
	Start-Transcript -Path $LogFile -Append -Force

	# check for the cluster
	$cluster = $null
	$cluster = Get-Service | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -ne 'Disabled' }
	If ($cluster) {
		Write-Host ("$Hostname - Cluster found, will create management switch and virtual adapters")
	}
	Else {
		Write-Host ("$Hostname - Cluster not found, will create management switch and skip virtual adapters")
	}

	# import CSV
	$map_network = Import-Csv -Path $NetworkCsv | Where-Object { $_.Host -eq $Hostname }

	# get the virtual switches from the network CSV
	Write-Host ("$Hostname - Processing virtual switch settings...")
	$map_network | Sort-Object -Property 'Switch' -Unique | ForEach-Object {
		# load variables
		$vswitch_name = $_.Switch
		# declare start
		Write-Host ("$Hostname,$vswitch_name - Verifying physical NICs for virtual switch...")
		# get the array of requested NICs for the switch
		$pnic_array = @()
		$pnic_names = $null
		$pnic_names = $map_network | Where-Object { $_.Switch -eq $vswitch_name } | Sort-Object -Property 'Adapter'
		$pnic_names | ForEach-Object {
			# get network adapters matching NIC names
			$pnic_name = $_.Adapter
			Write-Host ("$Hostname,$vswitch_name - Checking physical NIC: " + $pnic_name)
			$pnic = $null
			$pnic = Get-NetAdapter -Physical | Where-Object { $_.InterfaceAlias -eq $pnic_name }
			If ($pnic) {
				Write-Host ("$Hostname,$vswitch_name - Found physical NIC: " + $pnic_name)
				$pnic_array += $pnic
			}
			Else {
				Write-Host ("$Hostname,$vswitch_name - Physical NIC was NOT found: " + $pnic_name)
			}
		}

		# check for switch that matches name from CSV
		Write-Host ("$Hostname,$vswitch_name - Checking for switch...")
		$vswitch = $null
		$vswitch = Get-VMSwitchTeam | Where-Object { $_.Name -eq $vswitch_name }
		If ($vswitch) {
			# if switch found, check NICs in switch
			Write-Host ("$Hostname,$vswitch_name - Found switch: $vswitch_name")
			$pnic_array | ForEach-Object {
				$pnic = $_
				Write-Host ("$Hostname,$vswitch_name - Checking adapter: " + $pnic.InterfaceAlias)
				# if the NIC exists, check if NIC is already in the switch team
				If ($vswitch.NetAdapterInterfaceGuid -match [guid]$pnic.InterfaceGuid) {
					# if so, declare and move on
					Write-Host ("$Hostname,$vswitch_name - Adapter already in the switch team")
				}
				Else {
					# if not, add NIC to switch
					Write-Host ("$Hostname,$vswitch_name - Adapter not in the switch team, adding...")
					Add-VMSwitchTeamMember -SwitchName $vswitch_name -NetAdapterName $pnic.InterfaceAlias
				}
			}
			Write-Host ("$Hostname,$vswitch_name - Adapters verified, checking switch type...")
			If ($vswitch_name -eq 'Management') {
				# verify the management switch has a virtual NIC
				Write-Host ("$Hostname,$vswitch_name - Management switch found, checking for management adapter(s)...")
				$nic_mgmt = $null
				$nic_mgmt = Get-VMNetworkAdapter -ManagementOS | Where-Object { $_.SwitchName -eq $vswitch_name }
				# look for network adapters attached to the management switch...
				If ($nic_mgmt) {
					Write-Host ("$Hostname,$vswitch_name - Found " + $nic_mgmt.Count + ' management adapter(s)')
				}
				Else {
					# if no, create a network adapter
					Write-Host ("$Hostname,$vswitch_name - No management adapters found, creating initial management adapater...")
					$nic_mgmt = Add-VMNetworkAdapter -ManagementOS -SwitchName $vswitch_name -Name $vswitch_name
				}
			}
			Else {
				Write-Host ("$Hostname,$vswitch_name - Non-management switch found, skipping management adapter check...")
			}
		}
		Else {
			# if switch NOT found check the type of switch and if the cluster exists
			Write-Host ("$Hostname,$vswitch_name - Switch not found, checking switch type...")
			If ($pnic_array.Count -le 1) {
				# if only one physical NIC is defined to be in the switch, don't make a switch!
				Write-Host ("$Hostname,$vswitch_name - Switch defined with only one physical NIC, skipping switch creation: " + $pnic_array[0].Name)
			}
			ElseIf ($vswitch_name -eq 'Management') {
				# if switch NOT found and we SHOULD make the virtual network adapater, create switch with NICs and default adapter
				Write-Host ("$Hostname,$vswitch_name - Switch is Management, creating switch and virtual adapter with: " + $pnic_array[0].Name)
				$vswitch = New-VMSwitch -Name $vswitch_name -NetAdapterName $pnic_array[0].Name -EnableEmbeddedTeaming $true -MinimumBandwidthMode Weight -AllowManagementOS $true
				For ($i = 1; $i -lt $pnic_array.Count; $i++) {
					Write-Host ("$Hostname,$vswitch_name - Expanding switch with: " + $pnic_array[$i].Name)
					Add-VMSwitchTeamMember -SwitchName $vswitch_name -NetAdapterName $pnic_array[$i].Name
				}
			}
			Else {
				# if switch NOT found and we should NOT make the virtual network adapater, create switch with NICs without adapter
				Write-Host ("$Hostname,$vswitch_name - Switch is not Management and host is clustered, creating empty switch with: " + $pnic_array[0].Name)
				$vswitch = New-VMSwitch -Name $vswitch_name -NetAdapterName $pnic_array[0].Name -EnableEmbeddedTeaming $true -EnableIov $true -AllowManagementOS $false
				For ($i = 1; $i -lt $pnic_array.Count; $i++) {
					Write-Host ("$Hostname,$vswitch_name - Expanding switch with: " + $pnic_array[$i].Name)
					Add-VMSwitchTeamMember -SwitchName $vswitch_name -NetAdapterName $pnic_array[$i].Name
				}
			}
		}
	}
	
	# get the virtual NICs from the network CSV
	Write-Host ("$Hostname - Processing virtual NIC settings...")
	$map_network | Where-Object { $_.vNIC } | ForEach-Object {
		# load variables
		$pnic_name = $_.Adapter
		$vnic_name = $_.vNIC
		$vnic_addr = $_.Address
		$vnic_mask = $_.Mask
		$vnic_gway = $_.Gateway
		$vnic_vlan = $_.VLAN
		$vswitch_name = $_.Switch

		# verify that the vswitch exists
		Write-Host ("$Hostname,$vswitch_name,$vnic_name - Checking for virtual switch ...")
		$vswitch = $null
		$vswitch = Get-VMSwitchTeam | Where-Object { $_.Name -eq $vswitch_name }
		If ($vswitch) {
			# verify that any virtual NICs have a preference set
			Write-Host ("$Hostname,$vswitch_name,$vnic_name - Switch found by name, checking for virtual adapter(s)...")
			$nic_virtual = $null
			$nic_virtual = Get-VMNetworkAdapter -ManagementOS | Where-Object { $_.Name -match $vnic_name }
			# look for network adapters attached to the storage switch...
			If ($nic_virtual) {
				# declare virtual adapter exists
				Write-Host ("$Hostname,$vswitch_name,$vnic_name - Virtual adapter found by name, moving on...")
			}
			Else {
				# create virtual adapter after being found by switch name
				Write-Host ("$Hostname,$vswitch_name,$vnic_name - Virtual adapter not found by name, creating then renaming...")
				$nic_virtual = Add-VMNetworkAdapter -ManagementOS -SwitchName $vswitch_name -Name $vnic_name -PassThru
				$nic_virtual = $nic_virtual | Rename-VMNetworkAdapter -NewName $vnic_name -PassThru
			}

			# set the virtual adapter VLAN modes
			Write-Host ("$Hostname,$vswitch_name,$vnic_name - Virtual adapter configured to permit QoS tagging")
			$nic_virtual | Set-VMNetworkAdapter -IeeePriorityTag 'On'
			Write-Host ("$Hostname,$vswitch_name,$vnic_name - Virtual adapter VLAN mode set to Untagged")
			$nic_virtual | Set-VMNetworkAdapterVlan -Untagged
			If ($vnic_name -ne 'Management') {
				Write-Host ("$Hostname,$vswitch_name,$vnic_name - Virtual adapter isolation mode set to VLAN and default ID set to VLAN ID")
				$nic_virtual | Set-VMNetworkAdapterIsolation -IsolationMode 'VLAN' -AllowUntaggedTraffic $true -DefaultIsolationID $vnic_vlan
			}

			# update the name of the network adapter to remove the vEthernet nonsense
			$nic_network = $null
			$nic_network = Get-NetAdapter | Where-Object { $_.InterfaceAlias -match $vnic_name }
			If ($nic_network) {
				# check complete name of network adapter
				If ($nic_network.InterfaceAlias -eq $vnic_name) {
					Write-Host ("$Hostname,$vswitch_name,$vnic_name - Network adapter name is correct")
				}
				Else {
					Write-Host ("$Hostname,$vswitch_name,$vnic_name - Network adapter name is almost correct, fixing...")
					$nic_network = $nic_network | Rename-NetAdapter -NewName $vnic_name -PassThru
				}
				# check for DNS registration
				If ($vnic_name -match 'Manage') {
					Write-Host ("$Hostname,$vswitch_name,$vnic_name - DNS registration enabled for management NIC")
					$nic_network | Set-DnsClient -RegisterThisConnectionsAddress $true
				}
				Else {
					Write-Host ("$Hostname,$vswitch_name,$vnic_name - DNS registration disabled for non-management NIC")
					$nic_network | Set-DnsClient -RegisterThisConnectionsAddress $false
				}
			}

			# check jumbo packet settings
			$nic_size = $null
			$nic_size = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $vnic_name -and $_.RegistryKeyword -eq '*JumboPacket' }
			If ($nic_size) {
				Write-Host ("$Hostname,$vswitch_name,$vnic_name - Jumbo Packet found: " + $nic_size.DisplayValue)
				If ($vnic_name -match 'Manage') {
					If ($nic_size.RegistryValue -ne 1514) {
						Write-Host ("$Hostname,$vswitch_name,$vnic_name - Jumbo Packet on Management NIC not set to '1514', fixing...")
						Set-NetAdapterAdvancedProperty -Name $vnic_name -RegistryKeyword '*JumboPacket' -RegistryValue 1514
					}
				}
				Else {
					If ($nic_size.RegistryValue -ne 9014) {
						Write-Host ("$Hostname,$vswitch_name,$vnic_name - Jumbo Packet on non-Management NIC not set to '9014', fixing...")
						Set-NetAdapterAdvancedProperty -Name $vnic_name -RegistryKeyword '*JumboPacket' -RegistryValue 9014
					}
				}
			}
			Else {
				Write-Host ("$Hostname,$vswitch_name,$vnic_name - Jumbo Packet not found")
			}

			# check RDMA state on NIC
			$nic_rdma = $null
			$nic_rdma = Get-NetAdapterRdma | Where-Object { $_.Name -match $vnic_name }
			If ($nic_rdma) {
				If ($nic_rdma.Enabled) {
					Write-Host ("$Hostname,$vswitch_name,$vnic_name - RDMA enabled on vNIC")
				}
				Else {
					Write-Host ("$Hostname,$vswitch_name,$vnic_name - RDMA disabled, fixing...")
					$nic_rdma | Enable-NetAdapterRdma
					Start-Sleep -Seconds 15
				}
			}

			# enable QoS on the network adapter
			$nic_qos = $null
			$nic_qos = Get-NetAdapterQos | Where-Object { $_.Name -match $vnic_name }
			If ($nic_qos) {
				If ($nic_qos.Enabled) {
					Write-Host ("$Hostname,$vswitch_name,$vnic_name - QoS enabled")
				}
				Else {
					Write-Host ("$Hostname,$vswitch_name,$vnic_name - QoS not enabled, disabling NIC to enable QoS...")
					$nic_network | Disable-NetAdapter -Confirm:$false
					Start-Sleep -Seconds 5
					Write-Host ("$Hostname,$vswitch_name,$vnic_name - ...NIC disabled, enabling QoS...")
					$nic_qos | Enable-NetAdapterQos
					Start-Sleep -Seconds 15
					Write-Host ("$Hostname,$vswitch_name,$vnic_name - ...QoS enabled, enabling NIC...")
					$nic_network | Enable-NetAdapter
					Start-Sleep -Seconds 5
				}
			}
			Else {
				Write-Host ("$Hostname,$vswitch_name,$vnic_name - QoS not found")
			}

			# check the IP address on the networkadapter
			$nic_address = $null
			$nic_address = (Get-NetIPAddress -AddressFamily 'IPv4' | Where-Object { $_.InterfaceAlias -match $vnic_name }).IPv4Address
			If ($nic_address -eq $vnic_addr) {
				Write-Host ("$Hostname,$vswitch_name,$vnic_name - IP address correct, skipping...")
			}
			ElseIf ($nic_address -and ($nic_address -notlike '169.254.*')) {
				Write-Host ("$Hostname,$vswitch_name,$vnic_name - IP address incorrect, fixing...")
				$nic_address | Remove-NetIPAddress -Confirm:$false
				$nic_network | New-NetIPAddress -AddressFamily 'IPv4' -IPAddress $vnic_addr -PrefixLength $vnic_mask | Out-Null
			}
			Else {
				Write-Host ("$Hostname,$vswitch_name,$vnic_name - IP address missing, setting...")
				$nic_network | New-NetIPAddress -AddressFamily 'IPv4' -IPAddress $vnic_addr -PrefixLength $vnic_mask | Out-Null
			}

			# check the default route on the networkadapter
			If ($vnic_gway -eq 0) {
				Write-Host ("$Hostname,$vswitch_name,$vnic_name - No gateway defined for NIC")
			}
			Else {
				$nic_gateway = $null
				$nic_gateway = Get-NetRoute | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' }
				If ($nic_gateway.NextHop -eq $vnic_gway) {
					Write-Host ("$Hostname,$vswitch_name,$vnic_name - Default gateway correct")
				}
				ElseIf ($nic_gateway) {
					Write-Host ("$Hostname,$vswitch_name,$vnic_name - Default gateway incorrect, fixing...")
					$nic_gateway | Remove-NetRoute -Confirm:$false
					$nic_network | New-NetRoute -AddressFamily 'IPv4' -DestinationPrefix '0.0.0.0/0' -NextHop $vnic_gway | Out-Null
				}
				Else {
					Write-Host ("$Hostname,$vswitch_name,$vnic_name - Default gateway missing, creating...")
					$nic_network | New-NetRoute -AddressFamily 'IPv4' -DestinationPrefix '0.0.0.0/0' -NextHop $vnic_gway | Out-Null
				}
			}

			# check the IP address on the networkadapter
			$nic_mig_address = "$vnic_addr/32"
			$nic_mig_network = $null
			$nic_mig_network = Get-VMMigrationNetwork | Where-Object { $_.Subnet -eq $nic_mig_address }
			If ($nic_mig_network) {
				Write-Host ("$Hostname,$vswitch_name,$vnic_name - VM migration network exists for VNIC")
			}
			Else {
				Write-Host ("$Hostname,$vswitch_name,$vnic_name - VM migration network missing for VNIC, creating...")
				Add-VMMigrationNetwork -Subnet $nic_mig_address
			}

			# pause for network adapter changes to complete
			Write-Host ("$Hostname,$vswitch_name,$vnic_name - Pausing before team mapping")
			Start-Sleep -Seconds 5

			# force set the team mapping
			Write-Host ("$Hostname,$vswitch_name,$vnic_name - Team mapping configured")
			Set-VMNetworkAdapterTeamMapping -ManagementOS -VMNetworkAdapterName $vnic_name -PhysicalNetAdapterName $pnic_name
		}
		Else {
			Write-Host ("$Hostname,$vswitch_name,$vnic_name - Switch not found by name, re-run script to create the virtual switch...")
		}
	}
	
}
Finally {
	# stop logging
	Stop-Transcript
}
