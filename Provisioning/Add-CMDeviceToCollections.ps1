

Function Add-DeviceToSccm {
	param (
		[Parameter()]
		[object]$VmParams
	)

	# define required strings
	$vm_name = $VmParams.VMName
	$vm_host = $VmParams.VMHost
	$vm_switchname = $VmParams.SwitchName
	$vm_deployment_path = $VmParams.DeploymentPath
	$vm_deployment_server = $VmParams.DeploymentServer
	$vm_deployment_domain = $VmParams.DeploymentDomain
	$vm_deployment_collection = $VmParams.DeploymentCollection
	$vm_maintenance_collection = $VmParams.MaintenanceCollection

	# check switch
	If ($vm_switchname -eq 'Remove') {
		Write-Host ("$Hostname,$ComputerName,$Name - Switch is 'Remove', skipping SCCM provisioning...")
		Return
	}

	# check host
	If ($vm_host -eq 'cloud') {
		Write-Host ("$Hostname,$ComputerName,$Name - creating SCCM device for VM in the cloud")
	}
	Else {
		# get the mac address from the VM NIC
		$VM = Get-VM -ComputerName $vm_host -Name $vm_name
		$vm_hw_address = ($VM.NetworkAdapters)[0].MacAddress

		# create objects for invoked commands
		$vm_mac_address = ($vm_hw_address -split '(\w{2})' | Where-Object { $_ -ne '' }) -join ':'
		Write-Host ("$Hostname,$ComputerName,$Name - creating SCCM device with MAC: " + $vm_mac_address)
	}

	# connect to SCCM remotely
	Write-Host ("$Hostname,$ComputerName,$Name - connecting to SCCM: " + $vm_deployment_server)
	Invoke-Command -ComputerName $vm_deployment_server -ScriptBlock {
		# set local variables
		$script_host = $using:Hostname
		$remote_host = $using:vm_deployment_server
		$device_name = $using:vm_name
		$device_host = $using:vm_host
		$device_hwid = $using:vm_mac_address
		$device_domain = $using:vm_deployment_domain
		$device_oupath = $using:vm_deployment_path
		$cm_col_deploy = $using:vm_deployment_collection
		$cm_col_window = $using:vm_maintenance_collection

		# retrieve the psd1 file
		$cm_psd1_path = 'HKLM:\SOFTWARE\Microsoft\SMS\Setup'
		$cm_psd1_item = 'UI Installation Directory'
		$cm_psd1 = (Get-ItemProperty -Path $cm_psd1_path -Name $cm_psd1_item).$($cm_psd1_item) + '\bin\ConfigurationManager.psd1'

		# retrieve the site code
		$cm_site_path = 'HKLM:\SOFTWARE\Microsoft\SMS\Identification'
		$cm_site_item = 'Site Code'
		$cm_site = (Get-ItemProperty -Path $cm_site_path -Name $cm_site_item).$($cm_site_item)

		# connect to SCCM
		Write-Host ("$script_host,$remote_host,$device_name - ...importing SCCM module")
		Import-Module $cm_psd1
		Write-Host ("$script_host,$remote_host,$device_name - ...setting location to site drive")
		Set-Location ($cm_site + ':\')

		# build strings for WMI query
		$cm_space = 'Root\SMS\Site_' + $cm_site
		$cm_class = 'SMS_R_System'

		# empty variables
		$device_resid = $null

		# retrieve device
		Write-Host ("$script_host,$remote_host,$device_name - checking device location...")
		If ($device_host -match 'cloud') {
			# check for device by name via PowerShell
			Write-Host ("$script_host,$remote_host,$device_name - ...device is VM in the cloud, retrieving device by name")
			$device_found_by_name = @()
			$device_found_by_name += Get-WmiObject -Namespace $cm_space -Class $cm_class | Where-Object { $_.Name -eq $device_name }
			If ($device_found_by_name.Count -gt 1) {
				Write-Host ("$script_host,$remote_host,$device_name - EXCEPTION: multiple devices found with the same name")
				Write-Host ("$script_host,$remote_host,$device_name - ...remove extra devices before continuing")
				Return
			}
			ElseIf ($device_found_by_name.Client -eq 1) {
				# declare the device was found and the client is installed
				$device_resid = $device_found_by_name.ResourceId
				Write-Host ("$script_host,$remote_host,$device_name - ...found device by name with client installed, resource ID: " + $device_resid)
			}
			ElseIf ($device_found_by_name) {
				# declare the device was found but the client is NOT installed
				Write-Host ("$script_host,$remote_host,$device_name - EXCEPTION: device found WITHOUT client installed")
				Write-Host ("$script_host,$remote_host,$device_name - ...install SCCM agent then wait for SCCM to merge the objects")
				Return
			}
			Else {
				# declare issue and end early
				Write-Host ("$script_host,$remote_host,$device_name - EXCEPTION: device for cloud VM not found")
				Write-Host ("$script_host,$remote_host,$device_name - ...join VM to domain then install SCCM agent")
				Return
			}
		}
		ElseIf ($device_hwid) {
			# check for device by MAC via WMI, import if not found
			Write-Host ("$script_host,$remote_host,$device_name - ...device is VM on-premises, retrieving device by MAC address: " + $device_hwid)
			# check for device via WMI, import if not found
			$device_found_by_name = @()
			$device_found_by_name += Get-WmiObject -Namespace $cm_space -Class $cm_class | Where-Object { $_.Name -eq $device_name }
			If ($device_found_by_name.Count -gt 1) {
				Write-Host ("$script_host,$remote_host,$device_name - EXCEPTION: multiple devices found with the same MAC address")
				Write-Host ("$script_host,$remote_host,$device_name - ...remove extra devices before continuing")
				Return
			}
			ElseIf ($device_found_by_name.Client -eq 1) {
				# declare the device was found but the client is installed
				Write-Host ("$script_host,$remote_host,$device_name - EXCEPTION: device found WITH client installed")
				Write-Host ("$script_host,$remote_host,$device_name - ...verify any previous device has been removed from SCCM")
				Return
			}
			ElseIf ($device_found_by_name) {
				# declare the device was found in SCCM
				$device_resid = $device_found_by_name.ResourceId
				Write-Host ("$script_host,$remote_host,$device_name - ...found existing device with resource ID: " + $device_resid)
			}
			Else {
				# import the device into SCCM
				Try {
					Import-CMComputerInformation -ComputerName ($device_name.ToUpper()) -MacAddress $device_hwid
					Write-Host ("$script_host,$remote_host,$device_name - ...adding device to SCCM")
				}
				Catch {
					Write-Host ("$script_host,$remote_host,$device_name - ERROR: adding device to SCCM")
					Return $_
				}

				# wait until device is visible in SCCM
				Write-Host ("$script_host,$remote_host,$device_name - waiting for device to be visible in SCCM...")
				Do {
					Start-Sleep -Seconds 5
					$device_found_by_mac = $null
					$device_found_by_mac = Get-WmiObject -Namespace $cm_space -Class $cm_class | Where-Object { $_.MacAddresses -eq $device_hwid }
				}
				Until ($null -ne $device_found_by_mac)

				# declare the device was found in SCCM
				$device_resid = $device_found_by_mac.ResourceId
				Write-Host ("$script_host,$remote_host,$device_name - ...found resource ID for device: " + $device_resid)
			}
		}
		Else {
			Write-Host ("$script_host,$remote_host,$device_name - EXCEPTION: on-premises VM defined but no MAC address available")
			Return
		}

		# retrieve the All Systems collection
		Write-Host ("$script_host,$remote_host,$device_name - retrieving All Systems collection")
		$col_systems = $null
		$col_systems = Get-CMDeviceCollection -Name 'All Systems'
		If ($null -eq $col_systems) {
			Write-Error ("$script_host,$remote_host,$device_name - ERROR: All Systems collection not found")
			Return
		}

		# check for device in OS deployment collection for on-premises VMs
		If ($device_host -match 'cloud') {
			Write-Host ("$script_host,$remote_host,$device_name - skipping OS deployment collection for cloud VM")
		}
		Else {
			# update the All Systems collection manually
			Try {
				$null = $col_systems | Invoke-CMCollectionUpdate
				Write-Host ("$script_host,$remote_host,$device_name - ...updated All Systems Collection")
			}
			Catch {
				Write-Host ("$script_host,$remote_host,$device_name - ERROR: updating All Systems Collection")
				Return $_
			}

			# wait until device is visible in All Systems collection
			Write-Host ("$script_host,$remote_host,$device_name - waiting for device to be visible in All Systems collection")
			Try {
				Do { Start-Sleep -Seconds 5 }
				Until ($col_systems | Get-CMCollectionMember -ResourceId $device_resid)
			}
			Catch {
				Write-Host ("$script_host,$remote_host,$device_name - ERROR: retrieving device from All Systems Collection")
			}

			# declare the device was found in the collection
			Write-Host ("$script_host,$remote_host,$device_name - ...found device in All Systems")

			# retrieve the OS deployment collection
			Write-Host ("$script_host,$remote_host,$device_name - retrieving OS deployment collection: " + $cm_col_deploy)
			$col_deploy = $null
			$col_deploy = Get-CMDeviceCollection -Name $cm_col_deploy
			If ($null -eq $col_deploy) {
				Write-Host ("$script_host,$remote_host,$device_name - ERROR: OS deployment collection not found")
				Return
			}

			# check for direct membership rule in OS deployment collection
			If ($col_deploy | Get-CMDeviceCollectionDirectMembershipRule -ResourceId $device_resid) {
				# declare the direct membership rule found in the collection
				Write-Host ("$script_host,$remote_host,$device_name - ...found direct membership rule for device in OS deployment collection")
			}
			Else {
				# add the direct membership rule to the collection
				Try {
					$null = $col_deploy | Add-CMDeviceCollectionDirectMembershipRule -ResourceId $device_resid
					Write-Host ("$script_host,$remote_host,$device_name - ...added direct membership rule for device to OS deployment collection")
				}
				Catch {
					Write-Host ("$script_host,$remote_host,$device_name - ERROR: adding direct membership rule for device to OS deployment collection")
					Return
				}
			}

			# check for device in OS deployment collection
			If ($col_deploy | Get-CMCollectionMember -ResourceId $device_resid) {
				# declare the device was found in the collection
				Write-Host ("$script_host,$remote_host,$device_name - ...found device in OS deployment collection")
			}
			Else {
				# update the OS deployment collection manually
				Try {
					$null = $col_deploy | Invoke-CMCollectionUpdate
					Write-Host ("$script_host,$remote_host,$device_name - ...updated OS deployment collection")
				}
				Catch {
					Write-Host ("$script_host,$remote_host,$device_name - ERROR: updating OS deployment collection")
					Return
				}

				# wait until device is visible in collection
				Write-Host ("$script_host,$remote_host,$device_name - waiting for device to be visible in OS deployment collection...")
				Try {
					Do { Start-Sleep -Seconds 5 }
					Until ($col_deploy | Get-CMCollectionMember -ResourceId $device_resid)
				}
				Catch {
					Write-Host ("$script_host,$remote_host,$device_name - ERROR: retrieving device from OS deployment Collection")
				}

				# declare the device was found in the collection
				Write-Host ("$script_host,$remote_host,$device_name - ...found device in OS deployment collection")
			}

			# set variable for computer domain
			Try {
				$null = New-CMDeviceVariable -DeviceId $device_resid -VariableName 'OSDDOMAIN' -VariableValue $device_domain
				Write-Host ("$script_host,$remote_host,$device_name - ...set OSD domain to: $device_domain")
			}
			Catch {
				Write-Host ("$script_host,$remote_host,$device_name - ERROR: setting OSD domain to: $device_domain")
				Return
			}

			# set variable for computer LDAP path
			Try {
				$null = New-CMDeviceVariable -DeviceId $device_resid -VariableName 'OSDDOMAINOUNAME' -VariableValue $device_oupath
				Write-Host ("$script_host,$remote_host,$device_name - ...set OSD OU name to: $device_oupath")
			}
			Catch {
				Write-Host ("$script_host,$remote_host,$device_name - ERROR: setting OSD OU name to: $device_oupath")
				Return
			}
		}

		# check for maintenance window collection value
		If ([string]::IsNullOrEmpty($cm_col_window)) {
			Write-Host ("$script_host,$remote_host,$device_name - skipping maintenance window collection; name not provided")
		}
		Else {
			# retrieve maintenance window collection
			Write-Host ("$script_host,$remote_host,$device_name - retrieving maintenance window collection: " + $cm_col_window)
			$col_window = $null
			$col_window = Get-CMDeviceCollection -Name $cm_col_window
			If ($col_window) {
				Write-Host ("$script_host,$remote_host,$device_name - ...found maintenance window collection")
			}
			Else {
				Write-Host ("$script_host,$remote_host,$device_name - ERROR: maintenance window collection not found")
				Return
			}

			# check for device in maintenance window collection
			If ($col_window | Get-CMDeviceCollectionDirectMembershipRule -ResourceId $device_resid) {
				# declare device found in maintenance window collection
				Write-Host ("$script_host,$remote_host,$device_name - ...found direct membership rule for device in maintenance window collection")
			}
			Else {
				# add direct membership rule to maintenance window collection
				Try {
					$null = $col_window | Add-CMDeviceCollectionDirectMembershipRule -ResourceId $device_resid
					Write-Host ("$script_host,$remote_host,$device_name - ...added direct membership rule for device to maintenance window collection")
				}
				Catch {
					Write-Host ("$script_host,$remote_host,$device_name - ERROR: adding direct membership rule for device to maintenance window collection")
					Return
				}
			}
		}
	}
}