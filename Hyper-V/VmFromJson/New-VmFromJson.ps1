Param(
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	[Parameter(ValueFromPipeline = $True)]
	[string[]]$VMName,
	[Parameter()]
	[string]$VMHost,
	[Parameter()]
	[string]$VMHostPath,
	[Parameter()]
	[switch]$UseDefaultPathOnHost,
	[Parameter()]
	[switch]$SkipProvisioning,
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
)

Begin {
	# retrieve data from JSON file
	Try {
		[array]$JsonData = Get-Content -Path $Json | ConvertFrom-Json
	}
	Catch {
		Write-Host ("$Hostname - ERROR: could not get content of JSON file: '$Json'")
		Throw $_
	}

	Function Format-Bytes {
		Param (
			[Parameter(Position = 0, Mandatory = $true)]
			[uint64]$Size,
			[Parameter(Position = 1)]
			[byte]$RoundTo = 2
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

	Function Get-PSSessionByName {
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName
		)

		# check if sessions table has been built
		If ($null -eq $script:Sessions) {
			$script:PSSessions = @{}
		}

		# if session exists for computer...
		If (-not $script:Sessions.ContainsKey($ComputerName)) {
			Try {
				$script:Sessions[$ComputerName] = New-PSSession -ComputerName $ComputerName -Name $ComputerName -Authentication Default
			}
			Catch {
				Return $_
			}
		}

		# return session
		Return $script:Sessions[$ComputerName]
	}

	Function Get-ClusterNameFromComputer {
		[CmdletBinding(DefaultParameterSetName = 'Default')]
		Param(
			[Parameter(Mandatory = $true, ParameterSetName = 'ComputerName')]
			[string]$ComputerName,
			[Parameter(Mandatory = $true, ParameterSetName = 'Session')]
			[object]$Session
		)

		# define InvokeCommand splat
		If ($PSCmdlet.ParameterSetName -eq 'Session') {
			$InvokeCommand = @{ Session = $Session }
		}
		ElseIf ($PSCmdlet.ParameterSetName -eq 'ComputerName' -and $ComputerName -ne $Hostname) {
			$InvokeCommand = @{ ComputerName = $ComputerName }
		}
		Else {
			$InvokeCommand = @{ NoNewScope = $true }
		}

		# test for cluster
		Try {
			Invoke-Command @InvokeCommand -ScriptBlock {
				Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Services\ClusSvc\Parameters' -Name 'ClusterName' -ErrorAction 'SilentlyContinue' | Select-Object -ExpandProperty 'ClusterName'
			}
		}
		Catch {
			Return $_
		}
	}

	Function Get-VMActualHost {
		[CmdletBinding(DefaultParameterSetName = 'Default')]
		Param(
			[Parameter(Mandatory = $true, ParameterSetName = 'ComputerName')]
			[string]$ComputerName,
			[Parameter(Mandatory = $true, ParameterSetName = 'Session')]
			[object]$Session,
			[Parameter(Mandatory = $true)]
			[string]$Cluster,
			[Parameter(Mandatory = $true)]
			[string]$Name
		)

		# define InvokeCommand splat
		If ($PSCmdlet.ParameterSetName -eq 'Session') {
			$InvokeCommand = @{ Session = $Session }
		}
		ElseIf ($PSCmdlet.ParameterSetName -eq 'ComputerName' -and $ComputerName -ne $Hostname) {
			$InvokeCommand = @{ ComputerName = $ComputerName }
		}
		Else {
			$InvokeCommand = @{ NoNewScope = $true }
		}

		# retrieve cluster name from registry if exists
		If ($null -eq $Cluster) {
			Try {
				$Cluster = Invoke-Command @InvokeCommand -ScriptBlock {
					Get-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Services\ClusSvc\Parameters' -Name 'ClusterName' -ErrorAction 'SilentlyContinue' | Select-Object -ExpandProperty 'ClusterName'
				}
			}
			Catch {
				$_
			}
		}

		# define argument list
		$InvokeCommand['ArgumentList'] = $Cluster, $Name

		# if host is clustered...
		If ($Cluster) {
			# ...check host for cluster group...
			Invoke-Command @InvokeCommand -ScriptBlock {
				Param($Cluster, $Name)
				# check for virtual machine cluster group with matching name...
				Try {
					$ClusterGroup = Get-ClusterGroup -Cluster $Cluster | Where-Object { $_.Name -eq $Name -and $_.GroupType -eq 'VirtualMachine' }
				}
				Catch {
					Return $_
				}
				# if a virtual machine cluster group exists with matchine name...
				If ($ClusterGroup) {
					# ...return the node name of the cluster group owner
					Return @{ Cluster = $Cluster; ComputerName = $ClusterGroup.OwnerNode.NodeName }
				}
			}
		}
		# if host is not clustered...
		Else {
			# ...return host
			Return @{ Cluster = $null; ComputerName = $ComputerName }
		}
	}

	Function Get-VMHostNextMacAddress {
		Param(
			[Parameter(ParameterSetName = 'Session')]
			[object]$Session,
			[Parameter(ParameterSetName = 'ComputerName')]
			[string]$ComputerName,
			[Parameter()]
			[string]$Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\Worker'
		)

		# define InvokeCommand splat
		If ($PSCmdlet.ParameterSetName -eq 'Session') {
			$InvokeCommand = @{ Session = $Session }
		}
		ElseIf ($PSCmdlet.ParameterSetName -eq 'ComputerName' -and $ComputerName -ne $Hostname) {
			$InvokeCommand = @{ ComputerName = $ComputerName }
		}
		Else {
			$InvokeCommand = @{ NoNewScope = $true }
		}

		# define argument list
		$InvokeCommand['ArgumentList'] = $Path

		# retrieve current MAC address and increment
		Try {
			$CurrentMacAddress = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($Path)
				Get-ItemPropertyValue -Path $Path -Name 'CurrentMacAddress'
			}
		}
		Catch {
			Return $_
		}

		# define and increment updated MAC address
		$UpdatedMacAddress = $CurrentMacAddress
		$UpdatedMacAddress[-1] += 1

		# update argument list
		$InvokeCommand['ArgumentList'] = $Path, $UpdatedMacAddress

		# update current MAC address
		Try {
			$null = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($Path, $UpdatedMacAddress)
				Set-ItemProperty -Path $Path -Name 'CurrentMacAddress' -Value $UpdatedMacAddress
			}
		}
		Catch {
			Return $_
		}

		# current current MAC address
		Try {
			Return [System.BitConverter]::ToString($CurrentMacAddress).Replace('-', $null)
		}
		Catch {
			Return $_
		}
	}

	Function New-VHDFromPaths {
		[CmdletBinding(DefaultParameterSetName = 'Default')]
		Param(
			[Parameter(Mandatory = $true, ParameterSetName = 'Session')][ValidateScript( { $_ -is [System.Management.Automation.Runspaces.PSSession] } )]
			[object]$Session,
			[Parameter(Mandatory = $true, ParameterSetName = 'ComputerName')]
			[string]$ComputerName,
			[Parameter(Mandatory = $true)]
			[string]$Path,
			[Parameter(Mandatory = $true)]
			[string]$ChildPath,
			[Parameter(Mandatory = $true)]
			[uint64]$SizeBytes
		)

		# define InvokeCommand splat
		If ($PSCmdlet.ParameterSetName -eq 'Session') {
			$InvokeCommand = @{ Session = $Session }
		}
		ElseIf ($PSCmdlet.ParameterSetName -eq 'ComputerName' -and $ComputerName -ne $Hostname) {
			$InvokeCommand = @{ ComputerName = $ComputerName }
		}
		Else {
			$InvokeCommand = @{ NoNewScope = $true }
		}

		# define argument list
		$InvokeCommand['ArgumentList'] = $Path

		# check the path
		Try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($Path)
				Test-Path -Path $Path -PathType 'Container'
			}
		}
		Catch {
			Return $_
		}

		# create the path if necessary
		If ( $TestPath -eq $false) {
			Try {
				$null = Invoke-Command @InvokeCommand -ScriptBlock {
					Param($Path)
					New-Item -Path $Path -ItemType 'Directory'
				}
			}
			Catch {
				Return $_
			}
		}

		# update argument list
		$InvokeCommand['ArgumentList'] = $Path, $ChildPath

		# build the VHD path
		Try {
			$VHDPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($Path, $ChildPath)
				Join-Path -Path $Path -ChildPath $ChildPath
			}
		}
		Catch {
			Return $_
		}

		# update argument list
		$InvokeCommand['ArgumentList'] = $VHDPath, $SizeBytes

		# create the VHD
		Try {
			$null = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($VHDPath, $SizeBytes)
				New-VHD -Path $VHDPath -SizeBytes $SizeBytes
			}
		}
		Catch {
			Return $_
		}

		# return path
		Return $VHDPath
	}

	Function Set-VMSystemSetting {
		[CmdletBinding(DefaultParameterSetName = 'VM')]
		Param(
			[Parameter(ParameterSetName = 'VM')]
			[object]$VM,
			[Parameter(ParameterSetName = 'Id')]
			[string]$Id,
			[Parameter(ParameterSetName = 'Name')]
			[string]$Name,
			[Parameter(ParameterSetName = 'Id')]
			[Parameter(ParameterSetName = 'Name')]
			[string]$ComputerName = $Hostname,
			[hashtable]$SystemSettings
		)

		# retrieve VM object from parameters
		switch ($PSCmdlet.ParameterSetName) {
			'Id' {
				Try {
					$VM = Get-VM -ComputerName $ComputerName -Id $Id
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM object by Id")
					Return $_
				}
			}
			'Name' {
				Try {
					$VM = Get-VM -ComputerName $ComputerName -Name $Name
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM object by Name")
					Return $_
				}
			}
		}

		# verify VM object and retrieve all parameters
		If ($VM -is [Microsoft.HyperV.PowerShell.VirtualMachine]) {
			$Id = $VM.Id
			$Name = $VM.Name
			$ComputerName = $VM.ComputerName
		}
		Else {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: provided VM object is not the correct type")
			Throw
		}

		# retrieve CIM instance for host management service
		Write-Host ("$Hostname,$ComputerName,$Name - retrieving CIM instance for host management...")
		Try {
			$HostInstance = Get-CimInstance -ComputerName $ComputerName -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_VirtualSystemManagementService'
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve CIM instance for host management")
			Throw
		}

		# retrieve original VM system settings and host management service via CIM
		Write-Host ("$Hostname,$ComputerName,$Name - retrieving CIM instance for VM system settings...")
		Try {
			$DataInstance = Get-CimInstance -ComputerName $ComputerName -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_VirtualSystemSettingData' -Filter "ConfigurationId = '$($VM.Id)'"
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve CIM instance for VM system settings")
			Throw
		}

		# modify VM system settings
		ForEach ($SystemSetting in $SystemSettings.Keys) {
			$DataInstance.$SystemSetting = $SystemSettings[$SystemSetting]
		}

		# serialize and encode VM system settings
		Try {
			$CimSerializer = [Microsoft.Management.Infrastructure.Serialization.CimSerializer]::Create()
			$DataSerialized = $CimSerializer.Serialize($DataInstance, [Microsoft.Management.Infrastructure.Serialization.InstanceSerializationOptions]::None)
			$DataEncoded = [System.Text.Encoding]::Unicode.GetString($DataSerialized)
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not serialize the CIM objects for VM firmware")
			Throw $_
		}

		# invoke CIM method on host management service to update VM system settings with modified values
		Write-Host ("$Hostname,$ComputerName,$Name - updating firmware settings via CIM...")
		Try {
			$CimResponse = Invoke-CimMethod -CimInstance $HostInstance -MethodName 'ModifySystemSettings' -Arguments @{SystemSettings = $DataEncoded }
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not call method to update firmware settings via CIM")
			Throw $_
		}

		# check CIM return value
		If ($CimResponse.ReturnValue -eq 0) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...firmware settings updated...")
		}
		Else {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: firmware settings not updated, CIM returned: '$($CimResponse.ReturnValue)'")
			Throw
		}

		# retrieve updated firmware settings from WMI
		Write-Host ("$Hostname,$ComputerName,$Name - retrieving updated CIM objects for VM firmware...")
		Try {
			$DataInstance = Get-CimInstance -ComputerName $ComputerName -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_VirtualSystemSettingData' -Filter "ConfigurationId = '$($VM.Id)'"
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve updated CIM objects for VM firmware")
			Throw
		}

		# display updated firmware settings from WMI
		ForEach ($SystemSetting in $SystemSettings.Keys) {
			Write-Host ("$Hostname,$ComputerName,$VMName - ...set '$SystemSetting': '$($DataInstance.$SystemSetting)'")
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
			Write-Host ("$Hostname,$ComputerName,$Name - WARNING: could not retrieve BIOS GUID for VM")
			Return $_
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
			Write-Host ("$Hostname,$ComputerName,$Name - WDS server or OSD path not provided, skipping WDS provisioning...")
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
		$VM = Get-VM -ComputerName $vm_host -Name $vm_name

		# attach scsi controller for ISOs
		Write-Host ("$Hostname,$ComputerName,$Name - adding SCSI controller for ISO file")
		$vm_dvd_scsi = Add-VMScsiController -VM $VM -Passthru
		Write-Host ("$Hostname,$ComputerName,$Name - adding DVD drive for ISO file")
		$vm_dvd_drive = $vm_dvd_scsi | Add-VMDvdDrive -Passthru

		# attach any additional drives
		If ($vm_deployment_path) {
			$vm_host_found_iso = $null
			$vm_host_found_iso = Invoke-Command -ComputerName $vm_host -ScriptBlock { Test-Path -Path $using:vm_deployment_path }
			If ($vm_host_found_iso) {
				Write-Host ("$Hostname,$ComputerName,$Name - ...attaching ISO file: " + $vm_deployment_path)
				$vm_dvd_drive | Set-VMDvdDrive -Path $vm_deployment_path
				Write-Host ("$Hostname,$ComputerName,$Name - ...setting DVD drive as first boot device")
				$VM | Set-VMFirmware -FirstBootDevice $vm_dvd_drive
			}
			Else {
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping ISO attach, VM host could not find file: " + $vm_deployment_path)
			}
		}
		Else {
			Write-Host ("$Hostname,$ComputerName,$Name - ...skipping ISO attach, no file specified")
		}
	}

	Function New-VmFromParams {
		param (
			[Parameter(Mandatory)]
			[string]$ComputerName,
			[Parameter(Mandatory)]
			[string]$Name,
			[Parameter(Mandatory)]
			[object]$VmParams
		)

		# define required strings
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

		# connect to host with PS remoting
		Write-Host ("$Hostname,$ComputerName,$Name - connecting to host...")
		Try {
			$Session = Get-PSSessionByName -ComputerName $ComputerName
			Write-Host ("$Hostname,$ComputerName,$Name - ...connected to host")
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not connect to host")
			Return $_
		}

		# verify path
		Write-Host ("$Hostname,$ComputerName,$Name - verifying paths...")
		If ($UseDefaultPathOnHost) {
			Try {
				$VirtualMachinePath = (Get-VMHost -ComputerName $ComputerName).VirtualMachinePath
				Write-Host ("$Hostname,$ComputerName,$Name - ...using default VM path: '$VirtualMachinePath")
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VirtualMachinePath on host")
				Return $_
			}
		}
		Else {
			Write-Host ("$Hostname,$ComputerName,$Name - ...using provided VM path: '$VirtualMachinePath'")
		}

		# define path to the VM
		$vm_path_vm = Invoke-Command -Session $Session -ScriptBlock { Join-Path -Path $using:VirtualMachinePath -ChildPath $using:vm_name }
		$vm_path_hd = Invoke-Command -Session $Session -ScriptBlock { Join-Path -Path $using:vm_path_vm -ChildPath 'Virtual Hard Disks' }
		$vm_path_hv_ex = Invoke-Command -Session $Session -ScriptBlock { Join-Path -Path $using:VirtualMachinePath -ChildPath '.exclude' }
		$vm_path_hd_ex = Invoke-Command -Session $Session -ScriptBlock { Join-Path -Path $using:vm_path_hv_ex -ChildPath $using:vm_name }

		# declare start of disk section
		Write-Host ("$Hostname,$ComputerName,$Name - creating disks...")

		# define the VHD name
		$vhd_name = "$Name.vhdx"
		# create the VHD from paths and name
		Try {
			$vhd_path = New-VHDFromPaths -Session $Session -Path $vm_path_hd -ChildPath $vhd_name -SizeBytes $vhd_size_bytes
			$vhd_os_file += $vhd_path
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not create disk: '$vhd_path'")
			Return $_
		}

		# if there are data disks...
		$vhd_data_files = @()
		If ($vhd_data_count) {
			For ($vhd_count = 1; $vhd_count -le $vhd_data_count; $vhd_count++) {
				# define the VHD name
				$vhd_name = "$Name-data-$vhd_count.vhdx"
				# create the VHD from paths and name
				Try {
					$vhd_path = New-VHDFromPaths -Session $pss_vm -Path $vm_path_hd -ChildPath $vhd_name -SizeBytes $vhd_data_size_bytes
					$vhd_data_files += $vhd_path
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not create disk: '$vhd_path'")
					Return $_
				}
			}
		}

		# if there are data disks excluded from deduplication...
		$vhd_excl_files = @()
		If ($vhd_excluded_count) {
			# ...create the disks
			For ($vhd_count = 1; $vhd_count -le $vhd_excluded_count; $vhd_count++) {
				# define the VHD name
				$vhd_name = "$Name-excl-$vhd_count.vhdx"
				# create the VHD from paths and name
				Try {
					$vhd_path = New-VHDFromPaths -Session $pss_vm -Path $vm_path_hd_ex -ChildPath $vhd_name -SizeBytes $vhd_excluded_size_bytes
					$vhd_excl_files += $vhd_path
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not create disk: '$vhd_path'")
					Return $_
				}
			}
		}

		# define VM
		$NewVM = @{
			ComputerName       = $ComputerName
			Name               = $Name
			Generation         = 2
			MemoryStartupBytes = $vm_memory_startup_bytes
			Path               = $VirtualMachinePath
			VHDPath            = $vhd_os_file
		}

		# define initial networking for VM
		If ($vm_switchname -ne 'Remove') {
			$NewVM['BootDevice'] = 'NetworkAdapter'
			$NewVM['SwitchName'] = $vm_switchname
		}

		# create VM
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - creating VM...")
			$VM = New-VM @NewVM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not create VM")
			Return $_
		}

		# check process count
		If ($null -eq $vm_processor_count) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...no CPU count provided; setting CPU count to default of '2'")
			$vm_processor_count = 2
		}

		# configure processor
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...configuring processor")
			Set-VMProcessor -VM $VM -ExposeVirtualizationExtensions $true
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not configure processor")
			Return $_
		}

		# configure memory
		If ($vm_memory_minimum_bytes -and $vm_memory_maximum_bytes) {
			# create strings for reporting
			$vm_mem_string = (Format-Bytes -Size $vm_memory_startup_bytes), (Format-Bytes -Size $vm_memory_minimum_bytes), (Format-Bytes -Size $vm_memory_maximum_bytes) -join ', '
			# check minimum memory is between 32MB and startup memory, inclusive
			$vm_mem_minimum_passed = $vm_memory_minimum_bytes -ge 32MB -and $vm_memory_minimum_bytes -le $vm_memory_startup_bytes
			# check maximum memory is between 12TB and startup memory, inclusive
			$vm_mem_maximum_passed = $vm_memory_maximum_bytes -le 12TB -and $vm_memory_maximum_bytes -ge $vm_memory_startup_bytes
			# check dynamic memory settings
			If ($vm_mem_minimum_passed -and $vm_mem_maximum_passed) {
				# define dynamic memory
				$SetVMMemory = @{
					VM                   = $VM
					DynamicMemoryEnabled = $true
					StartupBytes         = $vm_memory_startup_bytes
					MinimumBytes         = $vm_memory_minimum_bytes
					MaximumBytes         = $vm_memory_maximum_bytes
				}
				# configure dynamic memory
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...enabling dynamic memory (start, min, max): $vm_mem_string")
					Set-VMMemory @SetVMMemory
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set dynamic memory")
					Return $_
				}
			}
			Else {
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping dynamic memory, bad values provided (start, min, max): $vm_mem_string")
			}
		}

		# enable all services
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...enabling guest services")
			Enable-VMIntegrationService -VM $VM -Name 'Guest Service Interface'
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not enable guest services")
			Return $_
		}

		# attach any additional drives
		If ($vhd_data_files) {
			# create controller for VHDs
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - adding SCSI controller for data disks")
				$vhd_data_scsi = Add-VMScsiController -VM $VM -Passthru
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add SCSI controller")
				Return $_
			}
			# attach VHDs to controller
			ForEach ($vhd_data_file in $vhd_data_files) {
				$vhd_location = [int](($vhd_data_file -split '.vhdx')[0] -split '-')[-1]
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...attaching data disk: " + $vhd_data_file)
					Add-VMHardDiskDrive -VMDriveController $vhd_data_scsi -ControllerLocation $vhd_location -Path $vhd_data_file
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not attach data disk")
					Return $_
				}
			}
		}

		# attach any additional drives
		If ($vhd_excl_files) {
			# create controller for VHDs
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - adding SCSI controller for data disks excluded from deduplication")
				$vhd_excl_scsi = Add-VMScsiController -VM $VM -Passthru
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add SCSI controller")
				Return $_
			}
			# attach VHDs to controller
			ForEach ($vhd_excl_file in $vhd_excl_files) {
				$vhd_location = [int](($vhd_excl_file -split '.vhdx')[0] -split '-')[-1]
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...attaching data disk: " + $vhd_excl_file)
					Add-VMHardDiskDrive -VMDriveController $vhd_excl_scsi -ControllerLocation $vhd_location -Path $vhd_excl_file
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not attach data disk")
					Return $_
				}
			}
		}

		# define system settings
		$SystemSettings = @{
			BiosNumLock      = $True
			LockOnDisconnect = $true
		}

		# modify system settings
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - updating system settings...")
			Set-VMSystemSetting -VM $VM -SystemSettings $SystemSettings
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not update system settings")
			Return $_
		}

		# if NIC should be removed...
		Write-Host ("$Hostname,$ComputerName,$Name - configuring networking...")
		If ($vm_switchname -eq 'Remove') {
			# remove NIC
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...removing NIC; switch was defined as '$vm_switchname'")
				ForEach ($vm_nic in (Get-VMNetworkAdapter -VM $VM)) {
					$vm_nic | Remove-VMNetworkAdapter
				}
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove NIC")
				Return $_
			}
		}
		# if NIC should not be removed...
		Else {
			# get the NIC
			Try {
				$vm_nic = (Get-VMNetworkAdapter -VM $VM)[0]
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not rename NIC")
				Return $_
			}
			# set the name of the NIC
			If ($vm_network_adapter_name) {
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...renaming NIC to: '$vm_network_adapter_name'")
					$vm_nic | Rename-VMNetworkAdapter -NewName $vm_network_adapter_name
					$vm_nic | Set-VMNetworkAdapter -DeviceNaming On
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not rename NIC")
					Return $_
				}
			}
			# set the VLAN on the NIC
			If ($vm_vlan -gt 0) {
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...setting VLAN to: '$vm_vlan'")
					$vm_nic | Set-VMNetworkAdapterVlan -Access -VlanId $vm_vlan
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set VLAN on NIC")
					Return $_
				}
			}
			# if the mac address prefix and the ip address are specified...
			If ($vm_mac_address_prefix -and $vm_ip_address) {
				# ...craft a custom MAC address using the prefix for the first two octets and the IP address for the last four octets
				Write-Host ("$Hostname,$ComputerName,$Name - ...creating MAC address from prefix and IP")
				$vm_hw_address = ($vm_mac_address_prefix + (($vm_ip_address.Split('.') | ForEach-Object { ([int]$_).ToString('X2') }) -join $null)).ToUpper()
			}
			# if the MAC address prefix and the IP address are not provided...
			Else {
				# ...retrieve the next MAC address from the host
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...retrieving next MAC address from host")
					$vm_hw_address = Get-VMHostNextMacAddress -Session $pss_vm
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve next MAC address from host")
					Return $_
				}
			}

			# statically assign the mac address to the NIC
			If ($vm_hw_address) {
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...setting static mac address: '$vm_hw_address'")
					$vm_nic | Set-VMNetworkAdapter -StaticMacAddress $vm_hw_address
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set static MAC address on NIC")
					Return $_
				}
			}
		}

		# return VM object
		Return $VM
	}

}

Process {
	ForEach ($Name in $VMname) {
		# retrieve parameters from JSON data for VM
		$VMParams = $JsonData | Where-Object { $_.VMName -eq $Name }

		# check if VMParams contains VM
		If ($null -eq $VMParams) {
			Write-Host ("$Hostname - VM not found in Json: '$Name")
			Continue
		}

		# check if VMParams contains multiple VMs with the same name
		If ($null -ne $VMParams.Count) {
			Write-Host ("$Hostname - VM found in Json multiple times: '$Name")
			Continue
		}

		# override VMParams with bound parameters if any
		If ($PSBoundParameters['VMHost']) { $ComputerName = $VMHost }
		If ($PSBoundParameters['VMHostPath']) { $vm_path = $VMHostPath }

		# check host
		switch ($ComputerName) {
			'cloud' {
				Write-Host ("$Hostname,$ComputerName,$Name - WARNING: VM is in the cloud, skipping some steps...")
				$vm_in_the_cloud = $true
			}
			$null {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: host not defined for VM")
				Return
			}
			Default {
				Write-Host ("$Hostname,$ComputerName,$Name - connecting to host via PS remoting...")
				Try {
					$Session = Get-PSSessionByName -ComputerName $ComputerName
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: connecting to host via PS remoting")
					Return $_
				}
			}
		}

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
		$vm_in_the_cloud = $false
		$vm_cluster_group = $null
		$vm_host_clustered = $null

		# check for host overrides
		If ($VMHost) { $vm_host = $VMHost }
		If ($VMHostPath) { $vm_path = $VMHostPath }

		# check if VM is in the cloud
		If ($vm_in_the_cloud) {
			Write-Host ("$Hostname,$ComputerName,$Name - WARNING: VM is in the cloud, skipping some OS and DHCP provisioning...")
		}

		# check if host is clustered
		If (-not $vm_in_the_cloud) {
			# get cluster name from host
			Write-Host ("$Hostname,$ComputerName,$Name - checking if host is clustered...")
			Try {
				$Cluster = Get-ClusterNameFromComputer -ComputerName $ComputerName
			}
			Catch {
				Return $_
			}
			# get actual host from cluster
			If ($Cluster) {
				Write-Host ("$Hostname,$ComputerName,$Name - ...host is clustered, check cluster for VM resource group...")
				Try {
					$ClusterNode = Get-VMActualHost -ComputerName $ComputerName -Cluster $Cluster -Name $Name
				}
				Catch {
					Return $_
				}
				# check cluster node
				switch ($ClusterNode) {
					$null {
						Write-Host ("$Hostname,$ComputerName,$Name - ...VM resource group not found on cluster")
					}
					$ComputerName {
						Write-Host ("$Hostname,$ComputerName,$Name - ...VM resource group found on expected host in cluster")
					}
					Default {
						Write-Host ("$Hostname,$ComputerName,$Name - ...VM resource group found on different host in cluster, changing host to: $ClusterNode")
						$ComputerName = $ClusterNode
						Try {
							$Session = Get-PSSessionByName -ComputerName $ComputerName
						}
						Catch {
							Write-Host ("$Hostname,$ComputerName,$Name - ERROR: host not defined for VM")
							Return $_
						}
					}
				}
			}
			Else {
				Write-Host ("$Hostname,$ComputerName,$Name - ...host is not clustered")
			}
		}

		# check host
		switch ($ComputerName) {
			'cloud' {
				Write-Host ("$Hostname,$ComputerName,$Name - WARNING: VM is in the cloud, skipping some steps...")
				$vm_in_the_cloud = $true
			}
			$null {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: host not defined for VM")
				Return
			}
			Default {
				If ($script:Sessions.ContainsKey($ComputerName)) {
					$Session = $script:Sessions[$ComputerName]
					Write-Host ("$Hostname,$ComputerName,$Name - connected to host with existing session")
				}
				Else {
					Try {
						$script:Sessions[$ComputerName] = $Session = New-PSSession -ComputerName $ComputerName -Name $ComputerName -Authentication Default
						Write-Host ("$Hostname,$ComputerName,$Name - connected to host with a new session")
					}
					Catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not connect to host")
						Return $_
					}
				}
			}
		}

		# check for VM on host
		If (-not $vm_in_the_cloud) {
			# try to get VM from host
			Write-Host ("$Hostname,$ComputerName,$Name - checking for VM on host...")
			Try {
				$VM = Get-VM -ComputerName $ComputerName -Name $Name -ErrorAction 'Stop'
				Write-Host ("$Hostname,$ComputerName,$Name - ....VM found on host")
				Write-Host ("$Hostname,$ComputerName,$Name - skipping VM provisioning, VM already exists")
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ....VM not found on host")
				Write-Host ("$Hostname,$ComputerName,$Name - creating VM on host...")
				Try {
					$VM = New-VmFromParams -ComputerName $ComputerName -Name $Name -VmParams $VmParams
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: creating VM on host...")
					Return $_
				}
			}
		}

		# retrieve MAC address
		If (($vm_switch_name -ne 'Remove') -and -not $vm_in_the_cloud) {
			$vm_hw_address = ($VM.NetworkAdapters)[0].MacAddress
			Write-Host ("$Hostname,$ComputerName,$Name - retrieved MAC address from VM: '$vm_hw_address'")
		}

		# start DHCP tasks unless cloud VM
		If ($vm_dhcp_server -and $vm_dhcp_scope -and $vm_ip_address -and $vm_hw_address -and -not $vm_in_the_cloud) {
			# check for existing DHCP scope
			Write-Host ("$Hostname,$ComputerName,$Name - checking for DHCP scope on: '$vm_dhcp_server'")
			$vm_scope_exists = $null
			$vm_scope_exists = Get-DhcpServerv4Scope -ComputerName $vm_dhcp_server | Where-Object { $_.ScopeId -eq $vm_dhcp_scope }
			If ($null -eq $vm_scope_exists) {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: DHCP scope does not exist on DHCP server '$vm_dhcp_server'")
				Return
			}

			# check for existing DHCP reservation
			Write-Host ("$Hostname,$ComputerName,$Name - checking for DHCP reservation on: '$vm_dhcp_server'")
			$vm_reservation_exists = $null
			$vm_reservation_exists = Get-DhcpServerv4Reservation -ComputerName $vm_dhcp_server -ScopeId $vm_dhcp_scope | Where-Object { $_.IPAddress -eq $vm_ip_address }
			If ($vm_reservation_exists) {
				Try {
					$vm_reservation_exists | Remove-DhcpServerv4Reservation -ComputerName $vm_dhcp_server
					Write-Host ("$Hostname,$ComputerName,$Name - removed existing DHCP reservation on: '$vm_dhcp_server'")
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing existing DHCP reservcation on: '$vm_dhcp_server'")
					Return
				}
			}

			# create objects for DHCP reservation
			$vm_mac_addr = ($vm_hw_address -split '(\w{2})' | Where-Object { $_ -ne '' }) -join '-'
			$vm_dns_tail = ($vm_deployment_oupath -split ',' | Where-Object { $_ -match 'DC=' }) -join '.' -replace 'DC=', ''
			$vm_dns_name = ($vm_name + '.' + $vm_dns_tail).ToLower()

			# declare values
			Write-Host ("$Hostname,$ComputerName,$Name - creating DHCP reservation...")
			Write-Host ("$Hostname,$ComputerName,$Name - ...Reservation name : $vm_dns_name")
			Write-Host ("$Hostname,$ComputerName,$Name - ...Hardare address  : $vm_mac_addr")
			Write-Host ("$Hostname,$ComputerName,$Name - ...IP Address       : $vm_ip_address")

			# create DHCP reservation
			Try {
				Add-DhcpServerv4Reservation -ComputerName $vm_dhcp_server -Name $vm_dns_name -ScopeId $vm_dhcp_scope -IPAddress $vm_ip_address -ClientId $vm_mac_addr
				Write-Host ("$Hostname,$ComputerName,$Name - created DHCP reservation on '$vm_dhcp_server'")
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: creating DHCP reservcation on '$vm_dhcp_server'")
				Return
			}

		}
		Else {
			Write-Host ("$Hostname,$ComputerName,$Name - skipping DHCP configuration, required information not provided")
		}

		# start deployement tasks
		If ($vm_deployment_method -and -not $SkipProvisioning) {
			Write-Host ("$Hostname,$ComputerName,$Name - VM will be provisioned via: '$($vm_deployment_method.ToUpper())'")
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
		ElseIf ($vm_deployment_method -and $SkipProvisioning) {
			Write-Host ("$Hostname,$vm_name - skipping deployment, SkipProvisioning")
		}

		# start cluster tasks
		If ($vm_host_clustered -and -not $vm_in_the_cloud) {
			# cluster VM if necessary
			If ($null -eq $vm_cluster_group) {
				Write-Host ("$Hostname,$ComputerName,$Name - VM ready to be clustered, adding to cluster: $vm_cluster")
				Try {
					$vm_cluster_group = Add-ClusterVirtualMachineRole -Cluster $vm_cluster -VMId $VM.Id
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: adding VM to cluster: '$vm_cluster'")
					Return
				}
			}
			If ($vm_cluster_group) {
				# power on VM if necessary
				If ($vm_cluster_group.State -ne 'Online') {
					Write-Host ("$Hostname,$ComputerName,$Name - VM powered off, starting VM on cluster...")
					$vm_cluster_group | Start-ClusterGroup | Out-Null
				}
				# set VM priority if defined
				If ($vm_prio) {
					Write-Host ("$Hostname,$ComputerName,$Name - VM priority defined, setting to: $vm_prio")
					$vm_cluster_group.Priority = $vm_prio
				}
			}
		}
		ElseIf (-not $vm_in_the_cloud) {
			If ($VM.State -ne 'Running') {
				Write-Host ("$Hostname,$ComputerName,$Name - starting VM on host")
				$VM | Start-VM
			}
		}
	}
}

End {
	# remove sessions
}