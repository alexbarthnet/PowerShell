<#
.SYNOPSIS
Configures the physical NICs on a Hyper-V host that will be or is running Storage Spaces Direct (S2D).

.DESCRIPTION
Configures the physical NICs on a Hyper-V host that will be or is running Storage Spaces Direct (S2D) with information from a set of host-specific configuration files.

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
	[string]$NicCsv = (Join-Path -Path $FilePath -ChildPath "$($Hostname)-nic.csv")
)

# pass 1: physical NIC rename
Try {
	# start logging
	Start-Transcript -Path $LogFile -Append -Force

	# get the adapters that are a hardware device to exclude virtual adapters
	$nic_hw_all = Get-NetAdapter -Physical | Where-Object { $_.PnPDeviceID -notlike 'USB*' } | Sort-Object -Property 'InterfaceAlias'
	ForEach ($nic_hw in $nic_hw_all) {
		# set base names
		$nic_old = $nic_hw.Name
		$nic_new = $null

		# get hardware info
		$nic_hw_info = Get-NetAdapterHardwareInfo -Name $nic_old -ErrorAction 'SilentlyContinue'
		$nic_adv_props = Get-NetAdapterAdvancedProperty -Name $nic_old -ErrorAction 'SilentlyContinue'

		# try to build the name from slot and port information
		If ($nic_hw_info.SlotNumber) {
			$nic_new = ('Slot ' + $nic_hw_info.SlotNumber + ' Port ' + ($nic_hw_info.FunctionNumber + 1))
			$nic_new_via = 'slot/port number'
		}
		Else {
			$nic_new = ('Port ' + ($nic_hw_info.FunctionNumber + 1))
			$nic_new_via = 'port number'
		}

		# try to build the name from PCI device label
		$nic_pci = $nic_hw_info.PciDeviceLabelString
		If ($null -ne $nic_pci) {
			$nic_new = $nic_pci
			$nic_new_via = 'PCI device label'
		}

		# try to build the name from Hyper-V
		$nic_adv = ($nic_adv_props | Where-Object { $_.RegistryKeyword -eq 'HyperVNetworkAdapterName' }).DisplayValue
		If ($null -ne $nic_adv) {
			$nic_new = $nic_adv
			$nic_new_via = 'Hyper-V'
		}

		# if the new name was generated...
		If ($nic_new) {
			If ($nic_old -eq 'Management') {
				# if old is "Management", leave alone; likely already configured by WAC
				Write-Host "$Hostname - '$nic_old' NOT renamed; a NIC named 'Management' is not renamed"
			}
			ElseIf ($nic_new -ne $nic_old) {
				# if new is different from old, set the NIC and declare the source
				Write-Host "$Hostname - '$nic_old' renamed to '$nic_new' via '$nic_new_via'"
				Rename-NetAdapter -Name $nic_old -NewName $nic_new
			}
			Else {
				# if new is the same as old, declare and move on
				Write-Host "$Hostname - '$nic_old' NOT renamed; generated name matches current name"
			}
		}
		Else {
			# if new name was not generated...
			Write-Host "$Hostname - '$nic_old' NOT renamed; could not generate name"
		}
	}
}
Finally {
	# stop logging
	Stop-Transcript
}

# pass 2: physical NIC configure
Try {
	# start logging
	Start-Transcript -Path $LogFile -Append -Force

	# import CSV
	$map_network = Import-Csv -Path $NicCsv | Where-Object { $_.Host -eq $Hostname -and $_.Adapter }

	# process the network mapping file - add phase
	Write-Host ("$Hostname - Checking physical NIC settings...")
	$map_network | ForEach-Object {
		# assign CSV values to objects
		$nic_name = $_.Adapter
		$nic_addr = $_.Address
		$nic_mask = $_.Mask
		$nic_gway = $_.Gateway
		$nic_vnic = $_.vNIC
		$nic_dns = $_.DnsServers

		# check for IP addresses
		# IP not found on NIC, check if requested NIC exists
		Write-Host ("$Hostname, $nic_name, $nic_addr - Checking for NIC...")
		$nic_exists = $null
		$nic_exists = Get-NetAdapter -Physical | Where-Object { $_.InterfaceAlias -eq $nic_name }
		If ($nic_exists) {
			# requested NIC found, check if requested NIC has IPv4 enabled
			Write-Host ("$Hostname, $nic_name, $nic_addr - NIC found, checking for IP bindings...")
			$nic_bound = $null
			$nic_bound = $nic_exists | Get-NetAdapterBinding | Where-Object { $_.ComponentID -eq 'ms_tcpip' -and $_.Enabled }
			If ($nic_bound) {
				# requested NIC has IPv4 bound, check IP addresses
				Write-Host ("$Hostname, $nic_name, $nic_addr - IPv4 bound, checking IPv4 settings...")

				# check for DHCP on current NIC
				$nic_dhcp_on = $null
				$nic_dhcp_on = $nic_exists | Get-NetIPInterface | Where-Object { $_.AddressFamily -eq 'IPv4' -and $_.DHCP }
				If ($nic_dhcp_on) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - ...DHCPv4 enabled found enabled on NIC, disabling...")
					$nic_dhcp_on | Set-NetIPInterface -Dhcp 'Disabled'
				}

				# check for wrong address on current NIC
				$nic_addr_on_nic = $null
				$nic_addr_on_nic = Get-NetIPAddress | Where-Object { $_.IPv4Address -ne $nic_addr -and $_.AddressFamily -eq 'IPv4' -and $_.InterfaceAlias -eq $nic_name -and $_.InterfaceAlias -ne $nic_vnic }
				If ($nic_addr_on_nic -and ($nic_addr_on_nic -notlike '169.254.*')) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - ...wrong IP address found on current NIC, removing '$($nic_addr_on_nic.IPv4Address)' from '$($nic_addr_on_nic.InterfaceAlias)'")
					$nic_addr_on_nic | Remove-NetIPAddress -Confirm:$false
				}

				# check for requested address on other NICs
				$nic_addr_on_sys = $null
				$nic_addr_on_sys = Get-NetIPAddress | Where-Object { $_.IPv4Address -eq $nic_addr -and $_.AddressFamily -eq 'IPv4' -and $_.InterfaceAlias -ne $nic_name -and $_.InterfaceAlias -ne $nic_vnic }
				If ($nic_addr_on_sys) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - ...correct IP address found on other NIC, removing '$($nic_addr_on_sys.IPv4Address)' from '$($nic_addr_on_sys.InterfaceAlias)'")
					$nic_addr_on_sys | Remove-NetIPAddress -Confirm:$false
				}

				# check for requested address on current NIC
				$nic_correct_ip = $null
				$nic_correct_ip = Get-NetIPAddress | Where-Object { $_.IPv4Address -eq $nic_addr -and $_.AddressFamily -eq 'IPv4' -and ($_.InterfaceAlias -eq $nic_name -or $_.InterfaceAlias -eq $nic_vnic) }
				If ($nic_correct_ip) {
					# IP address found
					Write-Host ("$Hostname, $nic_name, $nic_addr - ...correct IP address found on correct physical or virtual NIC")
				}
				Else {
					Write-Host ("$Hostname, $nic_name, $nic_addr - ...setting IP address")
					$nic_exists | New-NetIPAddress -AddressFamily IPv4 -IPAddress $nic_addr -PrefixLength $nic_mask | Out-Null
				}

				# check for gateway
				If ([string]::IsNullOrEmpty($nic_gway) -or $nic_gway -eq 0) {
					# check for default route on current NIC
					$nic_wrong_gw = $null
					$nic_wrong_gw = Get-NetRoute | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and ($_.InterfaceAlias -eq $nic_name -or $_.InterfaceAlias -eq $nic_vnic) }
					If ($nic_wrong_gw) {
						Write-Host ("$Hostname, $nic_name, $nic_addr - ...current NIC has default route and should not, removing route to '$($nic_wrong_gw.DestinationPrefix)' from '$($nic_wrong_gw.InterfaceAlias)'")
						$nic_wrong_gw | Remove-NetRoute -Confirm:$false
					}
					Else {
						Write-Host ("$Hostname, $nic_name, $nic_addr - ...gateway not found on current NIC")
					}
					# current NIC lacks gateway, clear the DNS servers
					Write-Host ("$Hostname, $nic_name, $nic_addr - ...clearing DNS servers")
					$nic_exists | Set-DnsClientServerAddress -ServerAddress $null
					# current NIC lacks gateway, disable DNS registration
					Write-Host ("$Hostname, $nic_name, $nic_addr - ...disabling DNS registration")
					$nic_exists | Set-DnsClient -RegisterThisConnectionsAddress $false

				}
				Else {
					# check for default route on other physical and virtual NICs
					$nic_route = $null
					$nic_route = Get-NetRoute | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.InterfaceAlias -ne $nic_name -and $_.InterfaceAlias -ne $nic_vnic }
					$nic_route | ForEach-Object {
						Write-Host ("$Hostname, $nic_name, $nic_addr - ...gateway found on other NIC, removing route to '$($_.DestinationPrefix)' from '$($_.InterfaceAlias)'")
						$_ | Remove-NetRoute -Confirm:$false
					}

					# check for default route on current NIC
					$nic_correct_gw = $null
					$nic_correct_gw = Get-NetRoute | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and ($_.InterfaceAlias -eq $nic_name -or $_.InterfaceAlias -eq $nic_vnic) }
					If ($nic_correct_gw) {
						Write-Host ("$Hostname, $nic_name, $nic_addr - ...default gateway found on correct physical or virtual NIC")
					}
					Else {
						Write-Host ("$Hostname, $nic_name, $nic_addr - ...default gateway not found, adding to physical NIC")
						$null = New-NetRoute -DestinationPrefix '0.0.0.0/0' -NextHop $nic_gway -InterfaceAlias $nic_name
					}

					# current NIC has gateway, set the DNS servers
					If ($nic_dns) {
						Write-Host ("$Hostname, $nic_name, $nic_addr - ...setting DNS servers: $nic_dns")
						$nic_exists | Set-DnsClientServerAddress -ServerAddress $nic_dns.Split(';')
					}
					Else {
						Write-Host ("$Hostname, $nic_name, $nic_addr - ...cannot set DNS servers: no value provided")
					}
					# requested NIC has gateway, enable DNS registration
					Write-Host ("$Hostname, $nic_name, $nic_addr - ...enabling DNS registration")
					$nic_exists | Set-DnsClient -RegisterThisConnectionsAddress $true
				}
			}
			Else {
				# requested NIC does not have IPv4 bound and likely a virtual NIC, exit loop
				Write-Host ("$Hostname, $nic_name, $nic_addr - IPv4 not bound, skipping IP configuration...")
			}

			# check jumbo packet settings
			$nic_size = $null
			$nic_size = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*JumboPacket' }
			If ($nic_size) {
				Write-Host ("$Hostname, $nic_name, $nic_addr - Jumbo Packet settings found: " + $nic_size.DisplayValue)
				If ($nic_name -notmatch 'Manage' -and $nic_name -notmatch 'Port 0') {
					If ($nic_size.RegistryValue -ne 9014) {
						Write-Host ("$Hostname, $nic_name, $nic_addr - Jumbo Packet on non-Management NIC not set to '9014', fixing...")
						Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*JumboPacket' -RegistryValue 9014
					}
				}
				Else {
					If ($nic_size.RegistryValue -ne 1514) {
						Write-Host ("$Hostname, $nic_name, $nic_addr - Jumbo Packet on Management NIC not set to '1514', fixing...")
						Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*JumboPacket' -RegistryValue 1514
					}
				}
			}
			Else {
				Write-Host ("$Hostname, $nic_name, $nic_addr - Jumbo Packet settings not found")
			}

			# check encapsulation overhead
			$nic_over = $null
			$nic_over = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*EncapOverhead' }
			If ($nic_over) {
				Write-Host ("$Hostname, $nic_name, $nic_addr - Encapsulation Overhead settings found: " + $nic_over.DisplayValue)
				If ($nic_name -notmatch 'Manage' -and $nic_name -notmatch 'Port 0') {
					If ($nic_over.RegistryValue -ne 160) {
						Write-Host ("$Hostname, $nic_name, $nic_addr - Encapsulation Overhead on non-Management NIC not set to '160', fixing...")
						Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*EncapOverhead' -RegistryValue 160
					}
				}
				Else {
					If ($nic_over.RegistryValue -ne 0) {
						Write-Host ("$Hostname, $nic_name, $nic_addr - Encapsulation Overhead on Management NIC not set to '0', fixing...")
						Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*EncapOverhead' -RegistryValue 0
					}
				}
			}
			Else {
				Write-Host ("$Hostname, $nic_name, $nic_addr - Encapsulation Overhead settings not found")
			}

			# check Encapsulated Packet Offload
			$nic_offp = $null
			$nic_offp = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*EncapsulatedPacketTaskOffload' }
			If ($nic_offp) {
				Write-Host ("$Hostname, $nic_name, $nic_addr - Encapsulated Packet Offload settings found: " + $nic_offp.DisplayValue)
				If ($nic_offp.RegistryValue -ne 1) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - Encapsulated Packet Offload not enabled, fixing...")
					Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*EncapsulatedPacketTaskOffload' -RegistryValue 1
				}
			}
			Else {
				Write-Host ("$Hostname, $nic_name, $nic_addr - Encapsulated Packet Offload settings not found")
			}

			# check Encapsulated Packet Offload NVGRE
			$nic_offn = $null
			$nic_offn = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*EncapsulatedPacketTaskOffloadNvgre' }
			If ($nic_offn) {
				Write-Host ("$Hostname, $nic_name, $nic_addr - Encapsulated Packet Offload for NVGRE settings found: " + $nic_offn.DisplayValue)
				If ($nic_offn.RegistryValue -ne 1) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - Encapsulated Packet Offload for NVGRE not enabled, fixing...")
					Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*EncapsulatedPacketTaskOffloadNvgre' -RegistryValue 1
				}
			}
			Else {
				Write-Host ("$Hostname, $nic_name, $nic_addr - Encapsulated Packet Offload for NVGRE settings not found")
			}

			# check Encapsulated Packet Offload VXLAN
			$nic_offv = $null
			$nic_offv = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*EncapsulatedPacketTaskOffloadVxlan' }
			If ($nic_offv) {
				Write-Host ("$Hostname, $nic_name, $nic_addr - Encapsulated Packet Offload for VXLAN settings found: " + $nic_offv.DisplayValue)
				If ($nic_offv.RegistryValue -ne 1) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - Encapsulated Packet Offload for VXLAN not enabled, fixing...")
					Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*EncapsulatedPacketTaskOffloadVxlan' -RegistryValue 1
				}
			}
			Else {
				Write-Host ("$Hostname, $nic_name, $nic_addr - Encapsulated Packet Offload for VXLAN settings not found")
			}

			# check Flow Control
			$nic_flow = $null
			$nic_flow = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*FlowControl' }
			If ($nic_flow) {
				Write-Host ("$Hostname, $nic_name, $nic_addr - Flow Control settings found: " + $nic_flow.DisplayValue)
				If ($nic_flow.RegistryValue -ne 4) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - Flow Control not set to 'Auto Negotiation', fixing...")
					Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*FlowControl' -RegistryValue 4
				}
			}
			Else {
				Write-Host ("$Hostname, $nic_name, $nic_addr - Flow Control settings not found")
			}

			# check NUMA node
			$nic_numa = $null
			$nic_numa = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*NumaNodeId' }
			If ($nic_numa) {
				Write-Host ("$Hostname, $nic_name, $nic_addr - NUMA node ID found: " + $nic_numa.DisplayValue)
				If ($nic_numa.RegistryValue -ne 65535) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - NUMA node ID not set to '65535', fixing...")
					Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*NumaNodeId' -RegistryValue 65535
				}
			}
			Else {
				Write-Host ("$Hostname, $nic_name, $nic_addr - NUMA node ID settings not found")
			}

			# check PTP Hardware Timestamp
			$nic_ptph = $null
			$nic_ptph = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*PtpHardwareTimestamp' }
			If ($nic_ptph) {
				Write-Host ("$Hostname, $nic_name, $nic_addr - PTP Hardware Timestamp found: " + $nic_ptph.DisplayValue)
				If ($nic_ptph.RegistryValue -ne 0) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - PTP Hardware Timestamp not disabled, fixing...")
					Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*PtpHardwareTimestamp' -RegistryValue 0
				}
			}
			Else {
				Write-Host ("$Hostname, $nic_name, $nic_addr - PTP Hardware Timestamp settings not found")
			}

			# check QoS Offload
			$nic_qoff = $null
			$nic_qoff = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*QosOffload' }
			If ($nic_qoff) {
				Write-Host ("$Hostname, $nic_name, $nic_addr - QoS Offload settings found: " + $nic_qoff.DisplayValue)
				If ($nic_qoff.RegistryValue -ne 0) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - QoS Offload settings not disabled, fixing...")
					Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*QosOffload' -RegistryValue 0
				}
			}
			Else {
				Write-Host ("$Hostname, $nic_name, $nic_addr - QoS Offload settings not found")
			}

			# check Recv Segment Coalescing (IPv4)
			$nic_rsc4 = $null
			$nic_rsc4 = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*RscIPv4' }
			If ($nic_rsc4) {
				Write-Host ("$Hostname, $nic_name, $nic_addr - Recv Segment Coalescing (IPv4) settings found: " + $nic_rsc4.DisplayValue)
				If ($nic_rsc4.RegistryValue -ne 1) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - Recv Segment Coalescing (IPv4) settings not enabled, fixing...")
					Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*RscIPv4' -RegistryValue 1
				}
			}
			Else {
				Write-Host ("$Hostname, $nic_name, $nic_addr - Recv Segment Coalescing (IPv4) settings not found")
			}

			# check Recv Segment Coalescing (IPv6)
			$nic_rsc6 = $null
			$nic_rsc6 = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*RscIPv6' }
			If ($nic_rsc6) {
				Write-Host ("$Hostname, $nic_name, $nic_addr - Recv Segment Coalescing (IPv6) settings found: " + $nic_rsc6.DisplayValue)
				If ($nic_rsc6.RegistryValue -ne 1) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - Recv Segment Coalescing (IPv6) settings not enabled, fixing...")
					Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*RscIPv6' -RegistryValue 1
				}
			}
			Else {
				Write-Host ("$Hostname, $nic_name, $nic_addr - Recv Segment Coalescing (IPv6) settings not found")
			}

			# check TCP/UDP Checksum Offload (IPv4)
			$nic_tco4 = $null
			$nic_tco4 = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*TCPUDPChecksumOffloadIPv4' }
			If ($nic_tco4) {
				Write-Host ("$Hostname, $nic_name, $nic_addr - TCP/UDP Checksum Offload (IPv4) settings found: " + $nic_tco4.DisplayValue)
				If ($nic_tco4.RegistryValue -ne 3) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - TCP/UDP Checksum Offload (IPv4) settings not 'Rx & Tx Enabled', fixing...")
					Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*TCPUDPChecksumOffloadIPv4' -RegistryValue 3
				}
			}
			Else {
				Write-Host ("$Hostname, $nic_name, $nic_addr - TCP/UDP Checksum Offload (IPv4) settings not found")
			}

			# check TCP/UDP Checksum Offload (IPv6)
			$nic_tco6 = $null
			$nic_tco6 = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*TCPUDPChecksumOffloadIPv6' }
			If ($nic_tco6) {
				Write-Host ("$Hostname, $nic_name, $nic_addr - TCP/UDP Checksum Offload (IPv6) settings found: " + $nic_tco6.DisplayValue)
				If ($nic_tco6.RegistryValue -ne 3) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - TCP/UDP Checksum Offload (IPv6) settings not 'Rx & Tx Enabled', fixing...")
					Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*TCPUDPChecksumOffloadIPv6' -RegistryValue 3
				}
			}
			Else {
				Write-Host ("$Hostname, $nic_name, $nic_addr - TCP/UDP Checksum Offload (IPv6) settings not found")
			}













			# check VMQ
			$nic_vmq = $null
			$nic_vmq = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*VMQ' }
			If ($nic_vmq) {
				Write-Host ("$Hostname, $nic_name, $nic_addr - Virtual Machine Queues found: " + $nic_vmq.DisplayValue)
				# check for iWARP
				If ($nic_vmq.RegistryValue -ne 1) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - Virtual Machine Queues not enabled, fixing...")
					Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*VMQ' -RegistryValue 1
				}
			}
			Else {
				Write-Host ("$Hostname, $nic_name, $nic_addr - Virtual Machine Queues not found")
			}

			# check RDMA technology
			$nic_tech = $null
			$nic_tech = Get-NetAdapterAdvancedProperty | Where-Object { $_.Name -eq $nic_name -and $_.RegistryKeyword -eq '*NetworkDirectTechnology' }
			If ($nic_tech) {
				$nic_rdma_on = $true
				Write-Host ("$Hostname, $nic_name, $nic_addr - RDMA Technology found: " + $nic_tech.DisplayValue)
				# check for iWARP
				If ($nic_tech.RegistryValue -ne 1) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - RDMA Technology not set to 'iWARP', fixing...")
					Set-NetAdapterAdvancedProperty -Name $nic_name -RegistryKeyword '*NetworkDirectTechnology' -RegistryValue 1
				}
			}
			Else {
				$nic_rdma_on = $false
				Write-Host ("$Hostname, $nic_name, $nic_addr - RDMA Technology not found")
			}

			# check RDMA state on NIC
			$nic_rdma = $null
			$nic_rdma = Get-NetAdapterRdma | Where-Object { $_.Name -match $nic_name }
			If ($nic_rdma) {
				If ($nic_rdma.Enabled -and $nic_rdma_on) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - RDMA enabled")
				}
				ElseIf ($nic_rdma_on) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - RDMA supported and not enabled, fixing...")
					$nic_rdma | Enable-NetAdapterRdma
					Start-Sleep -Seconds 15
				}
				ElseIf ($nic_rdma.Enabled) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - RDMA not supported and enabled, fixing...")
					$nic_rdma | Disable-NetAdapterRdma
					Start-Sleep -Seconds 15
				}
				Else {
					Write-Host ("$Hostname, $nic_name, $nic_addr - RDMA not enabled")
				}
			}
			Else {
				Write-Host ("$Hostname, $nic_name, $nic_addr - RDMA not found")
			}

			# enable QoS on the network adapter
			$nic_qos = $null
			$nic_qos = Get-NetAdapterQos | Where-Object { $_.Name -match $nic_name }
			If ($nic_qos) {
				If ($nic_qos.Enabled) {
					Write-Host ("$Hostname, $nic_name, $nic_addr - QoS enabled")
				}
				Else {
					Write-Host ("$Hostname, $nic_name, $nic_addr - QoS not enabled, disabling NIC to enable QoS...")
					$nic_exists | Disable-NetAdapter -Confirm:$false
					Start-Sleep -Seconds 5
					Write-Host ("$Hostname, $nic_name, $nic_addr - ...NIC disabled, enabling QoS...")
					$nic_qos | Enable-NetAdapterQos
					Start-Sleep -Seconds 15
					Write-Host ("$Hostname, $nic_name, $nic_addr - ...QoS enabled, enabling NIC...")
					$nic_exists | Enable-NetAdapter
					Start-Sleep -Seconds 5
				}
			}
			Else {
				Write-Host ("$Hostname, $nic_name, $nic_addr - QoS not found")
			}
		}
		Else {
			# requested NIC was NOT found, exit loop
			Write-Host ("$Hostname, $nic_name, $nic_addr - NIC was NOT found, skipping...")
		}
	}
}
Finally {
	# stop logging
	Stop-Transcript
}
