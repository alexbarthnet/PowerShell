Param(
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	[Parameter(ValueFromPipeline = $True)]
	[string[]]$VMName,
	[string]$ComputerName,
	[string]$Path,
	[switch]$UseDefaultPathOnHost,
	[switch]$UseExistingDisks,
	[switch]$SkipProvisioning,
	[switch]$SkipStart,
	[switch]$SkipClustering,
	[switch]$ForceRestart,
	[pscredential]$LocalAdminCredential,
	[pscredential]$DomainJoinCredential,
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
)

Begin {
	# set error action preference
	$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

	Function ConvertTo-Collection {
		Param (
			[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
			[object]$InputObject,
			[Parameter(Position = 1)][ValidateSet('Hashtable', 'SortedList', 'OrderedDictionary')]
			[string]$Type = 'Hashtable'
		)

		# switch on type
		switch ($Type) {
			'OrderedDictionary' {
				$Collection = [System.Collections.Specialized.OrderedDictionary]::new()
			}
			'SortedList' {
				$Collection = [System.Collections.SortedList]::new()
			}
			'Hashtable' {
				$Collection = [System.Collections.Hashtable]::new()
			}
		}

		# process each property of input object
		ForEach ($Property in $InputObject.PSObject.Properties) {
			# if property contains multiple values...
			If ($Property.Value.Count -gt 1) {
				# define list for property values
				$PropertyValues = [System.Collections.Generic.List[object]]::new($Property.Value.Count)
				# process each property value
				ForEach ($PropertyValue in $Property.Value) {
					# if property value is a pscustomobject...
					If ($PropertyValue -is [System.Management.Automation.PSCustomObject]) {
						# convert property value into collection
						$PropertyValueCollection = ConvertTo-Collection -InputObject $PropertyValue -Type $Type
						# add property value collection to list
						$PropertyValues.Add($PropertyValueCollection)
					}
					# if property value is not a pscustomobject...
					Else {
						# add property value to list
						$PropertyValues.Add($PropertyValue)
					}
				}
				# convert list to array then add array to collection
				$Collection[$Property.Name] = $PropertyValues.ToArray()
			}
			Else {
				# if property value is a pscustomobject...
				If ($Property.Value -is [System.Management.Automation.PSCustomObject]) {
					# convert property value into collection
					$PropertyValueCollection = ConvertTo-Collection -InputObject $Property.Value -Type $Type
					# add property name and value to collection
					$Collection[$Property.Name] = $PropertyValueCollection
				}
				# if property value is not a pscustomobject...
				Else {
					# add property name and value to collection
					$Collection[$Property.Name] = $Property.Value
				}
			}
		}

		# return collection
		Return $Collection
	}

	Function Format-Bytes {
		[CmdletBinding()]
		Param (
			[Parameter(Position = 0, Mandatory = $true)]
			[uint64]$Size,
			[Parameter(Position = 1)]
			[int32]$RoundTo = 2
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

	Function Test-PSSessionByName {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName
		)

		# if computername matches hostname...
		If ($ComputerName -eq $Hostname) {
			# ...return false as no session is needed
			Return $false
		}

		# if hashtable is missing...
		If ($script:PSSessions -isnot [hashtable]) {
			# ...create hashtable
			$script:PSSessions = @{}
		}

		# if session exists for computer...
		If ($script:PSSessions.ContainsKey($ComputerName) -and $script:PSSessions[$ComputerName] -is [System.Management.Automation.Runspaces.PSSession]) {
			# ...return true as session can already be referenced
			Return $true
		}
		Else {
			# ...try to create a session
			Try {
				$script:PSSessions[$ComputerName] = New-PSSession -ComputerName $ComputerName -Name $ComputerName -Authentication Default
			}
			Catch {
				Return $false
			}
			# ...validate session
			If ($script:PSSessions[$ComputerName] -is [System.Management.Automation.Runspaces.PSSession]) {
				Return $true
			}
			Else {
				Return $false
			}
		}
	}

	Function Get-PSSessionInvoke {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[hashtable]$ArgumentList
		)

		# default arguments passed to ScriptBlock run by Invoke-Command
		$ArgumentListForInvokeCommand = @{
			# ErrorAction for ScriptBlock run by Invoke-Command
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# optional arguments passed to ScriptBlock run by Invoke-Command
		ForEach ($Key in $ArgumentList.Keys) {
			$ArgumentListForInvokeCommand[$Key] = $ArgumentList[$Key]
		}

		# define hashtable for Invoke-Command
		$InvokeCommand = @{
			# ErrorAction for Invoke-Command itself
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			# arguments passed to script block executed by Invoke-Command
			ArgumentList = $ArgumentListForInvokeCommand
		}

		# if computername matches hostname...
		If ($ComputerName -eq $Hostname) {
			# ...update hashtable to invoke commands in the current scope on the local computer
			$InvokeCommand['NoNewScope'] = $true
			# ...return hashtable
			Return $InvokeCommand
		}

		# check for session
		Try {
			$SessionExists = Test-PSSessionByName -ComputerName $ComputerName
		}
		Catch {
			Throw $_
		}

		# if a session exists...
		If ($SessionExists) {
			# ...update hashtable to invoke commands in the session
			$InvokeCommand['Session'] = $script:PSSessions[$ComputerName]
			# ...return hashtable
			Return $InvokeCommand
		}
		Else {
			# ...update hashtable to invoke commands in a standalone session
			$InvokeCommand['ComputerName'] = $ComputerName
			# ...return hashtable
			Return $InvokeCommand
		}
	}

	Function Get-CimInstanceForVM {
		[CmdletBinding()]
		Param(
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower()
		)

		# get VM from parameters
		Try {
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			Throw $_
		}

		# define CIM instance for VM system settings
		$GetCimInstance = @{
			ComputerName = $ComputerName
			Namespace    = 'Root\Virtualization\V2'
			ClassName    = 'Msvm_VirtualSystemSettingData'
			Filter       = "ConfigurationId = '$($VM.Id)'"
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve original VM system settings and host management service via CIM
		Try {
			Get-CimInstance @GetCimInstance
		}
		Catch {
			Throw $_
		}
	}

	Function Get-CimInstanceForVMMS {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName
		)

		# define CIM instance for host management service
		$GetCimInstance = @{
			ComputerName = $ComputerName
			Namespace    = 'Root\Virtualization\V2'
			ClassName    = 'Msvm_VirtualSystemManagementService'
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve CIM instance for host management service
		Try {
			Get-CimInstance @GetCimInstance
		}
		Catch {
			Throw $_
		}
	}

	Function Get-ClusterName {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName
		)

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		Catch {
			Throw $_
		}

		# test for cluster
		Try {
			$ClusterName = Invoke-Command @InvokeCommand -ScriptBlock {
				$GetItemProperty = @{
					Path        = 'HKLM:\System\CurrentControlSet\Services\ClusSvc\Parameters'
					Name        = 'ClusterName'
					ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
				}
				Get-ItemProperty @GetItemProperty | Select-Object -ExpandProperty $GetItemProperty['Name']
			}
		}
		Catch {
			Throw $_
		}

		# return the cluster name
		If ($null -ne $ClusterName) {
			Return $ClusterName
		}
		Else {
			Return [string]::Empty
		}
	}

	Function Get-ClusterNodeNames {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName
		)

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		Catch {
			Throw $_
		}

		# test for cluster
		Try {
			$ClusterNodeNames = Invoke-Command @InvokeCommand -ScriptBlock {
				$GetClusterNode = @{
					ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
				}
				Get-ClusterNode @GetClusterNode | Select-Object -ExpandProperty 'Name'
			}
		}
		Catch {
			Throw $_
		}

		# return the cluster nodes
		If ($null -ne $ClusterNodeNames) {
			Return $ClusterNodeNames
		}
		Else {
			Return $null
		}
	}

	Function Get-CMModulePath {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[string]$ChildPath = '\bin\ConfigurationManager.psd1'
		)

		# define hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		Catch {
			Throw $_
		}

		# retrieve path to CM module from remote registry
		Try {
			$Path = Invoke-Command @InvokeCommand -ScriptBlock {
				# define parameters for Get-ItemProperty
				$GetItemProperty = @{
					Path        = 'HKLM:\SOFTWARE\Microsoft\SMS\Setup'
					Name        = 'UI Installation Directory'
					ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
				}
				# get property by name from path
				Get-ItemProperty @GetItemProperty | Select-Object -ExpandProperty $GetItemProperty['Name']
			}
		}
		Catch {
			Throw $_
		}

		# if path not found...
		If ([string]::IsNullOrEmpty($Path)) {
			# ...return empty string
			Return [string]::Empty
		}

		# update argument list with CM module path
		$InvokeCommand['ArgumentList']['Path'] = $Path
		$InvokeCommand['ArgumentList']['ChildPath'] = $ChildPath

		# test CM module path
		Try {
			$CMModulePath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				# define parameters for Join-Path
				$JoinPath = @{
					Path        = $ArgumentList['Path']
					ChildPath   = $ArgumentList['ChildPath']
					Resolve     = $true
					ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
				}
				# join paths together
				Join-Path @JoinPath
			}
		}
		Catch {
			Throw $_
		}

		# if path not found...
		If ([string]::IsNullOrEmpty($CMModulePath)) {
			Return [string]::Empty
		}
		# if path found...
		Else {
			# ...return path
			Return $CMModulePath
		}
	}

	Function Get-CMSiteCode {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName
		)

		# define hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		Catch {
			Throw $_
		}

		# retrieve CM site code from remote registry
		Try {
			$CMSiteCode = Invoke-Command @InvokeCommand -ScriptBlock {
				# define parameters for Get-ItemProperty
				$GetItemProperty = @{
					Path        = 'HKLM:\SOFTWARE\Microsoft\SMS\Identification'
					Name        = 'Site Code'
					ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
				}
				# get property by name from path
				Get-ItemProperty @GetItemProperty | Select-Object -ExpandProperty $GetItemProperty['Name']
			}
		}
		Catch {
			Throw $_
		}

		# if CM site code not found...
		If ([string]::IsNullOrEmpty($CMSiteCode)) {
			# ...return empty string
			Return [string]::Empty
		}
		# if CM site code found...
		Else {
			# ...return CM site code
			Return $CMSiteCode
		}
	}

	Function Get-VMFromComputerName {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[Parameter(Mandatory = $true)]
			[string]$Name,
			[string]$ClusterName
		)

		# if cluster name was provided...
		If ($PSBoundParameters['ClusterName']) {
			# define parameters for Get-ClusterNodeNames
			$GetClusterNodeNames = @{
				ComputerName = $ComputerName
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# define computernames as cluster node names
			Try {
				$ComputerNames = Get-ClusterNodeNames @GetClusterNodeNames
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving cluster node names from computer name")
				Throw $_
			}
		}
		Else {
			# define computernames as single computername
			$ComputerNames = $ComputerName
		}

		# create list for VMs
		$VMList = [System.Collections.Generic.List[object]]::new()

		# check for VM on each node
		:ComputerNames ForEach ($ComputerNameForGetVM in $ComputerNames) {
			# declare and begin
			Write-Host ("$Hostname,$ComputerName,$Name - checking for VM on host: '$ComputerNameForGetVM'")

			# define parameters for Get-VMHost
			$GetVMHost = @{
				ComputerName = $ComputerNameForGetVM
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# validate host before continuing
			Try {
				$null = Get-VMHost @GetVMHost
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - WARNING: could not connect to host: '$ComputerNameForGetVM'")
				Continue ComputerNames
			}

			# define parameters for Get-VM
			$GetVM = @{
				Name         = $Name
				ComputerName = $ComputerNameForGetVM
				ErrorAction  = [System.Management.Automation.ActionPreference]::SilentlyContinue
			}

			# get VMs with Name from ComputerName
			Try {
				$VMsFromGetVM = Get-VM @GetVM
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving VMs from host")
				Throw $_
			}

			# add each VM to VM list
			ForEach ($VMFromGetVM in $VMsFromGetVM) {
				$VMList.Add($VMFromGetVM)
			}
		}

		# check VM list
		switch ($VMList.Count) {
			# no VMs found
			0 {
				# declare then return null
				Write-Host ("$Hostname,$ComputerName,$Name - ....VM not found on provided host")
				Return $null
			}
			# one VM found
			1 {
				# declare then return VM
				Write-Host ("$Hostname,$ComputerName,$Name - ....VM found via provided host")
				Return $VMList[0]
			}
			# multiple VMs found
			Default {
				# declare and report then return null
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: multiple VMs found with name")
				ForEach ($VMObject in $VMList) {
					Write-Host ("$Hostname,$ComputerName,$Name - ...found VM on '$($VMObject.ComputerName)' with Id: '$($VMObject.Id)'")
				}
				Return 'multiple'
			}
		}
	}

	Function Get-VMFromParameters {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)][ValidateScript({ $_ -is [Microsoft.HyperV.PowerShell.VirtualMachine] -or $_ -is [guid] -or $_ -is [string] })]
			[object]$VM,
			[string]$ComputerName,
			[switch]$Force
		)

		# if VM is a virtual machine object and Force not set...
		If ($VM -is [Microsoft.HyperV.PowerShell.VirtualMachine] -and -not $Force) {
			# ...return VM as-is
			Return $VM
		}

		# if computername not provided...
		If ([string]::IsNullOrEmpty($ComputerName)) {
			# ...and VM is a virtual machine...
			If ($VM -is [Microsoft.HyperV.PowerShell.VirtualMachine]) {
				# get computer name from VM
				$ComputerName = $VM.ComputerName.ToLower()
			}
			Else {
				# get computer name from hostname
				$ComputerName = $Hostname
			}
		}

		# define required parameters for Get-VM
		$GetVM = @{
			ComputerName = $ComputerName
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# if VM is a virtual machine object...
		If ($VM -is [Microsoft.HyperV.PowerShell.VirtualMachine]) {
			# ...set ID from Id property on VM object
			$GetVM['Id'] = $VM.Id
		}
		# if VM is a GUID...
		ElseIf ($VM -is [guid] -or [guid]::TryParse($VM, [ref][guid]::Empty)) {
			# ...set ID from value of VM cast as a GUID
			$GetVM['Id'] = [guid]$VM
		}
		# if VM is a string...
		Else {
			# ...set Name from value of VM
			$GetVM['Name'] = $VM
		}

		# get VM with arguments
		Try {
			$VM = Get-VM @GetVM
		}
		Catch {
			Throw $_
		}

		# return objects
		If ($VM -is [Microsoft.HyperV.PowerShell.VirtualMachine]) {
			Return $VM
		}
		ElseIf ($VM -is [array]) {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieved multiple VM objects with provided parameters")
			Throw $_
		}
		Else {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieved unexpected object type with provided parameters")
			Throw $_
		}
	}

	Function Get-VMHostNextMacAddress {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[string]$Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\Worker'
		)

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not get initial hashtable for Invoke-Command")
			Throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['Path'] = $Path
		$InvokeCommand['ArgumentList']['Name'] = 'CurrentMacAddress'

		# retrieve current MAC address
		Try {
			$CurrentMacAddress = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				Get-ItemPropertyValue -Path $ArgumentList['Path'] -Name $ArgumentList['Name']
			}
		}
		Catch {
			Throw $_
		}

		# verify current MAC address
		If ($CurrentMacAddress -isnot [byte[]]) {
			Write-Host ("$Hostname,$ComputerName - ERROR: CurrentMacAddress registry value is not a byte array")
			Return $null
		}

		# define and increment updated MAC address
		If ($CurrentMacAddress[-1] -eq 255) {
			Write-Host ("$Hostname,$ComputerName - ERROR: CurrentMacAddress has reached the default limit")
			Return $null
		}

		# update argument list
		$InvokeCommand['ArgumentList']['CurrentMacAddress'] = $CurrentMacAddress

		# update current MAC address
		Try {
			$null = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				# increment last byte in current MAC address
				$ArgumentList['CurrentMacAddress'][-1]++
				# update current MAC address property
				Set-ItemProperty -Path $ArgumentList['Path'] -Name $ArgumentList['Name'] -Value $ArgumentList['CurrentMacAddress']
			}
		}
		Catch {
			Throw $_
		}

		# return current MAC address
		Try {
			Return [System.BitConverter]::ToString($CurrentMacAddress).Replace('-', $null)
		}
		Catch {
			Throw $_
		}
	}

	Function Add-DeviceToSccm {
		[CmdletBinding()]
		Param(
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			# define OSD parameters
			[Parameter(Mandatory)]
			[string]$Server,
			[Parameter(Mandatory)]
			[string[]]$Collections,
			[Parameter(Mandatory)]
			[string]$DomainName,
			[Parameter(Mandatory)]
			[string]$OrganizationalUnit
		)

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $Server
		}
		Catch {
			Throw $_
		}

		# get VM from parameters
		Try {
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			Throw $_
		}

		# define parameters for Get-CimInstanceForVM
		$GetCimInstanceForVM = @{
			VM          = $VM
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve CIM instance for VM
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...retrieving CIM instance for VM...")
			$CimInstanceForVM = Get-CimInstanceForVM @GetCimInstanceForVM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve CIM instance for VM")
			Throw $_
		}

		# retrive BIOS GUID from CIM instance
		If ([string]::IsNullOrEmpty($CimInstanceForVM.BIOSGUID)) {
			Write-Host ("$Hostname,$ComputerName,$Name - WARNING: BIOS GUID for VM is empty; skipping SCCM provisioning...")
			Return
		}
		Else {
			Write-Host ("$Hostname,$ComputerName,$Name - ...found BIOS GUID for VM")
			$BIOSGUID = $CimInstanceForVM.BIOSGUID
		}

		# define parameters for Get-CMModulePath
		$GetCMModulePath = @{
			ComputerName = $DeploymentServer
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# get CM module path
		Try {
			$CMModulePath = Get-CMModulePath @GetCMModulePath
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve path to CM PowerShell module")
			Throw $_
		}

		# test CM module path
		If ([string]::IsNullOrEmpty($CMModulePath)) {
			Write-Host ("$Hostname,$ComputerName,$Name - WARNING: could not retrieve path to CM PowerShell module")
			Return
		}

		# define parameters for Get-CMSiteCode
		$GetCMSiteCode = @{
			ComputerName = $Server
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# get CM site code
		Try {
			$CMSiteCode = Get-CMSiteCode @GetCMSiteCode
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve CM site code")
			Throw $_
		}

		# test CM site code
		If ([string]::IsNullOrEmpty($CMSiteCode)) {
			Write-Host ("$Hostname,$ComputerName,$Name - WARNING: could not retrieve CM site code")
			Return
		}

		# update arguments for Invoke-Command - reporting
		$InvokeCommand['ArgumentList']['Hostname'] = $Hostname
		$InvokeCommand['ArgumentList']['ComputerName'] = $Server
		$InvokeCommand['ArgumentList']['Name'] = $Name

		# update arguments for Invoke-Command - deployment
		$InvokeCommand['ArgumentList']['Collections'] = $Collections
		$InvokeCommand['ArgumentList']['ModulePath'] = $CMModulePath
		$InvokeCommand['ArgumentList']['SiteCode'] = $CMSiteCode
		$InvokeCommand['ArgumentList']['BIOSGUID'] = $BIOSGUID
		$InvokeCommand['ArgumentList']['OSDDOMAIN'] = $DomainName
		$InvokeCommand['ArgumentList']['OSDDOMAINOUNAME'] = $OrganizationalUnit

		# add VM to SCCM
		Invoke-Command @InvokeCommand -ScriptBlock {
			Param($ArgumentList)

			Function Get-CMDeviceFromCollection {
				[CmdletBinding()]
				Param(
					[Parameter(Mandatory = $true)]
					[string]$CollectionId,
					[Parameter(Mandatory = $true)]
					[string]$Name,
					[switch]$SkipUpdate,
					[int32]$Seconds = 5,
					[int32]$Limit = 8
				)

				# define parameters for Get-CMDevice
				$GetCMDevice = @{
					CollectionId = $CollectionId
					Name         = $Name
					Fast         = $true
					ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
				}

				# retrieve device by name
				Try {
					$Device = Get-CMDevice @GetCMDevice
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve device from collection")
					Throw $_
				}

				# if device found
				If ($null -ne $Device) {
					# ...return device
					Write-Host ("$Hostname,$ComputerName,$Name - ...found device in collection immediately")
					Return $Device
				}
				# if skip update...
				ElseIf ($SkipUpdate) {
					# ...return null
					Return $null
				}

				# update collection
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - updating collection...")
					Invoke-CMCollectionUpdate -CollectionId $CollectionId
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not update from collection")
					Throw $_
				}

				# define integers for while loop and reporting
				$WaitTime = [int32]0
				$Multiplier = [int32]0

				# wait until device is visible in SCCM
				Write-Host ("$Hostname,$ComputerName,$Name - waiting for device to be visible in SCCM...")
				While ($null -eq $Device -and $Multiplier -lt $Limit) {
					# increment multiplier
					$Multiplier++

					# record total time
					$WaitTime += ($Seconds * $Multiplier)

					# wait for collection update to complete
					Write-Host ("$Hostname,$ComputerName,$Name - ...waiting an additional '$($Seconds * $Multiplier)' seconds")
					Start-Sleep -Seconds ($Seconds * $Multiplier)

					# retrieve device by name
					Try {
						$Device = Get-CMDevice @GetCMDevice
					}
					Catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve device from collection")
						Throw $_
					}
				}

				# if device found...
				If ($null -ne $Device) {
					# ...declare wait time and return
					Write-Host ("$Hostname,$ComputerName,$Name - ...found device in collection after '$WaitTime' seconds")
					Return $Device
				}
				# if device not found...
				Else {
					# ...declare wait time and return
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: device not found after '$WaitTime' seconds")
					Write-Host ("$Hostname,$ComputerName,$Name - ...check SCCM before continuing")
					Return $null
				}
			}

			Function Add-CMDeviceToCollection {
				[CmdletBinding()]
				Param (
					[string]$CollectionName,
					[string]$ResourceId
				)

				# retrieve device collection
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - retrieving device collection: '$CollectionName'")
					$Collection = Get-CMDeviceCollection -Name $CollectionName
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve device collection")
					Throw $_
				}

				# if device collection not found...
				If ($null -eq $Collection) {
					# ...warn and return
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: could not retrieve device collection: '$CollectionName'")
					Return
				}

				# check for direct membership rule
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - retrieving direct membership rule for device...")
					$MembershipRule = Get-CMDeviceCollectionDirectMembershipRule -CollectionId $Collection.CollectionID -ResourceId $ResourceId
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving direct membership rule")
					Throw $_
				}

				# if direct membership rule not found...
				If ($null -eq $MembershipRule) {
					# add direct membership rule to collection
					Try {
						Write-Host ("$Hostname,$ComputerName,$Name - adding direct membership rule for device to collection...")
						$MembershipRule = Add-CMDeviceCollectionDirectMembershipRule -CollectionId $Collection.CollectionID -ResourceId $ResourceId -PassThru
					}
					Catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: adding direct membership rule for device to collection")
						Throw $_
					}
				}

				# if collection membership rule not found after adding rule...
				If ($null -eq $MembershipRule) {
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: could not retrieve direct membership rule after adding to collection")
					Return
				}

				# retrieve device from collection
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - retrieving device from collection...")
					Get-CMDeviceFromCollection -CollectionId $Collection.CollectionID -Name $Name
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving device from collection")
					Throw $_
				}
			}

			Function Update-CMDeviceVariable {
				[CmdletBinding()]
				Param (
					[string]$ResourceId,
					[string]$VariableName,
					[string]$VariableValue
				)

				# define parameters for Get-CMDeviceVariable
				$GetCMDeviceVariable = @{
					ResourceId   = $ResourceId
					VariableName = $VariableName
					ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
				}

				# retrieve device variable for OSD domain
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - retrieving device variable: '$VariableName'")
					$DeviceVariable = Get-CMDeviceVariable @GetCMDeviceVariable
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving device variable")
					Throw $_
				}

				# if device variable not found...
				If ($null -eq $DeviceVariable) {
					# define parameters for New-CMDeviceVariable
					$NewCMDeviceVariable = @{
						DeviceId      = $ResourceId # *MUST* be DeviceId due to CM module/cmdlet design
						VariableName  = $VariableName
						VariableValue = $VariableValue
						ErrorAction   = [System.Management.Automation.ActionPreference]::Stop
					}

					# create device variable
					Try {
						Write-Host ("$Hostname,$ComputerName,$Name - ...adding device variable: '$VariableName'")
						$null = New-CMDeviceVariable @NewCMDeviceVariable
					}
					Catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: adding device variable")
						Throw $_
					}

					# declare and return
					Write-Host ("$Hostname,$ComputerName,$Name - ...added device variable")
					Return
				}
				# if device variable found with wrong value...
				ElseIf ($DeviceVariable.Value -ne $VariableValue) {
					# define parameters for New-CMDeviceVariable
					$SetCMDeviceVariable = @{
						ResourceId   = $ResourceId
						VariableName = $VariableName
						ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
					}

					# update device variable
					Try {
						Write-Host ("$Hostname,$ComputerName,$Name - ...updating device variable: '$VariableName'")
						$null = Set-CMDeviceVariable @SetCMDeviceVariable
					}
					Catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: updating device variable")
						Throw $_
					}

					# declare and return
					Write-Host ("$Hostname,$ComputerName,$Name - ...updated device variable")
					Return
				}
				Else {
					Write-Host ("$Hostname,$ComputerName,$Name - ...found device variable: '$VariableName'")
					Return
				}
			}

			# reset device object
			$Device = $null

			# create objects for reporting
			$Hostname = $ArgumentList['Hostname']
			$ComputerName = $ArgumentList['ComputerName']
			$Name = $ArgumentList['Name']

			# import CM module
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...importing SCCM module")
				Import-Module -Name $ArgumentList['ModulePath'] -ErrorAction 'Stop'
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: importing SCCM module")
				Throw $_
			}

			# move to site drive
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...setting location to site drive")
				Set-Location -Path ([string]::Concat($ArgumentList['SiteCode'], ':\'))
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: setting location to SCCM drive")
				Throw $_
			}

			# retrieve All Systems collection
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - retrieving 'All Systems' collection")
				$AllSystems = Get-CMDeviceCollection -Name 'All Systems'
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving 'All Systems' collection")
				Throw $_
			}

			# validate All Systems collection
			If ($null -eq $AllSystems) {
				Write-Host ("$Hostname,$ComputerName,$Name - WARNING: All Systems collection is empty")
				Return
			}

			# retrieve device by name
			If ($null -eq $Device) {
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - retrieving device by name from 'All Systems' collection")
					$Device = Get-CMDevice -Collection $AllSystems -Fast -Name $Name
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving device by name from 'All Systems' collection")
					Throw $_
				}

				# if multiple devices found by name...
				If ($Device.Count -gt 1) {
					# ...warn and return
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: multiple devices found with the same name")
					Write-Host ("$Hostname,$ComputerName,$Name - ...remove extra devices from SCCM before continuing")
					Return
				}

				# if device found by name and Device is a full client...
				If ($null -ne $Device -and $Device.Client -eq 1) {
					# ...warn and return
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: device found by name with existing client")
					Write-Host ("$Hostname,$ComputerName,$Name - ...remove device from SCCM before continuing")
					Return
				}

				# if device found by name with different BIOSGUID...
				If ($null -ne $Device -and $Device.SMBIOSGUID -ne $ArgumentList['BIOSGUID']) {
					# ...warn and return
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: device found by name with unexpected SMBIOSGUID: '$($ArgumentList['BIOSGUID'])'")
					Write-Host ("$Hostname,$ComputerName,$Name - ...remove device from SCCM before continuing")
					Return
				}

				# if device not found by name...
				If ($null -eq $Device) {
					# report and continue
					Write-Host ("$Hostname,$ComputerName,$Name - ...device not found by name in 'All Systems' collection")
				}
			}

			# retrieve device by SMBIOSGUID
			If ($null -eq $Device) {
				# retrieve device by SMBIOSGUID
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - retrieving device by SMBIOSGUID from 'All Systems' collection")
					$Device = Get-CMDevice -Collection $AllSystems -Fast | Where-Object { $_.SMBIOSGUID -eq $ArgumentList['BIOSGUID'] }
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving devices from 'All Systems' collection")
					Throw $_
				}

				# if multiple devices found by SMBIOSGUID...
				If ($Device.Count -gt 1) {
					# ...warn and return
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: multiple devices found with the same SMBIOSGUID")
					Write-Host ("$Hostname,$ComputerName,$Name - ...remove extra devices from SCCM before continuing")
					Return
				}

				# if device found by SMBIOSGUID and Device is a full client...
				If ($null -ne $Device -and $Device.Client -eq 1) {
					# ...warn and return
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: device found by SMBIOSGUID with existing client")
					Write-Host ("$Hostname,$ComputerName,$Name - ...remove device from SCCM before continuing")
					Return
				}

				# if device found by SMBIOSGUID and Device is a full client...
				If ($null -ne $Device -and $Device.Name -ne $Name) {
					# ...warn and return
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: device found by SMBIOSGUID with unexpected name: '$($Device.Name)'")
					Write-Host ("$Hostname,$ComputerName,$Name - ...remove device from SCCM before continuing")
					Return
				}

				# if device not found by SMBIOSGUID...
				If ($null -eq $Device) {
					# report and continue
					Write-Host ("$Hostname,$ComputerName,$Name - ...device not found by SMBIOSGUID in 'All Systems' collection")
				}
			}

			# if device not found by name or SMBIOSGUID...
			If ($null -eq $Device) {
				# define parameters for Import-CMComputerInformation
				$ImportCMComputerInformation = @{
					CollectionId = $AllSystems.CollectionID
					ComputerName = $Name
					SMBiosGuid   = $ArgumentList['BIOSGUID']
					ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
				}

				# import the device into SCCM
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - adding device to SCCM...")
					Import-CMComputerInformation @ImportCMComputerInformation
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: adding device to SCCM")
					Throw $_
				}

				# define parameters for Get-CMDeviceFromCollection
				$GetCMDeviceFromCollection = @{
					CollectionId = $AllSystems.CollectionID
					Name         = $Name
					ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
				}

				# retrieve device from collection
				Try {
					$Device = Get-CMDeviceFromCollection @GetCMDeviceFromCollection
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving device from collection: '$($AllSystems.Name)'")
					Throw $_
				}

				# if device still not found...
				If ($null -eq $Device) {
					Return
				}

				# retrieve resource ID
				$ResourceId = $Device.ResourceId

				# ...report
				Write-Host ("$Hostname,$ComputerName,$Name - ...created new device with resource ID: '$ResourceId'")
			}
			# if device found...
			Else {
				# retrieve resource ID
				$ResourceId = $Device.ResourceId

				# ...report
				Write-Host ("$Hostname,$ComputerName,$Name - ...found existing device with resource ID: '$ResourceId'")

				# define parameters for Clear-CMPxeDeployment
				$ClearCMPxeDeployment = @{
					Device      = $Device
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}

				# clear PXE flag on CM resource
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - clearing any PXE deployments for existing device...")
					Clear-CMPxeDeployment @ClearCMPxeDeployment
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: clearing CM PXE deployment")
					Throw $_
				}

				# report and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...cleared PXE deployment for existing device")
			}

			# if device variable not provided...
			If ([string]::IsNullOrEmpty($ArgumentList['OSDDOMAIN'])) {
				Write-Host ("$Hostname,$ComputerName,$Name - skipping device variable: 'OSDDOMAIN'; value not provided")
			}
			# if deployment collection name provided...
			Else {
				# define parameterss for Update-CMDeviceVariable
				$UpdateCMDeviceVariable = @{
					ResourceId    = $Device.ResourceID
					VariableName  = 'OSDDOMAIN'
					VariableValue = $ArgumentList['OSDDomain']
					ErrorAction   = [System.Management.Automation.ActionPreference]::Stop
				}

				# update device variable for OSD domain
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - checking device variable: 'OSDDOMAIN'")
					Update-CMDeviceVariable @UpdateCMDeviceVariable
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: checking device variable")
					Throw $_
				}
			}

			# if device variable not provided...
			If ([string]::IsNullOrEmpty($ArgumentList['OSDDOMAINOUNAME'])) {
				Write-Host ("$Hostname,$ComputerName,$Name - skipping device variable: 'OSDDOMAINOUNAME'; value not provided")
			}
			Else {
				# define parameterss for Update-CMDeviceVariable
				$UpdateCMDeviceVariable = @{
					ResourceId    = $Device.ResourceID
					VariableName  = 'OSDDOMAINOUNAME'
					VariableValue = $ArgumentList['OSDDOMAINOUNAME']
					ErrorAction   = [System.Management.Automation.ActionPreference]::Stop
				}

				# update device variable for OSD domain OU name
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - checking device variable: 'OSDDOMAINOUNAME'")
					Update-CMDeviceVariable @UpdateCMDeviceVariable
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: checking device variable")
					Throw $_
				}
			}

			# loop through collections
			ForEach ($Collection in $ArgumentList['Collections']) {
				# define parameters for Get-CMDeviceFromCollection
				$AddCMDeviceToCollection = @{
					CollectionName = $Collection
					ResourceId     = $Device.ResourceID
					ErrorAction    = [System.Management.Automation.ActionPreference]::Stop
				}

				# add device to collection
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - adding device to collection: $Collection")
					$Device = Add-CMDeviceToCollection @AddCMDeviceToCollection
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add device to collection'")
					Throw $_
				}
			}
		}
	}

	Function Add-DeviceToWds {
		[CmdletBinding()]
		Param (
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			# define OSD parameters
			[Parameter(Mandatory)]
			[string]$DeploymentPath,
			[Parameter(Mandatory)]
			[string]$DeploymentServer
		)

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $DeploymentServer
		}
		Catch {
			Throw $_
		}

		# get VM from parameters
		Try {
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			Throw $_
		}

		# define CIM instance for VM system settings
		$GetCimInstanceForVM = @{
			VM          = $VM
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve original VM system settings and host management service via CIM
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...retrieving CIM instance for VM...")
			$CimInstanceForVM = Get-CimInstanceForVM @GetCimInstanceForVM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve CIM instance for VM")
			Throw $_
		}

		# retrive BIOS GUID from CIM data
		If ([string]::IsNullOrEmpty($CimInstanceForVM.BIOSGUID)) {
			Write-Host ("$Hostname,$ComputerName,$Name - WARNING: BIOS GUID for VM is empty; skipping WDS provisioning...")
			Return
		}
		Else {
			Write-Host ("$Hostname,$ComputerName,$Name - ...found BIOS GUID for VM: '$($CimInstanceForVM.BIOSGUID)'")
			$BIOSGUID = $CimInstanceForVM.BIOSGUID
		}

		# update arguments for Invoke-Command
		$InvokeCommand['ArgumentList']['Hostname'] = $Hostname
		$InvokeCommand['ArgumentList']['ComputerName'] = $DeploymentServer
		$InvokeCommand['ArgumentList']['DeviceName'] = $Name
		$InvokeCommand['ArgumentList']['DeviceID'] = $BIOSGUID
		$InvokeCommand['ArgumentList']['WdsClientUnattend'] = $DeploymentPath

		# add VM to WDS
		Invoke-Command @InvokeCommand -ScriptBlock {
			Param($ArgumentList)

			# create objects for reporting
			$Hostname = $ArgumentList['Hostname']
			$ComputerName = $ArgumentList['ComputerName']
			$Name = $ArgumentList['DeviceName']

			# define parameters for Get-Item Property
			$GetItemProperty = @{
				Path        = 'HKLM:\SYSTEM\CurrentControlSet\Services\WDSServer\Providers\WDSDCMGR\Providers\WDSADDC'
				Name        = 'Disabled'
				ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
			}

			# retrieve Disabled item property for WDS Active Directory inegration
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - checking WDS server...")
				$Disabled = Get-ItemProperty @GetItemProperty | Select-Object -ExpandProperty 'Disabled'
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not check WDS integration")
				Throw $_
			}

			# if WDS Active Directory integration is not disabled...
			If ($Disabled -eq 0) {
				# ...declare and return
				Write-Host ("$Hostname,$ComputerName,$Name - WARNING: WDS server is in Active Directory mode; skipping WDS provisioning...")
				Return
			}

			# define parameters for Get-WdsClient
			$GetWdsClient = @{
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# retrieve existing WDS clients
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - checking for matching WDS devices...")
				$WdsClients = Get-WdsClient @GetWdsClient
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve existing WDS devices")
				Throw $_
			}

			# create objects for device
			$DeviceID = $ArgumentList['DeviceID']

			# filter WDS clients
			$WdsClients = $WdsClients | Where-Object { $_.DeviceId -eq "{$DeviceId}" -or $_.DeviceName -eq $Name }

			# if no WDS clients found...
			If ($null -eq $WdsClients) {
				# ...declare and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...no matching WDS device found")
			}
			# if WDS clients found with matching DeviceId or DeviceName...
			Else {
				# process WDS clients
				ForEach ($WdsClient in $WdsClients) {
					# declare device found
					Write-Host ("$Hostname,$ComputerName,$Name - ...removing existing WDS device: ")
					Write-Host ("$Hostname,$ComputerName,$Name - ... - DeviceName : $($WdsClient.DeviceName)")
					Write-Host ("$Hostname,$ComputerName,$Name - ... - DeviceId   : $($WdsClient.DeviceId)")

					# define parameters for Remove-WdsClient
					$RemoveWdsClient = @{
						DeviceId    = $WdsClient.DeviceId
						ErrorAction = [System.Management.Automation.ActionPreference]::Stop
					}

					# remove matching WDS client by DeviceId
					Try {
						Remove-WdsClient @RemoveWdsClient
					}
					Catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove existing WDS device")
						Throw $_
					}
				}
			}

			# define parameters for New-WdsClient
			$NewWdsClient = @{
				DeviceId          = $DeviceId
				DeviceName        = $Name
				WdsClientUnattend = $ArgumentList['WdsClientUnattend']
				ErrorAction       = [System.Management.Automation.ActionPreference]::Stop
			}

			# create WDS client
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - creating WDS device...")
				$null = New-WdsClient @NewWdsClient
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not create WDS device")
				Throw $_
			}

			# declare complete and return
			Write-Host ("$Hostname,$ComputerName,$Name - ...created WDS device")
			Return
		}
	}

	Function Add-IsoToVM {
		[CmdletBinding()]
		Param (
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			# define OSD parameters
			[Parameter(Mandatory)]
			[string]$Path
		)

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		Catch {
			Throw $_
		}

		# get VM from parameters
		Try {
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			Throw $_
		}

		# update argument list for Test-Path
		$InvokeCommand['ArgumentList']['Path'] = $Path

		# test deployment path
		Try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				$TestPath = @{
					Path        = $ArgumentList['Path']
					PathType    = [Microsoft.PowerShell.Commands.TestPathType]::Leaf
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				Test-Path @TestPath
			}
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not check provided path")
			Throw $_
		}

		# evaluate deployment path
		If (-not $TestPath) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...skipping ISO attach, host did not find file: '$Path'")
			Return
		}

		# define parameters for Get-VMDvdDrive
		$GetVMDvdDrive = @{
			VM          = $VM
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve DVD drive
		Try {
			$VMDvdDrive = Get-VMDvdDrive @GetVMDvdDrive
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve DVD drives from VM")
			Throw $_
		}

		# if multiple DVD drives found...
		If ($VMDvdDrive.Count -gt 1) {
			# sort drives by controller and LUN then select first drive
			Write-Host ("$Hostname,$ComputerName,$Name - found multiple DVD drives on VM; selecting first drive")
			$VMDvdDrive = $VMDvdDrive | Sort-Object -Property ControllerNumber, ControllerLocation | Select-Object -First 1
		}

		# if DVD drive not found...
		If ($null -eq $VMDvdDrive) {
			# define parameters for Get-VMScsiController
			$GetVMScsiController = @{
				VM          = $VM
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# get SCSI controller
			Try {
				$VMScsiController = Get-VMScsiController @GetVMScsiController
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve SCSI controller")
				Throw $_
			}

			# if multiple SCSI controllers found...
			If ($VMScsiController.Count -gt 1) {
				# sort drives by controller and LUN then select first drive
				Write-Host ("$Hostname,$ComputerName,$Name - found multiple SCSI controllers on VM; selecting first controller")
				$VMScsiController = $VMScsiController | Sort-Object -Property ControllerNumber | Select-Object -First 1
			}

			# if SCSI controller not found...
			If ($null -eq $VMScsiController) {
				# define parameters for Add-VMScsiController
				$AddVMScsiController = @{
					VM          = $VM
					Passthru    = $true
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}

				# add SCSI controller
				Try {
					$VMScsiController = Add-VMScsiController @AddVMScsiController
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add SCSI controller")
					Throw $_
				}
			}

			# define parameters for Add-VMDvdDrive
			$AddVMDvdDrive = @{
				VMDriveController = $VMScsiController
				Passthru          = $true
				ErrorAction       = [System.Management.Automation.ActionPreference]::Stop
			}

			# add DVD drive
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - adding DVD drive to VM")
				$VMDvdDrive = Add-VMDvdDrive @AddVMDvdDrive
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add DVD drive to VM")
				Throw $_
			}
		}

		# define parameters for Set-VMDvdDrive
		$SetVMDvdDrive = @{
			VMDvdDrive  = $VMDvdDrive
			Path        = $Path
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# attach ISO to DVD drive
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...attaching ISO file: '$Path'")
			Set-VMDvdDrive @SetVMDvdDrive
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not attach ISO file to DVD drive")
			Throw $_
		}

		# define parameters for Set-VMFirmware
		$SetVMFirmware = @{
			VM              = $VM
			FirstBootDevice = $VMDvdDrive
			ErrorAction     = [System.Management.Automation.ActionPreference]::Stop
		}

		# attach ISO to DVD drive
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...updating first boot device in VM firmware")
			Set-VMFirmware @SetVMFirmware
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not update VM firmware")
			Throw $_
		}
	}

	Function Add-VMToClusterName {
		[CmdletBinding()]
		Param(
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			# define cluster parameters
			[Parameter(Mandatory = $true)]
			[string]$ClusterName,
			[Parameter()]
			[uint32]$ClusterPriority,
			[Parameter()]
			[string[]]$ClusterAffinityRules
		)

		# get VM from parameters
		Try {
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			Throw $_
		}

		# define parameters for Get-ClusterGroup
		$GetClusterGroup = @{
			Cluster     = $ClusterName
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve existing cluster group
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - checking cluster for VM...")
			$ClusterGroup = Get-ClusterGroup @GetClusterGroup | Where-Object { $_.Name -eq $Name }
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving cluster groups")
			Throw $_
		}

		# if cluster group found...
		If ($null -ne $ClusterGroup) {
			# declare found
			Write-Host ("$Hostname,$ComputerName,$Name - ...VM found in cluster: $ClusterName")
		}
		# if cluster group not found...
		Else {
			# declare and begin
			Write-Host ("$Hostname,$ComputerName,$Name - ...VM not found in cluster, adding to cluster: $ClusterName")

			# define parameters for Add-ClusterVirtualMachineRole
			$AddClusterVirtualMachineRole = @{
				Cluster     = $ClusterName
				VMId        = $VM.Id
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# add VM to cluster
			Try {
				$ClusterGroup = Add-ClusterVirtualMachineRole @AddClusterVirtualMachineRole
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: adding VM to cluster: $ClusterName")
				Throw $_
			}

			# declare state
			Write-Host ("$Hostname,$ComputerName,$Name - ...added VM to cluster")
		}

		# if cluster priority defined...
		If ($PSBoundParameters.ContainsKey('ClusterPriority')) {
			Write-Host ("$Hostname,$ComputerName,$Name - checking cluster group priority...")
			# if cluster priority does not match...
			If ($ClusterGroup.Priority -ne $ClusterPriority) {
				# declare and begin
				Write-Host ("$Hostname,$ComputerName,$Name - ...setting cluster group priority to: $ClusterPriority")

				# set cluster priority
				Try {
					$ClusterGroup.Priority = $ClusterPriority
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: setting cluster group priority")
					Throw $_
				}
			}
			# if cluster priority matches...
			Else {
				# declare
				Write-Host ("$Hostname,$ComputerName,$Name - ...found priority already set to: $ClusterPriority")
			}
		}

		# if cluster affinity rules defined...
		If ($PSBoundParameters.ContainsKey('ClusterAffinityRules')) {
			Write-Host ("$Hostname,$ComputerName,$Name - checking cluster affinity rules...")
			# process any requested cluster affinity rule
			:ClusterAffinityRules ForEach ($ClusterAffinityRuleName in $ClusterAffinityRules) {
				# define parameters for Get-ClusterAffinityRule
				$GetClusterAffinityRule = @{
					Cluster     = $ClusterName
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}

				# retrieve cluster affinity rules
				Try {
					$ClusterAffinityRule = Get-ClusterAffinityRule @GetClusterAffinityRule | Where-Object { $_.Name -eq $ClusterAffinityRuleName }
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving cluster affinity rules")
					Throw $_
				}

				# if affinity rule not found...
				If ($null -eq $ClusterAffinityRule) {
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: cluster affinity rule not found: $ClusterAffinityRuleName")
					Continue ClusterAffinityRules
				}

				# check affinity rule...
				If ($ClusterAffinityRule.Groups -contains $ClusterGroup.Name) {
					# declare
					Write-Host ("$Hostname,$ComputerName,$Name - ...found cluster group in cluster affinity rule: $ClusterAffinityRuleName")
					Continue ClusterAffinityRules
				}

				# declare and begin
				Write-Host ("$Hostname,$ComputerName,$Name - ...adding cluster group to cluster affinity rule: $ClusterAffinityRuleName")

				# define parameters for Get-ClusterAffinityRule
				$AddClusterGroupToAffinityRule = @{
					InputObject = $ClusterAffinityRule
					Groups      = $ClusterGroup.Name
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}

				# add cluster group to cluster affinity rule
				Try {
					Add-ClusterGroupToAffinityRule @AddClusterGroupToAffinityRule
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: setting cluster group priority")
					Throw $_
				}
			}
		}

		# if SkipPreferredOwner set...
		If ($SkipPreferredOwner) {
			# ...return cluster group
			Return $ClusterGroup
		}

		# define parameters for Get-ClusterOwnerNode
		$GetClusterOwnerNode = @{
			InputObject = $ClusterGroup
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# get cluster group owner node(s)
		Try {
			$ClusterOwnerNode = Get-ClusterOwnerNode @GetClusterOwnerNode
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving owner node(s) for cluster group")
			Throw $_
		}

		# check cluster group owner node(s)
		If (($ClusterOwnerNode.OwnerNodes.Name -join ',') -ne $ComputerName) {
			# declare state
			Write-Host ("$Hostname,$ComputerName,$Name - ...setting preferred owner on VM")

			# define parameters for Move-ClusterGroup
			$SetClusterOwnerNode = @{
				Owners      = $ComputerName
				InputObject = $ClusterGroup
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# move cluster group to computer
			Try {
				Set-ClusterOwnerNode @SetClusterOwnerNode
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: setting preferred owner on VM")
				Throw $_
			}

			# retrieve updated cluster group
			Try {
				$ClusterGroup = Get-ClusterGroup @GetClusterGroup
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving updated cluster group for VM")
				Throw $_
			}
		}

		# return cluster group
		Return $ClusterGroup
	}

	Function Add-VMNetworkAdapterToDHCP {
		[CmdletBinding()]
		Param(
			[string]$ComputerName,
			[string]$ScopeId,
			[string]$IPAddress,
			[string]$MacAddress,
			[string]$Router,
			[boolean]$ReservationRequired = $true
		)

		# define parameters for Get-DhcpServerv4Scope
		$GetDhcpServerv4Scope = @{
			ComputerName = $ComputerName
			ScopeId      = $ScopeId
			ErrorAction  = [System.Management.Automation.ActionPreference]::SilentlyContinue
		}

		# check for existing DHCP scope
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - checking for DHCP scope: '$ScopeId'")
			$Scope = Get-DhcpServerv4Scope @GetDhcpServerv4Scope
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: checking for DHCP scope")
			Throw $_
		}

		# if DHCP scope not found...
		If ($null -eq $Scope) {
			# declare and return
			Write-Host ("$Hostname,$ComputerName,$Name - ...DHCP scope not found, skipping DHCP provisioning")
			Return
		}

		# define parameters for Get-DhcpServerv4Reservation
		$GetDhcpServerv4Reservation = @{
			ComputerName = $ComputerName
			ScopeId      = $ScopeId
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve DHCP reservations
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...found DHCP scope, retrieving reservations...")
			$Reservations = Get-DhcpServerv4Reservation @GetDhcpServerv4Reservation
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving reservations from DHCP scope")
			Throw $_
		}

		# convert MAC address into client ID
		$ClientId = $MacAddress -replace '(..(?!$))', '$1-'

		# declare state
		Write-Host ("$Hostname,$ComputerName,$Name - checking for DHCP reservations with...")
		Write-Host ("$Hostname,$ComputerName,$Name -  IP Address : '$IPAddress'")
		Write-Host ("$Hostname,$ComputerName,$Name -  Client ID  : '$ClientId'")

		# filter DHCP reservations
		$Reservations = $Reservations | Where-Object { $_.IPAddress -eq $IPAddress -or $_.ClientId -eq $ClientId }

		# if matching DHCP reservations not found...
		If ($null -eq $Reservations) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...existing DHCP reservation not found")
		}
		# if matching DHCP reservations found...
		Else {
			# loop through DHCP reservations
			:NextReservation ForEach ($Reservation in $Reservations) {
				# if reservation found with both IP and client id...
				If ($Reservation.IPAddress -eq $IPAddress -and $Reservation.ClientId -eq $ClientId) {
					Write-Host ("$Hostname,$ComputerName,$Name - ...found existing DHCP reservation with requested IP address and client ID")
					$ReservationRequired = $false
					Continue NextReservation
				}
				ElseIf ($Reservation.IPAddress -ne $IPAddress) {
					# define parameters for Remove-DhcpServerv4Reservation
					$RemoveDhcpServerv4Reservation = @{
						ComputerName = $ComputerName
						IPAddress    = $IPAddress
						ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
					}

					# remove DHCP reservation with same IP addresss
					Try {
						Write-Host ("$Hostname,$ComputerName,$Name - ...removing existing DHCP reservation with conflicting IP address: '$($Reservation.IPAddress)'")
						Remove-DhcpServerv4Reservation @RemoveDhcpServerv4Reservation
					}
					Catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing existing DHCP reservation'")
						Throw $_
					}
				}
				ElseIf ($Reservation.ClientId -ne $ClientId) {
					# define parameters for Remove-DhcpServerv4Reservation
					$RemoveDhcpServerv4Reservation = @{
						ComputerName = $ComputerName
						ScopeId      = $ScopeId
						ClientId     = $ClientId
						ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
					}

					# remove DHCP reservation with same client ID
					Try {
						Write-Host ("$Hostname,$ComputerName,$Name - ...removing existing DHCP reservation with conflicting client ID: '$($Reservation.ClientId)'")
						Remove-DhcpServerv4Reservation @RemoveDhcpServerv4Reservation
					}
					Catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing existing DHCP reservation")
						Throw $_
					}
				}
			}
		}

		# if reservation required...
		If ($ReservationRequired) {
			# define parameters for Add-DhcpServerv4Reservation
			$AddDhcpServerv4Reservation = @{
				ComputerName = $ComputerName
				Name         = $Name
				ScopeId      = $ScopeId
				IPAddress    = $IPAddress
				ClientId     = $ClientId
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# create DHCP reservation
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - creating DHCP reservation...")
				Add-DhcpServerv4Reservation @AddDhcpServerv4Reservation
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: creating DHCP reservcation")
				Throw $_
			}

			# declare action and set repliation required
			Write-Host ("$Hostname,$ComputerName,$Name - ...created DHCP reservation")
		}

		# if router provided...
		If ($PSBoundParameters.ContainsKey('Router') -and $null -ne $Router) {
			# define parameters for Get-DhcpServerv4OptionValue
			$GetDhcpServerv4OptionValue = @{
				ComputerName = $ComputerName
				IPAddress    = $IPAddress
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# retrieve options
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - checking for DHCP option for router...")
				$DhcpServerv4OptionValue = Get-DhcpServerv4OptionValue @GetDhcpServerv4OptionValue
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving DHCP options")
				Throw $_
			}

			# filter DHCP options
			$DhcpServerv4OptionValue = $DhcpServerv4OptionValue | Where-Object { $_.Name -eq 'Router' }

			# if DHPC option exists
			If ($DhcpServerv4OptionValue.Value -eq $Router ) {
				# declare state
				Write-Host ("$Hostname,$ComputerName,$Name - ...existing DHCP option for router found")
			}
			Else {
				# declare state
				Write-Host ("$Hostname,$ComputerName,$Name - ...existing DHCP option for router not found")

				# define parameters for Get-DhcpServerv4OptionValue
				$SetDhcpServerv4OptionValue = @{
					ComputerName = $ComputerName
					IPAddress    = $IPAddress
					Router       = $Router
					ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
				}

				# update options for IP address
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - creating DHCP option for router...")
					Set-DhcpServerv4OptionValue @SetDhcpServerv4OptionValue
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: creating DHCP option for router")
					Throw $_
				}

				# declare action and set repliation required
				Write-Host ("$Hostname,$ComputerName,$Name - ...created DHCP option for router: $Router")
			}
		}

		# define parameters for DHCP reservation
		$GetDhcpServerv4Failover = @{
			ComputerName = $ComputerName
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# check for DHCP failover
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - retrieving DHCP failover for scope...")
			$Failover = Get-DhcpServerv4Failover @GetDhcpServerv4Failover
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving DHCP failover configuration")
			Throw $_
		}

		# check for scope in failover
		If ($Failover -and $Failover.ScopeId -contains $ScopeId) {
			# declare and continue
			Write-Host ("$Hostname,$ComputerName,$Name - ...found DHCP failover for scope")

			# define parameters for Invoke-DhcpServerv4FailoverReplication
			$InvokeDhcpServerv4FailoverReplication = @{
				ComputerName = $ComputerName
				ScopeId      = $ScopeId
				Force        = $true
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# replicate DHCP scope to peer
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - replicating DHCP scope to peer: '$($Failover.PartnerServer)'")
				$null = Invoke-DhcpServerv4FailoverReplication @InvokeDhcpServerv4FailoverReplication
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: replicating DHCP scope")
				Throw $_
			}

			# declare and return
			Write-Host ("$Hostname,$ComputerName,$Name - ...replicated DHCP scope to peer")
			Return
		}
		Else {
			# declare and return
			Write-Host ("$Hostname,$ComputerName,$Name - ...failover configuration not found for scope")
			Return
		}
	}

	Function Add-VMNetworkAdapterToVM {
		[CmdletBinding()]
		Param(
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			# define VMNetworkAdapter parameters
			[Parameter(Mandatory = $true)]
			[string]$NetworkAdapterName,
			[string]$SwitchName,
			[string]$MacAddressSpoofing,
			[string]$AllowTeaming
		)

		# get VM from parameters
		Try {
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			Throw $_
		}

		# define required parameters for Get-VMNetworkAdapter
		$GetVMNetworkAdapter = @{
			VM          = $VM
			Name        = $NetworkAdapterName
			ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
		}

		# retrieve existing adapters with requested values
		Try {
			$VMNetworkAdapter = Get-VMNetworkAdapter @GetVMNetworkAdapter
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VMNetworkAdapters for VM")
			Throw $_
		}

		# if multiple adapters found by name...
		If ($VMNetworkAdapter -is [array]) {
			# declare and remove adapters
			Write-Host ("$Hostname,$ComputerName,$Name - ...found multiple VMNetworkAdapters with name: '$NetworkAdapterName'")

			# processs each array entry and...
			ForEach ($NetworkAdapter in $VMNetworkAdapter) {
				# define parameters for Remove-VMNetworkAdapter
				$RemoveVMNetworkAdapter = @{
					VMNetworkAdapter = $NetworkAdapter
					ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
				}

				# remove VMNetworkAdapter with matching name
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...removing VMNetworkAdapter with ID: '$($NetworkAdapter.Id.Split('\')[-1])'")
					Remove-VMNetworkAdapter @RemoveVMNetworkAdapter
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove VMNetworkAdapter")
					Throw $_
				}
			}

			# clear adapter
			$null = $VMNetworkAdapter
		}

		# if single adapter found by name...
		If ($VMNetworkAdapter -is [Microsoft.HyperV.PowerShell.VMNetworkAdapter]) {
			# declare and begin verifying adapter settings
			Write-Host ("$Hostname,$ComputerName,$Name - ...found VMNetworkAdapter: '$NetworkAdapterName'")

			# if device naming is not enabled...
			If ($VMNetworkAdapter.DeviceNaming -ne 'On') {
				# define parameters for Set-VMNetworkAdapter
				$SetVMNetworkAdapter = @{
					VMNetworkAdapter = $VMNetworkAdapter
					DeviceNaming     = 'On'
					Passthru         = $true
					ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
				}

				# enable device naming on adapter
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...enabling DeviceNaming on VMNetworkAdapter: '$NetworkAdapterName'")
					$VMNetworkAdapter = Set-VMNetworkAdapter @SetVMNetworkAdapter
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set device naming on VMNetworkAdapter for VM")
					Throw $_
				}
			}

			# if SwitchName defined and not correct...
			If ($PSBoundParameters.ContainsKey('SwitchName') -and $VMNetworkAdapter.SwitchName -ne $SwitchName) {
				# define parameters for Connect-VMNetworkAdapter
				$ConnectVMNetworkAdapter = @{
					VMNetworkAdapter = $VMNetworkAdapter
					SwitchName       = $SwitchName
					Passthru         = $true
					ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
				}

				# connect adapter to correct switch
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...connecting VMNetworkAdapter '$NetworkAdapterName' to switch '$SwitchName'")
					$VMNetworkAdapter = Connect-VMNetworkAdapter @ConnectVMNetworkAdapter
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not connect VMNetworkAdapter to switch")
					Throw $_
				}
			}

			# if SwitchName not defined and has a value...
			If ($PSBoundParameters.ContainsKey('SwitchName') -eq $false -and $null -ne $VMNetworkAdapter.SwitchName) {
				# define parameters for Disconnect-VMNetworkAdapter
				$DisconnectVMNetworkAdapter = @{
					VMNetworkAdapter = $VMNetworkAdapter
					Passthru         = $true
					ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
				}

				# disconnect adapter from switch
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...disconnecting VMNetworkAdapter '$NetworkAdapterName' from switch '$($VMNetworkAdapter.SwitchName)'")
					$VMNetworkAdapter = Disconnect-VMNetworkAdapter @DisconnectVMNetworkAdapter
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not disconnect VMNetworkAdapter from switch")
					Throw $_
				}
			}
		}
		# if single adapter not found by name...
		Else {
			# define required parameters for Add-VMNetworkAdapter
			$AddVMNetworkAdapter = @{
				VM           = $VM
				Name         = $NetworkAdapterName
				DeviceNaming = 'On'
				Passthru     = $true
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# define optional parameters for Add-VMNetworkAdapter
			If ($PSBoundParameters['SwitchName']) {
				$AddVMNetworkAdapter['SwitchName'] = $SwitchName
			}

			# add network adapter to VM
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...adding VMNetworkAdapter: '$NetworkAdapterName'")
				$VMNetworkAdapter = Add-VMNetworkAdapter @AddVMNetworkAdapter
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add VMNetworkAdapter to VM")
				Throw $_
			}
		}

		# if MacAddressSpoofing defined and not correct...
		If ($PSBoundParameters.ContainsKey('MacAddressSpoofing') -and $VMNetworkAdapter.MacAddressSpoofing -ne $MacAddressSpoofing) {
			# define required parameters for Set-VMNetworkAdapter
			$SetVMNetworkAdapter = @{
				VMNetworkAdapter   = $VMNetworkAdapter
				MacAddressSpoofing = $MacAddressSpoofing
				Passthru           = $true
				ErrorAction        = [System.Management.Automation.ActionPreference]::Stop
			}

			# update adapter with MacAddressSpoofing setting
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...setting MacAddressSpoofing to '$MacAddressSpoofing' on VMNetworkAdapter: '$NetworkAdapterName'")
				$VMNetworkAdapter = Set-VMNetworkAdapter @SetVMNetworkAdapter
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set MacAddressSpoofing on VMNetworkAdapter for VM")
				Throw $_
			}
		}

		# if AllowTeaming defined and not correct...
		If ($PSBoundParameters.ContainsKey('AllowTeaming') -and $VMNetworkAdapter.AllowTeaming -ne $AllowTeaming) {
			# define parameters for Set-VMNetworkAdapter
			$SetVMNetworkAdapter = @{
				VMNetworkAdapter = $VMNetworkAdapter
				AllowTeaming     = $AllowTeaming
				Passthru         = $true
				ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
			}

			# update adapter with AllowTeaming setting
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...setting AllowTeaming to '$AllowTeaming' on VMNetworkAdapter: '$NetworkAdapterName'")
				$VMNetworkAdapter = Set-VMNetworkAdapter @SetVMNetworkAdapter
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set AllowTeaming on VMNetworkAdapter for VM")
				Throw $_
			}
		}

		# return network adapter
		Return $VMNetworkAdapter
	}

	Function Set-VMNetworkAdapterVlanId {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)][ValidateScript({ $_ -is [Microsoft.HyperV.PowerShell.VMNetworkAdapter] })]
			[object]$VMNetworkAdapter,
			[string]$ComputerName = $VMNetworkAdapter.ComputerName.ToLower(),
			[string]$VlanMode,
			[int32]$VlanId,
			[string]$VlanIdList
		)

		# if VLAN mode is Access...
		If ($VlanMode -eq 'Access') {
			# ...but the VLAN ID is 0...
			If ($VlanId -eq 0) {
				Write-Warning -Message "VlanMode is '$VlanMode' but VlanId is 0; VMNetworkAdapter '$($VMNetworkAdapter.Name)' will be untagged" -WarningAction Inquire
				$VlanMode = 'Untagged'
			}
			# ...but the VLAN ID is null...
			ElseIf ($null -eq $VlanId) {
				Write-Warning -Message "VlanMode is '$VlanMode' but VlanId is null; VMNetworkAdapter '$($VMNetworkAdapter.Name)' will be untagged" -WarningAction Inquire
				$VlanMode = 'Untagged'
			}
		}

		# if VLAN mode is Trunk...
		If ($VlanMode -eq 'Trunk') {
			# ...but VlanId and VlanIdList are null
			If ($null -eq $VlanId -and $null -eq $VlanIdList) {
				Write-Warning -Message "VlanMode is '$VlanMode' but VlanId and VlanIdList are null; VMNetworkAdapter '$($VMNetworkAdapter.Name)' will be untagged" -WarningAction Inquire
				$VlanMode = 'Untagged'
			}
			# ...but VlanId is null
			ElseIf ($null -eq $VlanId) {
				Write-Warning -Message "VlanMode is '$VlanMode' but VlanId is null; VMNetworkAdapter '$($VMNetworkAdapter.Name)' will use VlanId '0' for VlanId" -WarningAction Inquire
				$VlanId = 0
			}
			# ...but VlanIdList is null
			ElseIf ($null -eq $VlanIdList) {
				Write-Warning -Message "VlanMode is '$VlanMode' but VlanIdList is null; VMNetworkAdapter '$($VMNetworkAdapter.Name)' will use VlanId '$VlanId' for VlanId" -WarningAction Inquire
				$VlanIdList = [string]$VlanId
			}
		}

		# if VLAN mode is Access...
		If ($VlanMode -eq 'Isolation') {
			# ...but the VLAN ID is 0...
			If ($VlanId -eq 0) {
				Write-Warning -Message "VlanMode is '$VlanMode' but VlanId is 0; VMNetworkAdapter '$($VMNetworkAdapter.Name)' will be untagged" -WarningAction Inquire
				$VlanMode = 'Untagged'
			}
			# ...but the VLAN ID is null...
			ElseIf ($null -eq $VlanId) {
				Write-Warning -Message "VlanMode is '$VlanMode' but VlanId is null; VMNetworkAdapter '$($VMNetworkAdapter.Name)' will be untagged" -WarningAction Inquire
				$VlanMode = 'Untagged'
			}
		}


		# get VLAN for network adapter
		Try {
			$VMNetworkAdapterVlan = Get-VMNetworkAdapterVlan -VMNetworkAdapter $VMNetworkAdapter
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VLAN for VMNetworkAdapter")
			Throw $_
		}

		# if VLAN is null or mode is Isolation...
		If ($VlanMode -eq 'Untagged' -or $VlanMode -eq 'Isolation') {
			# ...and VLAN mode not untagged...
			If ($VMNetworkAdapterVlan.OperationMode -ne 'Untagged') {
				# define string for Write-Host
				$SetVMNetworkAdapterVlanAnnounce = "...setting VLAN to 'Untagged'"
				# define parameters for function
				$SetVMNetworkAdapterVlan = @{
					VMNetworkAdapter = $VMNetworkAdapter
					Untagged         = $true
					Passthru         = $true
					ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
				}
			}
		}
		# if VLAN list is not null and mode is Trunk...
		ElseIf ($VlanMode -eq 'Trunk') {
			# ...and VLAN mode is not access or not VLAN list is not requested VLANs...
			If ($VMNetworkAdapterVlan.OperationMode -ne 'Trunk' -or $VMNetworkAdapterVlan.NativeVlanId -ne $VlanId -or $VMNetworkAdapter.AllowedVlanIdListString -ne $VlanIdList) {
				# define string for Write-Host
				$SetVMNetworkAdapterVlanAnnounce = "...setting VLAN to 'Trunk' with native VLAN ID '$VlanId' and VLAN list '$VlanIdList'"
				# define parameters for Set-VMNetworkAdapterVlan
				$SetVMNetworkAdapterVlan = @{
					VMNetworkAdapter  = $VMNetworkAdapter
					Trunk             = $true
					NativeVlanId      = $VlanId
					AllowedVlanIdList = $VlanIdList
					Passthru          = $true
					ErrorAction       = [System.Management.Automation.ActionPreference]::Stop
				}
			}
		}
		# if VLAN is not null and mode is not Trunk...
		Else {
			# ...and VLAN mode is not access or not VLAN list is not requested VLANs...
			If ($VMNetworkAdapterVlan.OperationMode -ne 'Access' -or $VMNetworkAdapterVlan.AccessVlanId -ne $VlanId) {
				# define string for Write-Host
				$SetVMNetworkAdapterVlanAnnounce = "...setting VLAN to 'Access' with access VLAN ID '$VlanId'"
				# define parameters for Set-VMNetworkAdapterVlan
				$SetVMNetworkAdapterVlan = @{
					VMNetworkAdapter = $VMNetworkAdapter
					Access           = $true
					AccessVlanId     = $VlanId
					Passthru         = $true
					ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
				}
			}
		}

		# if parameters defined...
		If ($null -ne $SetVMNetworkAdapterVlan) {
			# ...set VLAN for VMNetworkAdapter
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - $SetVMNetworkAdapterVlanAnnounce")
				$VMNetworkAdapterVlan = Set-VMNetworkAdapterVlan @SetVMNetworkAdapterVlan
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set VLAN for VMNetworkAdapter")
				Throw $_
			}
			# refresh VMNetworkAdapter
			$VMNetworkAdapter = $VMNetworkAdapterVlan.ParentAdapter
		}

		# get Isolation for network adapter
		Try {
			$VMNetworkAdapterIsolation = Get-VMNetworkAdapterIsolation -VMNetworkAdapter $VMNetworkAdapter
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve Isolation for VMNetworkAdapter")
			Throw $_
		}

		# if VlanMode is Isolation...
		If ($VlanMode -eq 'Isolation') {
			If ($null -eq $VlanId -or $VlanId -eq 0) {
				If ($VMNetworkAdapterIsolation.IsolationMode -ne 'Vlan' -or $VMNetworkAdapterIsolation.AllowUntaggedTraffic -eq $true -or $VMNetworkAdapterIsolation.DefaultIsolationID -ne 0) {
					# define string for Write-Host
					$SetVMNetworkAdapterIsolationAnnounce = '...setting isolation mode to VLAN; untagged traffic will be dropped'
					# define parameters for Set-VMNetworkAdapterIsolation
					$SetVMNetworkAdapterIsolation = @{
						VMNetworkAdapter     = $VMNetworkAdapter
						IsolationMode        = 'Vlan'
						AllowUntaggedTraffic = $false
						ErrorAction          = [System.Management.Automation.ActionPreference]::Stop
					}
				}
			}
			Else {
				If ($VMNetworkAdapterIsolation.IsolationMode -ne 'Vlan' -or $VMNetworkAdapterIsolation.AllowUntaggedTraffic -eq $false -or $VMNetworkAdapterIsolation.DefaultIsolationID -ne $VlanId) {
					# define string for Write-Host
					$SetVMNetworkAdapterIsolationAnnounce = "...setting isolation mode to VLAN; untagged traffic will be tagged to VLAN '$VlanId'"
					# define parameters for Set-VMNetworkAdapterIsolation
					$SetVMNetworkAdapterIsolation = @{
						VMNetworkAdapter     = $VMNetworkAdapter
						IsolationMode        = 'Vlan'
						AllowUntaggedTraffic = $true
						DefaultIsolationID   = $VlanId
						ErrorAction          = [System.Management.Automation.ActionPreference]::Stop
					}
				}
			}
		}
		Else {
			If ($VMNetworkAdapterIsolation.IsolationMode -ne 'None') {
				# define string for Write-Host
				$SetVMNetworkAdapterIsolationAnnounce = '...setting isolation mode to None'
				# define parameters for Set-VMNetworkAdapterIsolation
				$SetVMNetworkAdapterIsolation = @{
					VMNetworkAdapter = $VMNetworkAdapter
					IsolationMode    = 'None'
					ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
				}
			}
		}

		# if parameters defined...
		If ($null -ne $SetVMNetworkAdapterIsolation) {
			# ...set Isolation for VMNetworkAdapter
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - $SetVMNetworkAdapterIsolationAnnounce")
				Set-VMNetworkAdapterIsolation @SetVMNetworkAdapterIsolation
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set VLAN for VMNetworkAdapter")
				Throw $_
			}

			# refresh VMNetworkAdapter
			$VMNetworkAdapter = $VMNetworkAdapterVlan.ParentAdapter
		}

		# check if priority tag needs to be enabled
		If ($VlanMode -eq 'Isolation' -and $VMNetworkAdapter.IeeePriorityTag -eq 'Off') {
			# define string for Write-Host
			$SetVMNetworkAdapterAnnounce = "...setting IeeePriorityTag mode to 'On'"
			# define parameters for Set-VMNetworkAdapter
			$SetVMNetworkAdapter = @{
				VMNetworkAdapter = $VMNetworkAdapter
				IeeePriorityTag  = 'On'
				Passthru         = $true
				ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
			}
		}

		# check if priority tag needs to be disabled
		If ($VlanMode -ne 'Isolation' -and $VMNetworkAdapter.IeeePriorityTag -eq 'On') {
			# define string for Write-Host
			$SetVMNetworkAdapterAnnounce = "...setting IeeePriorityTag mode to 'Off'"
			# define parameters for Set-VMNetworkAdapter
			$SetVMNetworkAdapter = @{
				VMNetworkAdapter = $VMNetworkAdapter
				IeeePriorityTag  = 'Off'
				Passthru         = $true
				ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
			}
		}

		# if parameters defined...
		If ($null -ne $SetVMNetworkAdapter) {
			# ...set Isolation for VMNetworkAdapter
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - $SetVMNetworkAdapterAnnounce")
				$VMNetworkAdapter = Set-VMNetworkAdapter @SetVMNetworkAdapter
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set IeeePriorityTag for VMNetworkAdapter")
				Throw $_
			}
		}

		# return VMNetworkAdapter after VLAN update
		Return $VMNetworkAdapter
	}

	Function Set-VMNetworkAdapterMacAddress {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)][ValidateScript({ $_ -is [Microsoft.HyperV.PowerShell.VMNetworkAdapter] })]
			[object]$VMNetworkAdapter,
			[string]$ComputerName = $VMNetworkAdapter.ComputerName.ToLower(),
			[string]$IPAddress,
			[string]$MacAddress,
			[string]$MacAddressPrefix
		)

		# report state
		Write-Host ("$Hostname,$ComputerName,$Name - checking MAC address on VMNetworkAdapter...")

		# if MAC address was provided...
		If ($PSBoundParameters['MacAddress']) {
			# declare provided MAC address
			Write-Host ("$Hostname,$ComputerName,$Name - ...using MAC address from parameter")
			# assign provided MAC address
			$StaticMacAddress = $MacAddress
		}
		# if MAC address was provided via prefix and IP address...
		ElseIf ($PSBoundParameters['IPAddress'] -and $PSBoundParameters['MacAddressPrefix']) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...creating MAC address from parameters")
			# create MAC address suffix by converting IPAddress octets to hexadecimal
			$MacAddressSuffix = ($IPAddress.Split('.') | ForEach-Object { ([int]$_).ToString('X2') }) -join $null
			# assign MAC address from prefix and suffix
			$StaticMacAddress = ($MacAddressPrefix, $MacAddressSuffix) -join $null
		}
		# if MAC address was not provided and VMNetworkAdapter has default MAC address
		ElseIf ($VMNetworkAdapter.MacAddress -eq '000000000000') {
			# retrieve MAC address from host
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...retrieving next MAC address from host")
				$StaticMacAddress = Get-VMHostNextMacAddress -ComputerName $ComputerName
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve next MAC address from host")
				Throw $_
			}
		}
		# if MAC address was not provided and VMNetworkAdapter has non-default MAC address
		Else {
			Write-Host ("$Hostname,$ComputerName,$Name - ...using existing MAC address: '$($VMNetworkAdapter.MacAddress)'")
			Return $VMNetworkAdapter
		}

		# if static MAC addresss not defined or matches existing MAC address...
		If ($null -eq $StaticMacAddress -or $VMNetworkAdapter.MacAddress -eq $StaticMacAddress) {
			# ...return
			Write-Host ("$Hostname,$ComputerName,$Name - ...verified MAC address: '$($VMNetworkAdapter.MacAddress)'")
			Return $VMNetworkAdapter
		}
		Else {
			# force MAC address to uppercase
			$StaticMacAddress = $StaticMacAddress.ToUpper()
		}

		# define parameters for Set-VMNetworkAdapter
		$SetVMNetworkAdapter = @{
			VMNetworkAdapter = $VMNetworkAdapter
			StaticMacAddress = $StaticMacAddress
			Passthru         = $true
			ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
		}

		# set static MAC addresss on VMNetworkAdapter
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...setting MAC address to: '$StaticMacAddress'")
			$VMNetworkAdapter = Set-VMNetworkAdapter @SetVMNetworkAdapter
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set MAC address")
			Throw $_
		}

		# return updated VMNetworkAdapter
		Return $VMNetworkAdapter
	}

	Function Set-VMSecuritySettings {
		[CmdletBinding()]
		Param(
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower()
		)

		# get VM from parameters
		Try {
			# cast return as type to force terminating error
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			Throw $_
		}

		# define parameters for Get-VMKeyProtector
		$GetVMKeyProtector = @{
			VM          = $VM
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# get key protector
		Try {
			$VMKeyProtector = Get-VMKeyProtector @GetVMKeyProtector
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM key protector")
			Throw $_
		}

		# define parameters for ConvertTo-HgsKeyProtector
		$ConvertToHgsKeyProtector = @{
			Bytes       = $VMKeyProtector
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# test key protector
		Try {
			$null = ConvertTo-HgsKeyProtector @ConvertToHgsKeyProtector
			Write-Host ("$Hostname,$ComputerName,$Name - ...found VM key protector")
		}
		Catch {
			# define parameters for Set-VMKeyProtector
			$SetVMKeyProtector = @{
				VM                   = $VM
				NewLocalKeyProtector = $true
				ErrorAction          = [System.Management.Automation.ActionPreference]::Stop
			}

			# set key protector
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...creating key protector for VM")
				Set-VMKeyProtector @SetVMKeyProtector
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not create VM key protector")
				Throw $_
			}
		}

		# define arguments for virtual TPM
		$EnableVMTPM = @{
			VM          = $VM
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# enable virtual TPM
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...enabling virtual TPM")
			Enable-VMTPM @EnableVMTPM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not enable virtual TPM")
			Throw $_
		}
	}

	Function Set-VMSystemSettings {
		[CmdletBinding()]
		Param(
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			# define system settings parameters
			[hashtable]$SystemSettings
		)

		# get VM from parameters
		Try {
			# cast return as type to force terminating error
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			Throw $_
		}

		# define CIM instance for VM system settings
		$GetCimInstanceForVM = @{
			VM          = $VM
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve original VM system settings and host management service via CIM
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...retrieving CIM instance for VM...")
			$CimInstanceForVM = Get-CimInstanceForVM @GetCimInstanceForVM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve CIM instance for VM")
			Throw $_
		}

		# define counter for changes
		$SystemSettingsCounter = [int32]0

		# modify VM system settings
		ForEach ($SystemSetting in $SystemSettings.Keys) {
			If ($CimInstanceForVM.$SystemSetting -eq $SystemSettings[$SystemSetting]) {
				Write-Host ("$Hostname,$ComputerName,$Name - ...found '$SystemSetting' set to '$($SystemSettings[$SystemSetting])'")
			}
			Else {
				Write-Host ("$Hostname,$ComputerName,$Name - ...updating '$SystemSetting' from '$($CimInstanceForVM.$SystemSetting)' to '$($SystemSettings[$SystemSetting])'")
				$CimInstanceForVM.$SystemSetting = $SystemSettings[$SystemSetting]
				$SystemSettingsCounter++
			}
		}

		# check counter for changes
		If ($SystemSettingsCounter -eq 0) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...existing firmware settings match requested settings")
			Return
		}

		# serialize and encode VM system settings
		Try {
			$CimSerializer = [Microsoft.Management.Infrastructure.Serialization.CimSerializer]::Create()
			$CimSerialized = $CimSerializer.Serialize($CimInstanceForVM, [Microsoft.Management.Infrastructure.Serialization.InstanceSerializationOptions]::None)
			$CimEncodedData = [System.Text.Encoding]::Unicode.GetString($CimSerialized)
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not serialize the CIM objects for VM firmware")
			Throw $_
		}

		# define CIM instance for VM management service
		$GetCimInstanceForVMMS = @{
			ComputerName = $ComputerName
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve CIM instance for host management service
		Write-Host ("$Hostname,$ComputerName,$Name - ...retrieving CIM instance for VM management service")
		Try {
			$CimInstanceForVMMS = Get-CimInstanceForVMMS @GetCimInstanceForVMMS
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve CIM instance for VM management service")
			Throw $_
		}

		# define CIM method for host management service
		$InvokeCimMethod = @{
			CimInstance = $CimInstanceForVMMS
			MethodName  = 'ModifySystemSettings'
			Arguments   = @{ SystemSettings = $CimEncodedData }
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# invoke CIM method on host management service to update VM system settings with modified values
		Write-Host ("$Hostname,$ComputerName,$Name - updating firmware settings via CIM...")
		Try {
			$CimMethod = Invoke-CimMethod @InvokeCimMethod
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not call method to update firmware settings via CIM")
			Throw $_
		}

		# check CIM return value
		If ($CimMethod.ReturnValue -eq 0) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...firmware settings updated...")
		}
		Else {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: firmware settings not updated, CIM returned: '$($CimMethod.ReturnValue)'")
		}
	}

	Function Add-VHDFromParams {
		[CmdletBinding()]
		Param(
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			# define VHD parameters
			[Parameter(Mandatory = $true)]
			[string]$Path,
			[int32]$ControllerNumber = [int32]0,
			[int32]$ControllerLocation,
			[switch]$PreserveDrives
		)

		# get VM from parameters
		Try {
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			Throw $_
		}

		# if scsi controller with requested number does not exist on VM...
		While ($null -eq (Get-VMScsiController -VM $VM -ControllerNumber $ControllerNumber)) {
			# ...create scsi controller on VM
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - adding VMScsiController to VM")
				Add-VMScsiController -VM $VM -ErrorAction Stop
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add VMScsiController to VM")
				Throw $_
			}
		}

		# define required parameters for Get-VMHardDiskDrive
		$GetVMHardDiskDrive = @{
			VM               = $VM
			ControllerNumber = $ControllerNumber
			ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
		}

		# define optional parameters for Get-VMHardDiskDrive
		If ($PSBoundParameters['ControllerLocation']) {
			$GetVMHardDiskDrive['ControllerLocation'] = $ControllerLocation
		}

		# get all drives with matching parameters
		Try {
			$VMHardDiskDrives = Get-VMHardDiskDrive @GetVMHardDiskDrive
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VMHardDiskDrives from VM")
			Throw $_
		}

		# if path found on drives...
		If ($Path -in $VMHardDiskDrives.Path) {
			# ...return
			Return
		}

		# retrieve existing drives
		Try {
			$VMHardDiskDrives = Get-VMHardDiskDrive -VM $VM -ErrorAction Stop
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VMHardDiskDrives from VM")
			Throw $_
		}

		# remove requested drive from other locations
		If ($PSBoundParameters['ControllerNumber']) {
			# ...get existing drives with requested path not on requested controller
			$VMHardDiskDrivesWithPath = $VMHardDiskDrives | Where-Object { $_.Path -eq $Path -and $_.ControllerNumber -ne $ControllerNumber }
			# if existing drives exists...
			ForEach ($VMHardDiskDrive in $VMHardDiskDrivesWithPath) {
				# ...remove drives from VM
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...removing requested VMHardDiskDrive from unexpected controller on VM")
					Remove-VMHardDiskDrive -VMHardDiskDrive $VMHardDiskDrive -ErrorAction Stop
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove errant VMHardDiskDrive from VM")
					Throw $_
				}
			}
		}

		# remove other drives from requested location
		If ($PSBoundParameters['ControllerLocation']) {
			# ...get existing drives without requested path on requested controller and requested location
			$VMHardDiskDrivesSansPath = $VMHardDiskDrives | Where-Object { $_.Path -ne $Path -and $_.ControllerNumber -eq $ControllerNumber -and $_.ControllerLocation -eq $ControllerLocation }
			# if existing drives exists...
			ForEach ($VMHardDiskDrive in $VMHardDiskDrivesSansPath) {
				# ...remove drives from VM
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...removing unexpected VMHardDiskDrive from requested controller location and number on VM")
					Remove-VMHardDiskDrive -VMHardDiskDrive $VMHardDiskDrive -ErrorAction Stop
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove VMHardDiskDrive from VM")
					Throw $_
				}
			}
		}

		# define arguments for drive
		$AddVMHardDiskDrive = @{
			VM               = $VM
			Path             = $Path
			ControllerNumber = $ControllerNumber
			ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
		}

		# define optional arguments for drive
		If ($PSBoundParameters['ControllerLocation']) {
			$AddVMHardDiskDrive['ControllerLocation'] = $ControllerLocation
		}

		# add requested drive to requested location
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...adding VMHardDiskDrive to VM with path: '$Path'")
			Add-VMHardDiskDrive @AddVMHardDiskDrive
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add VMHardDiskDrive to VM")
			Throw $_
		}

		# if preserve drives requested...
		If ($PreserveDrives) {
			# ...restore removed drives
			ForEach ($VMHardDiskDrive in $VMHardDiskDrivesSansPath) {
				# define path and controller number of drive
				$AddVMHardDiskDrive = @{
					VM               = $VM
					Path             = $VMHardDiskDrive.Path
					ControllerNumber = $VMHardDiskDrive.ControllerNumber
					ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
				}
				# add drive to VM
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...restoring VMHardDiskDrive to VM with path: '$($VMHardDiskDrive.Path)'")
					Add-VMHardDiskDrive @AddVMHardDiskDrive
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not restore VMHardDiskDrive to VM")
					Throw $_
				}
			}
		}
	}

	Function Copy-VHDFromParams {
		Param (
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			[string]$VMName = $VM.Name.ToLower(),
			# define OSD parameters
			[Parameter(Mandatory)]
			[string]$Path,
			[uint16]$ControllerNumber = 0,
			[uint16]$ControllerLocation = 0,
			[string]$UnattendFile,
			[string]$Domainname,
			[string]$OrganizationalUnit
		)

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		Catch {
			Throw $_
		}

		# get VM from parameters
		Try {
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			Throw $_
		}

		# update argument list for Test-Path
		$InvokeCommand['ArgumentList']['Path'] = $Path

		# test deployment path
		Try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				$TestPath = @{
					Path        = $ArgumentList['Path']
					PathType    = [Microsoft.PowerShell.Commands.TestPathType]::Leaf
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				Test-Path @TestPath
			}
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not check provided path")
			Throw $_
		}

		# evaluate deployment path
		If ($TestPath) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...found source VHD: $Path")
		}
		Else {
			Write-Host ("$Hostname,$ComputerName,$Name - ...skipping VHD attach, host did not find file: '$Path'")
			Return
		}

		# retrieve path to hard drive with provided controller number and location
		$VhdPath = $VM.HardDrives.Where({ $_.ControllerNumber -eq $ControllerNumber -and $_.ControllerLocation -eq $ControllerLocation }).Path

		# evaluate path to hard drive with provided controller number and location
		If ([System.String]::IsNullOrEmpty($VhdPath)) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...skipping VHD copy, could not locate VHD on controller $ControllerNumber at LUN $ControllerLocation")
			Return
		}
		Else {
			Write-Host ("$Hostname,$ComputerName,$Name - ...found target VHD: $VhdPath")
		}

		# update argument list for Get-Item
		$InvokeCommand['ArgumentList']['Path'] = $VhdPath

		# retrieve first hard drive
		Try {
			$GetItem = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				$GetItem = @{
					Path        = $ArgumentList['Path']
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				Get-Item @GetItem
			}
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve first VHD in boot order: '$VhdPath'")
			Throw $_
		}

		# evaluate first hard drive
		If ($GetItem.Length -gt 4MB) {
			Write-Warning ("$Hostname,$ComputerName,$Name - found VHD larger than expected: '$(Format-Bytes -Size $GetItem.Length)'")
			Write-Warning ("$Hostname,$ComputerName,$Name - replace VHD?") -WarningAction Inquire
		}

		# update argument list for Copy-Item
		$InvokeCommand['ArgumentList']['Path'] = $Path
		$InvokeCommand['ArgumentList']['Destination'] = $VhdPath

		# copy deployment path to VHD
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...copying source VHD")
			$CopyItem = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				$CopyItem = @{
					Path        = $ArgumentList['Path']
					Destination = $ArgumentList['Destination']
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				Copy-Item @CopyItem
			}
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not copy VHD from provided path to destination: '$Destination'")
			Throw $_
		}

		# update argument list for Get-ACL
		$InvokeCommand['ArgumentList']['Path'] = $VhdPath
		$InvokeCommand['ArgumentList']['VMId'] = $VM.Id
		$InvokeCommand['ArgumentList'].Remove('Destination')

		# update permissions
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...updating target VHD ACL")
			Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				# import parameters for VMId
				$VMId = $ArgumentList['VMId']
				# define parameters for Get-Acl
				$GetAcl = @{
					Path        = $ArgumentList['Path']
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				# retrieve ACL
				$Acl = Get-Acl @GetAcl
				# define VM prinicpal
				$VMPrincipal = [System.Security.Principal.NTAccount]::new("NT VIRTUAL MACHINE\$($VMId)")
				# create access rule
				$AccessRule = [System.Security.AccessControl.FileSystemAccessRule]::new($VMPrincipal, @('Read', 'Write', 'Synchronize'), 'None', 'None', 'Allow')
				# add access rule to ACL
				$Acl.AddAccessRule($AccessRule)
				# define parameters for Set-Acl
				$SetAcl = @{
					Acl         = $Acl
					Path        = $ArgumentList['Path']
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				# update ACL
				Set-Acl @SetAcl
			}
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not update ACL for VHD: '$Destination'")
			Throw $_
		}

		# if deployment file not provided...
		If (!$PSBoundParameters.ContainsKey('UnattendFile')) {
			Return
		}

		# update argument list for Test-Path
		$InvokeCommand['ArgumentList']['Path'] = $UnattendFile

		# test deployment file
		Try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				$TestPath = @{
					Path        = $ArgumentList['Path']
					PathType    = [Microsoft.PowerShell.Commands.TestPathType]::Leaf
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				Test-Path @TestPath
			}
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not check provided path")
			Throw $_
		}

		# evaluate deployment file
		If (-not $TestPath) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...skipping target VHD update, host did not find unattend file: '$UnattendFile'")
			Return
		}

		# update argument list for Mount-VHD
		$InvokeCommand['ArgumentList']['Path'] = $VhdPath

		# mount VHD
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...mounting target VHD")
			$DriveLetter = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				$MountVHD = @{
					Path        = $ArgumentList['Path']
					Passthru    = $true
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				Mount-VHD @MountVHD | Get-Disk | Get-Partition | Get-Volume | Select-Object -ExpandProperty 'DriveLetter'
			}
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not mount target VHD: '$($_.Exception.Message)'")
			Throw $_
		}

		# evaluate deployment path
		If (-not $DriveLetter) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...skipping VHD attach, could not mount target VHD: '$Destination'")
			Return
		}

		# define unattend file on VHD
		$UnattendFileOnVHD = '{0}:\Windows\Panther\unattend.xml' -f $DriveLetter

		# update argument list for Copy-Item with unattend files on VHD
		$InvokeCommand['ArgumentList']['Path'] = $UnattendFile
		$InvokeCommand['ArgumentList']['Destination'] = $UnattendFileOnVHD

		# copy file to VHD
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...updating target VHD with unattend file: '$UnattendFile'")
			Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				$CopyItem = @{
					Path        = $ArgumentList['Path']
					Destination = $ArgumentList['Destination']
					Force       = $true
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				Copy-Item @CopyItem
			}
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not copy file: '$UnattendFile'")
			Throw $_
		}

		# update argument list for Get-Content and Set-Content
		$InvokeCommand['ArgumentList']['Path'] = $UnattendFileOnVHD

		# define hashtable for unattend expand strings
		$UnattendExpandStrings = @{ 'COMPUTERNAME' = $VMName.Split('.')[0] }

		# if LocalAdminCredential provided...
		If ($script:PSBoundParameters.ContainsKey('LocalAdminCredential')) {
			# append required string to plaintext password
			$AdministratorPasswordAppended = '{0}AdministratorPassword' -f $script:LocalAdminCredential.GetNetworkCredential().Password

			# encode appended password to base64
			$AdministratorPasswordAsBase64 = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($AdministratorPasswordAppended))

			# add encoded password to hashtable
			$UnattendExpandStrings['ADMINISTRATORPASSWORD'] = $AdministratorPasswordAsBase64
		}

		# if DomainJoinCredential provided...
		If ($script:PSBoundParameters.ContainsKey('DomainJoinCredential')) {
			$UnattendExpandStrings['USERNAME'] = $script:DomainJoinCredential.GetNetworkCredential().Username
			$UnattendExpandStrings['PASSWORD'] = $script:DomainJoinCredential.GetNetworkCredential().Password
		}

		# if DomainName provided...
		If ($PSBoundParameters.ContainsKey('DomainName')) {
			$UnattendExpandStrings['DOMAINNAME'] = $DomainName
		}

		# if OrganizationalUnit provided...
		If ($PSBoundParameters.ContainsKey('OrganizationalUnit')) {
			$UnattendExpandStrings['ORGANIZATIONALUNIT'] = $OrganizationalUnit
		}

		# update argument list with expand strings
		$InvokeCommand['ArgumentList']['Name'] = $Name
		$InvokeCommand['ArgumentList']['Hostname'] = $HostName
		$InvokeCommand['ArgumentList']['ComputerName'] = $ComputerName
		$InvokeCommand['ArgumentList']['UnattendExpandStrings'] = $UnattendExpandStrings

		# update file on VHD
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...replacing values in unattend file")
			Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)

				# get variables from arguments
				$Path = $ArgumentList['Path']
				$Name = $ArgumentList['Name']
				$HostName = $ArgumentList['HostName']
				$ComputerName = $ArgumentList['ComputerName']
				$UnattendExpandStrings = $ArgumentList['UnattendExpandStrings']

				# get contents of unattend file
				Try {
					$Content = Get-Content -Path $Path -Raw
				}
				Catch {
					Return $_
				}

				# if administrator password provided...
				If ($UnattendExpandStrings.ContainsKey('AdministratorPassword')) {
					$Content = $Content -replace '<!-- <AdministratorPassword>', '<AdministratorPassword>'
					$Content = $Content -replace '</AdministratorPassword> -->', '</AdministratorPassword>'
				}

				# while content contains XML element with expand string as value...
				While ($Content -match '<\w+>%(?<ExpandString>\w+)%</\w+>') {
					# retrieve original XML element
					$OriginalString = $Matches[0]
					# retrieve expand string
					$ExpandString = $Matches['ExpandString']
					# if value for expand string provided...
					If ($UnattendExpandStrings.ContainsKey($ExpandString)) {
						# replace the expand string with the provided value
						$ModifiedString = $OriginalString -replace "%$ExpandString%", $UnattendExpandStrings[$ExpandString]

						# report state
						Write-Host ("$Hostname,$ComputerName,$Name - ...replaced value in unattend file: '$ExpandString'")
					}
					Else {
						# comment out the original XML element
						$ModifiedString = '<!-- {0} -->' -f ($OriginalString -replace '%')

						Write-Host ("$Hostname,$ComputerName,$Name - ...disabled value in unattend file: '$ExpandString'")
					}
					# replace original XML element with modified XML element
					$Content = $Content -replace $OriginalString, $ModifiedString
				}

				# add unattend file to ISO
				Try {
					$Content | Set-Content -Path $Path
				}
				Catch {
					Return $_
				}
			}
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not update file: '$UnattendFile'")
			Throw $_
		}

		# update argument list for Dismount-VHD
		$InvokeCommand['ArgumentList']['Path'] = $VhdPath

		# dismount VHD
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...dismounting target VHD after updates")
			Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				$DismountVHD = @{
					Path        = $ArgumentList['Path']
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				Dismount-VHD @DismountVHD
			}
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not dismount target VHD: '$($_.Exception.Message)'")
			Throw $_
		}
	}

	Function New-VHDFromParams {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[Parameter(Mandatory = $true)]
			[string]$Path,
			[Parameter(Mandatory = $true)]
			[uint64]$SizeBytes
		)

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		Catch {
			Throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['Path'] = $Path

		# get parent path
		Try {
			Write-Verbose ("$Hostname,$ComputerName,$Name - getting parent path for VHD")
			$ParentPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				Split-Path -Path $ArgumentList['Path'] -Parent -ErrorAction Stop
			}
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not get parent path")
			Throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['ParentPath'] = $ParentPath

		# verify parent path
		Try {
			Write-Verbose ("$Hostname,$ComputerName,$Name - testing parent path for VHD")
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				Test-Path -Path $ArgumentList['ParentPath'] -PathType Container -ErrorAction Stop
			}
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not test parent path")
			Throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['TestPath'] = $TestPath

		# verify parent path
		Try {
			Write-Verbose ("$Hostname,$ComputerName,$Name - verifying parent path for VHD")
			Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				If (-not $ArgumentList['TestPath']) {
					$null = New-Item -Path $ArgumentList['ParentPath'] -ItemType 'Directory' -ErrorAction Stop
				}
			}
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not verify parent path")
			Throw $_
		}

		# define arguments for Get-VHD
		$GetVHD = @{
			ComputerName = $ComputerName
			Path         = $Path
			ErrorAction  = [System.Management.Automation.ActionPreference]::SilentlyContinue
		}

		# get existing VHD
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - checking for VHD with Path: '$Path'")
			$VHD = Get-VHD @GetVHD
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not get VHD")
			Throw $_
		}

		# if VHD found...
		If ($null -ne $VHD) {
			# report VHD found
			Write-Host ("$Hostname,$ComputerName,$Name - ...found existing VHD with Path: '$Path'")
			# if use existing VHDs not provided...
			If (!$UseExistingDisks) {
				# warn and inquire
				Write-Warning -Message ("$Hostname,$ComputerName,$Name - continue and use existing VHD?") -WarningAction Inquire
			}
			# return
			Return
		}

		# define arguments for New-VHD
		$NewVHD = @{
			ComputerName = $ComputerName
			Path         = $Path
			SizeBytes    = $SizeBytes
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# create the VHD
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - creating VHD with Path: '$Path'")
			$null = New-VHD @NewVHD
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not create VHD")
			Throw $_
		}
	}

	Function New-VmFromParams {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory)]
			[string]$ComputerName,
			[Parameter(Mandatory)]
			[string]$Name,
			[Parameter(Mandatory)]
			[string]$Path,
			[ValidateRange(1, 256)]
			[uint16]$ProcessorCount = 2,
			[ValidateScript({ ($_ -ge 32MB) -and ($_ -le 12TB) })]
			[uint64]$MemoryStartupBytes = 2GB,
			[ValidateScript({ ($_ -ge 32MB) -and ($_ -le 12TB) })]
			[uint64]$MemoryMinimumBytes,
			[ValidateScript({ ($_ -ge 32MB) -and ($_ -le 12TB) })]
			[uint64]$MemoryMaximumBytes,
			[switch]$EnableVMTPM,
			[switch]$DisableSMT,
			[uint16]$Generation = 2
		)

		# verify path
		Write-Host ("$Hostname,$ComputerName,$Name - verifying paths...")
		If ($UseDefaultPathOnHost) {
			Try {
				$Path = Get-VMHost -ComputerName $ComputerName | Select-Object -ExpandProperty 'VirtualMachinePath'
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VirtualMachinePath on host")
				Throw $_
			}
			Write-Host ("$Hostname,$ComputerName,$Name - ...using default VM path: '$Path")
		}
		Else {
			Write-Host ("$Hostname,$ComputerName,$Name - ...using provided VM path: '$Path'")
		}

		# define parameters for VM
		$NewVM = @{
			ComputerName       = $ComputerName
			Name               = $Name
			Path               = $Path
			MemoryStartupBytes = $MemoryStartupBytes
			Generation         = $Generation
			ErrorAction        = [System.Management.Automation.ActionPreference]::Stop
		}

		# create VM
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - creating VM...")
			$VM = New-VM @NewVM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not create VM")
			Throw $_
		}

		# remove default network adapter
		Try {
			Get-VMNetworkAdapter -VM $VM | Remove-VMNetworkAdapter -Confirm:$false
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove initial VMNetworkAdapter")
			Throw $_
		}

		# define parameters for integration services
		$EnableVMIntegrationService = @{
			VM          = $VM
			Name        = 'Guest Service Interface'
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# enable integration services
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...enabling guest services")
			Enable-VMIntegrationService @EnableVMIntegrationService
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not enable guest services")
			Throw $_
		}

		# define parameters for VM processor
		$SetVMProcessor = @{
			VM                             = $VM
			Count                          = $ProcessorCount
			ExposeVirtualizationExtensions = $true
			ErrorAction                    = [System.Management.Automation.ActionPreference]::Stop
		}

		# if SMT should be disabled...
		If ($DisableSMT) {
			$SetVMProcessor['HwThreadCountPerCore'] = 1
		}

		# configure VM processor
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...configuring processor")
			Set-VMProcessor @SetVMProcessor
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not configure processor")
			Throw $_
		}

		# validate minimum memory
		If ($null -ne $MemoryMinimumBytes -and $MemoryMinimumBytes -gt 0 -and $MemoryMinimumBytes -gt $MemoryStartupBytes) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...overriding MemoryMinimumBytes; provided value is not less than or equal to MemoryStartupBytes")
			$MemoryMinimumBytes = $MemoryStartupBytes
		}

		# validate maximum memory
		If ($null -ne $MemoryMaximumBytes -and $MemoryMaximumBytes -gt 0 -and $MemoryMaximumBytes -lt $MemoryStartupBytes) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...overriding MemoryMaximumBytes; provided value is not greater than or equal to MemoryStartupBytes")
			$MemoryMaximumBytes = $MemoryStartupBytes
		}

		# configure memory
		If ($MemoryMinimumBytes -and $MemoryMaximumBytes) {
			# define string for reporting
			$MemoryValues = (Format-Bytes -Size $MemoryStartupBytes), (Format-Bytes -Size $MemoryMinimumBytes), (Format-Bytes -Size $MemoryMaximumBytes) -join ', '

			# define arguments for dynamic memory
			$SetVMMemory = @{
				VM                   = $VM
				StartupBytes         = $MemoryStartupBytes
				MinimumBytes         = $MemoryMinimumBytes
				MaximumBytes         = $MemoryMaximumBytes
				DynamicMemoryEnabled = $true
				ErrorAction          = [System.Management.Automation.ActionPreference]::Stop
			}

			# configure dynamic memory
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...enabling dynamic memory (start, min, max): $MemoryValues")
				Set-VMMemory @SetVMMemory
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set dynamic memory (start, min, max): $MemoryValues")
				Throw $_
			}
		}

		# if virtual TPM requested...
		If ($EnableVMTPM) {
			# define arguments for VM security settings
			$SetVMSecuritySettings = @{
				VM = $VM
			}

			# set VM security settings
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - updating security settings...")
				Set-VMSecuritySettings @SetVMSecuritySettings
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not update security settings")
				Throw $_
			}
		}

		# define parameters for VM system settings
		$SetVMSystemSettings = @{
			VM             = $VM
			SystemSettings = @{
				BiosNumLock      = $true
				LockOnDisconnect = $true
			}
		}

		# set system settings
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - updating system settings...")
			Set-VMSystemSettings @SetVMSystemSettings
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not update system settings")
			Throw $_
		}

		# return VM object
		Return $VM
	}
}

Process {
	# if Json is not an absolute path...
	if (![System.IO.Path]::IsPathRooted($Json)) {
		# get unresolved absolute path
		try {
			$Json = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Json)
		}
		catch {
			Write-Warning -Message "could not create absolute path from the provided Json parameter: $Json"
			return
		}

		# report absolute path
		Write-Warning -Message "converted relative path in provided Json parameter to absolute path: $Json"
	}

	# import JSON data
	Try {
		$JsonData = [array](Get-Content -Path $Json -ErrorAction Stop | ConvertFrom-Json)
	}
	Catch {
		Write-Warning -Message "could not read configuration file: '$Json'"
		Throw $_
	}

	# process each VMname
	:VMName ForEach ($Name in $VMName) {
		# check if JSON contains VM
		If ($null -eq $JsonData.$Name) {
			Write-Host ("$Hostname - VM not found in Json: '$Name'")
			Continue
		}

		# override ComputerName with bound parameters if provided
		If ($PSBoundParameters['ComputerName']) {
			$ComputerName = $ComputerName
			Write-Warning ("overriding ComputerName from JSON: '$($JsonData.$Name.ComputerName)'")
		}
		Else {
			$ComputerName = $JsonData.$Name.ComputerName
		}

		# override VirtualMachinePath with bound parameters if provided
		If ($PSBoundParameters['Path']) {
			$Path = $Path
			Write-Warning ("overriding Path from JSON: '$($JsonData.$Name.Path)'")
		}
		Else {
			$Path = $JsonData.$Name.Path
		}

		# if VM has host...
		If ($null -ne $ComputerName) {
			# define parameters for Get-ClusterName
			$GetClusterName = @{
				ComputerName = $ComputerName
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# check if host is clustered
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - checking if host is clustered...")
				$ClusterName = Get-ClusterName @GetClusterName
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: checking if host is clustered")
				Throw $_
			}

			# define parameters for Get-VMFromComputerName
			$GetVMFromComputerName = @{
				Name         = $Name
				ComputerName = $ComputerName
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# if clustername not defined...
			If ([string]::IsNullOrEmpty($ClusterName)) {
				# declare and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...host is not clustered")
			}
			Else {
				# declare and define optional parameters for Get-VMFromComputerName
				Write-Host ("$Hostname,$ComputerName,$Name - ...host is in cluster: '$ClusterName'")
				$GetVMFromComputerName['ClusterName'] = $ClusterName
			}

			# retrieve VM
			Try {
				$VM = Get-VMFromComputerName @GetVMFromComputerName
			}
			Catch {
				Throw $_
			}

			# check VM
			If ($VM -eq 'multiple') {
				Continue VMName
			}
		}

		# if VM is on a different computer...
		If ($null -ne $VM -and $ComputerName -ne $VM.ComputerName) {
			# declare and begin
			Write-Host ("$Hostname,$ComputerName,$Name - VM found on another computer...")

			# update computer name
			Try {
				$ComputerName = $VM.ComputerName.ToLower()
			}
			Catch {
				Throw $_
			}

			# declare and continue
			Write-Host ("$Hostname,$ComputerName,$Name - ....updated computer name")
		}

		# if VM not found...
		If ($null -eq $VM -and $null -ne $ComputerName) {
			# define required parameters from input
			$NewVMFromParams = @{
				ComputerName = $ComputerName
				Name         = $Name
				Path         = $Path
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# declare required parameters
			Write-Host ("$Hostname,$ComputerName,$Name - defining VM for New-VMFromParams...")
			Write-Host ("$Hostname,$ComputerName,$Name -   Name: $Name")
			Write-Host ("$Hostname,$ComputerName,$Name -   Path: $Path")

			# define and declare optional parameters
			If ($null -ne $JsonData.$Name.ProcessorCount) {
				$NewVMFromParams['ProcessorCount'] = $JsonData.$Name.ProcessorCount
				Write-Host ("$Hostname,$ComputerName,$Name -   ProcessorCount: $($NewVMFromParams['ProcessorCount'])")
			}
			If ($null -ne $JsonData.$Name.MemoryStartupBytes) {
				$NewVMFromParams['MemoryStartupBytes'] = $JsonData.$Name.MemoryStartupBytes
				Write-Host ("$Hostname,$ComputerName,$Name -   MemoryStartupBytes: $(Format-Bytes -Size $($NewVMFromParams['MemoryStartupBytes']))")
			}
			If ($null -ne $JsonData.$Name.MemoryMinimumBytes) {
				$NewVMFromParams['MemoryMinimumBytes'] = $JsonData.$Name.MemoryMinimumBytes
				Write-Host ("$Hostname,$ComputerName,$Name -   MemoryMinimumBytes: $(Format-Bytes -Size $($NewVMFromParams['MemoryMinimumBytes']))")
			}
			If ($null -ne $JsonData.$Name.MemoryMaximumBytes) {
				$NewVMFromParams['MemoryMaximumBytes'] = $JsonData.$Name.MemoryMaximumBytes
				Write-Host ("$Hostname,$ComputerName,$Name -   MemoryMaximumBytes: $(Format-Bytes -Size $($NewVMFromParams['MemoryMaximumBytes']))")
			}
			If ($null -ne $JsonData.$Name.DisableSMT) {
				$NewVMFromParams['DisableSMT'] = $JsonData.$Name.DisableSMT
				Write-Host ("$Hostname,$ComputerName,$Name -   DisableSMT: $($NewVMFromParams['DisableSMT'])")
			}
			If ($null -ne $JsonData.$Name.EnableVMTPM) {
				$NewVMFromParams['EnableVMTPM'] = $JsonData.$Name.EnableVMTPM
				Write-Host ("$Hostname,$ComputerName,$Name -   EnableVMTPM: $($NewVMFromParams['EnableVMTPM'])")
			}
			If ($null -ne $JsonData.$Name.Generation) {
				$NewVMFromParams['Generation'] = $JsonData.$Name.Generation
				Write-Host ("$Hostname,$ComputerName,$Name -   Generation: $($NewVMFromParams['Generation'])")
			}

			# create VM from provided parameters
			Try {
				$VM = New-VmFromParams @NewVMFromParams
			}
			Catch {
				Write-Verbose 'caught VM create error'
				Throw $_
			}
		}

		# if VM has hard disk drives...
		If ($null -ne $VM -and $null -ne $JsonData.$Name.VMHardDiskDrives) {
			# create hard drives
			ForEach ($VMHardDiskDrive in $JsonData.$Name.VMHardDiskDrives) {
				# if path provided...
				If ($PSBoundParameters.ContainsKey('Path')) {
					# retrieve modified VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path.Replace($JsonData.$Name.Path, $Path)
				}
				Else {
					# retrieve original VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path
				}

				# create VHD
				$NewVHDFromParams = @{
					ComputerName = $ComputerName
					Path         = $VMHardDiskDrivePath
					SizeBytes    = $VMHardDiskDrive.SizeBytes
				}
				Try {
					New-VHDFromParams @NewVHDFromParams
				}
				Catch {
					Throw $_
				}
			}

			# filter hard drives with controller number and controller location
			$VMHardDiskDrivesWithNumberAndLocation = $JsonData.$Name.VMHardDiskDrives | Where-Object { $null -ne $_.ControllerNumber -and $null -ne $_.ControllerLocation }

			# attach hard drives with controller number and controller location
			ForEach ($VMHardDiskDrive in $VMHardDiskDrivesWithNumberAndLocation) {
				# if path provided...
				If ($PSBoundParameters.ContainsKey('Path')) {
					# retrieve modified VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path.Replace($JsonData.$Name.Path, $Path)
				}
				Else {
					# retrieve original VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path
				}

				# add VHD to VM
				$AddVHDFromParams = @{
					ComputerName       = $ComputerName
					VM                 = $VM
					Path               = $VMHardDiskDrivePath
					ControllerNumber   = $VMHardDiskDrive.ControllerNumber
					ControllerLocation = $VMHardDiskDrive.ControllerLocation
				}
				Try {
					Add-VHDFromParams @AddVHDFromParams
				}
				Catch {
					Throw $_
				}
			}

			# filter hard drives with controller number and without controller location
			$VMHardDiskDrivesWithNumberWithoutLocation = $JsonData.$Name.VMHardDiskDrives | Where-Object { $null -ne $_.ControllerNumber -and $null -eq $_.ControllerLocation }

			# attach hard drives with controller number and without controller location
			ForEach ($VMHardDiskDrive in $VMHardDiskDrivesWithNumberWithoutLocation) {
				# if path provided...
				If ($PSBoundParameters.ContainsKey('Path')) {
					# retrieve modified VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path.Replace($JsonData.$Name.Path, $Path)
				}
				Else {
					# retrieve original VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path
				}

				# add VHD to VM
				$AddVHDFromParams = @{
					ComputerName     = $ComputerName
					VM               = $VM
					Path             = $VMHardDiskDrivePath
					ControllerNumber = $VMHardDiskDrive.ControllerNumber
				}
				Try {
					Add-VHDFromParams @AddVHDFromParams
				}
				Catch {
					Throw $_
				}
			}

			# filter hard drives without controller number but with controller location
			$VMHardDiskDrivesWithoutNumberWithLocation = $JsonData.$Name.VMHardDiskDrives | Where-Object { $null -eq $_.ControllerNumber -and $null -ne $_.ControllerLocation }

			# attach hard drives without controller number but with controller location
			ForEach ($VMHardDiskDrive in $VMHardDiskDrivesWithoutNumberWithLocation) {
				# if path provided...
				If ($PSBoundParameters.ContainsKey('Path')) {
					# retrieve modified VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path.Replace($JsonData.$Name.Path, $Path)
				}
				Else {
					# retrieve original VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path
				}

				# add VHD to VM
				$AddVHDFromParams = @{
					ComputerName       = $ComputerName
					VM                 = $VM
					Path               = $VMHardDiskDrivePath
					ControllerLocation = $VMHardDiskDrive.ControllerLocation
				}
				Try {
					Add-VHDFromParams @AddVHDFromParams
				}
				Catch {
					Throw $_
				}
			}

			# attach hard drives without controller number or controller location
			$VMHardDiskDrivesWithoutNumberWithoutLocation = $JsonData.$Name.VMHardDiskDrives | Where-Object { $null -eq $_.ControllerNumber -and $null -eq $_.ControllerLocation }

			# attach hard drives without controller number or controller location
			ForEach ($VMHardDiskDrive in $VMHardDiskDrivesWithoutNumberWithoutLocation) {
				# if path provided...
				If ($PSBoundParameters.ContainsKey('Path')) {
					# retrieve modified VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path.Replace($JsonData.$Name.Path, $Path)
				}
				Else {
					# retrieve original VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path
				}

				# add VHD to VM
				$AddVHDFromParams = @{
					ComputerName = $ComputerName
					VM           = $VM
					Path         = $VMHardDiskDrivePath
				}
				Try {
					Add-VHDFromParams @AddVHDFromParams
				}
				Catch {
					Throw $_
				}
			}
		}

		# if VM has network adapters...
		If ($null -ne $VM -and $null -ne $JsonData.$Name.VMNetworkAdapters) {
			# create VM network adapter
			ForEach ($VMNetworkAdapterEntry in $JsonData.$Name.VMNetworkAdapters) {
				# define required parameters for VMNetworkAdapter
				$AddVMNetworkAdapterToVM = @{
					ComputerName       = $ComputerName
					VM                 = $VM
					NetworkAdapterName = $VMNetworkAdapterEntry.NetworkAdapterName
				}

				# report state
				Write-Host ("$Hostname,$ComputerName,$Name - checking VMNetworkAdapter with Name: '$($VMNetworkAdapterEntry.NetworkAdapterName)'")

				# define optional parameters for VMNetworkAdapter
				If ($null -ne $VMNetworkAdapterEntry.SwitchName) {
					$AddVMNetworkAdapterToVM['SwitchName'] = $VMNetworkAdapterEntry.SwitchName
				}
				If ($null -ne $VMNetworkAdapterEntry.MacAddressSpoofing) {
					$AddVMNetworkAdapterToVM['MacAddressSpoofing'] = $VMNetworkAdapterEntry.MacAddressSpoofing
				}
				If ($null -ne $VMNetworkAdapterEntry.AllowTeaming) {
					$AddVMNetworkAdapterToVM['AllowTeaming'] = $VMNetworkAdapterEntry.AllowTeaming
				}

				# add VMNetworkAdapter to VM and get VMNetworkAdapter
				Try {
					$VMNetworkAdapter = Add-VMNetworkAdapterToVM @AddVMNetworkAdapterToVM
				}
				Catch {
					Throw $_
				}

				# define required parameters for VLAN
				$SetVMNetworkAdapterVlanId = @{
					VMNetworkAdapter = $VMNetworkAdapter
				}

				# define optional parameters for VLAN
				If ($null -ne $VMNetworkAdapterEntry.VlanMode) {
					$SetVMNetworkAdapterVlanId['VlanMode'] = $VMNetworkAdapterEntry.VlanMode
				}
				If ($null -ne $VMNetworkAdapterEntry.VlanId) {
					$SetVMNetworkAdapterVlanId['VlanId'] = $VMNetworkAdapterEntry.VlanId
				}
				If ($null -ne $VMNetworkAdapterEntry.VlanIdList) {
					$SetVMNetworkAdapterVlanId['VlanIdList'] = $VMNetworkAdapterEntry.VlanIdList
				}

				# set VLAN on VMNetworkAdapter and get updated VMNetworkAdapter
				Try {
					$VMNetworkAdapter = Set-VMNetworkAdapterVlanId @SetVMNetworkAdapterVlanId
				}
				Catch {
					Throw $_
				}

				# define required parameters for MAC address
				$SetVMNetworkAdapterMacAddress = @{
					VMNetworkAdapter = $VMNetworkAdapter
				}

				# define optional parameters for MAC address
				If ($null -ne $VMNetworkAdapterEntry.IPAddress) {
					$SetVMNetworkAdapterMacAddress['IPAddress'] = $VMNetworkAdapterEntry.IPAddress
				}
				If ($null -ne $VMNetworkAdapterEntry.MacAddress) {
					$SetVMNetworkAdapterMacAddress['MacAddress'] = $VMNetworkAdapterEntry.MacAddress
				}
				If ($null -ne $VMNetworkAdapterEntry.MacAddressPrefix) {
					$SetVMNetworkAdapterMacAddress['MacAddressPrefix'] = $VMNetworkAdapterEntry.MacAddressPrefix
				}

				# set MAC address on VMNetworkAdapter and get updated VMNetworkAdapter
				Try {
					$VMNetworkAdapter = Set-VMNetworkAdapterMacAddress @SetVMNetworkAdapterMacAddress
				}
				Catch {
					Throw $_
				}

				# add VM IP address and MAC address to DHCP server
				If ($null -ne $VMNetworkAdapterEntry.DhcpServer -and $null -ne $VMNetworkAdapterEntry.DhcpScope -and $null -ne $VMNetworkAdapterEntry.IPAddress) {
					# define required parameters for DHCP reservation
					$AddVMNetworkAdapterToDHCP = @{
						ComputerName = $VMNetworkAdapterEntry.DhcpServer
						ScopeId      = $VMNetworkAdapterEntry.DhcpScope
						IPAddress    = $VMNetworkAdapterEntry.IPAddress
						MacAddress   = $VMNetworkAdapter.MacAddress
					}

					# define optional parameters for DHCP reservation
					If (![System.String]::IsNullOrEmpty($VMNetworkAdapterEntry.Router)) {
						$AddVMNetworkAdapterToDHCP['Router'] = $VMNetworkAdapterEntry.Router
					}
					# create DHCP reservation
					Try {
						Add-VMNetworkAdapterToDHCP @AddVMNetworkAdapterToDHCP
					}
					Catch {
						Throw $_
					}
				}
			}
		}

		# if VM has OS deployment...
		If ($null -ne $VM -and $null -ne $JsonData.$Name.OSDeployment) {
			# ...retrieve OS deployment method
			$DeploymentMethod = $JsonData.$Name.OSDeployment.DeploymentMethod.ToUpper()

			# ...configure OS deployment
			If ([string]::IsNullOrEmpty($DeploymentMethod)) {
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping deployment, no provisioning method provided")
			}
			ElseIf ($SkipProvisioning) {
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping deployment, SkipProvisioning set")
			}
			Else {
				switch ($DeploymentMethod) {
					'ISO' {
						# define parameters for Add-IsoToVM
						$AddIsoToVM = @{
							VM   = $VM
							Path = $JsonData.$Name.OSDeployment.FilePath
						}

						# mount ISO file on VM
						Try {
							Write-Host ("$Hostname,$ComputerName,$Name - VM will be provisioned via ISO file")
							Add-IsoToVM @AddIsoToVM
						}
						Catch {
							Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add ISO to VM")
							Throw $_
						}
					}
					'SCCM' {
						# define parameters for Add-DeviceToSccm
						$AddDeviceToSccm = @{
							VM                 = $VM
							Server             = $JsonData.$Name.OSDeployment.Server
							Collections        = $JsonData.$Name.OSDeployment.Collections
							DomainName         = $JsonData.$Name.OSDeployment.DomainName
							OrganizationalUnit = $JsonData.$Name.OSDeployment.OrganizationalUnit
						}

						# add VM to SCCM
						Try {
							Write-Host ("$Hostname,$ComputerName,$Name - VM will be provisioned via PXE boot and SCCM")
							Add-DeviceToSccm @AddDeviceToSccm
						}
						Catch {
							Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add VM to SCCM")
							Throw $_
						}
					}
					default {
						Write-Host ("$Hostname,$ComputerName,$Name - ...skipping deployment, unknown provisioning method provided: '$DeploymentMethod'")
					}
					'VHD' {
						# define parameters for Copy-VHDFromParams
						$CopyVHDFromParams = @{
							VM                 = $VM
							Path               = $JsonData.$Name.OSDeployment.FilePath
							ControllerNumber   = $JsonData.$Name.OSDeployment.ControllerNumber
							ControllerLocation = $JsonData.$Name.OSDeployment.ControllerLocation
							UnattendFile       = $JsonData.$Name.OSDeployment.UnattendFile
							DomainName         = $JsonData.$Name.OSDeployment.DomainName
							OrganizationalUnit = $JsonData.$Name.OSDeployment.OrganizationalUnit
						}

						# mount ISO file on VM
						Try {
							Write-Host ("$Hostname,$ComputerName,$Name - VM will be provisioned via VHD file")
							Copy-VHDFromParams @CopyVHDFromParams
						}
						Catch {
							Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add VHD to VM")
							Throw $_
						}
					}
				}
			}
		}

		# if VM is on a cluster...
		If ($null -ne $VM -and -not [string]::IsNullOrEmpty($ClusterName)) {
			# if DoNotCluster is set...
			If ($JsonData.$Name.DoNotCluster) {
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping clustering, DoNotCluster was set")
			}
			# if SkipClustering is set...
			ElseIf ($SkipClustering) {
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping clustering, SkipClustering was set")
			}
			# if DoNotCluster and SkipClustering are not set...
			Else {
				# define required parameters for Add-VMToClusterName
				$AddVMToClusterName = @{
					VM          = $VM
					ClusterName = $ClusterName
				}

				# define optional parameters for Add-VMToClusterName
				If ($null -ne $JsonData.$Name.ClusterPriority) {
					$AddVMToClusterName['ClusterPriority'] = $JsonData.$Name.ClusterPriority
				}
				If ($null -ne $JsonData.$Name.ClusterAffinityRules) {
					$AddVMToClusterName['ClusterAffinityRules'] = $JsonData.$Name.ClusterAffinityRules
				}

				# add VM to cluster
				Try {
					$ClusterGroup = Add-VMToClusterName @AddVMToClusterName
				}
				Catch {
					Throw $_
				}
			}
		}

		# if VM is on a cluster...
		If ($null -ne $VM -and $null -ne $ClusterGroup) {
			# if cluster group is not online and SkipStart set...
			If ($ClusterGroup.State -eq 'Offline' -and $SkipStart) {
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping Start, SkipStart was set...")
			}
			# if cluster group is not online and SkipStart not set...
			ElseIf ($ClusterGroup.State -eq 'Offline') {
				# declare and begin
				Write-Host ("$Hostname,$ComputerName,$Name - VM cluster group is offline, starting VM on cluster...")

				# define parameters for Start-ClusterGroup
				$StartClusterGroup = @{
					Cluster        = $ClusterName
					Name           = $Name
					ChooseBestNode = $true
					ErrorAction    = [System.Management.Automation.ActionPreference]::Stop
				}

				# start cluster group
				Try {
					$ClusterGroup = Start-ClusterGroup @StartClusterGroup
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: starting VM on cluster")
					Throw $_
				}

				# declare and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...started VM on cluster")
				Continue
			}
			# if cluster group is online and ForceRestart set...
			ElseIf ($ClusterGroup.State -eq 'Online' -and $ForceRestart) {
				# declare and begin
				Write-Host ("$Hostname,$ComputerName,$Name - VM cluster group is not offline but ForceRestart set, restarting VM on cluster...")

				# define parameters for Stop-ClusterGroup
				$StopClusterGroup = @{
					Cluster        = $ClusterName
					Name           = $Name
					ChooseBestNode = $true
					ErrorAction    = [System.Management.Automation.ActionPreference]::Stop
				}

				# stop cluster group
				Try {
					$ClusterGroup = Stop-ClusterGroup @StopClusterGroup
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: stopping VM on cluster")
					Throw $_
				}

				# define parameters for Start-ClusterGroup
				$StartClusterGroup = @{
					Cluster        = $ClusterName
					Name           = $Name
					ChooseBestNode = $true
					ErrorAction    = [System.Management.Automation.ActionPreference]::Stop
				}

				# start cluster group
				Try {
					$ClusterGroup = Start-ClusterGroup @StartClusterGroup
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: starting VM on cluster")
					Throw $_
				}

				# declare and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...restarted VM on cluster")
				Continue
			}
			# if cluster group is online and ForceRestart not set...
			ElseIf ($ClusterGroup.State -eq 'Online') {
				# declare and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...found VM running on cluster")
				Continue
			}
			# if cluster group is not in an expected state...
			Else {
				# declare and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...found VM cluster group in unexpected state: $($ClusterGroup.State)")
				Continue
			}
		}

		# if VM is not on a cluster...
		If ($null -ne $VM -and $null -eq $ClusterGroup) {
			# if VM is not online and SkipStart set...
			If ($VM.State -eq 'Off' -and $SkipStart) {
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping Start, SkipStart was set...")
			}
			# if VM is not online and SkipStart not set...
			ElseIf ($VM.State -eq 'Off') {
				# ...start VM
				Write-Host ("$Hostname,$ComputerName,$Name - starting VM on host...")

				# start VM
				Try {
					Start-VM -VM $VM
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: starting VM")
					Throw $_
				}

				# declare and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...started VM on host")
				Continue
			}
			# if VM is online and ForceRestart set...
			ElseIf ($VM.State -eq 'Running' -and $ForceRestart) {
				# ...restart VM
				Write-Host ("$Hostname,$ComputerName,$Name - restarting VM on host...")

				# restart VM
				Try {
					Restart-VM -VM $VM -Force
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: restarting VM")
					Throw $_
				}

				# declare and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...restarted VM on host")
				Continue
			}
			# if VM is online and ForceRestart not set...
			ElseIf ($VM.State -eq 'Running') {
				# declare and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...found VM running on host")
				Continue
			}
			# if VM is not in an expected state...
			Else {
				# declare and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...found VM in unexpected state: $($VM.State)")
				Continue
			}
		}
	}
}

End {
	# remove sessions
}