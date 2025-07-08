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
	[Parameter(Mandatory = $True, Position = 1, ParameterSetName = 'AddOSD')]
	[switch]$AddOSD,
	[Parameter(Mandatory = $True, Position = 1, ParameterSetName = 'RemoveOSD')]
	[switch]$RemoveOSD,
	# All - name of VM
	[Parameter(Mandatory = $False, Position = 1, ParameterSetName = 'Default')]
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
	[Parameter(Mandatory = $True, Position = 3, ParameterSetName = 'AddVMNetworkAdapter')]
	[Parameter(Mandatory = $True, Position = 3, ParameterSetName = 'RemoveVMNetworkAdapter')]
	[string]$NetworkAdapterName,
	# OS Deployment - OSD method
	[Parameter(Mandatory = $true, Position = 3, ParameterSetName = 'AddOSD')]
	[ValidateSet('ISO', 'SCCM', 'WDS')]
	[string]$DeploymentMethod,
	# VMHardDiskDrive - bytes for VHD size
	[Parameter(Mandatory = $True, Position = 4, ParameterSetName = 'AddVMHardDiskDrive')]
	[ValidateScript({ ($_ -ge 3MB) -and ($_ -le 64TB) })]
	[uint64]$SizeBytes,
	# VM - name of virtual machine host
	[Parameter(Position = 4, ParameterSetName = 'Add')]
	[string]$ComputerName,
	# VM - count of virtual processors
	[Parameter(Position = 5, ParameterSetName = 'Add')]
	[ValidateRange(1, 256)]
	[uint16]$ProcessorCount,
	# VM - bytes of memory on startup
	[Parameter(Position = 6, ParameterSetName = 'Add')]
	[ValidateScript({ ($_ -ge 32MB) -and ($_ -le 12TB) })]
	[uint64]$MemoryStartupBytes,
	# VM - minimum bytes of memory when dynamic memory is enabled
	[Parameter(Position = 7, ParameterSetName = 'Add')]
	[ValidateScript({ ($_ -ge 32MB) -and ($_ -le 12TB) })]
	[uint64]$MemoryMinimumBytes,
	# VM - maximum bytes of memory when dynamic memory is enabled
	[Parameter(Position = 8, ParameterSetName = 'Add')]
	[ValidateScript({ ($_ -ge 32MB) -and ($_ -le 12TB) })]
	[uint64]$MemoryMaximumBytes,
	# VM - create default VMHardDiskDrive
	[Parameter(Position = 9, ParameterSetName = 'Add')]
	[switch]$CreateDefaultVMHardDiskDrive,
	# VMHardDiskDrive - ID of SCSI controller
	[Parameter(Position = 5, ParameterSetName = 'AddVMHardDiskDrive')]
	[ValidateRange(0, 3)]
	[uint64]$ControllerNumber,
	# VMHardDiskDrive - LUN number for VHD on SCSI controller
	[Parameter(Position = 6, ParameterSetName = 'AddVMHardDiskDrive')]
	[ValidateRange(0, 63)]
	[uint64]$ControllerLocation,
	# VM - create default VMNetworkAdapter
	[Parameter(Position = 10, ParameterSetName = 'Add')]
	[switch]$CreateDefaultVMNetworkAdapter,
	# VM - name of connected VM switch for default network adapter
	# VMNetworkAdapter - name of connected VM switch for network adapter
	[Parameter(Position = 11, ParameterSetName = 'Add')]
	[Parameter(Position = 4, ParameterSetName = 'AddVMNetworkAdapter')]
	[string]$SwitchName,
	# VM - VLAN ID for default network adapter
	# VMNetworkAdapter - VLAN ID for network adapter
	[Parameter(Position = 12, ParameterSetName = 'Add')]
	[Parameter(Position = 5, ParameterSetName = 'AddVMNetworkAdapter')]
	[ValidateSet('Untagged','Access', 'Trunk', 'Isolation')]
	[string]$VlanMode,
	# VM - VLAN ID for default network adapter
	# VMNetworkAdapter - VLAN ID for network adapter
	[Parameter(Position = 13, ParameterSetName = 'Add')]
	[Parameter(Position = 6, ParameterSetName = 'AddVMNetworkAdapter')]
	[ValidateRange(1, 4094)]
	[uint16]$VlanId,
	# VM - VLAN ID for default network adapter
	# VMNetworkAdapter - VLAN ID for network adapter
	[Parameter(Position = 14, ParameterSetName = 'Add')]
	[Parameter(Position = 7, ParameterSetName = 'AddVMNetworkAdapter')]
	[string]$VlanIdList,
	# VM - name of DHCP server for default network adapter
	# VMNetworkAdapter - name of DHCP server for network adapter
	[Parameter(Position = 15, ParameterSetName = 'Add')]
	[Parameter(Position = 8, ParameterSetName = 'AddVMNetworkAdapter')]
	[string]$DhcpServer,
	# VM - name of DHCP scope on DHCP server for default network adapter
	# VMNetworkAdapter - name of DHCP scope on DHCP server for network adapter
	[Parameter(Position = 16, ParameterSetName = 'Add')]
	[Parameter(Position = 9, ParameterSetName = 'AddVMNetworkAdapter')]
	[string]$DhcpScope,
	# VM - IP address for default network adapter, paired with the MAC address prefix to create a MAC address
	# VMNetworkAdapter - IP address for network adapter, paired with the MAC address prefix to create a MAC address
	[Parameter(Position = 17, ParameterSetName = 'Add')]
	[Parameter(Position = 10, ParameterSetName = 'AddVMNetworkAdapter')]
	[string]$IPAddress,
	# VM - MAC address for default network adapter
	# VMNetworkAdapter - MAC address for network adapter
	[Parameter(Position = 18, ParameterSetName = 'Add')]
	[Parameter(Position = 11, ParameterSetName = 'AddVMNetworkAdapter')]
	[string]$MacAddress,
	# VM - MAC address prefix for default network adapter, paired with the IP address to create a MAC address
	# VMNetworkAdapter - MAC address prefix for network adapter, paired with the IP address to create a MAC address
	[Parameter(Position = 19, ParameterSetName = 'Add')]
	[Parameter(Position = 12, ParameterSetName = 'AddVMNetworkAdapter')]
	[ValidateScript({ ($_.Length -eq 4) -and ($_ -match '^[0-9A-F]+$') })]
	[string]$MacAddressPrefix,
	# VM - allow default network adapter to change MAC address on outgoing packets
	# VMNetworkAdapter - allow network adapter to change MAC address on outgoing packets
	[Parameter(Position = 20, ParameterSetName = 'Add')]
	[Parameter(Position = 13, ParameterSetName = 'AddVMNetworkAdapter')]
	[ValidateSet("On","Off")]
	[string]$MacAddressSpoofing,
	# VM - allow default network adapter to be teamed with other network adapters on the same virtual switch
	# VMNetworkAdapter - allow network adapter to be teamed with other network adapters on the same virtual switch
	[Parameter(Position = 21, ParameterSetName = 'Add')]
	[Parameter(Position = 14, ParameterSetName = 'AddVMNetworkAdapter')]
	[ValidateSet("On","Off")]
	[string]$AllowTeaming,
	# OS Deployment - multiple - server name for WDS or SCCM
	[Parameter(Position = 4, ParameterSetName = 'AddOSD')]
	[string]$DeploymentServer,
	# OS Deployment - based upon Deployment Method
	#  ISO	: literal path to ISO file on hypervisor
	#  VHD	: literal path to VHD file on hypervisor
	#  SCCM	: distinguished name of OU where VM will be created
	[Parameter(Position = 5, ParameterSetName = 'AddOSD')]
	[string]$DeploymentPath,
	# OS Deployment - SCCM - NetBIOS name of Windows domain
	[Parameter(Position = 6, ParameterSetName = 'AddOSD')]
	[string]$DeploymentDomain,
	# OS Deployment - SCCM - deployment collection
	[Parameter(Position = 7, ParameterSetName = 'AddOSD')]
	[string]$DeploymentCollection,
	# OS Deployment - SCCM - maintenance window collection
	[Parameter(Position = 8, ParameterSetName = 'AddOSD')]
	[string]$MaintenanceCollection,
	# OS Deployment - VHD - literal path to unattend XML file on hypervisor
	[Parameter(Position = 9, ParameterSetName = 'AddOSD')]
	[string]$UnattendFile,
	# OS Deployment - VHD - FQDN of domain for VM to join
	[Parameter(Position = 10, ParameterSetName = 'AddOSD')]
	[string]$DomainName,
	# OS Deployment - VHD - FQDN of OU where VM will be created
	[Parameter(Position = 11, ParameterSetName = 'AddOSD')]
	[string]$OrganizationalUnit,
	# VM - optional affinity rules for clustered VMs
	[Parameter(Position = 22, ParameterSetName = 'Add')]
	[string[]]$ClusterAffinityRules,
	# VM - startup priority value for clustered VMs, 0 = no auto start, 1000 = low, 2000 = medium, 3000 = high
	[Parameter(Position = 22, ParameterSetName = 'Add')]
	[ValidateSet(0, 1000, 2000, 3000)]
	[uint32]$ClusterPriority,
	# VM - define VM generation; 1 = generation 1 VM, 2 = generation 2 VM
	[Parameter(Position = 21, ParameterSetName = 'Add')]
	[ValidateSet(1, 2)]
	[uint16]$Generation,
	# VM - enable the virtual TPM for the VM (warning: virtual TPM locked to host without additional work)
	[Parameter(Position = 22, ParameterSetName = 'Add')]
	[switch]$EnableVMTPM,
	# VM - do not add VM to cluster if created a hypervisor joined to a cluster
	[Parameter(Position = 26, ParameterSetName = 'Add')]
	[switch]$DoNotCluster,
	# VM - preserve existing parameters when editing a VM
	[Parameter(ParameterSetName = 'Add')]
	[switch]$PreserveVMParameters,
	[Parameter()]
	[switch]$PassThru,
	[Parameter(DontShow)]
	[string[]]$ExcludedParametersDefault = @(
		'Json'
		'VMName'
		'CreateDefaultVMHardDiskDrive'
		'CreateDefaultVMNetworkAdapter'
		'PreserveVMParameters'
	),
	[Parameter(DontShow)]
	[string]$JsonKeyParameter = 'VMName'
)

Begin {
	Function Get-ParametersFromCommand {
		Param(
			[string]$CommandName = $PSCommandPath,
			[string]$ParameterSetName,
			[switch]$ExcludeParameterSetName,
			[string[]]$ExcludeParameters,
			[string[]]$ExcludeParameterSets
		)

		# verify command
		Try {
			$Command = Get-Command -Name $CommandName -ErrorAction ([System.Management.Automation.ActionPreference]::Stop)
		}
		Catch {
			Return $_
		}

		# define lists
		$ExcludedParametersList = [System.Collections.Generic.List[string]]::new()

		# retrieve parameters for script
		$ParametersFromScript = $Command.Parameters.Values

		# filter parameters to parameter set
		If ($ParameterSetName) {
			# filter parameters to parameter set
			$ParametersFromScript = $ParametersFromScript.Where({ $_.Attributes.ParameterSetName -eq $ParameterSetName })
			# filter out parameter set name
			If ($ExcludeParameterSetName) {
				$ExcludedParametersList.Add($ParameterSetName)
			}
		}

		# define parameters excluded by parameter set
		ForEach ($ExcludedParameterSet in $ExcludeParameterSets) {
			# process each parameter in the excluded parameter set
			ForEach ($ExcludedParameter in ($ParametersFromScript.Where({ $_.Attributes.ParameterSetName -eq $ExcludedParameterSet }).Name) ) {
				$ExcludedParametersList.Add($ExcludedParameter)
			}
		}

		# define parameters excluded
		ForEach ($ExcludedParameter in $ExcludeParameters) {
			$ExcludedParametersList.Add($ExcludedParameter)
		}

		# define parameters excluded by default
		ForEach ($ExcludedParameter in $ExcludedParametersDefault) {
			$ExcludedParametersList.Add($ExcludedParameter)
		}

		# filter out excluded parameters
		If ($ExcludedParametersList.Count -gt 0) {
			$ParametersFromScript = $ParametersFromScript.Where({ $_.Name -notin $ExcludedParametersList })
		}

		# get parameters with position
		$ParametersWithPosition = $ParametersFromScript.Where({ $_.Attributes.Position -ge 0 })

		# get parameters with position
		$ParametersWithOutPosition = $ParametersFromScript.Where({ $_.Attributes.Position -lt 0 })

		# define lists
		$ParametersList = [System.Collections.Generic.List[string]]::new()

		# process each parameter for script
		ForEach ($Parameter in $ParametersWithPosition | Sort-Object -Property { $_.Attributes.Position } ) {
			# if parameter has a name and name not in ExcludeParameters or ExcludedParametersDefault...
			If ($null -ne $Parameter.Name) {
				# add parameter name to list
				$ParametersList.Add($Parameter.Name)
			}
		}

		# process each parameter for script
		ForEach ($Parameter in $ParametersWithOutPosition | Sort-Object -Property { $_.Name } ) {
			# if parameter has a name and name not in ExcludeParameters or ExcludedParametersDefault...
			If ($null -ne $Parameter.Name) {
				# add parameter name to list
				$ParametersList.Add($Parameter.Name)
			}
		}

		# return list
		Return $ParametersList
	}

	Function Add-NestedJsonKeyValuePair {
		Param(
			[hashtable]$BoundParameters,
			[string]$ParameterSetName,
			[string]$JsonPathSeparator = '\',
			[string]$JsonPathToKey,
			[string]$JsonNestedKey,
			[string]$JsonNestedValue,
			[object]$JsonNestedParams = [ordered]@{}
		)

		# check path to key
		If ($JsonPathToKey -eq $JsonKey) {
			# report pending action
			Write-Host "Adding '$JsonNestedKey' of '$JsonNestedValue' to '$JsonKey' in '$Json'..."
			# define initial key
			$JsonCurrentKey = $JsonPathToKey
			# define initial object
			$JsonCurrentObject = $JsonData
		}
		Else {
			# report pending action
			Write-Host "Adding '$JsonNestedKey' of '$JsonNestedValue' to '$JsonPathToKey' on '$JsonKey'..."
			# define initial key
			$JsonCurrentKey = $JsonPathToKey
			# define initial object
			$JsonCurrentObject = $JsonData.$JsonKey
		}

		# retrieve nested objects using keys in path
		While ($JsonPathSeparator -in [char[]]$JsonPathToKey) {
			# split keys in path into current and remaining keys in path
			$JsonCurrentKey, $JsonPathToKey = $JsonPathToKey.Split($JsonPathSeparator, 2)
			# if current key is not a member of current object...
			If ($null -eq (Get-Member -InputObject $JsonCurrentObject -Name $JsonCurrentKey)) {
				# ...add current key as member of current object
				Try {
					Add-Member -InputObject $JsonCurrentObject -Name $JsonCurrentKey -Value ([PSCustomObject]@{}) -MemberType NoteProperty
				}
				Catch {
					Write-Host "`nERROR: could not add intermediate object in path to '$JsonPathToKey' property on '$JsonKey' in configuration file: '$Json'"
					Return $_
				}
			}
			# move down to next object in path
			$JsonCurrentObject = $JsonCurrentObject.$JsonCurrentKey
		}

		# create list for nested objects
		$JsonNestedObjects = [System.Collections.Generic.List[object]]::new()

		# for each existing object in current object...
		ForEach ($ExistingObject in $JsonCurrentObject.$JsonCurrentKey) {
			# if existing object has nested key value pair that matches parameters...
			If ($ExistingObject.$JsonNestedKey -eq $JsonNestedValue ) {
				# ...warning for replace
				Write-Warning -Message "found object in '$JsonPathToKey' with provided value for '$JsonNestedKey'; continue to replace the object" -WarningAction Inquire
			}
			# if existing object has nested key value pair that does not match parameters...
			Else {
				# ...add to list
				$JsonNestedObjects.Add($ExistingObject)
			}
		}

		# define required parameters for Get-ParametersFromCommand
		$GetParametersFromCommand = @{
			ExcludeParameters       = $JsonNestedParams.Keys
			ExcludeParameterSetName = $true
		}

		# define optional parameters for Get-ParametersFromCommand
		If ($PSBoundParameters['ParameterSetName']) {
			$GetParametersFromCommand['ParameterSetName'] = $ParameterSetName
		}

		# get parameters
		Try {
			$Parameters = Get-ParametersFromCommand @GetParametersFromCommand
		}
		Catch {
			Return $_
		}

		# process each parameter in parameter set
		ForEach ($Parameter in $Parameters) {
			# if optional parameter is defined...
			If ($BoundParameters.ContainsKey($Parameter)) {
				# ...and is a switch paramter
				If ($BoundParameters[$Parameter] -is [System.Management.Automation.SwitchParameter]) {
					# ...add to provided dictionary after converting to boolean
					$JsonNestedParams[$Parameter] = $BoundParameters[$Parameter].ToBool()
				}
				# ...and is not a switch paramter
				Else {
					# ...add to provided dictionary as-is
					$JsonNestedParams[$Parameter] = $BoundParameters[$Parameter]
				}
			}
		}

		# create nested object from parameters
		$JsonNestedObjects.Add([pscustomobject]$JsonNestedParams)

		# sort nested objects
		If ($JsonNestedObjects.Count -gt 1) {
			$JsonNestedObjects = $JsonNestedObjects | Sort-Object -Property $JsonNestedKey
		}

		# if current key is not a member of current object...
		If ($null -eq (Get-Member -InputObject $JsonCurrentObject -Name $JsonCurrentKey)) {
			# ...add current key as member of current object with nested objects as value
			Add-Member -InputObject $JsonCurrentObject -Name $JsonCurrentKey -Value $JsonNestedObjects -MemberType NoteProperty
		}
		# if current key is already a member of current object...
		Else {
			# ...set current key to nested objects sorted by nested key
			$JsonCurrentObject.$JsonCurrentKey = $JsonNestedObjects
		}
	}

	Function Remove-NestedJsonKeyValuePair {
		Param (
			[string]$JsonPathSeparator = '\',
			[string]$JsonPathToKey,
			[string]$JsonNestedKey,
			[string]$JsonNestedValue
		)

		# report pending action
		Write-Host "Removing '$JsonNestedKey' of '$JsonNestedValue' from '$JsonPathToKey' on '$JsonKey'..."

		# define initial object and key
		$JsonCurrentKey = $JsonPathToKey
		$JsonCurrentObject = $JsonData.$JsonKey

		# retrieve nested objects using keys in path
		While ($JsonPathSeparator -in [char[]]$JsonPathToKey) {
			# split keys in path into current and remaining keys in path
			$JsonCurrentKey, $JsonPathToKey = $JsonPathToKey.Split($JsonPathSeparator, 2)
			# if current key is not a member of current object...
			If ($null -eq (Get-Member -InputObject $JsonCurrentObject -Name $JsonCurrentKey)) {
				Write-Host "`nERROR: could not find intermediate object in path to '$JsonPathToKey' property on '$JsonKey' in configuration file: '$Json'"
				Return
			}
			# drill down in object
			$JsonCurrentObject = $JsonCurrentObject.$JsonCurrentKey
		}

		# if current object does not exist...
		If ($null -eq $JsonCurrentObject.$JsonCurrentKey) {
			Write-Host "`nERROR: could not find '$JsonPathToKey' property on '$JsonKey' in configuration file: '$Json'"
			Return
		}

		# if object does not exist on item with matching property and value...
		If ($JsonCurrentObject.$JsonCurrentKey.Where({ $_.$JsonNestedKey -eq $JsonNestedValue }).Count -eq 0) {
			Write-Host "`nERROR: could not find object in '$JsonPathToKey' with the provided '$JsonNestedKey' on '$JsonKey' in configuration file: '$Json'"
			Return
		}

		# create list for nested objects
		$JsonNestedObjects = [System.Collections.Generic.List[object]]::new()

		# for each existing object in current object...
		ForEach ($ExistingObject in $JsonCurrentObject.$JsonCurrentKey) {
			# if existing object has nested key value pair that does not match parameters...
			If ($ExistingObject.$JsonNestedKey -ne $JsonNestedValue ) {
				# ...add to list
				$JsonNestedObjects.Add($ExistingObject)
			}
		}

		# sort nested objects
		If ($JsonNestedObjects.Count -gt 1) {
			$JsonNestedObjects = $JsonNestedObjects | Sort-Object -Property $JsonNestedKey
		}

		# if object is empty after removing the matching property and value...
		If ($JsonNestedObjects.Count -eq 0) {
			# ...remove object from item
			$JsonCurrentObject.PSObject.Properties.Remove($JsonCurrentKey)
		}
		# if object is not empty after removing the matching property and value...
		Else {
			# ...set object on item to remaining values
			$JsonCurrentObject.$JsonCurrentKey = $JsonNestedObjects
		}
	}

	Function Format-PSCustomObject {
		Param(
			[object]$InputObject
		)

		# create ordered dictionary
		$SortedProperties = [ordered]@{}

		# get members of input object and sort by name then add to sorted dictionary
		Get-Member -Type NoteProperty -InputObject $JsonData | Sort-Object Name | ForEach-Object {
			$SortedProperties[$_.Name] = $JsonData.$($_.Name)
		}

		# create new custom object and return
		Return [pscustomobject]$SortedProperties
	}

	Function Show-JsonFile {
		Param(
			[object]$JsonData
		)

		# if passthru...
		If ($PassThru) {
			# ...dump JSON data object to pipeline
			Return $JsonData
		}

		# define JsonKeyName from JsonKeyParameter property
		$JsonKeyName = (Get-Variable -Name $JsonKeyParameter -ValueOnly)
		# get JSON data object property
		$JsonKey = $JsonData.$JsonKeyName

		# if verbose...
		If ($VerbosePreference -eq 'Continue') {
			# ...display full file
			Write-Host "`nDisplaying full configuration file: '$Json'"
			$JsonData | ConvertTo-Json -Depth 100
		}
		# if not verbose...
		Else {
			# ...and JSON item exists (i.e. wasn't removed)...
			If ($null -ne $JsonKey) {
				# ...display JSON item if it exists (i.e. wasn't removed)
				Write-Host "`nDisplaying '$(Get-Variable -Name $JsonKeyParameter -ValueOnly)' entry in configuration file: '$Json'"
				$JsonKey | ConvertTo-Json -Depth 100
			}
			ElseIf ($PSCmdlet.ParameterSetName -eq 'Default') {
				Write-Warning "`nCould not locate'$(Get-Variable -Name $JsonKeyParameter -ValueOnly)' entry in configuration file: '$Json'"
			}
		}
	}

	Function Update-JsonFile {
		Param(
			[AllowNull()]
			[object]$JsonData
		)

		# clear file if JSON data is empty
		If ($null -eq $JsonData) {
			# if the JSON file found...
			If (Test-Path -Path $Json -PathType Leaf) {
				# ...try to remove it
				Try {
					Write-Host "`nRemoving configuration file: '$Json'"
					Remove-Item -Path $Json -Force
					Return
				}
				Catch {
					Write-Host "`nERROR: could not remove configuration file: '$Json'"
					Return $_
				}
			}
			# if the JSON file not found...
			Else {
				# ...report and return
				Write-Host "`nERROR: could not find configuration file: '$Json'"
				Return
			}
		}

		# filter and sort objects in JSON data
		$SortedProperties = [ordered]@{}
		Get-Member -Type NoteProperty -InputObject $JsonData | Sort-Object Name | ForEach-Object { $SortedProperties[$_.Name] = $JsonData.$($_.Name) }
		$JsonData = [pscustomobject]$SortedProperties

		# convert JsonData to JSON then update file
		Try {
			Write-Host "`nUpdating configuration file: '$Json'"
			$JsonData | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
		}
		Catch {
			Write-Host "`nERROR: could not update configuration file: '$Json'"
			Return $_
		}

		# report JSON data
		Show-JsonFile -JsonData $JsonData
	}
}

Process {
	# if JSON file was not found...
	If (-not (Test-Path -Path $Json)) {
		# if Add set...
		If ($Add) {
			# ...try to create the JSON file
			Try {
				$null = New-Item -ItemType 'File' -Path $Json -ErrorAction Stop
			}
			Catch {
				Write-Host "`nERROR: could not create configuration file: '$Json'"
				Return $_
			}
			# ...create empty JSON data object
			$JsonData = [PSCustomObject]@{}
		}
		# if Add not set...
		Else {
			# ...report and return
			Write-Host "`nERROR: could not find configuration file: '$Json'"
			Return
		}
	}
	Else {
		# import JSON data AS-IS; do not cast to array
		Try {
			$JsonData = Get-Content -Path $Json -ErrorAction Stop | ConvertFrom-Json
		}
		Catch {
			Write-Warning -Message "could not read configuration file: '$Json'"
			Return $_
		}
	}

	# retrieve current object
	If ($PSCmdlet.ParameterSetName -notin @('Clear', 'Default')) {
		# define JsonKeyName from JsonKeyParameter property
		$JsonKey = (Get-Variable -Name $JsonKeyParameter -ValueOnly)
		# retrieve JsonEntry from JsonData
		# $JsonEntry = $JsonData | Where-Object { $_.$JsonKeyParameter -eq $JsonKey }

		# if item not found in JSON data and not Adding...
		If ($null -eq $JsonData.$JsonKey -and -not $Add) {
			# ...report and return
			Write-Warning -Message "could not find entry '$JsonKey' in configuration file: '$Json'"
			Return
		}
	}

	# evaluate parameters
	switch ($true) {
		$Clear {
			# warning for clear
			Write-Warning -Message "continuing will remove the configuration file '$Json'" -WarningAction Inquire

			# update JSON file
			Update-JsonFile -JsonPath $Json -JsonData $null
		}
		$Remove {
			# report pending action
			Write-Host "Removing '$JsonKey'..."

			# remove property from JSON data
			$JsonData.PSObject.Properties.Remove($JsonKeyName)

			# update JSON file
			Update-JsonFile -JsonPath $Json -JsonData $JsonData
		}
		$RemoveOSD {
			# define parameters for function
			$RemoveNestedJsonKeyValuePair = @{
				# define keys between root key and nested key
				JsonPathToKey   = 'OSDeployment'
				# define key for finding existing key value pair
				JsonNestedKey   = 'DeploymentMethod'
				# define value for finding existing key value pair
				JsonNestedValue = $DeploymentMethod
			}

			# remove object from nested JSON key
			Try {
				Remove-NestedJsonKeyValuePair @RemoveNestedJsonKeyValuePair
			}
			Catch {
				Return $_
			}

			# update JSON file
			Update-JsonFile -JsonData $JsonData
		}
		$RemoveVMHardDiskDrive {
			# define parameters for function
			$RemoveNestedJsonKeyValuePair = @{
				# define keys between root key and nested key
				JsonPathToKey   = 'VMHardDiskDrives'
				# define key for finding existing key value pair
				JsonNestedKey   = 'Path'
				# define value for finding existing key value pair
				JsonNestedValue = $Path
			}

			# remove object from nested JSON key
			Try {
				Remove-NestedJsonKeyValuePair @RemoveNestedJsonKeyValuePair
			}
			Catch {
				Return $_
			}

			# update JSON file
			Update-JsonFile -JsonData $JsonData
		}
		$RemoveVMNetworkAdapter {
			# define parameters for function
			$RemoveNestedJsonKeyValuePair = @{
				# define keys between root key and nested key
				JsonPathToKey   = 'VMNetworkAdapters'
				# define key for finding existing key value pair
				JsonNestedKey   = 'NetworkAdapterName'
				# define value for finding existing key value pair
				JsonNestedValue = $NetworkAdapterName
			}
			# remove object from nested JSON key
			Try {
				Remove-NestedJsonKeyValuePair @RemoveNestedJsonKeyValuePair
			}
			Catch {
				Return $_
			}

			# update JSON file
			Update-JsonFile -JsonData $JsonData
		}
		$Add {
			# if JSON key found in JSON data...
			If ($null -eq $JsonData.$JsonKey) {
				# report pending action
				Write-Host "Adding '$JsonKey'..."
			}
			Else {
				# if preserve parameters requested...
				If ($PreserveVMParameters) {
					# warn and inquire about replacing
					Write-Warning -Message "found root key '$JsonKey' and PreserveVMParameters was set; continue to update the object." -WarningAction Inquire
					# define hashtable for properties on existing VM object
					$ExistingKeyValuePairs = @{}
					# populate hashtable with properties from existing VM object
					ForEach ($Property in $JsonData.$JsonKey.PSObject.Properties) {
						$ExistingKeyValuePairs[$Property.Name] = $Property.Value
					}
				}
				Else {
					# warn and inquire about replacing
					Write-Warning -Message "found root key '$JsonKey' and PreserveVMParameters not set; continue to replace the object." -WarningAction Inquire
				}
				# report pending action
				Write-Host "Replacing '$JsonKey'..."
				# remove objects with matching key name
				$JsonData.PSObject.Properties.Remove($JsonKey)
			}

			# create ordered hashtable with required parameters
			$JsonKeyValues = [ordered]@{
				ComputerName = $ComputerName
				Path         = $Path
			}

			# define parameters for Get-ParametersFromCommand
			$GetParametersFromCommand = @{
				ParameterSetName        = 'Add'
				ExcludeParameters       = $JsonKeyValues.Keys
				ExcludeParameterSetName = $true
				ExcludeParameterSets    = @('AddVMHardDiskDrive', 'AddVMNetworkAdapter')
			}

			# get parameters
			Try {
				$Parameters = Get-ParametersFromCommand @GetParametersFromCommand
			}
			Catch {
				Return $_
			}

			# process each parameter in parameter set
			ForEach ($Parameter in $Parameters) {
				# if optional parameter is defined...
				If ($PSBoundParameters[$Parameter]) {
					# ...and is a switch paramter
					If ($PSBoundParameters[$Parameter] -is [System.Management.Automation.SwitchParameter]) {
						# ...convert to boolean then add to hashtable
						$JsonKeyValues[$Parameter] = $PSBoundParameters[$Parameter].ToBool()
					}
					# ...and is not a switch paramter
					Else {
						# ...add to hashtable as-is
						$JsonKeyValues[$Parameter] = $PSBoundParameters[$Parameter]
					}
				}
			}

			# if PreserveVMParameters set and ExistingKeyValuePairs exist...
			If ($PreserveVMParameters -and $ExistingKeyValuePairs) {
				# ...process each keys of ExistingKeyValuePairs...
				ForEach ($Key in $ExistingKeyValuePairs.Keys) {
					# ...if VMObjectParams does not contain the key...
					If ($null -eq $JsonKeyValues[$Key]) {
						# ...add property to the ordered hashtable
						$JsonKeyValues[$Key] = $ExistingKeyValuePairs[$Key]
					}
				}
			}

			# add updated item as property to JSON data
			Add-Member -InputObject $JsonData -Name $JsonKey -Value $JsonKeyValues -MemberType NoteProperty

			# if default hard disk drive requested...
			If ($CreateDefaultVMHardDiskDrive) {
				# update JsonData 
				$JsonData = $JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json

				# define parameters for function
				$AddNestedJsonKeyValuePair = @{
					# define parameters
					BoundParameters  = $PSBoundParameters
					# define parameter set name
					ParameterSetName = 'AddVMHardDiskDrive'
					# define keys between root key and nested key
					JsonPathToKey    = 'VMHardDiskDrives'
					# define key for finding existing key value pair
					JsonNestedKey    = 'Path'
					# define value for finding existing key value pair
					JsonNestedValue  = "$Path\$VMName\$VMName.vhdx"
					# define value for default entries
					JsonNestedParams = [ordered]@{
						Path      = "$Path\$VMName\Virtual Hard Disks\$VMName.vhdx"
						SizeBytes = 100GB
					}
				}

				# add object to nested JSON key
				Try {
					Add-NestedJsonKeyValuePair @AddNestedJsonKeyValuePair
				}
				Catch {
					Return $_
				}
			}

			# if default network adapter requested...
			If ($CreateDefaultVMNetworkAdapter) {
				# update JsonData 
				$JsonData = $JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json

				# define parameters for function
				$AddNestedJsonKeyValuePair = @{
					# define parameters
					BoundParameters  = $PSBoundParameters
					# define paramter set name
					ParameterSetName = 'AddVMNetworkAdapter'
					# define keys between root key and nested key
					JsonPathToKey    = 'VMNetworkAdapters'
					# define key for finding existing key value pair
					JsonNestedKey    = 'NetworkAdapterName'
					# define value for finding existing key value pair
					JsonNestedValue  = 'Network Adapter'
					# define value for default entries
					JsonNestedParams = [ordered]@{
						NetworkAdapterName = 'Network Adapter'
					}
				}

				# add object to nested JSON key
				Try {
					Add-NestedJsonKeyValuePair @AddNestedJsonKeyValuePair
				}
				Catch {
					Return $_
				}
			}

			# update JSON file
			Update-JsonFile -JsonData $JsonData
		}
		$AddOSD {
			# define parameters for function
			$AddNestedJsonKeyValuePair = @{
				# define parameters
				BoundParameters  = $PSBoundParameters
				# define paramter set name
				ParameterSetName = 'AddOSD'
				# define keys between root key and nested key
				JsonPathToKey    = 'OSDeployment'
				# define key for finding existing key value pair
				JsonNestedKey    = 'DeploymentMethod'
				# define value for finding existing key value pair
				JsonNestedValue  = $DeploymentMethod
			}

			# add object to nested JSON key
			Try {
				Add-NestedJsonKeyValuePair @AddNestedJsonKeyValuePair
			}
			Catch {
				Return $_
			}

			# update JSON file
			Update-JsonFile -JsonData $JsonData
		}
		$AddVMHardDiskDrive {
			# define parameters for function
			$AddNestedJsonKeyValuePair = @{
				# define parameters
				BoundParameters  = $PSBoundParameters
				# define paramter set name
				ParameterSetName = 'AddVMHardDiskDrive'
				# define keys between root key and nested key
				JsonPathToKey    = 'VMHardDiskDrives'
				# define key for finding existing key value pair
				JsonNestedKey    = 'Path'
				# define value for finding existing key value pair
				JsonNestedValue  = $Path
			}

			# add object to nested JSON key
			Try {
				Add-NestedJsonKeyValuePair @AddNestedJsonKeyValuePair
			}
			Catch {
				Return $_
			}

			# update JSON file
			Update-JsonFile -JsonData $JsonData
		}
		$AddVMNetworkAdapter {
			# define parameters for function
			$AddNestedJsonKeyValuePair = @{
				# define parameters
				BoundParameters  = $PSBoundParameters
				# define paramter set name
				ParameterSetName = 'AddVMNetworkAdapter'
				# define keys between root key and nested key
				JsonPathToKey    = 'VMNetworkAdapters'
				# define key for finding existing key value pair
				JsonNestedKey    = 'NetworkAdapterName'
				# define value for finding existing key value pair
				JsonNestedValue  = $NetworkAdapterName
			}

			# add object to nested JSON key
			Try {
				Add-NestedJsonKeyValuePair @AddNestedJsonKeyValuePair
			}
			Catch {
				Return $_
			}

			# update JSON file
			Update-JsonFile -JsonData $JsonData
		}
		Default {
			Show-JsonFile -JsonData $JsonData
		}
	}
}
