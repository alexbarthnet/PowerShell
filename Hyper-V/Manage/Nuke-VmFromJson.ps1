Param(
	[Parameter(Mandatory = $True, ValueFromPipeline = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$VmJson,
	[Parameter(Mandatory = $True)]
	[string[]]$VmName,
	[string]$HostName,
	[switch]$UseDefaultPathOnHost
)

Function Remove-DeviceFromSccm {
	param (
		[Parameter()]
		[object]$VmParams,
		[string]$VmMacAddress
	)

	# define optional objects from CSV - OSD general parameters
	$vm_name = $VmParams.Name
	$vm_deployment_server = $VmParams.DeploymentServer

	# connect to SCCM remotely
	Write-Host ("$env_comp_name,$vm_host,$vm_name - connecting to SCCM: " + $vm_deployment_server)
	Invoke-Command -ComputerName $vm_deployment_server -ScriptBlock {
		# set local variables
		$env_name = $using:env_comp_name
		$sccm_srv = $using:vm_deployment_server
		$dev_name = $using:vm_name
		$dev_hwid = $using:VmMacAddress

		# retrieve the psd1 file
		$cm_psd1_path = 'HKLM:\SOFTWARE\Microsoft\SMS\Setup'
		$cm_psd1_item = 'UI Installation Directory'
		$cm_psd1 = (Get-ItemProperty -Path $cm_psd1_path -Name $cm_psd1_item).$($cm_psd1_item) + '\bin\ConfigurationManager.psd1'

		# retrieve the site code
		$cm_site_path = 'HKLM:\SOFTWARE\Microsoft\SMS\Identification'
		$cm_site_item = 'Site Code'
		$cm_site = (Get-ItemProperty -Path $cm_site_path -Name $cm_site_item).$($cm_site_item)

		# connect to SCCM
		Write-Host ("$env_name,$sccm_srv,$dev_name - importing SCCM module")
		Import-Module $cm_psd1
		Write-Host ("$env_name,$sccm_srv,$dev_name - setting location to site drive")
		Set-Location ($cm_site + ':\')

		# build strings for WMI query
		$cm_space = 'Root\SMS\Site_' + $cm_site
		$cm_class = 'SMS_R_System'

		# empty variables
		$dev_found = $null
		$dev_resid = $null

		# check for device by mac address via WMI call
		If ($dev_hwid) {
			Write-Host ("$env_name,$sccm_srv,$dev_name - retrieving device with MAC address: " + $dev_hwid)
			$dev_found = Get-WmiObject -Namespace $cm_space -Class $cm_class | Where-Object { $_.MacAddresses -eq $dev_hwid }
			If ($dev_found.Count -gt 1) {
				Write-Host ("$env_name,$sccm_srv,$dev_name - EXCEPTION: multiple devices found with the same MAC address")
				Write-Host ("$env_name,$sccm_srv,$dev_name - ...remove extra devices before continuing")
				Break
			}
			Else {
				# declare the device was found in SCCM
				$dev_resid = $dev_found.ResourceId
				Write-Host ("$env_name,$sccm_srv,$dev_name - ...found device by MAC address, resource ID: " + $dev_resid)
			}
		}

		# check for device by mac address via WMI call
		If ($null -eq $dev_resid) {
			Write-Host ("$env_name,$sccm_srv,$dev_name - retrieving device with name: " + $dev_name)
			$dev_found = Get-WmiObject -Namespace $cm_space -Class $cm_class | Where-Object { $_.Name -eq $dev_name }
			If ($dev_found.Count -gt 1) {
				Write-Host ("$env_name,$sccm_srv,$dev_name - EXCEPTION: multiple devices found with the same name")
				Write-Host ("$env_name,$sccm_srv,$dev_name - ...remove extra devices before continuing")
				Break
			}
			Else {
				# declare the device was found
				$dev_resid = $dev_found.ResourceId
				Write-Host ("$env_name,$sccm_srv,$dev_name - ...found device by name, resource ID: " + $dev_resid)
			}
		}

		# remove the device
		If ($dev_resid) {
			# reset PXE state
			Write-Host ("$env_name,$sccm_srv,$dev_name - resetting PXE deployment status for VM")
			Clear-CMPxeDeployment -ResourceId $dev_resid
			# remove device
			Write-Host ("$env_name,$sccm_srv,$dev_name - removing device")
			Remove-CMDevice -ResourceId $dev_resid -Force
		}
		Else {
			# declare device not found
			Write-Host ("$env_name,$sccm_srv,$dev_name - ...device not found")
		}
	}
}

# create global objects
$env_comp_name = $env:computername.ToLower()

# verify JSON file
If (-not (Test-Path -Path $VmJson)) {
	Write-Output "`nERROR: could not find configuration file:"
	Write-Output "$VmJson`n"
	Return
}

# import and filter JSON data
$vm_list = @()
If ($VmName) {
	$vm_list += (Get-Content -Path $VmJson | ConvertFrom-Json) | Where-Object { $_.VMHost -and $_.VMName -in $VMName }
	If ($vm_list.Count -eq 0) {
		Write-Host ("$env_comp_name - VM(s) not found in Json, exiting!")
		Return
	}
}

# import VM information
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
	If ($HostName) { $vm_host = $HostName }

	# check host
	switch ($vm_host) {
		'cloud' {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - WARNING: VM is in the cloud, skipping...")
			$vm_in_the_cloud = $true
		}
		$null {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ERROR: host not defined for VM")
			Return
		}
		Default {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - checking host...")
			Try {
				$null = Test-WSMan -ComputerName $vm_host -Authentication 'Default'
				Write-Host ("$env_comp_name,$vm_host,$vm_name - ...found host")
			}
			Catch {
				Write-Host ("$env_comp_name,$vm_host,$vm_name - ERROR: could not connect to host")
				Return
			}
		}
	}

	# check if host is clustered
	If (-not $vm_in_the_cloud) {
		Write-Host ("$env_comp_name,$vm_host,$vm_name - checking if host is clustered...")
		$vm_host_clustered = Get-Service -ComputerName $vm_host | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -eq 'Automatic' -and $_.Status -eq 'Running' }
		If ($vm_host_clustered) {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ...host is clustered")
			# check for VM on cluster
			Write-Host ("$env_comp_name,$vm_host,$vm_name - checking cluster for VM resource group...")
			$vm_cluster = Invoke-Command -ComputerName $vm_host { (Get-Cluster).Name }
			$vm_cluster_group = Get-ClusterGroup -Cluster $vm_cluster | Where-Object { $_.Name -eq $vm_name -and $_.GroupType -eq 'VirtualMachine' }
			If ($vm_cluster_group) {
				# verify the resource group is on the local node
				$vm_node = $vm_cluster_group.OwnerNode.NodeName
				If ($vm_host -eq $vm_node) {
					Write-Host ("$env_comp_name,$vm_host,$vm_name - ...VM resource group found on specified host in cluster")
				}
				Else {
					Write-Host ("$env_comp_name,$vm_host,$vm_name - ...VM resource group found on different host in cluster, changing host to: $vm_node")
					$vm_host = $vm_node
				}
			}
		}
	}

	# remove any resource group from the cluster
	If ($vm_cluster_group) {
		Write-Host ("$env_comp_name,$vm_host,$vm_name - removing cluster resource...")
		Try {
			$vm_cluster_group | Remove-ClusterGroup -RemoveResources -Force
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ...cluster resource removed")
		}
		Catch {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ERROR: could not remove cluster resource")
		}
	}

	# check for VM on host
	If (-not $vm_in_the_cloud) {
		# try to get VM from host
		Write-Host ("$env_comp_name,$vm_host,$vm_name - checking for VM on host...")
		$vm_on_host = Get-VM -ComputerName $vm_host | Where-Object { $_.Name -eq $vm_name }
	}

	# get VM information
	If (-not $vm_in_the_cloud -and -not $vm_on_host) {
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ...VM not found on host")
	}
	ElseIf (-not $vm_in_the_cloud) {
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ...VM found on host")

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

	# remove VM from host
	If ($vm_on_host) {
		Write-Host ("$env_comp_name,$vm_host,$vm_name - removing VM from host...")

		# turn off the VM if running
		If ($vm_on_host.State -ne 'Off') { $vm_on_host | Stop-VM -TurnOff }

		# remove the VM
		$vm_on_host | Remove-VM -Force -Confirm:$false
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ...VM removed from host")
	}

	# remove VHDs from host
	If ($vm_on_host -and $vhd_paths) {
		Invoke-Command -ComputerName $vm_host -ScriptBlock {
			# map objects into session
			$env_name = $using:env_comp_name
			$env_host = $using:vm_host
			$vm_label = $using:vm_name
			$vm_drive = $using:vhd_paths

			# dismount VHDs to unlock files for delete
			Write-Host ("$env_name,$env_host,$vm_label - dismounting VHDs on host...")
			ForEach ($vm_vhd_path in $vm_drive) {
				Try {
					Dismount-DiskImage -ImagePath $vm_vhd_path
					Write-Host ("$env_name,$env_host,$vm_label - ...dismounting: " + $vm_vhd_path)
				}
				Catch {
					Write-Host ("$env_name,$env_host,$vm_label - ERROR: could not dismount VHD: " + $vm_vhd_path)
				}
			}

			# remove VHD files
			Write-Host ("$env_name,$env_host,$vm_label - deleting VHDs on host...")
			ForEach ($vm_vhd_path in $vm_drive) {
				Try {
					Remove-Item -Path $vm_vhd_path -Force
					Write-Host ("$env_name,$env_host,$vm_label - ...deleting: " + $vm_vhd_path)
				}
				Catch {
					Write-Host ("$env_name,$env_host,$vm_label - ERROR: could not delete VHD: " + $vm_vhd_path)
				}
			}
		}
	}

	# remove folders from host
	Invoke-Command -ComputerName $vm_host -ScriptBlock {
		# map objects into session
		$env_name = $using:env_comp_name
		$env_host = $using:vm_host
		$vm_label = $using:vm_name
		$vm_ident = $using:vm_guid
		$vm_paths = $using:vm_path_unique

		# remove the VM folder and all files
		Write-Host ("$env_name,$env_host,$vm_label - locating VM folders on host...")
		ForEach ($vm_path in $vm_paths) {
			If (Test-Path -Path $vm_path) {
				Write-Host ("$env_name,$env_host,$vm_label - ...located folder: $vm_path")
				# remove files that match the VM name or GUID
				$vm_files_match = Get-ChildItem -Path $vm_path -File -Recurse -Force | Where-Object { $_.BaseName -eq $vm_label -or $_.BaseName -eq $vm_ident }
				$vm_files_match | ForEach-Object {
					Write-Host ("$env_name,$env_host,$vm_label - ...removing matching file: $($_.FullName)")
					$_ | Remove-Item -Confirm:$false
				}

				# remove folders that match the VM name or GUID
				$vm_paths_match = Get-ChildItem -Path $vm_path -Directory -Recurse -Force | Where-Object { $_.BaseName -eq $vm_label -or $_.BaseName -eq $vm_ident }
				$vm_paths_match | ForEach-Object {
					$vm_path_files = Get-ChildItem -Path $_ -Recurse -Force
					If ($vm_path_files) {
						Write-Host ("$env_name,$env_host,$vm_label - ...removing empty matching folder: $($_.FullName)")
						$_ | Remove-Item -Confirm:$false
					}
					Else {
						Write-Host ("$env_name,$env_host,$vm_label - ...skipping matching folder with child objects: $($_.FullName)")
					}
				}

				# check for any remaining files or folders in the path
				$vm_files_other = Get-ChildItem -Path $vm_path -File -Recurse -Force | Where-Object { $_.BaseName -ne $vm_label -and $_.BaseName -notmatch $vm_ident }
				$vm_paths_other = Get-ChildItem -Path $vm_path -Directory -Recurse -Force | Where-Object { $_.BaseName -notmatch "^$vm_label" -and $_.BaseName -notmatch "^$vm_ident" }
				If ($vm_files_other -or $vm_paths_other) {
					Write-Host ("$env_name,$env_host,$vm_label - ...skipping non-empty folder: $vm_path")
				}
				Else {
					Try {
						$vm_path | Remove-Item -Recurse -Confirm:$false
						Write-Host ("$env_name,$env_host,$vm_label - ...removing empty folder: $vm_path")
					}
					Catch {
						Write-Host ("$env_name,$env_host,$vm_label - ERROR: could not remove folder: $vm_path")
					}
				}
			}
			Else {
				Write-Host ("$env_name,$env_host,$vm_label - ...folder not found: $vm_path")
			}
		}
	}

	# remove device from OSD
	switch ($vm_deployment_method) {
		'sccm' {
			Remove-DeviceFromSccm -VmParams $VmParams -VmMacAddress $vm_mac_address
		}
		'wds' {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - skipping OSD cleanup...")
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ...WDS devices are reset during provisioining")
		}
		default {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - skipping OSD cleanup...")
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ...Deployment method not provided or not recognized")
		}
	}

	# remove dhcp reservation
	If ($vm_dhcp_server -and $vm_dhcp_scope -and $vm_ip_address) {
		# check for existing DHCP reservation
		Write-Host ("$env_comp_name,$vm_host,$vm_name - checking for DHCP reservation on: " + $vm_dhcp_server)
		$vm_dhcp = $null
		$vm_dhcp = Get-DhcpServerv4Reservation -ComputerName $vm_dhcp_server -ScopeId $vm_dhcp_scope | Where-Object { $_.IPAddress -eq $vm_ip_address }
		If ($vm_dhcp) {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ...removing DHCP reservation")
			$vm_dhcp | Remove-DhcpServerv4Reservation -ComputerName $vm_dhcp_server
		}
		Else {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ...no DHCP reservation found")
		}
	}
	Else {
		Write-Host ("$env_comp_name,$vm_host,$vm_name - skipping DHCP configuration...")
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ...required information not provided")
	}

	# get AD objects
	$domain = Get-ADDomain
	$pdc = $domain.PDCEmulator
	$dns = $domain.DnsRoot
	$nbt = $domain.NetBIOSName

	# check OSD and NBT domains
	If ($nbt -eq $vm_deployment_domain -or $null -eq $vm_deployment_domain) {
		# remove computer object from AD
		Write-Host ("$env_comp_name,$vm_host,$vm_name - checking for VM in AD")
		$vm_ad = Get-ADObject -Server $pdc -Filter "Name -eq '$($vm_name)' -and ObjectClass -eq 'computer'"
		If ($vm_ad) {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ...AD object found")
			Write-Host ("$env_comp_name,$vm_host,$vm_name - removing AD object...")
			$vm_ad | Remove-ADObject -Server $pdc -Recursive -Confirm:$false
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ...removed AD object")
		}
		Else {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ...AD object not found")
		}

		# remove computer records from DNS
		Write-Host ("$env_comp_name,$vm_host,$vm_name - checking for VM in DNS")
		$vm_dns = Get-DnsServerResourceRecord -ComputerName $pdc -ZoneName $dns -RRType A | Where-Object { $_.HostName -eq $vm_name }
		If ($vm_dns) {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ...DNS records found")
			Write-Host ("$env_comp_name,$vm_host,$vm_name - removing DNS records...")
			$vm_dns | Remove-DnsServerResourceRecord -ComputerName $pdc -ZoneName $dns -Force
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ...removed DNS records")
		}
		Else {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ...DNS records not found")
		}
	}
	Else {
		Write-Host ("$env_comp_name,$vm_host,$vm_name - skipping AD and DNS cleanup...")
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ...VM not in same domain as script host")
	}
}
