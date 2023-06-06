[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# All - json file name
	[Parameter(Mandatory = $true, Position = 0)]
	[string]$Json,
	# All - mode
	[Parameter(Mandatory = $True, Position = 1, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Mandatory = $True, Position = 1, ParameterSetName = 'Add')]
	[switch]$Add,
	[Parameter(Mandatory = $True, Position = 1, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Mandatory = $True, Position = 1, ParameterSetName = 'AddVMHardDiskDrive')]
	[switch]$AddVMHardDiskDrive,
	[Parameter(Mandatory = $True, Position = 1, ParameterSetName = 'RemoveVMHardDiskDrive')]
	[switch]$RemoveVMHardDiskDrive,
	[Parameter(Mandatory = $True, Position = 1, ParameterSetName = 'AddVMNetworkAdapter')]
	[switch]$AddVMNetworkAdapter,
	[Parameter(Mandatory = $True, Position = 1, ParameterSetName = 'RemoveVMNetworkAdapter')]
	[switch]$RemoveVMNetworkAdapter,
	# All - name of VM
	[Parameter(Mandatory = $True, Position = 2, ParameterSetName = 'Add')]
	[Parameter(Mandatory = $True, Position = 2, ParameterSetName = 'Remove')]
	[Parameter(Mandatory = $True, Position = 2, ParameterSetName = 'AddVMHardDiskDrive')]
	[Parameter(Mandatory = $True, Position = 2, ParameterSetName = 'RemoveVMHardDiskDrive')]
	[Parameter(Mandatory = $True, Position = 2, ParameterSetName = 'AddVMNetworkAdapter')]
	[Parameter(Mandatory = $True, Position = 2, ParameterSetName = 'RemoveVMNetworkAdapter')]
	[Parameter(Mandatory = $True, Position = 2, ParameterSetName = 'AddOSD')]
	[Parameter(Mandatory = $True, Position = 2, ParameterSetName = 'RemoveOSD')]
	[string]$VMName,
	# VM - path of virtual machine files
	# VMHardDiskDrive - path of virtual hard disk drive
	[Parameter(Mandatory = $True, Position = 3, ParameterSetName = 'Add')]
	[Parameter(Mandatory = $True, Position = 3, ParameterSetName = 'AddVMHardDiskDrive')]
	[Parameter(Mandatory = $True, Position = 3, ParameterSetName = 'RemoveVMHardDiskDrive')]
	[string]$Path,
	# VMNetworkAdapter - name of network adapter
	[Parameter(Position = 3, ParameterSetName = 'AddVMNetworkAdapter')]
	[Parameter(Position = 3, ParameterSetName = 'RemoveVMNetworkAdapter')]
	[string]$NetworkAdapterName = 'Network Adapter',
	# VM - count of virtual processors
	[Parameter(ParameterSetName = 'Add')][ValidateRange(1, 256)]
	[uint16]$ProcessorCount,
	# VM - bytes of memory on startup
	[Parameter(ParameterSetName = 'Add')][ValidateScript({ ($_ -ge 32MB) -and ($_ -le 12TB) })]
	[uint64]$MemoryStartupBytes,
	# VM - minimum bytes of memory when dynamic memory is enabled
	[Parameter(ParameterSetName = 'Add')][ValidateScript({ ($_ -ge 32MB) -and ($_ -le 12TB) })]
	[uint64]$MemoryMinimumBytes,
	# VM - maximum bytes of memory when dynamic memory is enabled
	[Parameter(ParameterSetName = 'Add')][ValidateScript({ ($_ -ge 32MB) -and ($_ -le 12TB) })]
	[uint64]$MemoryMaximumBytes,
	# VM - startup priority value for clustered VMs, 0 = no auto start, 1000 = low, 2000 = medium, 3000 = high
	[Parameter(ParameterSetName = 'Add')][ValidateSet(0, 1000, 2000, 3000)]
	[uint32]$ClusterPriority,
	[Parameter(ParameterSetName = 'Add')]
	[switch]$PreserveVMHardDiskDrives,
	[Parameter(ParameterSetName = 'Add')]
	[switch]$PreserveVMNetworkAdapters,
	# VMHardDiskDrive - bytes for VHD size
	[Parameter(ParameterSetName = 'AddVMHardDiskDrive')][ValidateScript({ ($_ -ge 3MB) -and ($_ -le 64TB) })]
	[uint64]$SizeBytes,
	# VMHardDiskDrive - LUN number for VHD on SCSI controller
	[Parameter(ParameterSetName = 'AddVMHardDiskDrive')][ValidateRange(0, 63)]
	[uint64]$ControllerLocation,
	# VMHardDiskDrive - ID of SCSI controller
	[Parameter(ParameterSetName = 'AddVMHardDiskDrive')][ValidateRange(0, 3)]
	[uint64]$ControllerNumber,
	# VMNetworkAdapter - name of VM switch to connect VM to, set to "Remove" to remove NIC
	[Parameter(ParameterSetName = 'AddVMNetworkAdapter')]
	[string]$SwitchName,
	# VMNetworkAdapter - VLAN ID for network adapter
	[Parameter(ParameterSetName = 'AddVMNetworkAdapter')][ValidateRange(0, 4094)]
	[uint16]$VLAN,
	# VMNetworkAdapter - MAC address for network adapter
	[Parameter(ParameterSetName = 'AddVMNetworkAdapter')]
	[string]$MacAddress,
	# VMNetworkAdapter - MAC address prefix for network adapter, paired with the IP address to create a MAC address
	[Parameter(ParameterSetName = 'AddVMNetworkAdapter')][ValidateScript({ ($_.Length -eq 4) -and ($_ -match '^[0-9A-F]+$') })]
	[string]$MacAddressPrefix,
	# VMNetworkAdapter - IP address of network adapter
	[Parameter(ParameterSetName = 'AddVMNetworkAdapter')]
	[string]$IPAddress,
	# VMNetworkAdapter - name of network adapter
	[Parameter(ParameterSetName = 'AddVMNetworkAdapter')]
	[string]$DhcpServer,
	# VMNetworkAdapter - name of network adapter
	[Parameter(ParameterSetName = 'AddVMNetworkAdapter')]
	[string]$DhcpScope,
	# OS Deployment - OSD method
	[Parameter(Mandatory = $true, ParameterSetName = 'AddOSD')][ValidateSet('ISO', 'SCCM', 'WDS')]
	[string]$DeploymentMethod,
	# OS Deployment - OSD path (ISO path, OU path, etc.)
	[Parameter(ParameterSetName = 'AddOSD')]
	[string]$DeploymentPath,
	# OS Deployment - OSD server (WDS server, SCCM server, etc.)
	[Parameter(ParameterSetName = 'AddOSD')]
	[string]$DeploymentServer,
	# OS Deployment - domain for SCCM
	[Parameter(ParameterSetName = 'AddOSD')]
	[string]$DeploymentDomain,
	# OS Deployment - deployment collection for SCCM
	[Parameter(ParameterSetName = 'AddOSD')]
	[string]$DeploymentCollection,
	# OS Deployment - maintenance collection for SCCM
	[Parameter(ParameterSetName = 'AddOSD')]
	[string]$MaintenanceCollection,
	[Parameter(DontShow)]
	[string]$JsonSortProperty = 'VMName'
)

Begin {
	# verify JSON file
	If ($Add -and -not (Test-Path -Path $Json)) {
		Try {
			$null = New-Item -ItemType 'File' -Path $Json -ErrorAction Stop
		}
		Catch {
			Write-Verbose "`nERROR: could not create configuration file: '$Json'"
			Throw $_
		}
	}

	# import JSON data
	Try {
		[array]$JsonData = Get-Content -Path $Json | ConvertFrom-Json
	}
	Catch {
		Write-Verbose "`nERROR: could not read configuration file: '$Json'"
		Throw $_
	}

	Function Update-JsonFile {
		Param(
			[Parameter()][AllowNull()]
			[object[]]$JsonData,
			[string]$JsonPath,
			[switch]$Replaced,
			[string]$Subject,
			[string]$VMName
		)

		# filter and sort objects in JsonData array
		$JsonData = $JsonData | Where-Object -Property $JsonSortProperty | Sort-Object -Property $JsonSortProperty

		# convert JsonData to JSON then update file
		Try {
			$JsonData | ConvertTo-Json -Depth 100 | Set-Content -Path $JsonPath
		}
		Catch {
			Write-Output "`nERROR: could not update configuration file: '$JsonPath'"
			Return $_
		}

		# report on changes
		If ($Replaced) {
			Write-Output "`nReplaced $Subject in configuration file: '$JsonPath'"
		}
		Else {
			Write-Output "`nAdded $Subject to configuration file: '$JsonPath'"
		}
		$JsonItem = $JsonData | Where-Object { $_.VMName -eq $VMName }
		$JsonItem | ConvertTo-Json -Depth 100 | ConvertFrom-Json

		# if verbose...
		If ($VerbosePreference) {
			# ...display full file
			Write-Output "`nDisplaying full configuration file: '$Json'"
			$JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json
		}
	}
}

Process {
	# evaluate parameters
	switch ($true) {
		$Clear {
			# remove configuration file
			Write-Warning -Message "Continuing will remove the configuration file '$Json'"
			If (Test-Path -Path $Json) {
				Try {
					Remove-Item -Path $Json -Force
					Write-Output "`nCleared configuration file: '$Json'"
				}
				Catch {
					Write-Output "`nERROR: could not clear configuration file: '$Json'"
				}
			}
		}
		$Remove {
			# remove matching entries from object
			Try {
				$JsonData = $JsonData | Where-Object { $_.VMName -ne $VMName }
				If ($null -eq $JsonData) {
					[string]::Empty | Set-Content -Path $Json
					Write-Output "`nRemoved '$VMName' from configuration file: '$Json'"
				}
				Else {
					$JsonData | ConvertTo-Json | Set-Content -Path $Json
					Write-Output "`nRemoved '$VMName' from configuration file: '$Json'"
				}
				If ($VerbosePreference) {
					$JsonData
				}
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file: '$Json'"
			}
		}
		$RemoveVMHardDiskDrive {
			# remove matching entries from object
			Try {
				# get VM entry
				$VM = $JsonData | Where-Object { $_.VMName -eq $VMName }
				# get VMHardDiskDrive entry for VM where Path does not match
				$VMHardDiskDrive = $VM.VMHardDiskDrive | Where-Object { $_.Path -ne $Path }
				# update VM entry
				$VM.VMHardDiskDrive = $VMHardDiskDrive
				# remove old VM entry
				$JsonData = $JsonData | Where-Object { $_.VMName -ne $VMName }
				# add updated VM entry
				$JsonData += $VM
				If ($null -eq $JsonData) {
					[string]::Empty | Set-Content -Path $Json
					Write-Output "`nRemoved '$Path' from '$VMName' in configuration file: '$Json'"
				}
				Else {
					$JsonData | ConvertTo-Json | Set-Content -Path $Json
					Write-Output "`nRemoved '$Path' from '$VMName' in configuration file: '$Json'"
				}
				If ($VerbosePreference) {
					$JsonData
				}
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file: '$Json'"
			}
		}
		$RemoveVMNetworkAdapter {
			# remove matching entries from object
			Try {
				# get entry for VM
				$VMData = $JsonData | Where-Object { $_.VMName -eq $VMName }
				# get entry for VHDs on VM where path does not match
				$VHDData = $VMData.VMHardDiskDrive | Where-Object { $_.Path -ne $Path }
				# 
				$VMData.VMHardDiskDrive = $VHDData

				$JsonData = $JsonData | Where-Object { $_.VMName -ne $VMName }
				If ($null -eq $JsonData) {
					[string]::Empty | Set-Content -Path $Json
					Write-Output "`nRemoved '$VMName' from configuration file: '$Json'"
				}
				Else {
					$JsonData | ConvertTo-Json | Set-Content -Path $Json
					Write-Output "`nRemoved '$VMName' from configuration file: '$Json'"
				}
				If ($VerbosePreference) {
					$JsonData
				}
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file: '$Json'"
			}
		}
		$Add {
			# get any existing VM object from JsonData array
			$VM = $JsonData | Where-Object { $_.VMName -eq $VMName }
			# check for existing VM object
			If ($VM) {
				Write-Warning -Message 'JSON file contains VM with provided VMName. This will overwrite the existing entry.' -WarningAction Inquire
				# declare replace
				$Replaced = $true
				# if preserve VMHardDiskDrive requested...
				If ($PreserveVMHardDiskDrives) {
					If ($VM.VMHardDiskDrives) {
						[array]$VMHardDiskDrives = $VM.VMHardDiskDrives
					}
					Else {
						Write-Warning -Message 'PreserveVMHardDiskDrives requested but no VMHardDiskDrives found' -WarningAction Inquire
					}
				}
				# if preserve VMNetworkAdapter requested...
				If ($PreserveVMNetworkAdapters) {
					# 
					If ($VM.VMNetworkAdapters) {
						[array]$VMNetworkAdapters = $VM.VMNetworkAdapters
					}
					Else {
						Write-Warning -Message 'PreserveVMNetworkAdapters requested but no VMNetworkAdapters found.' -WarningAction Inquire
					}
				}
				# filter out VM objects with matching VMName
				$JsonData = $JsonData | Where-Object { $_.VMName -ne $VMName }
			}
			# create VM hashtable with required parameters
			$VMParams = [ordered]@{
				VMName = $VMName
				Path   = $Path
			}
			# define VM optional parameters
			$VMOptionalParams = @(
				'ProcessorCount'
				'MemoryStartupBytes'
				'MemoryMinimumBytes'
				'MemoryMaximumBytes'
				'ClusterPriority'
			)
			# check optional parameters
			ForEach ($Parameter in $VMOptionalParams) {
				# if optional parameter is defined...
				If ($PSBoundParameters[$Parameter]) {
					# ...add to hashtable
					$VMParams[$Parameter] = $PSBoundParameters[$Parameter]
				}
			}
			# if VMHardDiskDrives were preserved...
			If ($VMHardDiskDrives) {
				# ...add to hashtable
				$VMParams['VMHardDiskDrives'] = $VMHardDiskDrives
			}
			# if VMNetworkAdapters were preserved...
			If ($VMNetworkAdapters) {
				# ...add to hashtable
				$VMParams['VMNetworkAdapters'] = $VMNetworkAdapters
			}
			# create VM object from parameters
			$VM = [pscustomobject]$VMParams
			# if JsonData is an array...
			If ($JsonData -is [System.Object[]]) {
				# ...add VM to array
				$JsonData += $VM
			}
			# if JsonData is not an array...
			Else {
				# ...create new array containing VM
				$JsonData = @($VM)
			}
			# update JSON file
			Update-JsonFile -JsonData $JsonData -JsonPath $Json -Replaced:$Replaced -Subject "VM '$VMName'" -VMName $VMName
		}
		$AddVMHardDiskDrive {
			# get and validate VM object from JsonData array
			$VM = $JsonData | Where-Object { $_.VMName -eq $VMName }
			If ($null -eq $VM) {
				Write-Output "`nERROR: could not locate '$VMName' in configuration file: '$Json'"
			}
			# if VM object is missing the VMHardDiskDrive property...
			If ($null -eq $VM.VMHardDiskDrives) {
				# ...add VMHardDiskDrive property as an array if missing
				Add-Member -InputObject $VM -MemberType 'NoteProperty' -Name 'VMHardDiskDrives' -Value @()
			}
			# check for existing VMHardDiskDrive object
			If ($VM.VMHardDiskDrives | Where-Object { $_.Path -eq $Path }) {
				Write-Warning -Message 'JSON file contains VMHardDiskDrive with provided VMName and Path. This will overwrite the existing entry.' -WarningAction Inquire
				# declare replace
				$Replaced = $true
				# filter out VMHardDiskDrive objects with matching Path
				$VM.VMHardDiskDrives = $VM.VMHardDiskDrives | Where-Object { $_.Path -ne $Path }
			}
			# create VMHardDiskDrive hashtable with required parameters
			$VMHardDiskDriveParams = @{
				Path      = $Path
				SizeBytes = $SizeBytes
			}
			# define VMNetworkAdapter optional parameters
			$VMHardDiskDriveOptionalParams = @(
				'ControllerLocation'
				'ControllerNumber'
			)
			# check optional parameters
			ForEach ($Parameter in $VMHardDiskDriveOptionalParams) {
				# if optional parameter is defined...
				If ($PSBoundParameters[$Parameter]) {
					# ...add to hashtable
					$VMHardDiskDriveParams[$Parameter] = $PSBoundParameters[$Parameter]
				}
			}
			# create VMHardDiskDrive object from parameters
			$VMHardDiskDrive = [pscustomobject]$VMHardDiskDriveParams
			# if VMHardDiskDrives is an array...
			If ($VM.VMHardDiskDrives -is [System.Object[]]) {
				# ...add VMHardDiskDrive to array
				$VM.VMHardDiskDrives += $VMHardDiskDrive
			}
			# if VMHardDiskDrives is not an array...
			Else {
				# ...create new array containing VMHardDiskDrive
				$VM.VMHardDiskDrives = @($VMHardDiskDrive)
			}
			# remove existing VM object from JsonData array
			$JsonData = $JsonData | Where-Object { $_.VMName -ne $VMName }
			# add updated VM object to JsonData array
			$JsonData += $VM
			# update JSON file
			Update-JsonFile -JsonData $JsonData -JsonPath $Json -Replaced:$Replaced -Subject "VMHardDiskDrive '$Path' on VM '$VMName'" -VMName $VMName
		}
		$AddVMNetworkAdapter {
			# get and validate VM object from JsonData array
			$VM = $JsonData | Where-Object { $_.VMName -eq $VMName }
			If ($null -eq $VM) {
				Write-Output "`nERROR: could not locate '$VMName' in configuration file: '$Json'"
			}
			# if VM object is missing the VMNetworkAdapter property...
			If ($null -eq $VM.VMNetworkAdapters) {
				# ...add VMNetworkAdapter property as an array if missing
				Add-Member -InputObject $VM -MemberType 'NoteProperty' -Name 'VMNetworkAdapters' -Value @()
			}
			# check for existing VMNetworkAdapter object
			If ($VM.VMNetworkAdapters | Where-Object { $_.NetworkAdapterName -eq $NetworkAdapterName }) {
				Write-Warning -Message 'JSON file contains VMNetworkAdapter with provided VMName and NetworkAdapterName. This will overwrite the existing entry.' -WarningAction Inquire
				# declare replace
				$Replaced = $true
				# filter out VMNetworkAdapter objects with matching NetworkAdapterName
				$VM.VMNetworkAdapters = $VM.VMNetworkAdapters | Where-Object { $_.NetworkAdapterName -ne $NetworkAdapterName }
			}
			# create VMNetworkAdapter hashtable with required parameters
			$VMNetworkAdapterParams = @{
				NetworkAdapterName = $NetworkAdapterName
			}
			# define VMNetworkAdapter optional parameters
			$VMNetworkAdapterOptionalParams = @(
				'SwitchName'
				'VLAN'
				'MacAddress'
				'MacAddressPrefix'
				'IPAddress'
				'DhcpServer'
				'DhcpScope'
			)
			# check VMNetworkAdapter optional parameters
			ForEach ($Parameter in $VMNetworkAdapterOptionalParams) {
				# if VMNetworkAdapter optional parameter is defined...
				If ($PSBoundParameters[$Parameter]) {
					# ...add to hashtable
					$VMNetworkAdapterParams[$Parameter] = $PSBoundParameters[$Parameter]
				}
			}
			# create VMNetworkAdapter object from parameters
			$VMNetworkAdapter = [pscustomobject]$VMNetworkAdapterParams
			# if VMNetworkAdapters is an array...
			If ($VM.VMNetworkAdapters -is [System.Object[]]) {
				# ...add VMNetworkAdapter to array
				$VM.VMNetworkAdapters += $VMNetworkAdapter
			}
			# if VMNetworkAdapters is not an array...
			Else {
				# ...create new array containing VMNetworkAdapter
				$VM.VMNetworkAdapters = @($VMNetworkAdapter)
			}
			# remove existing VM object from JsonData array
			$JsonData = $JsonData | Where-Object { $_.VMName -ne $VMName }
			# add updated VM object to JsonData array
			$JsonData += $VM
			# update JSON file
			Update-JsonFile -JsonData $JsonData -JsonPath $Json -Replaced:$Replaced -Subject "VMNetworkAdapter '$NetworkAdapterName' on VM '$VMName'" -VMName $VMName
		}
		Default {
			Write-Output "`nDisplaying configuration file: '$Json'"
			$JsonData
		}
	}
}

End {
	# if importing...
	If ($Import) {
		# ...stop transcript
		Stop-Transcript
	}
}
