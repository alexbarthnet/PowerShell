Param(
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$VmCsv,
	[Parameter(Mandatory = $True)]
	[string[]]$VmName,
	[string]$HostName,
	[switch]$UseDefaultPathOnHost
)

# create global objects
$env_comp_name = $env:computername.ToLower()

# import VM information
$vm_list = @()
If ($VmName) {
	# process requested VMs
	$VmName | ForEach-Object {
		$vm_temp = $null
		$vm_temp = $_
		$vm_list += Import-Csv -Path $VmCsv | Where-Object { $_.Name -eq $vm_temp }
		If ($vm_list.Name -notcontains $vm_temp) {
			Write-Host ("$env_comp_name,$vm_name - VM not found in CSV, exiting!")
			Return
		}
	}
}

# import VM information
$vm_list | ForEach-Object {
	# define objects from CSV
	$vm_name = $_.Name
	$vm_host = $_.Host

	# define objects from CSV for storage cleanup
	$vm_path = $_.Path
	$vhd_excl_ct = $_.ExclVhdCount

	# # define optional objects from CSV - IP address configuration
	$vm_dhcp_server = $_.DhcpServer
	$vm_dhcp_scope = $_.DhcpScope
	$vm_ip_address = $_.IpAddress

	# define optional objects from CSV - OSD general parameters
	$vm_osd_method = $_.OsdMethod
	$vm_osd_server = $_.OsdServer
	$vm_osd_domain = $_.Domain

	# check for host override
	If ($HostName) {
		$vm_host = $HostName
	}

	# check for host override
	If ($HostPath) {
		$vm_path = $HostPath
	}	

	# check if host is valid
	Write-Host ("$env_comp_name,$vm_host,$vm_name - checking host...")
	Try {
		$null = Test-WSMan -ComputerName $vm_host -Authentication 'Default'
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ...found host")
	}
	Catch {
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ERROR: could not connect to host")
		Return
	}

	# check if host is clustered
	Write-Host ("$env_comp_name,$vm_host,$vm_name - checking if host is clustered...")
	$vm_on_cl = $null
	$vm_host_cl = $null
	$vm_host_cl = Get-Service -ComputerName $vm_host | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -ne 'Disabled' }

	# check for VM on cluster
	If ($vm_host_cl) {
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ...host is clustered")
		# check for VM on cluster
		Write-Host ("$env_comp_name,$vm_host,$vm_name - locating VM on cluster...")
		$vm_cluster = Invoke-Command -ComputerName $vm_host { (Get-Cluster).Name }
		$vm_on_cl = Get-ClusterGroup -Cluster $vm_cluster | Where-Object { $_.Name -eq $vm_name -and $_.GroupType -eq 'VirtualMachine' }
		# remove VM from cluster
		If ($vm_on_cl) {
			# verify the resource group is on the local node
			$vm_node = $vm_on_cl.OwnerNode.NodeName
			If ($vm_host -eq $vm_node) {
				Write-Host ("$env_comp_name,$vm_host,$vm_name - ...VM found on expected host in cluster")
			}
			Else {
				Write-Host ("$env_comp_name,$vm_host,$vm_name - ...VM found on different host in cluster, changing host to: " + $vm_node)
				$vm_host = $vm_node
			}

			# remove resource group from the cluster
			Write-Host ("$env_comp_name,$vm_host,$vm_name - removing cluster resource...")
			$vm_on_cl | Remove-ClusterGroup -RemoveResources -Force
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ...cluster resource removed")
		}
		Else {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ...cluster resource not found")
		}
	}
	Else {
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ...host is standalone")
	}


	# check for VM on host
	Write-Host ("$env_comp_name,$vm_host,$vm_name - locating VM on host...")
	$vm_on_hv = Get-VM -ComputerName $vm_host | Where-Object { $_.Name -eq $vm_name }

	# remove VM from host
	$vm_hwid = $null
	$vm_disk = $null
	If ($vm_on_hv) {
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ...VM found on host")
		Write-Host ("$env_comp_name,$vm_host,$vm_name - removing VM from host...")

		# turn off the VM if running
		If ($vm_on_hv.State -ne 'Off') {
			$vm_on_hv | Stop-VM -TurnOff
		}

		# retrieve any drive paths before removing VM
		$vm_hdd = $null
		$vm_hdd = $vm_on_hv | Get-VMHardDiskDrive
		If ($vm_hdd) {
			$vm_disk = ($vm_on_hv | Get-VMHardDiskDrive).Path
		}

		# retrieve the MAC address from the first NIC before removing VM
		$vm_nic = $null
		$vm_nic = $vm_on_hv | Get-VMNetworkAdapter
		If ($vm_nic) {
			$vm_hwid = ($vm_on_hv | Get-VMNetworkAdapter)[0].MacAddress
		}

		# remove the VM
		$vm_on_hv | Remove-VM -Force -Confirm:$false
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ...VM removed from host")
	}
	Else {
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ...VM not found")
	}

	# remove files from host
	If ($vm_disk) {
		Invoke-Command -ComputerName $vm_host -ScriptBlock {
			# map objects into session
			$env_name = $using:env_comp_name
			$env_host = $using:vm_host
			$vm_label = $using:vm_name
			$vm_drive = $using:vm_disk

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

	# verify which VM path to use
	Write-Host ("$env_comp_name,$vm_host,$vm_name - verifying VM path...")
	If ($vm_path -and -not $UseDefaultPathOnHost) {
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ...using provided VM path: " + $vm_path)
	}
	Else {
		$vm_path = (Get-VMHost -ComputerName $vm_host).VirtualMachinePath
		Write-Host ("$env_comp_name,$vm_host,$vm_name - ...using default VM path: " + $vm_path)
	}

	# define paths to folders using VM information
	$vm_path_delete = @()
	$vm_path_delete += $vm_on_hv.CheckpointFileLocation
	$vm_path_delete += $vm_on_hv.ConfigurationLocation
	$vm_path_delete += $vm_on_hv.SmartPagingFilePath
	$vm_path_delete += $vm_on_hv.SnapshotFileLocation
	$vm_path_delete += $vm_on_hv.Path
	$vm_path_delete += $vm_disk

	# define paths to folders using CSV information
	$vm_path_delete += Invoke-Command -ComputerName $vm_host -ScriptBlock { Join-Path -Path $using:vm_path -ChildPath $using:vm_name }
	If ($vhd_excl_ct) {
		$vm_path_delete += Invoke-Command -ComputerName $vm_host -ScriptBlock { Join-Path -Path $using:vm_path -ChildPath ('Exclude\' + $using:vm_name) }
	}

	# get unique paths to folders
	$vm_path_unique = $vm_path_delete | Select-Object -Unique

	# remove folders from host
	Invoke-Command -ComputerName $vm_host -ScriptBlock {
		# map objects into session
		$env_name = $using:env_comp_name
		$env_host = $using:vm_host
		$vm_label = $using:vm_name
		$vm_paths = $using:vm_path_unique

		# remove the VM folder and all files
		Write-Host ("$env_name,$env_host,$vm_label - locating VM folders on host...")
		ForEach ($vm_path in $vm_paths) {
			If (Test-Path $vm_path) {
				Write-Host ("$env_name,$env_host,$vm_label - ...located folder: " + $vm_path)
				If (Get-ChildItem -Path $vm_path -Recurse -Force) {
					Write-Host ("$env_name,$env_host,$vm_label - ...skipping non-empty folder: " + $vm_path)
				}
				Else {
					Try {
						$vm_path | Remove-Item -Confirm:$false
						Write-Host ("$env_name,$env_host,$vm_label - ...removing empty folder: " + $vm_path)
					}
					Catch {
						Write-Host ("$env_name,$env_host,$vm_label - ERROR: could not remove folder: " + $vm_path)
					}
				}
			}
			Else {
				Write-Host ("$env_name,$env_host,$vm_label - ...folder not found: " + $vm_path)
			}
		}
	}

	# remove device from OSD
	switch ($vm_osd_method) {
		'wds' {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - skipping OSD cleanup...")
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ...WDS devices are reset during provisioining")
		}
		'sccm' {
			# connect to SCCM remotely
			Write-Host ("$env_comp_name,$vm_host,$vm_name - connecting to SCCM: " + $vm_osd_server)
			Invoke-Command -ComputerName $vm_osd_server -ScriptBlock {
				# set local variables
				$env_name = $using:env_comp_name
				$sccm_srv = $using:vm_osd_server
				$dev_name = $using:vm_name
				$dev_hwid = $using:vm_hwid

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
		default {
			Write-Host ("$env_comp_name,$vm_host,$vm_name - skipping OSD cleanup...")
			Write-Host ("$env_comp_name,$vm_host,$vm_name - ...OSD method not provided or not recognized")
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
	$pdc = (Get-ADDomain).PDCEmulator
	$dns = (Get-ADDomain).DnsRoot
	$nbt = (Get-ADDomain).NetBIOSName

	# check OSD and NBT domains
	If ($nbt -eq $vm_osd_domain -or $null -eq $vm_osd_domain) {
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
