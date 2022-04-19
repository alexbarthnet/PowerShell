Param(
	[Parameter(Mandatory = $True, ValueFromPipeline = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$VmJson,
	[Parameter(Mandatory = $True)]
	[string[]]$VmName,
	[Parameter()]
	[string]$VMHost,
	[Parameter()]
	[switch]$UseDefaultPathOnHost,
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
)

Function Remove-DeviceFromSccm {
	param (
		[Parameter()]
		[object]$VmParams,
		[string]$VmMacAddress
	)

	# define optional objects from CSV - OSD general parameters
	$vm_name = $VmParams.VMName
	$vm_deployment_server = $VmParams.DeploymentServer

	# format mac address for SCCM
	If ($VmMacAddress -like '*:*') {
		$vm_mac_address = ($VmMacAddress -split '(\w{2})' | Where-Object { $_ -ne '' }) -join ':'
		Write-Host ("$Hostname,$vm_host,$vm_name - formatted MAC address for SCCM: " + $vm_mac_address)
	}

	# connect to SCCM remotely
	Write-Host ("$Hostname,$vm_host,$vm_name - connecting to SCCM: " + $vm_deployment_server)
	Invoke-Command -ComputerName $vm_deployment_server -ScriptBlock {
		# set local variables
		$script_host = $using:Hostname
		$sccm_server = $using:vm_deployment_server
		$device_name = $using:vm_name
		$device_hwid = $using:vm_mac_address

		# retrieve the psd1 file
		$cm_psd1_path = 'HKLM:\SOFTWARE\Microsoft\SMS\Setup'
		$cm_psd1_item = 'UI Installation Directory'
		$cm_psd1 = (Get-ItemProperty -Path $cm_psd1_path -Name $cm_psd1_item).$($cm_psd1_item) + '\bin\ConfigurationManager.psd1'

		# retrieve the site code
		$cm_site_path = 'HKLM:\SOFTWARE\Microsoft\SMS\Identification'
		$cm_site_item = 'Site Code'
		$cm_site = (Get-ItemProperty -Path $cm_site_path -Name $cm_site_item).$($cm_site_item)

		# connect to SCCM
		Write-Host ("$script_host,$sccm_server,$device_name - importing SCCM module")
		Import-Module $cm_psd1
		Write-Host ("$script_host,$sccm_server,$device_name - setting location to site drive")
		Set-Location ($cm_site + ':\')

		# build strings for WMI query
		$cm_space = 'Root\SMS\Site_' + $cm_site
		$cm_class = 'SMS_R_System'

		# empty variables
		$device_resid = $null

		# check for device by mac address via WMI call
		If ($device_hwid) {
			Write-Host ("$script_host,$sccm_server,$device_name - retrieving device with MAC address: " + $device_hwid)
			$device_found_by_mac = @()
			$device_found_by_mac += Get-WmiObject -Namespace $cm_space -Class $cm_class | Where-Object { $_.MacAddresses -eq $device_hwid }
			switch ($device_found_by_mac.Count) {
				1 {
					$device_resid = $device_found_by_mac.ResourceId
					Write-Host ("$script_host,$sccm_server,$device_name - ...found device by MAC address, resource ID: $device_resid")
				}
				0 {
					$device_resid = $null
					Write-Host ("$script_host,$sccm_server,$device_name - ...could not find device by MAC address")
				}
				Default {
					Write-Host ("$script_host,$sccm_server,$device_name - EXCEPTION: multiple devices found with the same MAC address")
					Write-Host ("$script_host,$sccm_server,$device_name - ...remove extra devices before continuing")
					Break
				}
			}
		}

		# check for device by mac address via WMI call
		If ($null -eq $device_resid) {
			Write-Host ("$script_host,$sccm_server,$device_name - retrieving device with name: " + $device_name)
			$device_found_by_name = @()
			$device_found_by_name += Get-WmiObject -Namespace $cm_space -Class $cm_class | Where-Object { $_.Name -eq $device_name }
			switch ($device_found_by_name.Count) {
				1 {
					$device_resid = $device_found_by_name.ResourceId
					Write-Host ("$script_host,$sccm_server,$device_name - ...found device by name, resource ID: $device_resid")
				}
				0 {
					$device_resid = $null
					Write-Host ("$script_host,$sccm_server,$device_name - ...could not find device by name")
				}
				Default {
					Write-Host ("$script_host,$sccm_server,$device_name - EXCEPTION: multiple devices found with the same name")
					Write-Host ("$script_host,$sccm_server,$device_name - ...remove extra devices before continuing")
					Break
				}
			}
		}

		# remove the device
		If ($device_resid) {
			# reset PXE state
			Write-Host ("$script_host,$sccm_server,$device_name - resetting PXE deployment status for VM")
			Clear-CMPxeDeployment -ResourceId $device_resid
			# remove device
			Write-Host ("$script_host,$sccm_server,$device_name - removing device")
			Remove-CMResource -ResourceId $device_resid -Force
		}
	}
}

# create VM list from parameters
$vm_list = @()
If ($VmName) {
	$vm_list += (Get-Content -Path $VmJson | ConvertFrom-Json) | Where-Object { $_.VMHost -and $_.VMName -in $VMName }
}

# check VM list
If ($vm_list.Count -eq 0) {
	Write-Host ("$Hostname - VM(s) not found in Json, exiting!")
	Return
}

# process VM list
ForEach ($VmParams in $vm_list) {
	# define required strings
	$vm_name = $VmParams.VMName
	$vm_host = $VmParams.VMHost

	# # define optional strings for networking
	$vm_dhcp_server = $VmParams.DhcpServer
	$vm_dhcp_scope = $VmParams.DhcpScope
	$vm_ip_address = $VmParams.IPAddress

	# define optional strings for deployment
	$vm_deployment_method = $VmParams.DeploymentMethod
	$vm_deployment_server = $VmParams.DeploymentServer
	$vm_deployment_domain = $VmParams.Domain

	# clear check objects
	$vm_on_host = $null
	$vm_in_the_cloud = $false
	$vm_cluster_group = $null
	$vm_host_clustered = $null

	# check for host overrides
	If ($VMHost) { $vm_host = $VMHost }

	# check host
	switch ($vm_host) {
		'cloud' {
			$vm_in_the_cloud = $true
		}
		$null {
			Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: host not defined for VM")
			Return
		}
		Default {
			Try {
				$null = Test-WSMan -ComputerName $vm_host -Authentication 'Default'
				Write-Host ("$Hostname,$vm_host,$vm_name - connected to host")
			}
			Catch {
				Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: could not connect to host")
				Return
			}
		}
	}

	# check if VM is in the cloud
	If ($vm_in_the_cloud) {
		Write-Host ("$Hostname,$vm_host,$vm_name - WARNING: VM is in the cloud, skipping VM removal...")
	}

	# check if host is clustered
	If (-not $vm_in_the_cloud) {
		Write-Host ("$Hostname,$vm_host,$vm_name - checking if host is clustered...")
		$vm_host_clustered = Get-Service -ComputerName $vm_host | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -eq 'Automatic' -and $_.Status -eq 'Running' }
		If ($vm_host_clustered) {
			Write-Host ("$Hostname,$vm_host,$vm_name - ...host is clustered")
			# check for VM on cluster
			Write-Host ("$Hostname,$vm_host,$vm_name - checking cluster for VM resource group...")
			$vm_cluster = Invoke-Command -ComputerName $vm_host { (Get-Cluster).Name }
			$vm_cluster_group = Get-ClusterGroup -Cluster $vm_cluster | Where-Object { $_.Name -eq $vm_name -and $_.GroupType -eq 'VirtualMachine' }
			If ($vm_cluster_group) {
				# verify the resource group is on the local node
				$vm_node = $vm_cluster_group.OwnerNode.NodeName
				If ($vm_host -eq $vm_node) {
					Write-Host ("$Hostname,$vm_host,$vm_name - ...VM resource group found on specified host in cluster")
				}
				Else {
					Write-Host ("$Hostname,$vm_host,$vm_name - ...VM resource group found on different host in cluster, changing host to: $vm_node")
					$vm_host = $vm_node
				}
			}
		}
	}

	# check for VM on host
	If (-not $vm_in_the_cloud) {
		# try to get VM from host
		Write-Host ("$Hostname,$vm_host,$vm_name - checking for VM on host...")
		$vm_on_host = Get-VM -ComputerName $vm_host | Where-Object { $_.Name -eq $vm_name }
	}

	# get VM information
	If (-not $vm_in_the_cloud -and -not $vm_on_host) {
		Write-Host ("$Hostname,$vm_host,$vm_name - ...VM not found on host")
		$vm_guid = [guid]::Empty
	}
	ElseIf (-not $vm_in_the_cloud) {
		Write-Host ("$Hostname,$vm_host,$vm_name - ...VM found on host")

		# get path information
		$vm_path_delete = @()
		$vm_path_delete += $vm_on_host.CheckpointFileLocation
		$vm_path_delete += $vm_on_host.ConfigurationLocation
		$vm_path_delete += $vm_on_host.SmartPagingFilePath
		$vm_path_delete += $vm_on_host.SnapshotFileLocation
		$vm_path_delete += $vm_on_host.Path

		# get GUID
		$vm_guid = $vm_on_host.id

		# get network information
		$vm_mac_address = $null
		If ($vm_on_host | Get-VMNetworkAdapter) {
			$vm_mac_address = ($vm_on_host | Get-VMNetworkAdapter)[0].MacAddress
		}

		# get disk information
		$vhd_paths = @()
		If ($vm_on_host | Get-VMHardDiskDrive) {
			$vhd_paths += ($vm_on_host | Get-VMHardDiskDrive).Path
			$vhd_paths | ForEach-Object { $vm_path_delete += Split-Path -Path $_ -Parent }
		}

		# get unique paths
		$vm_path_unique = $vm_path_delete | Select-Object -Unique
	}

	# remove device from OSD
	switch ($vm_deployment_method) {
		'sccm' {
			Try {
				Remove-DeviceFromSccm -VmParams $VmParams -VmMacAddress $vm_mac_address
			}
			Catch {
				Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: could not remove device from SCCM")
				Return
			}
		}
		'wds' {
			Write-Host ("$Hostname,$vm_host,$vm_name - skipping OSD cleanup...")
			Write-Host ("$Hostname,$vm_host,$vm_name - ...WDS devices are reset during provisioining")
		}
		default {
			Write-Host ("$Hostname,$vm_host,$vm_name - skipping OSD cleanup...")
			Write-Host ("$Hostname,$vm_host,$vm_name - ...Deployment method not provided or not recognized")
		}
	}

	# remove dhcp reservation
	If ($vm_dhcp_server -and $vm_dhcp_scope -and $vm_ip_address) {
		# check for existing DHCP reservation
		Write-Host ("$Hostname,$vm_host,$vm_name - checking for DHCP reservation on: " + $vm_dhcp_server)
		$vm_dhcp = $null
		$vm_dhcp = Get-DhcpServerv4Reservation -ComputerName $vm_dhcp_server -ScopeId $vm_dhcp_scope | Where-Object { $_.IPAddress -eq $vm_ip_address }
		If ($vm_dhcp) {
			Write-Host ("$Hostname,$vm_host,$vm_name - ...removing DHCP reservation")
			$vm_dhcp | Remove-DhcpServerv4Reservation -ComputerName $vm_dhcp_server
		}
		Else {
			Write-Host ("$Hostname,$vm_host,$vm_name - ...no DHCP reservation found")
		}
	}
	Else {
		Write-Host ("$Hostname,$vm_host,$vm_name - skipping DHCP configuration...")
		Write-Host ("$Hostname,$vm_host,$vm_name - ...required information not provided")
	}

	# remove any resource group from the cluster
	If ($vm_cluster_group) {
		Write-Host ("$Hostname,$vm_host,$vm_name - removing cluster resource...")
		Try {
			$vm_cluster_group | Remove-ClusterGroup -RemoveResources -Force
			Write-Host ("$Hostname,$vm_host,$vm_name - ...cluster resource removed")
		}
		Catch {
			Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: could not remove cluster resource")
		}
	}

	# remove VM from host
	If ($vm_on_host) {
		Write-Host ("$Hostname,$vm_host,$vm_name - removing VM from host...")

		# turn off the VM if running
		If ($vm_on_host.State -ne 'Off') { $vm_on_host | Stop-VM -TurnOff }

		# remove the VM
		$vm_on_host | Remove-VM -Force -Confirm:$false
		Write-Host ("$Hostname,$vm_host,$vm_name - ...VM removed from host")
	}

	# remove VHDs from host
	If ($vm_on_host -and $vhd_paths) {
		Invoke-Command -ComputerName $vm_host -ScriptBlock {
			# map objects into session
			$script_host = $using:Hostname
			$remote_host = $using:vm_host
			$remote_name = $using:vm_name
			$remote_vhds = $using:vhd_paths

			# dismount VHDs to unlock files for delete
			Write-Host ("$script_host,$remote_host,$remote_name - dismounting VHDs on host...")
			ForEach ($vm_vhd_path in $remote_vhds) {
				Try {
					Dismount-DiskImage -ImagePath $vm_vhd_path
					Write-Host ("$script_host,$remote_host,$remote_name - ...dismounting: " + $vm_vhd_path)
				}
				Catch {
					Write-Host ("$script_host,$remote_host,$remote_name - ERROR: could not dismount VHD: " + $vm_vhd_path)
				}
			}

			# remove VHD files
			Write-Host ("$script_host,$remote_host,$remote_name - deleting VHDs on host...")
			ForEach ($vm_vhd_path in $remote_vhds) {
				Try {
					Remove-Item -Path $vm_vhd_path -Force
					Write-Host ("$script_host,$remote_host,$remote_name - ...deleting: " + $vm_vhd_path)
				}
				Catch {
					Write-Host ("$script_host,$remote_host,$remote_name - ERROR: could not delete VHD: " + $vm_vhd_path)
				}
			}
		}
	}

	# remove folders from host
	If ($vm_guid -and $vm_path_unique) {
		Invoke-Command -ComputerName $vm_host -ScriptBlock {
			# map objects into session
			$script_host = $using:Hostname
			$remote_host = $using:vm_host
			$remote_name = $using:vm_name
			$remote_guid = $using:vm_guid
			$remote_dirs = $using:vm_path_unique

			# remove the VM folder and all files
			Write-Host ("$script_host,$remote_host,$remote_name - locating VM folders on host...")
			ForEach ($vm_path in $remote_dirs) {
				If (Test-Path -Path $vm_path) {
					Write-Host ("$script_host,$remote_host,$remote_name - ...located folder: $vm_path")
					# remove files that match the VM name or GUID
					$vm_files_match = Get-ChildItem -Path $vm_path -File -Recurse -Force | Where-Object { $_.BaseName -eq $remote_name -or $_.BaseName -eq $remote_guid }
					$vm_files_match | ForEach-Object {
						Write-Host ("$script_host,$remote_host,$remote_name - ...removing matching file: $($_.FullName)")
						$_ | Remove-Item -Confirm:$false
					}

					# remove folders that match the VM name or GUID
					$vm_paths_match = Get-ChildItem -Path $vm_path -Directory -Recurse -Force | Where-Object { $_.BaseName -eq $remote_name -or $_.BaseName -eq $remote_guid }
					$vm_paths_match | ForEach-Object {
						$vm_path_files = Get-ChildItem -Path $_ -Recurse -Force
						If ($vm_path_files) {
							Write-Host ("$script_host,$remote_host,$remote_name - ...removing empty matching folder: $($_.FullName)")
							$_ | Remove-Item -Confirm:$false
						}
						Else {
							Write-Host ("$script_host,$remote_host,$remote_name - ...skipping matching folder with child objects: $($_.FullName)")
						}
					}

					# check for any remaining files or folders in the path
					$vm_files_other = Get-ChildItem -Path $vm_path -File -Recurse -Force | Where-Object { $_.BaseName -ne $remote_name -and $_.BaseName -notmatch $remote_guid }
					$vm_paths_other = Get-ChildItem -Path $vm_path -Directory -Recurse -Force | Where-Object { $_.BaseName -notmatch "^$remote_name" -and $_.BaseName -notmatch "^$remote_guid" }
					If ($vm_files_other -or $vm_paths_other) {
						Write-Host ("$script_host,$remote_host,$remote_name - ...skipping non-empty folder: $vm_path")
					}
					Else {
						Try {
							$vm_path | Remove-Item -Recurse -Confirm:$false
							Write-Host ("$script_host,$remote_host,$remote_name - ...removing empty folder: $vm_path")
						}
						Catch {
							Write-Host ("$script_host,$remote_host,$remote_name - ERROR: could not remove folder: $vm_path")
						}
					}
				}
				Else {
					Write-Host ("$script_host,$remote_host,$remote_name - ...folder not found: $vm_path")
				}
			}
		}
	}

	# get AD objects
	$domain = Get-ADDomain
	$pdc = $domain.PDCEmulator
	$dns = $domain.DnsRoot
	$nbt = $domain.NetBIOSName

	# check OSD and NBT domains
	If ($nbt -eq $vm_deployment_domain -or $null -eq $vm_deployment_domain) {
		# remove computer object from AD
		Write-Host ("$Hostname,$vm_host,$vm_name - checking for VM in AD")
		$vm_ad = Get-ADObject -Server $pdc -Filter "Name -eq '$($vm_name)' -and ObjectClass -eq 'computer'"
		If ($vm_ad) {
			Write-Host ("$Hostname,$vm_host,$vm_name - ...AD object found")
			Write-Host ("$Hostname,$vm_host,$vm_name - removing AD object...")
			$vm_ad | Remove-ADObject -Server $pdc -Recursive -Confirm:$false
			Write-Host ("$Hostname,$vm_host,$vm_name - ...removed AD object")
		}
		Else {
			Write-Host ("$Hostname,$vm_host,$vm_name - ...AD object not found")
		}

		# remove computer records from DNS
		Write-Host ("$Hostname,$vm_host,$vm_name - checking for VM in DNS")
		$vm_dns = Get-DnsServerResourceRecord -ComputerName $pdc -ZoneName $dns -RRType A | Where-Object { $_.VMHost -eq $vm_name }
		If ($vm_dns) {
			Write-Host ("$Hostname,$vm_host,$vm_name - ...DNS records found")
			Write-Host ("$Hostname,$vm_host,$vm_name - removing DNS records...")
			$vm_dns | Remove-DnsServerResourceRecord -ComputerName $pdc -ZoneName $dns -Force
			Write-Host ("$Hostname,$vm_host,$vm_name - ...removed DNS records")
		}
		Else {
			Write-Host ("$Hostname,$vm_host,$vm_name - ...DNS records not found")
		}
	}
	Else {
		Write-Host ("$Hostname,$vm_host,$vm_name - skipping AD and DNS cleanup...")
		Write-Host ("$Hostname,$vm_host,$vm_name - ...VM not in same domain as script host")
	}
}
