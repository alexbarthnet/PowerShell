Param(
	[Parameter(Mandatory = $True, ValueFromPipeline = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$VmJson,
	[Parameter()]
	[string[]]$VmName,
	[Parameter()]
	[string]$VMHost,
	[Parameter()]
	[string]$VMHostPath,
	[Parameter()]
	[switch]$UseDefaultPathOnHost,
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
)

Function Format-Bytes {
	Param (
		[int64]$Size
	)
	Switch ($Size) {
		{ $_ -ge 1PB } { "$([math]::Round($Size / 1PB,$RoundTo)) PB"; Break }
		{ $_ -ge 1TB } { "$([math]::Round($Size / 1TB,$RoundTo)) TB"; Break }
		{ $_ -ge 1GB } { "$([math]::Round($Size / 1GB,$RoundTo)) GB"; Break }
		{ $_ -ge 1MB } { "$([math]::Round($Size / 1MB,$RoundTo)) MB"; Break }
		{ $_ -ge 1KB } { "$([math]::Round($Size / 1KB,$RoundTo)) KB"; Break }
		Default { "$([math]::Round($Size,$RoundTo)) B" }
	}
}

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
		Write-Host ("$Hostname,$vm_host,$vm_name - Switch is 'Remove', skipping SCCM provisioning...")
		Return
	}

	# check host
	If ($vm_host -eq 'cloud') {
		Write-Host ("$Hostname,$vm_host,$vm_name - creating SCCM device for VM in the cloud")
	}
	Else {
		# get the mac address from the VM NIC
		$vm = Get-VM -ComputerName $vm_host -Name $vm_name
		$vm_hw_address = ($vm.NetworkAdapters)[0].MacAddress

		# create objects for invoked commands
		$vm_mac_address = ($vm_hw_address -split '(\w{2})' | Where-Object { $_ -ne '' }) -join ':'
		Write-Host ("$Hostname,$vm_host,$vm_name - creating SCCM device with MAC: " + $vm_mac_address)
	}

	# connect to SCCM remotely
	Write-Host ("$Hostname,$vm_host,$vm_name - connecting to SCCM: " + $vm_deployment_server)
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
		$dev_found = $null
		$dev_resid = $null
		$col_window = $null
		$col_deploy = $null

		# retrieve device
		Write-Host ("$script_host,$remote_host,$device_name - checking device location...")
		If ($device_host -match 'cloud') {
			# check for device by name via PowerShell
			Write-Host ("$script_host,$remote_host,$device_name - ...device is VM in the cloud, retrieving device by name")
			$dev_found = Get-WmiObject -Namespace $cm_space -Class $cm_class | Where-Object { $_.Name -eq $device_name }
			If ($dev_found.Count -gt 1) {
				Write-Host ("$script_host,$remote_host,$device_name - EXCEPTION: multiple devices found with the same name")
				Write-Host ("$script_host,$remote_host,$device_name - ...remove extra devices before continuing")
				Break
			}
			ElseIf ($dev_found.IsClient) {
				# declare the device was found and the client is installed
				$dev_resid = $dev_found.ResourceId
				Write-Host ("$script_host,$remote_host,$device_name - ...found device by name with client installed, resource ID: " + $dev_resid)
			}
			ElseIf ($dev_found) {
				# declare the device was found but the client is NOT installed
				Write-Host ("$script_host,$remote_host,$device_name - EXCEPTION: device found WITHOUT client installed")
				Write-Host ("$script_host,$remote_host,$device_name - ...install SCCM agent then wait for SCCM to merge the objects")
				Break
			}
			Else {
				# declare issue and end early
				Write-Host ("$script_host,$remote_host,$device_name - EXCEPTION: device for cloud VM not found")
				Write-Host ("$script_host,$remote_host,$device_name - ...join VM to domain then install SCCM agent")
				Break
			}
		}
		ElseIf ($device_hwid) {
			# check for device by MAC via WMI, import if not found
			Write-Host ("$script_host,$remote_host,$device_name - ...device is VM on-premises, retrieving device by MAC address: " + $device_hwid)
			# check for device via WMI, import if not found
			$dev_found = Get-WmiObject -Namespace $cm_space -Class $cm_class | Where-Object { $_.Name -eq $device_name }
			If ($dev_found.Count -gt 1) {
				Write-Host ("$script_host,$remote_host,$device_name - EXCEPTION: multiple devices found with the same MAC address")
				Write-Host ("$script_host,$remote_host,$device_name - ...remove extra devices before continuing")
				Break
			}
			ElseIf ($dev_found.IsClient) {
				# declare the device was found but the client is installed
				Write-Host ("$script_host,$remote_host,$device_name - EXCEPTION: device found WITH client installed")
				Write-Host ("$script_host,$remote_host,$device_name - ...verify any previous device has been removed from SCCM")
				Break
			}
			ElseIf ($dev_found) {
				# declare the device was found in SCCM
				Write-Host ("$script_host,$remote_host,$device_name - ...found existing device with resource ID: " + $dev_resid)
				$dev_resid = $dev_found.ResourceId
			}
			Else {
				# import the device into SCCM
				Write-Host ("$script_host,$remote_host,$device_name - ...adding device to SCCM")
				Import-CMComputerInformation -ComputerName ($device_name.ToLower()) -MacAddress $device_hwid

				# wait until device is visible in SCCM
				Write-Host ("$script_host,$remote_host,$device_name - waiting for device to be visible in SCCM...")
				Do { Start-Sleep -Seconds 5 }
				Until (Get-WmiObject -Namespace $cm_space -Class $cm_class | Where-Object { $_.MacAddresses -eq $device_hwid })

				# declare the device was found in SCCN
				Write-Host ("$script_host,$remote_host,$device_name - ...retrieving resource ID for device")
				$dev_found = Get-WmiObject -Namespace $cm_space -Class $cm_class | Where-Object { $_.MacAddresses -eq $device_hwid }
				$dev_resid = $dev_found.ResourceId
			}
		}
		Else {
			Write-Host ("$script_host,$remote_host,$device_name - EXCEPTION: on-premises VM found but no MAC address available")
			Break
		}

		# retrieve the all systems collection
		Write-Host ("$script_host,$remote_host,$device_name - retrieving collection for All Systems")
		$col_systems = Get-CMDeviceCollection -Name 'All Systems'
		If ($col_systems) {
			Write-Host ("$script_host,$remote_host,$device_name - ...found All Systems collection")
		}
		Else {
			Write-Host ("$script_host,$remote_host,$device_name - ERROR: All Systems collection not found")
			Break
		}

		# retrieve the maintenance window collection
		Write-Host ("$script_host,$remote_host,$device_name - retrieving collection for maintenance window: " + $cm_col_window)
		$col_window = Get-CMDeviceCollection -Name $cm_col_window
		If ($col_window) {
			Write-Host ("$script_host,$remote_host,$device_name - ...found maintenance window collection")
		}
		Else {
			Write-Host ("$script_host,$remote_host,$device_name - ERROR: maintenance window collection not found")
			Break
		}

		# check for device in maintenance window collection
		If ($col_window | Get-CMDeviceCollectionDirectMembershipRule -ResourceId $dev_resid) {
			# declare the device was found in the collection
			Write-Host ("$script_host,$remote_host,$device_name - ...found direct membership rule for device in maintenance window")
		}
		Else {
			# add the device to the collection
			Write-Host ("$script_host,$remote_host,$device_name - ...adding direct membership rule for device to maintenance window")
			$null = $col_window | Add-CMDeviceCollectionDirectMembershipRule -ResourceId $dev_resid

			# update the All Systems collection manually
			Write-Host ("$script_host,$remote_host,$device_name - ...updating the All Systems Collection")
			$null = $col_systems | Invoke-CMCollectionUpdate

			# wait until device is visible in collection
			Write-Host ("$script_host,$remote_host,$device_name - waiting for device to be visible in All Systems")
			Do { Start-Sleep -Seconds 5 }
			Until ($col_systems | Get-CMCollectionMember -ResourceId $dev_resid)

			# declare the device was found in the collection
			Write-Host ("$script_host,$remote_host,$device_name - ...found device in All Systems")

			# update the deploy collection manually
			Write-Host ("$script_host,$remote_host,$device_name - ...updating maintenance window")
			$null = $col_window | Invoke-CMCollectionUpdate

			# wait until device is visible in collection
			Write-Host ("$script_host,$remote_host,$device_name - waiting for device to be visible in maintenance window")
			Do { Start-Sleep -Seconds 5 }
			Until ($col_window | Get-CMCollectionMember -ResourceId $dev_resid)

			# declare the device was found in the collection
			Write-Host ("$script_host,$remote_host,$device_name - ...found device in maintenance window")
		}

		# check for device in deploy collection for on-premises VMs
		If ($device_host -match 'cloud') {
			Write-Host ("$script_host,$remote_host,$device_name - skipping deploy collection for cloud VM")
		}
		Else {
			# retrieve the deploy collection
			Write-Host ("$script_host,$remote_host,$device_name - retrieving collection for OS deployment: " + $cm_col_deploy)
			$col_deploy = Get-CMDeviceCollection -Name $cm_col_deploy
			If ($col_deploy) {
				Write-Host ("$script_host,$remote_host,$device_name - ...found collection")
			}
			Else {
				Write-Host ("$script_host,$remote_host,$device_name - ERROR: collection not found")
				Break
			}

			# check for device in specified collection
			If ($col_deploy | Get-CMDeviceCollectionDirectMembershipRule -ResourceId $dev_resid) {
				# declare the device was found in the collection
				Write-Host ("$script_host,$remote_host,$device_name - ...found direct membership rule for device in deploy collection")
			}
			Else {
				# import the device into the collection
				Write-Host ("$script_host,$remote_host,$device_name - ...adding direct membership rule for device to deploy collection")
				$null = $col_deploy | Add-CMDeviceCollectionDirectMembershipRule -ResourceId $dev_resid

				# update the deploy collection manually
				Write-Host ("$script_host,$remote_host,$device_name - ...updating deploy collection")
				$null = $col_deploy | Invoke-CMCollectionUpdate

				# wait until device is visible in collection
				Write-Host ("$script_host,$remote_host,$device_name - waiting for device to be visible in deploy collection...")
				Do { Start-Sleep -Seconds 5 }
				Until ($col_deploy | Get-CMCollectionMember -ResourceId $dev_resid)

				# declare the device was found in the collection
				Write-Host ("$script_host,$remote_host,$device_name - ...found device in collection")
			}

			# update the device with the domain and LDAP path of the computer object
			Write-Host ("$script_host,$remote_host,$device_name - setting OSD variables for local VM")
			Write-Host ("$script_host,$remote_host,$device_name - ...setting OSD domain to: " + $device_domain)
			$null = New-CMDeviceVariable -DeviceId $dev_resid -VariableName 'OSDDOMAIN' -VariableValue $device_domain
			Write-Host ("$script_host,$remote_host,$device_name - ...setting OSD OU name to: " + $device_oupath)
			$null = New-CMDeviceVariable -DeviceId $dev_resid -VariableName 'OSDDOMAINOUNAME' -VariableValue $device_oupath
		}
	}
}

Function Add-DeviceToWds {
	param (
		[Parameter(Mandatory)]
		[object]$VmParams
	)

	# define required strings
	$vm_deployment_server = $VmParams.DeploymentServer
	$vm_deployment_path = $VmParams.DeploymentPath

	# retrieve BIOS GUID
	Try {
		$vm_biosguid = (Get-WmiObject -ComputerName $vm_host -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_VirtualSystemSettingData' -Filter "ElementName = '$vm_name'").BIOSGUID
	}
	Catch {
		Write-Host ("$Hostname,$vm_host,$vm_name - WARNING: could not retrieve BIOS GUID for VM")
		Return
	}

	# pre-stage VM in WDS
	If ($vm_deployment_server -and $vm_deployment_path -and $vm_biosguid) {
		Invoke-Command -ComputerName $vm_deployment_server -ScriptBlock {
			# map objects to session
			$script_host = $using:Hostname
			$remote_host = $using:vm_deployment_server
			$device_name = $using:vm_name
			$device_guid = $using:vm_biosguid
			$device_file = $using:vm_deployment_path

			# check if AD mode is disabled
			If ((Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\WDSServer\Providers\WDSDCMGR\Providers\WDSADDC').Disabled) {
				Get-WdsClient | Where-Object { $_.DeviceName -eq $device_name.ToUpper() } | Remove-WdsClient
				New-WdsClient -DeviceName $device_name.ToUpper() -DeviceID $device_guid -WdsClientUnattend $device_file | Out-Null
				Write-Host ("$script_host,$remote_host,$device_name - creating WDS device")
			}
			Else {
				Write-Host ("$script_host,$remote_host,$device_name - WDS server is AD-integrated, skipping WDS provisioning...")
			}
		}
	}
	Else {
		Write-Host ("$Hostname,$vm_host,$vm_name - WDS server or OSD path not provided, skipping WDS provisioning...")
	}
}

Function Add-IsoToVm {
	param (
		[Parameter()]
		[object]$VmParams
	)

	# define required strings
	$vm_deployment_path = $VmParams.DeploymentPath

	# get the mac address from the VM NIC
	$vm = Get-VM -ComputerName $vm_host -Name $vm_name

	# attach scsi controller for ISOs
	Write-Host ("$Hostname,$vm_host,$vm_name - adding SCSI controller for ISO file")
	$vm_dvd_scsi = Add-VMScsiController -VM $vm -Passthru
	Write-Host ("$Hostname,$vm_host,$vm_name - adding DVD drive for ISO file")
	$vm_dvd_drive = $vm_dvd_scsi | Add-VMDvdDrive -Passthru

	# attach any additional drives
	If ($vm_deployment_path) {
		$vm_host_found_iso = $null
		$vm_host_found_iso = Invoke-Command -ComputerName $vm_host -ScriptBlock { Test-Path -Path $using:vm_deployment_path }
		If ($vm_host_found_iso) {
			Write-Host ("$Hostname,$vm_host,$vm_name - ...attaching ISO file: " + $vm_deployment_path)
			$vm_dvd_drive | Set-VMDvdDrive -Path $vm_deployment_path
			Write-Host ("$Hostname,$vm_host,$vm_name - ...setting DVD drive as first boot device")
			$vm | Set-VMFirmware -FirstBootDevice $vm_dvd_drive
		}
		Else {
			Write-Host ("$Hostname,$vm_host,$vm_name - ...skipping ISO attach, VM host could not find file: " + $vm_deployment_path)
		}
	}
	Else {
		Write-Host ("$Hostname,$vm_host,$vm_name - ...skipping ISO attach, no file specified")
	}
}

Function New-VmFromParams {
	param (
		[Parameter(Mandatory)]
		[object]$VmParams
	)

	# define required strings
	$vm_path = $VmParams.Path
	$vm_processor_count = $VmParams.ProcessorCount

	# define required strings for memory
	$vm_memory_startup_bytes = $VmParams.MemoryStartupBytes
	$vm_memory_maximum_bytes = $VmParams.MemoryMaximumBytes
	$vm_memory_minimum_bytes = $VmParams.MemoryMinimumBytes

	# define required strings for storage
	$vhd_size_bytes = $VmParams.VHDSizeBytes
	$vhd_data_count = $VmParams.DataVHDCount
	$vhd_data_size_bytes = $VmParams.DataVHDSizeBytes
	$vhd_excluded_count = $VmParams.ExcludedVHDCount
	$vhd_excluded_size_bytes = $VmParams.ExcludedVHDSizeBytes

	# define required strings for networking
	$vm_vlan = $VmParams.VLAN
	$vm_switchname = $VmParams.SwitchName
	$vm_network_adapter_name = $VmParams.NetworkAdapterName
	$vm_mac_address_prefix = $VmParams.MacAddressPrefix

	# verify path
	Write-Host ("$Hostname,$vm_host,$vm_name - verifying paths...")
	If ($vm_path -and $UseDefaultPathOnHost) {
		$vm_path = (Get-VMHost -ComputerName $vm_host).VirtualMachinePath
		Write-Host ("$Hostname,$vm_host,$vm_name - ...using default VM path: " + $vm_path)
	}
	Else {
		Write-Host ("$Hostname,$vm_host,$vm_name - ...using provided VM path: " + $vm_path)
	}

	# define required folders
	$vm_path_vm = Invoke-Command -ComputerName $vm_host -ScriptBlock { Join-Path -Path $using:vm_path -ChildPath $using:vm_name }
	$vm_path_hd = Invoke-Command -ComputerName $vm_host -ScriptBlock { Join-Path -Path $using:vm_path_vm -ChildPath 'Virtual Hard Disks' }

	# verify required folders
	Write-Host ("$Hostname,$vm_host,$vm_name - checking folders...")
	Invoke-Command -ComputerName $vm_host -ScriptBlock {
		@($using:vm_path_vm, $using:vm_path_hd) | ForEach-Object {
			$vm_path_local = $_
			If (Test-Path $vm_path_local) {
				Write-Host ("$using:Hostname,$using:vm_host,$using:vm_name - ...found folder: " + $vm_path_local)
			}
			Else {
				Try {
					New-Item -ItemType Directory -Path $vm_path_local | Out-Null
					Write-Host ("$using:Hostname,$using:vm_host,$using:vm_name - ...created VM folder: " + $vm_path_local)
				}
				Catch {
					Write-Host ("$using:Hostname,$using:vm_host,$using:vm_name - ERROR: could not create VM folder: " + $vm_path_local)
					Exit
				}
			}
		}
	}

	# define path for OS VHD
	$vhd_os_file = Invoke-Command -ComputerName $vm_host -ScriptBlock { Join-Path -Path $using:vm_path_hd -ChildPath ($using:vm_name + '.vhdx') }

	# define paths for any data VHDs
	$vhd_data_files = @()
	If ($vhd_data_count) {
		# populate array of data VHDs
		For ($vhd_addl = 1; $vhd_addl -le $vhd_data_count; $vhd_addl++) {
			$vhd_data_files += Invoke-Command -ComputerName $vm_host -ScriptBlock { Join-Path -Path $using:vm_path_hd -ChildPath ($using:vm_name + '-data-' + $using:vhd_addl + '.vhdx') }
		}
	}

	# define paths for any excluded data VHDs
	$vhd_excl_files = @()
	If ($vhd_excluded_count) {
		# define path to excluded VHDs and add to array of paths
		$vm_path_ex = Invoke-Command -ComputerName $vm_host -ScriptBlock { Join-Path -Path $using:vm_path -ChildPath ('Exclude\' + $using:vm_name) }
		$vm_path_all += $vm_path_ex
		# populate array of excluded VHDs
		For ($vhd_excl = 1; $vhd_excl -le $vhd_excluded_count; $vhd_excl++) {
			$vhd_excl_files += Invoke-Command -ComputerName $vm_host -ScriptBlock { Join-Path -Path $using:vm_path_ex -ChildPath ($using:vm_name + '-excl-' + $using:vhd_excl + '.vhdx') }
		}
	}

	# check for OS vhdx
	Write-Host ("$Hostname,$vm_host,$vm_name - creating OS disk...")
	$vhd_os_file | ForEach-Object {
		$vhd_data = $null
		$vhd_data = $_
		$vhd_exists = $null
		$vhd_exists = Invoke-Command -ComputerName $vm_host -ScriptBlock { Test-Path $using:vhd_data }
		If ($vhd_exists) {
			Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: found existing OS disk: " + $vhd_data)
			Break
		}
		Else {
			# create the VM hard disk
			Try {
				New-VHD -Computer $vm_host -SizeBytes $vhd_size_bytes -Path $vhd_data | Out-Null
				Write-Host ("$Hostname,$vm_host,$vm_name - ...created OS disk: " + $vhd_data)
			}
			Catch {
				Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: could not create OS disk: " + $vhd_data)
				Exit
			}
		}
	}

	# create any additional drives
	If ($vhd_data_files) { Write-Host ("$Hostname,$vm_host,$vm_name - creating data disks...") }
	$vhd_data_files | ForEach-Object {
		$vhd_file = $null
		$vhd_file = $_
		$vhd_exists = $null
		$vhd_exists = Invoke-Command -ComputerName $vm_host -ScriptBlock { Test-Path $using:vhd_file }
		If ($vhd_exists) {
			Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: found existing data disk: " + $vhd_file)
			Break
		}
		Else {
			Try {
				New-VHD -Computer $vm_host -SizeBytes $vhd_data_size_bytes -Path $vhd_file | Out-Null
				Write-Host ("$Hostname,$vm_host,$vm_name - ...created data disk: " + $vhd_file)
			}
			Catch {
				Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: could not create data disk: " + $vhd_file)
				Exit
			}
		}
	}

	# create any additional drives excluded from dedupe
	If ($vhd_excl_files) { Write-Host ("$Hostname,$vm_host,$vm_name - creating excluded disks...") }
	$vhd_excl_files | ForEach-Object {
		$vhd_file = $null
		$vhd_file = $_
		$vhd_exists = $null
		$vhd_exists = Invoke-Command -ComputerName $vm_host -ScriptBlock { Test-Path $using:vhd_file }
		If ($vhd_exists) {
			Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: found existing excluded data disk: " + $vhd_file)
			Break
		}
		Else {
			Try {
				New-VHD -Computer $vm_host -SizeBytes $vhd_excluded_size_bytes -Path $vhd_file | Out-Null
				Write-Host ("$Hostname,$vm_host,$vm_name - ...created disk: " + $vhd_file)
			}
			Catch {
				Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: could not create disk: " + $vhd_file)
				Exit
			}
		}
	}

	# create the VM
	If ($vm_switchname -eq 'Remove') {
		Write-Host ("$Hostname,$vm_host,$vm_name - creating VM not connected to vSwitch")
		Try {
			$vm = New-VM -ComputerName $vm_host -Name $vm_name -Generation 2 -MemoryStartupBytes $vm_memory_startup_bytes -Path $vm_path -VHDPath $vhd_os_file
			$vm_id = $vm.Id
		}
		Catch {
			Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: could not create VM")
			Exit
		}
	}
	Else {
		Write-Host ("$Hostname,$vm_host,$vm_name - creating VM connected to vSwitch: " + $vm_switchname)
		Try {
			$vm = New-VM -ComputerName $vm_host -Name $vm_name -Generation 2 -MemoryStartupBytes $vm_memory_startup_bytes -Path $vm_path -VHDPath $vhd_os_file -BootDevice NetworkAdapter -SwitchName $vm_switchname
		}
		Catch {
			Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: could not create VM")
			Exit
		}
	}

	# configure the CPU
	If ($null = $vm_processor_count) { $vm_processor_count = 2 }
	Write-Host ("$Hostname,$vm_host,$vm_name - ...setting CPU count: " + $vm_processor_count)
	$vm | Set-VMProcessor -Count $vm_processor_count -ExposeVirtualizationExtensions $true

	# configure the memory
	If ($vm_memory_minimum_bytes -and $vm_memory_maximum_bytes) {
		# enable dynamic memory if:
		# - minimum must be between 32MB and startup memory, inclusive
		# - maximum must be between startup memory and 12TB, inclusive
		If (($vm_memory_minimum_bytes -ge 32MB) -and ($vm_memory_minimum_bytes -le $vm_memory_startup_bytes) -and ($vm_memory_maximum_bytes -ge $vm_memory_startup_bytes) -and ($vm_memory_maximum_bytes -le 12TB)) {
			Write-Host ("$Hostname,$vm_host,$vm_name - ...enabling dynamic memory (start, min, max): $(Format-Bytes -Size $vm_memory), $(Format-Bytes -Size $vm_memory_minimum_bytes), $(Format-Bytes -Size $vm_memory_maximum_bytes)")
			$vm | Set-VMMemory -DynamicMemoryEnabled $true -StartupBytes $vm_memory_startup_bytes -MinimumBytes $vm_memory_minimum_bytes -MaximumBytes $vm_memory_maximum_bytes
		}
		Else {
			Write-Host ("$Hostname,$vm_host,$vm_name - ...skipping dynamic memory, bad values provided (start, min, max): $(Format-Bytes -Size $vm_memory_startup_bytes), $(Format-Bytes -Size $vm_memory_minimum_bytes), $(Format-Bytes -Size $vm_memory_maximum_bytes)")
		}
	}

	# enable all services
	Write-Host ("$Hostname,$vm_host,$vm_name - ...enabling guest services")
	$vm | Enable-VMIntegrationService -Name 'Guest Service Interface'

	# attach any additional drives
	If ($vhd_data_files) {
		Write-Host ("$Hostname,$vm_host,$vm_name - adding SCSI controller for data VHDs")
		$vhd_data_scsi = Add-VMScsiController -VM $vm -Passthru
		$vhd_data_files | ForEach-Object {
			$vhd_data_name = $_
			Write-Host ("$Hostname,$vm_host,$vm_name - ...attaching data VHD: " + $vhd_data_name)
			# create new VHD and attach to VM
			$vhd_data_lun = [int](($vhd_data_name -split '.vhdx')[0] -split '-')[-1]
			$vhd_data_scsi | Add-VMHardDiskDrive -Path $vhd_data_name -ControllerLocation $vhd_data_lun
		}
	}

	# attach any additional drives
	If ($vhd_excl_files) {
		Write-Host ("$Hostname,$vm_host,$vm_name - adding SCSI controller for excluded VHDs")
		$vhd_excl_scsi = Add-VMScsiController -VM $vm -Passthru
		$vhd_excl_files | ForEach-Object {
			$vhd_excl_name = $_
			Write-Host ("$Hostname,$vm_host,$vm_name - ...attaching excluded VHD: " + $vhd_excl_name)
			# create new VHD and attach to VM
			$vhd_excl_lun = [int](($vhd_excl_name -split '.vhdx')[0] -split '-')[-1]
			$vhd_excl_scsi | Add-VMHardDiskDrive -Path $vhd_excl_name -ControllerLocation $vhd_excl_lun
		}
	}

	# retrieve VM Id
	Write-Host ("$Hostname,$vm_host,$vm_name - retrieving VM id for WMI...")
	$vm_id = $vm.Id

	# retrieve HV management objects and method parameters via WMI
	Write-Host ("$Hostname,$vm_host,$vm_name - retrieving settings via WMI...")
	$vm_data_object = Get-WmiObject -ComputerName $vm_host -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_VirtualSystemSettingData' -Filter "ConfigurationId = '$vm_id'"
	$vm_host_object = Get-WmiObject -ComputerName $vm_host -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_VirtualSystemManagementService'
	$vm_host_params = $vm_host_object.GetMethodParameters('ModifySystemSettings')

	# modify VM firmware settings to fix NumLock on boot
	Write-Host ("$Hostname,$vm_host,$vm_name - ...setting NumLock to True")
	$vm_data_object.BIOSNumLock = $true

	# update method parameters with modified VM firmware settings
	$vm_host_params.SystemSettings = $vm_data_object.GetText([System.Management.TextFormat]::CimDtd20)

	# update VM via call to VSMS
	Write-Host ("$Hostname,$vm_host,$vm_name - applying updated firmware settings via WMI...")
	$vm_host_output = Invoke-WmiMethod -InputObject $vm_host_object -Name 'ModifySystemSettings' -ArgumentList ($vm_host_params.SystemSettings)

	# check WMI out
	If ($vm_host_output.ReturnValue -eq 0) {
		Write-Host ("$Hostname,$vm_host,$vm_name - ...firmware settings updated...")
	}
	Else {
		Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: firmware settings not updated")
	}

	# retrieve updated firmware settings from WMI
	Write-Host ("$Hostname,$vm_host,$vm_name - retrieving updated settings via WMI...")
	$vm_data_object = Get-WmiObject -ComputerName $vm_host -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_VirtualSystemSettingData' -Filter "ElementName = '$vm_name'"

	# display updated firmware settings from WMI
	Write-Host ("$Hostname,$vm_host,$vm_name - ...BIOSGUID value: " + $vm_data_object.BIOSGUID)
	Write-Host ("$Hostname,$vm_host,$vm_name - ...NumLock status: " + $vm_data_object.BIOSNumLock)

	# check if NIC should be removed
	Write-Host ("$Hostname,$vm_host,$vm_name - configuring networking...")
	If ($vm_switchname -eq 'Remove') {
		Write-Host ("$Hostname,$vm_host,$vm_name - ...removing NIC; switch was defined as 'Remove'")
		$vm_nic = Get-VMNetworkAdapter -VM $vm
		$vm_nic | Remove-VMNetworkAdapter
	}
	Else {
		# set the name of the NIC
		If ($vm_network_adapter_name) {
			Write-Host ("$Hostname,$vm_host,$vm_name - ...renaming NIC to: " + $vm_network_adapter_name)
			$vm | Rename-VMNetworkAdapter -NewName $vm_network_adapter_name
			$vm | Set-VMNetworkAdapter -DeviceNaming On
		}

		# set the VLAN on the NIC
		If ($vm_vlan -gt 0) {
			Write-Host ("$Hostname,$vm_host,$vm_name - ...setting VLAN to: " + $vm_vlan)
			$vm | Set-VMNetworkAdapterVlan -Access -VlanId $vm_vlan
		}

		# set the MAC address
		$vm_hw_address = $null
		If (($vm_dhcp_server -and $vm_dhcp_scope) -or $vm_deployment_method -eq 'sccm') {
			Write-Host ("$Hostname,$vm_host,$vm_name - retriving MAC address for DHCP or OSD...")
			If ($vm_mac_address_prefix -and $vm_ip_address) {
				# add logic for checking mac prefix (see https://en.wikipedia.org/wiki/MAC_address)
				Write-Host ("$Hostname,$vm_host,$vm_name - ...creating MAC address from prefix and IP")
				$vm_hw_address = ($vm_mac_address_prefix + (($vm_ip_address.Split('.') | ForEach-Object { ([int]$_).ToString('X2') }) -join $null)).ToUpper()
			}
			Else {
				# start the VM to get the mac address assigned
				Write-Host ("$Hostname,$vm_host,$vm_name - ...getting MAC address from VM")
				$vm | Start-VM
				$vm | Stop-VM -Force; Start-Sleep -Seconds 5
				$vm | Set-VM -AutomaticStartAction Start
				# reload the VM object with the mac address
				$vm = Get-VM -ComputerName $vm_host -Id $vm_id
				# retrieve the mac address
				$vm_hw_address = ($vm.NetworkAdapters)[0].MacAddress
			}
		}
		Else {
			Write-Host ("$Hostname,$vm_host,$vm_name - ...skipping MAC address, OSD method is not 'sccm' or required DHCP values are not defined")
		}

		# statically assign the mac address to the NIC
		If ($vm_hw_address) {
			Write-Host ("$Hostname,$vm_host,$vm_name - ...setting static mac address: " + $vm_hw_address)
			$vm | Set-VMNetworkAdapter -StaticMacAddress $vm_hw_address
		}
	}

	# return VM object
	Return $vm
}

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
		Write-Host ("$Hostname - VM(s) not found in Json, exiting!")
		Return
	}
}
Else {
	$vm_list += (Get-Content -Path $VmJson | ConvertFrom-Json) | Where-Object { $_.VMHost -and $_.VMName }
}

# process JSON
ForEach ($VmParams in $vm_list) {
	# define required strings
	$vm_name = $VmParams.VMName
	$vm_host = $VmParams.VMHost
	$vm_prio = $VmParams.ClusterPriority

	# define optional strings for networking
	$vm_switch_name = $VmParams.SwitchName
	$vm_dhcp_server = $VmParams.DhcpServer
	$vm_dhcp_scope = $VmParams.DhcpScope
	$vm_ip_address = $VmParams.IPAddress

	# define optional strings for deployement
	$vm_deployment_method = $VmParams.DeploymentMethod

	# clear check objects
	$vm_on_host = $null
	$vm_in_the_cloud = $false
	$vm_cluster_group = $null
	$vm_host_clustered = $null

	# check for host overrides
	If ($VMHost) { $vm_host = $VMHost }
	If ($VMHostPath) { $vm_path = $VMHostPath }

	# check host
	switch ($vm_host) {
		'cloud' {
			Write-Host ("$Hostname,$vm_host,$vm_name - VM is in the cloud, skipping: VM build and DHCP configuration")
			$vm_in_the_cloud = $true
		}
		$null {
			Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: host not defined for VM")
			Return
		}
		Default {
			Write-Host ("$Hostname,$vm_host,$vm_name - checking host...")
			Try {
				$null = Test-WSMan -ComputerName $vm_host -Authentication 'Default'
				Write-Host ("$Hostname,$vm_host,$vm_name - ...found host")
			}
			Catch {
				Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: could not connect to host")
				Return
			}
		}
	}

	# check if host is clustered
	If (-not $vm_in_the_cloud) {
		Write-Host ("$Hostname,$vm_host,$vm_name - checking if host is clustered...")
		$vm_host_clustered = Get-Service -ComputerName $vm_host | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -eq 'Automatic' -and $_.Status -eq 'Running' }
		# check for VM on cluster
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
			Else {
				Write-Host ("$Hostname,$vm_host,$vm_name - ...VM resource group not found on cluster")
			}
		}
		Else {
			Write-Host ("$Hostname,$vm_host,$vm_name - ...host is standalone")
		}
	}

	# check for VM on host
	If (-not $vm_in_the_cloud) {
		# try to get VM from host
		Write-Host ("$Hostname,$vm_host,$vm_name - checking for VM on host...")
		$vm_on_host = Get-VM -ComputerName $vm_host | Where-Object { $_.Name -eq $vm_name }
	}

	# start VM provisioning
	If (-not $vm_in_the_cloud -and -not $vm_on_host) {
		Write-Host ("$Hostname,$vm_host,$vm_name - ....VM not found on host")
		Try {
			Write-Host ("$Hostname,$vm_host,$vm_name - creating VM on host...")
			$vm = New-VmFromParams -VmParams $VmParams
		}
		Catch {
			Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: creating VM on host...")
			Return
		}
	}
	ElseIf (-not $vm_in_the_cloud) {
		Write-Host ("$Hostname,$vm_host,$vm_name - skipping VM provisioning, VM already exists")
		$vm = $vm_on_host
	}

	# retrieve MAC address
	If (($vm_switch_name -ne 'Remove') -and -not $vm_in_the_cloud) {
		$vm_hw_address = ($vm.NetworkAdapters)[0].MacAddress
		Write-Host ("$Hostname,$vm_host,$vm_name - retrieved MAC address from VM: '$vm_hw_address'")
	}

	# start DHCP tasks unless cloud VM
	If ($vm_dhcp_server -and $vm_dhcp_scope -and $vm_ip_address -and $vm_hw_address -and -not $vm_in_the_cloud) {
		# check for existing DHCP scope
		Write-Host ("$Hostname,$vm_host,$vm_name - checking for DHCP scope on: '$vm_dhcp_server'")
		$vm_scope_exists = $null
		$vm_scope_exists = Get-DhcpServerv4Scope -ComputerName $vm_dhcp_server | Where-Object { $_.ScopeId -eq $vm_dhcp_scope }
		If ($null -eq $vm_scope_exists) {
			Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: DHCP scope does not exist on DHCP server '$vm_dhcp_server'")
			Return
		}

		# check for existing DHCP reservation
		Write-Host ("$Hostname,$vm_host,$vm_name - checking for DHCP reservation on: '$vm_dhcp_server'")
		$vm_reservation_exists = $null
		$vm_reservation_exists = Get-DhcpServerv4Reservation -ComputerName $vm_dhcp_server -ScopeId $vm_dhcp_scope | Where-Object { $_.IPAddress -eq $vm_ip_address }
		If ($vm_reservation_exists) {
			Try {
				$vm_reservation_exists | Remove-DhcpServerv4Reservation -ComputerName $vm_dhcp_server
				Write-Host ("$Hostname,$vm_host,$vm_name - removed existing DHCP reservation on: '$vm_dhcp_server'")
			}
			Catch {
				Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: removing existing DHCP reservcation on: '$vm_dhcp_server'")
				Return
			}
		}

		# create objects for DHCP reservation
		$vm_mac_addr = ($vm_hw_address -split '(\w{2})' | Where-Object { $_ -ne '' }) -join '-'
		$vm_dns_tail = ($vm_deployment_oupath -split ',' | Where-Object { $_ -match 'DC=' }) -join '.' -replace 'DC=', ''
		$vm_dns_name = ($vm_name + '.' + $vm_dns_tail).ToLower()

		# declare values
		Write-Host ("$Hostname,$vm_host,$vm_name - creating DHCP reservation...")
		Write-Host ("$Hostname,$vm_host,$vm_name - ...Reservation name : $vm_dns_name")
		Write-Host ("$Hostname,$vm_host,$vm_name - ...Hardare address  : $vm_mac_addr")
		Write-Host ("$Hostname,$vm_host,$vm_name - ...IP Address       : $vm_ip_address")

		# create DHCP reservation
		Try {
			Add-DhcpServerv4Reservation -ComputerName $vm_dhcp_server -Name $vm_dns_name -ScopeId $vm_dhcp_scope -IPAddress $vm_ip_address -ClientId $vm_mac_addr
			Write-Host ("$Hostname,$vm_host,$vm_name - created DHCP reservation on '$vm_dhcp_server'")
		}
		Catch {
			Write-Host ("$Hostname,$vm_host,$vm_name - ERROR: creating DHCP reservcation on '$vm_dhcp_server'")
			Return
		}

	}
	Else {
		Write-Host ("$Hostname,$vm_host,$vm_name - skipping DHCP configuration, required information not provided")
	}

	# start deployement tasks
	If ($vm_deployment_method) {
		Write-Host ("$Hostname,$vm_host,$vm_name - VM will be provisioned via: '$($vm_deployment_method.ToUpper())'")
		switch ($vm_deployment_method) {
			'iso' {
				Add-IsoToVm -VmParams $VmParams
			}
			'sccm' {
				Add-DeviceToSccm -VmParams $VmParams
			}
			'wds' {
				Add-DeviceToWds -VmParams $VmParams
			}
			default {
				Write-Host ("$Hostname,$vm_name - ...skipping deployment, unknown provisioning method provided: " + $vm_deployment_method.ToUpper())
			}
		}
	}

	# start cluster tasks
	If ($vm_host_clustered -and -not $vm_in_the_cloud) {
		# cluster VM if necessary
		If ($null -eq $vm_cluster_group) {
			Write-Host ("$Hostname,$vm_host,$vm_name - VM ready to be clustered, adding to cluster: " + $vm_cluster)
			$vm_cluster_group = Add-ClusterVirtualMachineRole -Cluster $vm_cluster -VMId $vm.Id
		}
		If ($vm_cluster_group) {
			# power on VM if necessary
			If ($vm_cluster_group.State -ne 'Online') {
				Write-Host ("$Hostname,$vm_host,$vm_name - VM powered off, starting VM on cluster...")
				$vm_cluster_group | Start-ClusterGroup | Out-Null
			}
			# set VM priority if defined
			If ($vm_prio) {
				Write-Host ("$Hostname,$vm_host,$vm_name - VM priority defined, setting to: " + $vm_prio)
				$vm_cluster_group.Priority = $vm_prio
			}
		}
	}
	ElseIf (-not $vm_in_the_cloud) {
		If ($vm.State -ne 'Running') {
			Write-Host ("$Hostname,$vm_host,$vm_name - starting VM on host")
			$vm | Start-VM
		}
	}
}
