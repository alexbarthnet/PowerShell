#requires -Modules 'Hyper-V', FailoverClusters, DhcpServer

[CmdletBinding(SupportsShouldProcess)]
param(
	[Parameter(Position = 0, Mandatory)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	[Parameter(Position = 1, ValueFromPipeline)]
	[string[]]$VMName,
	[Parameter(Position = 2)]
	[string]$ComputerName,
	[Parameter(Position = 3)]
	[string]$Path,
	[Parameter(Position = 4)]
	[string]$DhcpServer,
	[Parameter()]
	[switch]$UseDefaultPathOnHost,
	[Parameter()]
	[switch]$UseExistingVHDs,
	[Parameter()]
	[switch]$SkipProvisioning,
	[Parameter()]
	[switch]$SkipStart,
	[Parameter()]
	[switch]$SkipClustering,
	[Parameter()]
	[switch]$SkipVMConnect,
	[Parameter()]
	[switch]$ChooseBestNode,
	[Parameter()]
	[switch]$ForceRestart,
	[Parameter()]
	[pscredential]$LocalAdminCredential,
	[Parameter()]
	[pscredential]$DomainJoinCredential,
	[Parameter()][ValidateNotNull()]
	[hashtable]$ExpandStrings = @{},
	[Parameter(DontShow)]
	[bool]$YesToAll,
	[Parameter(DontShow)]
	[bool]$NoToAll,
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
)

begin {
	# set error action preference
	$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

	function ConvertTo-Collection {
		param (
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
		foreach ($Property in $InputObject.PSObject.Properties) {
			# if property contains multiple values...
			if ($Property.Value.Count -gt 1) {
				# define list for property values
				$PropertyValues = [System.Collections.Generic.List[object]]::new($Property.Value.Count)
				# process each property value
				foreach ($PropertyValue in $Property.Value) {
					# if property value is a pscustomobject...
					if ($PropertyValue -is [System.Management.Automation.PSCustomObject]) {
						# convert property value into collection
						$PropertyValueCollection = ConvertTo-Collection -InputObject $PropertyValue -Type $Type
						# add property value collection to list
						$PropertyValues.Add($PropertyValueCollection)
					}
					# if property value is not a pscustomobject...
					else {
						# add property value to list
						$PropertyValues.Add($PropertyValue)
					}
				}
				# convert list to array then add array to collection
				$Collection[$Property.Name] = $PropertyValues.ToArray()
			}
			else {
				# if property value is a pscustomobject...
				if ($Property.Value -is [System.Management.Automation.PSCustomObject]) {
					# convert property value into collection
					$PropertyValueCollection = ConvertTo-Collection -InputObject $Property.Value -Type $Type
					# add property name and value to collection
					$Collection[$Property.Name] = $PropertyValueCollection
				}
				# if property value is not a pscustomobject...
				else {
					# add property name and value to collection
					$Collection[$Property.Name] = $Property.Value
				}
			}
		}

		# return collection
		return $Collection
	}

	function Format-Bytes {
		[CmdletBinding()]
		param (
			[Parameter(Position = 0, Mandatory = $true)]
			[uint64]$Size,
			[Parameter(Position = 1)]
			[int32]$RoundTo = 2
		)
		switch ($Size) {
			{ $_ -ge 1PB } { "$([math]::Round($Size / 1PB,$RoundTo)) PB"; break }
			{ $_ -ge 1TB } { "$([math]::Round($Size / 1TB,$RoundTo)) TB"; break }
			{ $_ -ge 1GB } { "$([math]::Round($Size / 1GB,$RoundTo)) GB"; break }
			{ $_ -ge 1MB } { "$([math]::Round($Size / 1MB,$RoundTo)) MB"; break }
			{ $_ -ge 1KB } { "$([math]::Round($Size / 1KB,$RoundTo)) KB"; break }
			Default { "$([math]::Round($Size,$RoundTo)) B" }
		}
	}

	function Test-PSSessionByName {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName
		)

		# if computername matches hostname...
		if ($ComputerName -eq $Hostname) {
			# ...return false as no session is needed
			return $false
		}

		# if hashtable is missing...
		if ($script:PSSessions -isnot [hashtable]) {
			# ...create hashtable
			$script:PSSessions = @{}
		}

		# if session exists for computer...
		if ($script:PSSessions[$ComputerName] -is [System.Management.Automation.Runspaces.PSSession]) {
			# if session is open and available...
			if ($script:PSSessions[$ComputerName].State -eq 'Opened' -and $script:PSSessions[$ComputerName].Availability -eq 'Available') {
				# ...return true as session can already be referenced
				return $true
			}
		}

		# create a new session
		try {
			$script:PSSessions[$ComputerName] = New-PSSession -ComputerName $ComputerName -Name $ComputerName -Authentication Default
		}
		catch {
			return $false
		}

		# ...validate session
		if ($script:PSSessions[$ComputerName] -is [System.Management.Automation.Runspaces.PSSession]) {
			# if session is open and available...
			if ($script:PSSessions[$ComputerName].State -eq 'Opened' -and $script:PSSessions[$ComputerName].Availability -eq 'Available') {
				# ...return true as session can already be referenced
				return $true
			}
			else {
				return $false
			}
		}
		else {
			return $false
		}
	}

	function Get-PSSessionInvoke {
		[CmdletBinding()]
		param(
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
		foreach ($Key in $ArgumentList.Keys) {
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
		if ($ComputerName -eq $Hostname) {
			# ...update hashtable to invoke commands in the current scope on the local computer
			$InvokeCommand['NoNewScope'] = $true
			# ...return hashtable
			return $InvokeCommand
		}

		# check for session
		try {
			$SessionExists = Test-PSSessionByName -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# if a session exists...
		if ($SessionExists) {
			# ...update hashtable to invoke commands in the session
			$InvokeCommand['Session'] = $script:PSSessions[$ComputerName]
			# ...return hashtable
			return $InvokeCommand
		}
		else {
			# ...update hashtable to invoke commands in a standalone session
			$InvokeCommand['ComputerName'] = $ComputerName
			# ...return hashtable
			return $InvokeCommand
		}
	}

	function Get-CimInstanceForVM {
		[CmdletBinding()]
		param(
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower()
		)

		# get VM from parameters
		try {
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			throw $_
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
		try {
			Get-CimInstance @GetCimInstance
		}
		catch {
			throw $_
		}
	}

	function Get-CimInstanceForVMMS {
		[CmdletBinding()]
		param(
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
		try {
			Get-CimInstance @GetCimInstance
		}
		catch {
			throw $_
		}
	}

	function Get-ClusterName {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName
		)

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# test for cluster
		try {
			$ClusterName = Invoke-Command @InvokeCommand -ScriptBlock {
				$GetItemProperty = @{
					Path        = 'HKLM:\System\CurrentControlSet\Services\ClusSvc\Parameters'
					Name        = 'ClusterName'
					ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
				}
				Get-ItemProperty @GetItemProperty | Select-Object -ExpandProperty $GetItemProperty['Name']
			}
		}
		catch {
			throw $_
		}

		# return the cluster name
		if ($null -ne $ClusterName) {
			return $ClusterName
		}
		else {
			return [string]::Empty
		}
	}

	function Get-ClusterNodeNames {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName
		)

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# test for cluster
		try {
			$ClusterNodeNames = Invoke-Command @InvokeCommand -ScriptBlock {
				$GetClusterNode = @{
					ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
				}
				Get-ClusterNode @GetClusterNode | Select-Object -ExpandProperty 'Name'
			}
		}
		catch {
			throw $_
		}

		# return the cluster nodes
		if ($null -ne $ClusterNodeNames) {
			return $ClusterNodeNames
		}
		else {
			return $null
		}
	}

	function Get-CMModulePath {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[string]$ChildPath = '\bin\ConfigurationManager.psd1'
		)

		# define hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# retrieve path to CM module from remote registry
		try {
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
		catch {
			throw $_
		}

		# if path not found...
		if ([string]::IsNullOrEmpty($Path)) {
			# ...return empty string
			return [string]::Empty
		}

		# update argument list with CM module path
		$InvokeCommand['ArgumentList']['Path'] = $Path
		$InvokeCommand['ArgumentList']['ChildPath'] = $ChildPath

		# test CM module path
		try {
			$CMModulePath = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
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
		catch {
			throw $_
		}

		# if path not found...
		if ([string]::IsNullOrEmpty($CMModulePath)) {
			return [string]::Empty
		}
		# if path found...
		else {
			# ...return path
			return $CMModulePath
		}
	}

	function Get-CMSiteCode {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName
		)

		# define hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# retrieve CM site code from remote registry
		try {
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
		catch {
			throw $_
		}

		# if CM site code not found...
		if ([string]::IsNullOrEmpty($CMSiteCode)) {
			# ...return empty string
			return [string]::Empty
		}
		# if CM site code found...
		else {
			# ...return CM site code
			return $CMSiteCode
		}
	}

	function Get-VMFromComputerName {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[Parameter(Mandatory = $true)]
			[string]$Name,
			[string]$ClusterName
		)

		# if cluster name was provided...
		if ($PSBoundParameters['ClusterName']) {
			# define parameters for Get-ClusterNodeNames
			$GetClusterNodeNames = @{
				ComputerName = $ComputerName
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# define computernames as cluster node names
			try {
				$ComputerNames = Get-ClusterNodeNames @GetClusterNodeNames
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving cluster node names from computer name")
				throw $_
			}
		}
		else {
			# define computernames as single computername
			$ComputerNames = $ComputerName
		}

		# create list for VMs
		$VMList = [System.Collections.Generic.List[object]]::new()

		# check for VM on each node
		:ComputerNames foreach ($ComputerNameForGetVM in $ComputerNames) {
			# declare and begin
			Write-Host ("$Hostname,$ComputerName,$Name - checking for VM on host: '$ComputerNameForGetVM'")

			# define parameters for Get-VMHost
			$GetVMHost = @{
				ComputerName = $ComputerNameForGetVM
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# validate host before continuing
			try {
				$null = Get-VMHost @GetVMHost
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - WARNING: could not connect to host: '$ComputerNameForGetVM'")
				continue ComputerNames
			}

			# define parameters for Get-VM
			$GetVM = @{
				Name         = $Name
				ComputerName = $ComputerNameForGetVM
				ErrorAction  = [System.Management.Automation.ActionPreference]::SilentlyContinue
			}

			# get VMs with Name from ComputerName
			try {
				$VMsFromGetVM = Get-VM @GetVM
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving VMs from host")
				throw $_
			}

			# add each VM to VM list
			foreach ($VMFromGetVM in $VMsFromGetVM) {
				$VMList.Add($VMFromGetVM)
			}
		}

		# check VM list
		switch ($VMList.Count) {
			# no VMs found
			0 {
				# declare then return null
				Write-Host ("$Hostname,$ComputerName,$Name - ....VM not found on provided host")
				return $null
			}
			# one VM found
			1 {
				# declare then return VM
				Write-Host ("$Hostname,$ComputerName,$Name - ....VM found via provided host")
				return $VMList[0]
			}
			# multiple VMs found
			Default {
				# declare and report then return null
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: multiple VMs found with name")
				foreach ($VMObject in $VMList) {
					Write-Host ("$Hostname,$ComputerName,$Name - ...found VM on '$($VMObject.ComputerName)' with Id: '$($VMObject.Id)'")
				}
				return 'multiple'
			}
		}
	}

	function Get-VMFromParameters {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)][ValidateScript({ $_ -is [Microsoft.HyperV.PowerShell.VirtualMachine] -or $_ -is [guid] -or $_ -is [string] })]
			[object]$VM,
			[string]$ComputerName,
			[switch]$Force
		)

		# if VM is a virtual machine object and Force not set...
		if ($VM -is [Microsoft.HyperV.PowerShell.VirtualMachine] -and -not $Force) {
			# ...return VM as-is
			return $VM
		}

		# if computername not provided...
		if ([string]::IsNullOrEmpty($ComputerName)) {
			# ...and VM is a virtual machine...
			if ($VM -is [Microsoft.HyperV.PowerShell.VirtualMachine]) {
				# get computer name from VM
				$ComputerName = $VM.ComputerName.ToLower()
			}
			else {
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
		if ($VM -is [Microsoft.HyperV.PowerShell.VirtualMachine]) {
			# ...set ID from Id property on VM object
			$GetVM['Id'] = $VM.Id
		}
		# if VM is a GUID...
		elseif ($VM -is [guid] -or [guid]::TryParse($VM, [ref][guid]::Empty)) {
			# ...set ID from value of VM cast as a GUID
			$GetVM['Id'] = [guid]$VM
		}
		# if VM is a string...
		else {
			# ...set Name from value of VM
			$GetVM['Name'] = $VM
		}

		# get VM with arguments
		try {
			$VM = Get-VM @GetVM
		}
		catch {
			throw $_
		}

		# return objects
		if ($VM -is [Microsoft.HyperV.PowerShell.VirtualMachine]) {
			return $VM
		}
		elseif ($VM -is [array]) {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieved multiple VM objects with provided parameters")
			throw $_
		}
		else {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieved unexpected object type with provided parameters")
			throw $_
		}
	}

	function Get-VMHostNextMacAddress {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[string]$Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\Worker'
		)

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not get initial hashtable for Invoke-Command")
			throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['Path'] = $Path
		$InvokeCommand['ArgumentList']['Name'] = 'CurrentMacAddress'

		# retrieve current MAC address
		try {
			$CurrentMacAddress = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				Get-ItemPropertyValue -Path $ArgumentList['Path'] -Name $ArgumentList['Name']
			}
		}
		catch {
			throw $_
		}

		# verify current MAC address
		if ($CurrentMacAddress -isnot [byte[]]) {
			Write-Host ("$Hostname,$ComputerName - ERROR: CurrentMacAddress registry value is not a byte array")
			return $null
		}

		# define and increment updated MAC address
		if ($CurrentMacAddress[-1] -eq 255) {
			Write-Host ("$Hostname,$ComputerName - ERROR: CurrentMacAddress has reached the default limit")
			return $null
		}

		# update argument list
		$InvokeCommand['ArgumentList']['CurrentMacAddress'] = $CurrentMacAddress

		# update current MAC address
		try {
			$null = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				# increment last byte in current MAC address
				$ArgumentList['CurrentMacAddress'][-1]++
				# update current MAC address property
				Set-ItemProperty -Path $ArgumentList['Path'] -Name $ArgumentList['Name'] -Value $ArgumentList['CurrentMacAddress']
			}
		}
		catch {
			throw $_
		}

		# return current MAC address
		try {
			return [System.BitConverter]::ToString($CurrentMacAddress).Replace('-', $null)
		}
		catch {
			throw $_
		}
	}

	function Add-DeviceToSccm {
		[CmdletBinding()]
		param(
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
			[hashtable]$DeviceVariables
		)

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $Server
		}
		catch {
			throw $_
		}

		# get VM from parameters
		try {
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			throw $_
		}

		# define parameters for Get-CimInstanceForVM
		$GetCimInstanceForVM = @{
			VM          = $VM
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve CIM instance for VM
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...retrieving CIM instance for VM...")
			$CimInstanceForVM = Get-CimInstanceForVM @GetCimInstanceForVM
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve CIM instance for VM")
			throw $_
		}

		# retrive BIOS GUID from CIM instance
		if ([string]::IsNullOrEmpty($CimInstanceForVM.BIOSGUID)) {
			Write-Host ("$Hostname,$ComputerName,$Name - WARNING: BIOS GUID for VM is empty; skipping SCCM provisioning...")
			return
		}
		else {
			Write-Host ("$Hostname,$ComputerName,$Name - ...found BIOS GUID for VM")
			$BIOSGUID = $CimInstanceForVM.BIOSGUID
		}

		# define parameters for Get-CMModulePath
		$GetCMModulePath = @{
			ComputerName = $Server
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# get CM module path
		try {
			$CMModulePath = Get-CMModulePath @GetCMModulePath
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve path to CM PowerShell module")
			throw $_
		}

		# test CM module path
		if ([string]::IsNullOrEmpty($CMModulePath)) {
			Write-Host ("$Hostname,$ComputerName,$Name - WARNING: could not retrieve path to CM PowerShell module")
			return
		}

		# define parameters for Get-CMSiteCode
		$GetCMSiteCode = @{
			ComputerName = $Server
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# get CM site code
		try {
			$CMSiteCode = Get-CMSiteCode @GetCMSiteCode
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve CM site code")
			throw $_
		}

		# test CM site code
		if ([string]::IsNullOrEmpty($CMSiteCode)) {
			Write-Host ("$Hostname,$ComputerName,$Name - WARNING: could not retrieve CM site code")
			return
		}

		# update arguments for Invoke-Command - reporting
		$InvokeCommand['ArgumentList']['Hostname'] = $Hostname
		$InvokeCommand['ArgumentList']['ComputerName'] = $Server
		$InvokeCommand['ArgumentList']['Name'] = $Name

		# update arguments for Invoke-Command - deployment
		$InvokeCommand['ArgumentList']['ModulePath'] = $CMModulePath
		$InvokeCommand['ArgumentList']['SiteCode'] = $CMSiteCode
		$InvokeCommand['ArgumentList']['BIOSGUID'] = $BIOSGUID
		$InvokeCommand['ArgumentList']['Collections'] = $Collections
		$InvokeCommand['ArgumentList']['DeviceVariables'] = $DeviceVariables

		# add VM to SCCM
		Invoke-Command @InvokeCommand -ScriptBlock {
			param($ArgumentList)

			function Get-CMDeviceFromCollection {
				[CmdletBinding()]
				param(
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
				try {
					$Device = Get-CMDevice @GetCMDevice
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve device from collection")
					throw $_
				}

				# if device found
				if ($null -ne $Device) {
					# ...return device
					Write-Host ("$Hostname,$ComputerName,$Name - ...found device in collection immediately")
					return $Device
				}
				# if skip update...
				elseif ($SkipUpdate) {
					# ...return null
					return $null
				}

				# update collection
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - updating collection...")
					Invoke-CMCollectionUpdate -CollectionId $CollectionId
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not update from collection")
					throw $_
				}

				# define integers for while loop and reporting
				$WaitTime = [int32]0
				$Multiplier = [int32]0

				# wait until device is visible in SCCM
				Write-Host ("$Hostname,$ComputerName,$Name - waiting for device to be visible in SCCM...")
				while ($null -eq $Device -and $Multiplier -lt $Limit) {
					# increment multiplier
					$Multiplier++

					# record total time
					$WaitTime += ($Seconds * $Multiplier)

					# wait for collection update to complete
					Write-Host ("$Hostname,$ComputerName,$Name - ...waiting an additional '$($Seconds * $Multiplier)' seconds")
					Start-Sleep -Seconds ($Seconds * $Multiplier)

					# retrieve device by name
					try {
						$Device = Get-CMDevice @GetCMDevice
					}
					catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve device from collection")
						throw $_
					}
				}

				# if device found...
				if ($null -ne $Device) {
					# ...declare wait time and return
					Write-Host ("$Hostname,$ComputerName,$Name - ...found device in collection after '$WaitTime' seconds")
					return $Device
				}
				# if device not found...
				else {
					# ...declare wait time and return
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: device not found after '$WaitTime' seconds")
					Write-Host ("$Hostname,$ComputerName,$Name - ...check SCCM before continuing")
					return $null
				}
			}

			function Add-CMDeviceToCollection {
				[CmdletBinding()]
				param (
					[string]$CollectionName,
					[string]$ResourceId
				)

				# retrieve device collection
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - retrieving device collection: '$CollectionName'")
					$Collection = Get-CMDeviceCollection -Name $CollectionName
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve device collection")
					throw $_
				}

				# if device collection not found...
				if ($null -eq $Collection) {
					# ...warn and return
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: could not retrieve device collection: '$CollectionName'")
					return
				}

				# check for direct membership rule
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - retrieving direct membership rule for device...")
					$MembershipRule = Get-CMDeviceCollectionDirectMembershipRule -CollectionId $Collection.CollectionID -ResourceId $ResourceId
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving direct membership rule")
					throw $_
				}

				# if direct membership rule not found...
				if ($null -eq $MembershipRule) {
					# add direct membership rule to collection
					try {
						Write-Host ("$Hostname,$ComputerName,$Name - adding direct membership rule for device to collection...")
						$MembershipRule = Add-CMDeviceCollectionDirectMembershipRule -CollectionId $Collection.CollectionID -ResourceId $ResourceId -PassThru
					}
					catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: adding direct membership rule for device to collection")
						throw $_
					}
				}

				# if collection membership rule not found after adding rule...
				if ($null -eq $MembershipRule) {
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: could not retrieve direct membership rule after adding to collection")
					return
				}

				# retrieve device from collection
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - retrieving device from collection...")
					Get-CMDeviceFromCollection -CollectionId $Collection.CollectionID -Name $Name
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving device from collection")
					throw $_
				}
			}

			function Update-CMDeviceVariable {
				[CmdletBinding()]
				param (
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
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - retrieving device variable: '$VariableName'")
					$DeviceVariable = Get-CMDeviceVariable @GetCMDeviceVariable
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving device variable")
					throw $_
				}

				# if device variable not found...
				if ($null -eq $DeviceVariable) {
					# define parameters for New-CMDeviceVariable
					$NewCMDeviceVariable = @{
						DeviceId      = $ResourceId # *MUST* be DeviceId due to CM module/cmdlet design
						VariableName  = $VariableName
						VariableValue = $VariableValue
						ErrorAction   = [System.Management.Automation.ActionPreference]::Stop
					}

					# create device variable
					try {
						Write-Host ("$Hostname,$ComputerName,$Name - ...adding device variable: '$VariableName'")
						$null = New-CMDeviceVariable @NewCMDeviceVariable
					}
					catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: adding device variable")
						throw $_
					}

					# declare and return
					Write-Host ("$Hostname,$ComputerName,$Name - ...added device variable")
					return
				}
				# if device variable found with wrong value...
				elseif ($DeviceVariable.Value -ne $VariableValue) {
					# define parameters for New-CMDeviceVariable
					$SetCMDeviceVariable = @{
						ResourceId   = $ResourceId
						VariableName = $VariableName
						ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
					}

					# update device variable
					try {
						Write-Host ("$Hostname,$ComputerName,$Name - ...updating device variable: '$VariableName'")
						$null = Set-CMDeviceVariable @SetCMDeviceVariable
					}
					catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: updating device variable")
						throw $_
					}

					# declare and return
					Write-Host ("$Hostname,$ComputerName,$Name - ...updated device variable")
					return
				}
				else {
					Write-Host ("$Hostname,$ComputerName,$Name - ...found device variable: '$VariableName'")
					return
				}
			}

			# reset device object
			$Device = $null

			# create objects for reporting
			$Hostname = $ArgumentList['Hostname']
			$ComputerName = $ArgumentList['ComputerName']
			$Name = $ArgumentList['Name']

			# import CM module
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...importing SCCM module")
				Import-Module -Name $ArgumentList['ModulePath'] -ErrorAction 'Stop'
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: importing SCCM module")
				throw $_
			}

			# move to site drive
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...setting location to site drive")
				Set-Location -Path ([string]::Concat($ArgumentList['SiteCode'], ':\'))
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: setting location to SCCM drive")
				throw $_
			}

			# retrieve All Systems collection
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - retrieving 'All Systems' collection")
				$AllSystems = Get-CMDeviceCollection -Name 'All Systems'
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving 'All Systems' collection")
				throw $_
			}

			# validate All Systems collection
			if ($null -eq $AllSystems) {
				Write-Host ("$Hostname,$ComputerName,$Name - WARNING: All Systems collection is empty")
				return
			}

			# retrieve device by name
			if ($null -eq $Device) {
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - retrieving device by name from 'All Systems' collection")
					$Device = Get-CMDevice -Collection $AllSystems -Fast -Name $Name
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving device by name from 'All Systems' collection")
					throw $_
				}

				# if multiple devices found by name...
				if ($Device.Count -gt 1) {
					# ...warn and return
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: multiple devices found with the same name")
					Write-Host ("$Hostname,$ComputerName,$Name - ...remove extra devices from SCCM before continuing")
					return
				}

				# if device found by name and Device is a full client...
				if ($null -ne $Device -and $Device.Client -eq 1) {
					# ...warn and return
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: device found by name with existing client")
					Write-Host ("$Hostname,$ComputerName,$Name - ...remove device from SCCM before continuing")
					return
				}

				# if device found by name with different BIOSGUID...
				if ($null -ne $Device -and $Device.SMBIOSGUID -ne $ArgumentList['BIOSGUID']) {
					# ...warn and return
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: device found by name with unexpected SMBIOSGUID: '$($ArgumentList['BIOSGUID'])'")
					Write-Host ("$Hostname,$ComputerName,$Name - ...remove device from SCCM before continuing")
					return
				}

				# if device not found by name...
				if ($null -eq $Device) {
					# report and continue
					Write-Host ("$Hostname,$ComputerName,$Name - ...device not found by name in 'All Systems' collection")
				}
			}

			# retrieve device by SMBIOSGUID
			if ($null -eq $Device) {
				# retrieve device by SMBIOSGUID
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - retrieving device by SMBIOSGUID from 'All Systems' collection")
					$Device = Get-CMDevice -Collection $AllSystems -Fast | Where-Object { $_.SMBIOSGUID -eq $ArgumentList['BIOSGUID'] }
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving devices from 'All Systems' collection")
					throw $_
				}

				# if multiple devices found by SMBIOSGUID...
				if ($Device.Count -gt 1) {
					# ...warn and return
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: multiple devices found with the same SMBIOSGUID")
					Write-Host ("$Hostname,$ComputerName,$Name - ...remove extra devices from SCCM before continuing")
					return
				}

				# if device found by SMBIOSGUID and Device is a full client...
				if ($null -ne $Device -and $Device.Client -eq 1) {
					# ...warn and return
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: device found by SMBIOSGUID with existing client")
					Write-Host ("$Hostname,$ComputerName,$Name - ...remove device from SCCM before continuing")
					return
				}

				# if device found by SMBIOSGUID and Device is a full client...
				if ($null -ne $Device -and $Device.Name -ne $Name) {
					# ...warn and return
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: device found by SMBIOSGUID with unexpected name: '$($Device.Name)'")
					Write-Host ("$Hostname,$ComputerName,$Name - ...remove device from SCCM before continuing")
					return
				}

				# if device not found by SMBIOSGUID...
				if ($null -eq $Device) {
					# report and continue
					Write-Host ("$Hostname,$ComputerName,$Name - ...device not found by SMBIOSGUID in 'All Systems' collection")
				}
			}

			# if device not found by name or SMBIOSGUID...
			if ($null -eq $Device) {
				# define parameters for Import-CMComputerInformation
				$ImportCMComputerInformation = @{
					CollectionId = $AllSystems.CollectionID
					ComputerName = $Name
					SMBiosGuid   = $ArgumentList['BIOSGUID']
					ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
				}

				# import the device into SCCM
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - adding device to SCCM...")
					Import-CMComputerInformation @ImportCMComputerInformation
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: adding device to SCCM")
					throw $_
				}

				# define parameters for Get-CMDeviceFromCollection
				$GetCMDeviceFromCollection = @{
					CollectionId = $AllSystems.CollectionID
					Name         = $Name
					ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
				}

				# retrieve device from collection
				try {
					$Device = Get-CMDeviceFromCollection @GetCMDeviceFromCollection
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving device from collection: '$($AllSystems.Name)'")
					throw $_
				}

				# if device still not found...
				if ($null -eq $Device) {
					return
				}

				# retrieve resource ID
				$ResourceId = $Device.ResourceId

				# ...report
				Write-Host ("$Hostname,$ComputerName,$Name - ...created new device with resource ID: '$ResourceId'")
			}
			# if device found...
			else {
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
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - clearing any PXE deployments for existing device...")
					Clear-CMPxeDeployment @ClearCMPxeDeployment
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: clearing CM PXE deployment")
					throw $_
				}

				# report and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...cleared PXE deployment for existing device")
			}

			# loop through collections
			foreach ($Collection in $ArgumentList['Collections']) {
				# define parameters for Get-CMDeviceFromCollection
				$AddCMDeviceToCollection = @{
					CollectionName = $Collection
					ResourceId     = $Device.ResourceID
					ErrorAction    = [System.Management.Automation.ActionPreference]::Stop
				}

				# add device to collection
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - adding device to collection: $Collection")
					$Device = Add-CMDeviceToCollection @AddCMDeviceToCollection
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add device to collection'")
					throw $_
				}
			}

			# if device variables object is not a hashtable...
			if ($ArgumentList['DeviceVariables'] -isnot [hashtable]) {
				# return before calling GetEnumerator method on unsupported object
				return
			}

			# loop through device variables
			foreach ($DeviceVariable in $ArgumentList['DeviceVariables'].GetEnumerator()) {
				# define parameterss for Update-CMDeviceVariable
				$UpdateCMDeviceVariable = @{
					ResourceId    = $Device.ResourceID
					VariableName  = $DeviceVariable.Key
					VariableValue = $DeviceVariable.Value
					ErrorAction   = [System.Management.Automation.ActionPreference]::Stop
				}

				# update device variable for OSD domain OU name
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - checking device variable: '$($DeviceVariable.Key)'")
					Update-CMDeviceVariable @UpdateCMDeviceVariable
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: checking device variable")
					throw $_
				}
			}
		}
	}

	function Add-IsoToVM {
		[CmdletBinding()]
		param (
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			# define OSD parameters
			[Parameter(Mandatory)]
			[string]$Path
		)

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# get VM from parameters
		try {
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			throw $_
		}

		# update argument list for Test-Path
		$InvokeCommand['ArgumentList']['Path'] = $Path

		# test deployment path
		try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				# import module to load TestPathType enum
				Import-Module -Name 'Microsoft.PowerShell.Management'
				# define parameters for Test-Path
				$TestPath = @{
					Path        = $ArgumentList['Path']
					PathType    = [Microsoft.PowerShell.Commands.TestPathType]::Leaf
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				# test path
				Test-Path @TestPath
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not check provided path")
			throw $_
		}

		# evaluate deployment path
		if (-not $TestPath) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...skipping ISO attach, host did not find file: '$Path'")
			return
		}

		# define parameters for Get-VMDvdDrive
		$GetVMDvdDrive = @{
			VM          = $VM
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve DVD drive
		try {
			$VMDvdDrive = Get-VMDvdDrive @GetVMDvdDrive
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve DVD drives from VM")
			throw $_
		}

		# if multiple DVD drives found...
		if ($VMDvdDrive.Count -gt 1) {
			# sort drives by controller and LUN then select first drive
			Write-Host ("$Hostname,$ComputerName,$Name - found multiple DVD drives on VM; selecting first drive")
			$VMDvdDrive = $VMDvdDrive | Sort-Object -Property ControllerNumber, ControllerLocation | Select-Object -First 1
		}

		# if DVD drive not found...
		if ($null -eq $VMDvdDrive) {
			# define parameters for Get-VMScsiController
			$GetVMScsiController = @{
				VM          = $VM
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# get SCSI controller
			try {
				$VMScsiController = Get-VMScsiController @GetVMScsiController
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve SCSI controller")
				throw $_
			}

			# if multiple SCSI controllers found...
			if ($VMScsiController.Count -gt 1) {
				# sort drives by controller and LUN then select first drive
				Write-Host ("$Hostname,$ComputerName,$Name - found multiple SCSI controllers on VM; selecting first controller")
				$VMScsiController = $VMScsiController | Sort-Object -Property ControllerNumber | Select-Object -First 1
			}

			# if SCSI controller not found...
			if ($null -eq $VMScsiController) {
				# define parameters for Add-VMScsiController
				$AddVMScsiController = @{
					VM          = $VM
					Passthru    = $true
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}

				# add SCSI controller
				try {
					$VMScsiController = Add-VMScsiController @AddVMScsiController
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add SCSI controller")
					throw $_
				}
			}

			# define parameters for Add-VMDvdDrive
			$AddVMDvdDrive = @{
				VMDriveController = $VMScsiController
				Passthru          = $true
				ErrorAction       = [System.Management.Automation.ActionPreference]::Stop
			}

			# add DVD drive
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - adding DVD drive to VM")
				$VMDvdDrive = Add-VMDvdDrive @AddVMDvdDrive
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add DVD drive to VM")
				throw $_
			}
		}

		# define parameters for Set-VMDvdDrive
		$SetVMDvdDrive = @{
			VMDvdDrive  = $VMDvdDrive
			Path        = $Path
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# attach ISO to DVD drive
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...attaching ISO file: '$Path'")
			Set-VMDvdDrive @SetVMDvdDrive
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not attach ISO file to DVD drive")
			throw $_
		}
	}

	function Add-VMToClusterName {
		[CmdletBinding()]
		param(
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
			[string[]]$ClusterAffinityRules,
			[Parameter()]
			[bool]$DisableHeartbeat = $false
		)

		# get VM from parameters
		try {
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			throw $_
		}

		# define parameters for Get-ClusterGroup
		$GetClusterGroup = @{
			Cluster     = $ClusterName
			VMId        = $VM.Id
			ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
		}

		# retrieve existing cluster group
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - checking cluster for VM...")
			$ClusterGroup = Get-ClusterGroup @GetClusterGroup
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: getting cluster group for VM")
			throw $_
		}

		# if cluster group found...
		if ($null -ne $ClusterGroup) {
			# declare found
			Write-Host ("$Hostname,$ComputerName,$Name - ...VM found in cluster: $ClusterName")
		}
		# if cluster group not found...
		else {
			# declare and begin
			Write-Host ("$Hostname,$ComputerName,$Name - ...VM not found in cluster, adding to cluster: $ClusterName")

			# define parameters for Add-ClusterVirtualMachineRole
			$AddClusterVirtualMachineRole = @{
				Cluster     = $ClusterName
				VMId        = $VM.Id
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# add VM to cluster
			try {
				$ClusterGroup = Add-ClusterVirtualMachineRole @AddClusterVirtualMachineRole
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: adding VM to cluster: $ClusterName")
				throw $_
			}

			# declare state
			Write-Host ("$Hostname,$ComputerName,$Name - ...added VM to cluster")
		}

		# if DisableHeartbeat provided...
		if ($DisableHeartbeat) {
			# define parameters for Get-ClusterResource
			$GetClusterResource = @{
				Cluster     = $ClusterName
				VMId        = $VM.Id
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# retrieve existing cluster resource
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - retrieving parameters for VM...")
				$ClusterResource = Get-ClusterResource @GetClusterResource
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving parameters for VM")
				throw $_
			}

			# define parameters for Set-ClusterParameter
			$SetClusterParameter = @{
				Cluster     = $ClusterName
				InputObject = $ClusterResource
				Name        = 'CheckHeartbeat'
				Value       = 0
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# disable heartbeat for cluster resource
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...disabling heartbeat for VM")
				Set-ClusterParameter @SetClusterParameter
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: disabling heartbeat for VM")
				throw $_
			}
		}

		# if cluster priority defined...
		if ($PSBoundParameters.ContainsKey('ClusterPriority')) {
			Write-Host ("$Hostname,$ComputerName,$Name - checking cluster group priority...")
			# if cluster priority does not match...
			if ($ClusterGroup.Priority -ne $ClusterPriority) {
				# declare and begin
				Write-Host ("$Hostname,$ComputerName,$Name - ...setting cluster group priority to: $ClusterPriority")

				# set cluster priority
				try {
					$ClusterGroup.Priority = $ClusterPriority
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: setting cluster group priority")
					throw $_
				}
			}
			# if cluster priority matches...
			else {
				# declare
				Write-Host ("$Hostname,$ComputerName,$Name - ...found priority already set to: $ClusterPriority")
			}
		}

		# if cluster affinity rules defined...
		if ($PSBoundParameters.ContainsKey('ClusterAffinityRules')) {
			Write-Host ("$Hostname,$ComputerName,$Name - checking cluster affinity rules...")
			# process any requested cluster affinity rule
			:ClusterAffinityRules foreach ($ClusterAffinityRuleName in $ClusterAffinityRules) {
				# define parameters for Get-ClusterAffinityRule
				$GetClusterAffinityRule = @{
					Cluster     = $ClusterName
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}

				# retrieve cluster affinity rules
				try {
					$ClusterAffinityRule = Get-ClusterAffinityRule @GetClusterAffinityRule | Where-Object { $_.Name -eq $ClusterAffinityRuleName }
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving cluster affinity rules")
					throw $_
				}

				# if affinity rule not found...
				if ($null -eq $ClusterAffinityRule) {
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: cluster affinity rule not found: $ClusterAffinityRuleName")
					continue ClusterAffinityRules
				}

				# check affinity rule...
				if ($ClusterAffinityRule.Groups -contains $ClusterGroup.Name) {
					# declare
					Write-Host ("$Hostname,$ComputerName,$Name - ...found cluster group in cluster affinity rule: $ClusterAffinityRuleName")
					continue ClusterAffinityRules
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
				try {
					Add-ClusterGroupToAffinityRule @AddClusterGroupToAffinityRule
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: setting cluster group priority")
					throw $_
				}
			}
		}

		# if SkipPreferredOwner set...
		if ($SkipPreferredOwner) {
			# ...return cluster group
			return $ClusterGroup
		}

		# define parameters for Get-ClusterOwnerNode
		$GetClusterOwnerNode = @{
			InputObject = $ClusterGroup
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# get cluster group owner node(s)
		try {
			$ClusterOwnerNode = Get-ClusterOwnerNode @GetClusterOwnerNode
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving owner node(s) for cluster group")
			throw $_
		}

		# check cluster group owner node(s)
		if (($ClusterOwnerNode.OwnerNodes.Name -join ',') -ne $ComputerName) {
			# declare state
			Write-Host ("$Hostname,$ComputerName,$Name - ...setting preferred owner on VM")

			# define parameters for Move-ClusterGroup
			$SetClusterOwnerNode = @{
				Owners      = $ComputerName
				InputObject = $ClusterGroup
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# move cluster group to computer
			try {
				Set-ClusterOwnerNode @SetClusterOwnerNode
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: setting preferred owner on VM")
				throw $_
			}

			# retrieve updated cluster group
			try {
				$ClusterGroup = Get-ClusterGroup @GetClusterGroup
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving updated cluster group for VM")
				throw $_
			}
		}

		# return cluster group
		return $ClusterGroup
	}

	function Add-VMNetworkAdapterToDHCP {
		[CmdletBinding()]
		param(
			[string]$ComputerName,
			[string]$ScopeId,
			[string]$IPAddress,
			[string]$MacAddress,
			[string]$Router,
			[string[]]$DnsServer,
			[boolean]$ReservationRequired = $true
		)

		# define parameters for Get-DhcpServerv4Scope
		$GetDhcpServerv4Scope = @{
			ComputerName = $ComputerName
			ScopeId      = $ScopeId
			ErrorAction  = [System.Management.Automation.ActionPreference]::SilentlyContinue
		}

		# check for existing DHCP scope
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - checking for DHCP scope: '$ScopeId'")
			$Scope = Get-DhcpServerv4Scope @GetDhcpServerv4Scope
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: checking for DHCP scope")
			throw $_
		}

		# if DHCP scope not found...
		if ($null -eq $Scope) {
			# declare and return
			Write-Host ("$Hostname,$ComputerName,$Name - ...DHCP scope not found, skipping DHCP provisioning")
			return
		}

		# define parameters for Get-DhcpServerv4Reservation
		$GetDhcpServerv4Reservation = @{
			ComputerName = $ComputerName
			ScopeId      = $ScopeId
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve DHCP reservations
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...found DHCP scope, retrieving reservations...")
			$Reservations = Get-DhcpServerv4Reservation @GetDhcpServerv4Reservation
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving reservations from DHCP scope")
			throw $_
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
		if ($null -eq $Reservations) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...existing DHCP reservation not found")
		}
		# if matching DHCP reservations found...
		else {
			# loop through DHCP reservations
			:NextReservation foreach ($Reservation in $Reservations) {
				# if reservation found with both IP and client id...
				if ($Reservation.IPAddress -eq $IPAddress -and $Reservation.ClientId -eq $ClientId) {
					Write-Host ("$Hostname,$ComputerName,$Name - ...found existing DHCP reservation with requested IP address and client ID")
					$ReservationRequired = $false
					continue NextReservation
				}
				elseif ($Reservation.IPAddress -ne $IPAddress) {
					# define parameters for Remove-DhcpServerv4Reservation
					$RemoveDhcpServerv4Reservation = @{
						ComputerName = $ComputerName
						IPAddress    = $IPAddress
						ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
					}

					# remove DHCP reservation with same IP addresss
					try {
						Write-Host ("$Hostname,$ComputerName,$Name - ...removing existing DHCP reservation with conflicting IP address: '$($Reservation.IPAddress)'")
						Remove-DhcpServerv4Reservation @RemoveDhcpServerv4Reservation
					}
					catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing existing DHCP reservation'")
						throw $_
					}
				}
				elseif ($Reservation.ClientId -ne $ClientId) {
					# define parameters for Remove-DhcpServerv4Reservation
					$RemoveDhcpServerv4Reservation = @{
						ComputerName = $ComputerName
						ScopeId      = $ScopeId
						ClientId     = $ClientId
						ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
					}

					# remove DHCP reservation with same client ID
					try {
						Write-Host ("$Hostname,$ComputerName,$Name - ...removing existing DHCP reservation with conflicting client ID: '$($Reservation.ClientId)'")
						Remove-DhcpServerv4Reservation @RemoveDhcpServerv4Reservation
					}
					catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing existing DHCP reservation")
						throw $_
					}
				}
			}
		}

		# if reservation required...
		if ($ReservationRequired) {
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
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - creating DHCP reservation...")
				Add-DhcpServerv4Reservation @AddDhcpServerv4Reservation
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: creating DHCP reservcation")
				throw $_
			}

			# declare action and set repliation required
			Write-Host ("$Hostname,$ComputerName,$Name - ...created DHCP reservation")
		}

		# if options provided...
		if ($PSBoundParameters.ContainsKey('Router') -or $PSBoundParameters.ContainsKey('DnsServer')) {
			# define parameters for Get-DhcpServerv4OptionValue
			$GetDhcpServerv4OptionValue = @{
				ComputerName = $ComputerName
				IPAddress    = $IPAddress
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# retrieve options
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - retrieving existing DHCP options...")
				$DhcpServerv4OptionValues = Get-DhcpServerv4OptionValue @GetDhcpServerv4OptionValue
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving DHCP options")
				throw $_
			}

			# if router provided...
			if ($PSBoundParameters.ContainsKey('Router') -and $null -ne $Router) {
				# filter DHCP options
				$DhcpServerv4OptionValue = $DhcpServerv4OptionValues | Where-Object { $_.Name -eq 'Router' }

				# if DHPC option exists
				if ($DhcpServerv4OptionValue.Value -eq $Router ) {
					# declare state
					Write-Host ("$Hostname,$ComputerName,$Name - ...existing DHCP option for router found")
				}
				else {
					# if value is empty...
					if ([System.String]::IsNullOrEmpty($DhcpServerv4OptionValue)) {
						# declare state
						Write-Host ("$Hostname,$ComputerName,$Name - ...existing DHCP option for router not found")
					}
					# if value is not empty...
					else {
						# declare state
						Write-Host ("$Hostname,$ComputerName,$Name - ...existing DHCP option for router not correct")
					}

					# define parameters for Get-DhcpServerv4OptionValue
					$SetDhcpServerv4OptionValue = @{
						ComputerName = $ComputerName
						IPAddress    = $IPAddress
						Router       = $Router
						ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
					}

					# update options for IP address
					try {
						Write-Host ("$Hostname,$ComputerName,$Name - setting DHCP option for router...")
						Set-DhcpServerv4OptionValue @SetDhcpServerv4OptionValue
					}
					catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: setting DHCP option for router")
						throw $_
					}

					# declare action and set repliation required
					Write-Host ("$Hostname,$ComputerName,$Name - ...set DHCP option for router: $Router")
				}
			}

			# if name servers provided...
			if ($PSBoundParameters.ContainsKey('DnsServer') -and $null -ne $DnsServer) {
				# filter DHCP options
				$DhcpServerv4OptionValue = $DhcpServerv4OptionValues | Where-Object { $_.Name -eq 'Name Servers' }

				# if DHCP option already configured
				if ($DhcpServerv4OptionValue.Value -as [string] -eq $DnsServer -as [string]) {
					# declare state
					Write-Host ("$Hostname,$ComputerName,$Name - ...existing DHCP option for name servers already configured")
				}
				else {
					# if value is empty...
					if ([System.String]::IsNullOrEmpty($DhcpServerv4OptionValue)) {
						# declare state
						Write-Host ("$Hostname,$ComputerName,$Name - ...existing DHCP option for name servers not found")
					}
					# if value is not empty...
					else {
						# declare state
						Write-Host ("$Hostname,$ComputerName,$Name - ...existing DHCP option for name servers not correct")
					}

					# define parameters for Get-DhcpServerv4OptionValue
					$SetDhcpServerv4OptionValue = @{
						ComputerName = $ComputerName
						IPAddress    = $IPAddress
						DnsServer    = $DnsServer
						ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
					}

					# update options for IP address
					try {
						Write-Host ("$Hostname,$ComputerName,$Name - setting DHCP option for name servers...")
						Set-DhcpServerv4OptionValue @SetDhcpServerv4OptionValue
					}
					catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: setting DHCP option for name servers")
						throw $_
					}

					# declare action and set repliation required
					Write-Host ("$Hostname,$ComputerName,$Name - ...set DHCP option for name servers: $($DnsServer -join ',')")
				}
			}
		}

		# define parameters for DHCP reservation
		$GetDhcpServerv4Failover = @{
			ComputerName = $ComputerName
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# check for DHCP failover
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - retrieving DHCP failover for scope...")
			$Failover = Get-DhcpServerv4Failover @GetDhcpServerv4Failover
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving DHCP failover configuration")
			throw $_
		}

		# check for scope in failover
		if ($Failover -and $Failover.ScopeId -contains $ScopeId) {
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
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - replicating DHCP scope to peer: '$($Failover.PartnerServer)'")
				$null = Invoke-DhcpServerv4FailoverReplication @InvokeDhcpServerv4FailoverReplication
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: replicating DHCP scope")
				throw $_
			}

			# declare and return
			Write-Host ("$Hostname,$ComputerName,$Name - ...replicated DHCP scope to peer")
			return
		}
		else {
			# declare and return
			Write-Host ("$Hostname,$ComputerName,$Name - ...failover configuration not found for scope")
			return
		}
	}

	function Add-VMNetworkAdapterToVM {
		[CmdletBinding()]
		param(
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
		try {
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			throw $_
		}

		# define required parameters for Get-VMNetworkAdapter
		$GetVMNetworkAdapter = @{
			VM          = $VM
			Name        = $NetworkAdapterName
			ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
		}

		# retrieve existing adapters with requested values
		try {
			$VMNetworkAdapter = Get-VMNetworkAdapter @GetVMNetworkAdapter
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VMNetworkAdapters for VM")
			throw $_
		}

		# if multiple adapters found by name...
		if ($VMNetworkAdapter -is [array]) {
			# declare and remove adapters
			Write-Host ("$Hostname,$ComputerName,$Name - ...found multiple VMNetworkAdapters with name: '$NetworkAdapterName'")

			# processs each array entry and...
			foreach ($NetworkAdapter in $VMNetworkAdapter) {
				# define parameters for Remove-VMNetworkAdapter
				$RemoveVMNetworkAdapter = @{
					VMNetworkAdapter = $NetworkAdapter
					ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
				}

				# remove VMNetworkAdapter with matching name
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...removing VMNetworkAdapter with ID: '$($NetworkAdapter.Id.Split('\')[-1])'")
					Remove-VMNetworkAdapter @RemoveVMNetworkAdapter
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove VMNetworkAdapter")
					throw $_
				}
			}

			# clear adapter
			$null = $VMNetworkAdapter
		}

		# if single adapter found by name...
		if ($VMNetworkAdapter -is [Microsoft.HyperV.PowerShell.VMNetworkAdapter]) {
			# declare and begin verifying adapter settings
			Write-Host ("$Hostname,$ComputerName,$Name - ...found VMNetworkAdapter: '$NetworkAdapterName'")

			# if device naming is not enabled...
			if ($VMNetworkAdapter.DeviceNaming -ne 'On') {
				# define parameters for Set-VMNetworkAdapter
				$SetVMNetworkAdapter = @{
					VMNetworkAdapter = $VMNetworkAdapter
					DeviceNaming     = 'On'
					Passthru         = $true
					ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
				}

				# enable device naming on adapter
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...enabling DeviceNaming on VMNetworkAdapter: '$NetworkAdapterName'")
					$VMNetworkAdapter = Set-VMNetworkAdapter @SetVMNetworkAdapter
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set device naming on VMNetworkAdapter for VM")
					throw $_
				}
			}

			# if SwitchName defined and not correct...
			if ($PSBoundParameters.ContainsKey('SwitchName') -and $VMNetworkAdapter.SwitchName -ne $SwitchName) {
				# define parameters for Connect-VMNetworkAdapter
				$ConnectVMNetworkAdapter = @{
					VMNetworkAdapter = $VMNetworkAdapter
					SwitchName       = $SwitchName
					Passthru         = $true
					ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
				}

				# connect adapter to correct switch
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...connecting VMNetworkAdapter '$NetworkAdapterName' to switch '$SwitchName'")
					$VMNetworkAdapter = Connect-VMNetworkAdapter @ConnectVMNetworkAdapter
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not connect VMNetworkAdapter to switch")
					throw $_
				}
			}

			# if SwitchName not defined and has a value...
			if ($PSBoundParameters.ContainsKey('SwitchName') -eq $false -and $null -ne $VMNetworkAdapter.SwitchName) {
				# define parameters for Disconnect-VMNetworkAdapter
				$DisconnectVMNetworkAdapter = @{
					VMNetworkAdapter = $VMNetworkAdapter
					Passthru         = $true
					ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
				}

				# disconnect adapter from switch
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...disconnecting VMNetworkAdapter '$NetworkAdapterName' from switch '$($VMNetworkAdapter.SwitchName)'")
					$VMNetworkAdapter = Disconnect-VMNetworkAdapter @DisconnectVMNetworkAdapter
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not disconnect VMNetworkAdapter from switch")
					throw $_
				}
			}
		}
		# if single adapter not found by name...
		else {
			# define required parameters for Add-VMNetworkAdapter
			$AddVMNetworkAdapter = @{
				VM           = $VM
				Name         = $NetworkAdapterName
				DeviceNaming = 'On'
				Passthru     = $true
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# define optional parameters for Add-VMNetworkAdapter
			if ($PSBoundParameters['SwitchName']) {
				$AddVMNetworkAdapter['SwitchName'] = $SwitchName
			}

			# add network adapter to VM
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...adding VMNetworkAdapter: '$NetworkAdapterName'")
				$VMNetworkAdapter = Add-VMNetworkAdapter @AddVMNetworkAdapter
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add VMNetworkAdapter to VM")
				throw $_
			}
		}

		# if MacAddressSpoofing defined and not correct...
		if ($PSBoundParameters.ContainsKey('MacAddressSpoofing') -and $VMNetworkAdapter.MacAddressSpoofing -ne $MacAddressSpoofing) {
			# define required parameters for Set-VMNetworkAdapter
			$SetVMNetworkAdapter = @{
				VMNetworkAdapter   = $VMNetworkAdapter
				MacAddressSpoofing = $MacAddressSpoofing
				Passthru           = $true
				ErrorAction        = [System.Management.Automation.ActionPreference]::Stop
			}

			# update adapter with MacAddressSpoofing setting
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...setting MacAddressSpoofing to '$MacAddressSpoofing' on VMNetworkAdapter: '$NetworkAdapterName'")
				$VMNetworkAdapter = Set-VMNetworkAdapter @SetVMNetworkAdapter
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set MacAddressSpoofing on VMNetworkAdapter for VM")
				throw $_
			}
		}

		# if AllowTeaming defined and not correct...
		if ($PSBoundParameters.ContainsKey('AllowTeaming') -and $VMNetworkAdapter.AllowTeaming -ne $AllowTeaming) {
			# define parameters for Set-VMNetworkAdapter
			$SetVMNetworkAdapter = @{
				VMNetworkAdapter = $VMNetworkAdapter
				AllowTeaming     = $AllowTeaming
				Passthru         = $true
				ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
			}

			# update adapter with AllowTeaming setting
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...setting AllowTeaming to '$AllowTeaming' on VMNetworkAdapter: '$NetworkAdapterName'")
				$VMNetworkAdapter = Set-VMNetworkAdapter @SetVMNetworkAdapter
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set AllowTeaming on VMNetworkAdapter for VM")
				throw $_
			}
		}

		# return network adapter
		return $VMNetworkAdapter
	}

	function Set-VMNetworkAdapterVlanId {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)][ValidateScript({ $_ -is [Microsoft.HyperV.PowerShell.VMNetworkAdapter] })]
			[object]$VMNetworkAdapter,
			[string]$ComputerName = $VMNetworkAdapter.ComputerName.ToLower(),
			[string]$VlanMode,
			[int32]$VlanId,
			[string]$VlanIdList
		)

		# if VLAN mode is Access...
		if ($VlanMode -eq 'Access') {
			# ...but the VLAN ID is 0...
			if ($VlanId -eq 0) {
				Write-Warning -Message "VlanMode is '$VlanMode' but VlanId is 0; VMNetworkAdapter '$($VMNetworkAdapter.Name)' will be untagged" -WarningAction Inquire
				$VlanMode = 'Untagged'
			}
			# ...but the VLAN ID is null...
			elseif ($null -eq $VlanId) {
				Write-Warning -Message "VlanMode is '$VlanMode' but VlanId is null; VMNetworkAdapter '$($VMNetworkAdapter.Name)' will be untagged" -WarningAction Inquire
				$VlanMode = 'Untagged'
			}
		}

		# if VLAN mode is Trunk...
		if ($VlanMode -eq 'Trunk') {
			# ...but VlanId and VlanIdList are null
			if ($null -eq $VlanId -and $null -eq $VlanIdList) {
				Write-Warning -Message "VlanMode is '$VlanMode' but VlanId and VlanIdList are null; VMNetworkAdapter '$($VMNetworkAdapter.Name)' will be untagged" -WarningAction Inquire
				$VlanMode = 'Untagged'
			}
			# ...but VlanId is null
			elseif ($null -eq $VlanId) {
				Write-Warning -Message "VlanMode is '$VlanMode' but VlanId is null; VMNetworkAdapter '$($VMNetworkAdapter.Name)' will use VlanId '0' for VlanId" -WarningAction Inquire
				$VlanId = 0
			}
			# ...but VlanIdList is null
			elseif ($null -eq $VlanIdList) {
				Write-Warning -Message "VlanMode is '$VlanMode' but VlanIdList is null; VMNetworkAdapter '$($VMNetworkAdapter.Name)' will use VlanId '$VlanId' for VlanId" -WarningAction Inquire
				$VlanIdList = [string]$VlanId
			}
		}

		# if VLAN mode is Access...
		if ($VlanMode -eq 'Isolation') {
			# ...but the VLAN ID is 0...
			if ($VlanId -eq 0) {
				Write-Warning -Message "VlanMode is '$VlanMode' but VlanId is 0; VMNetworkAdapter '$($VMNetworkAdapter.Name)' will be untagged" -WarningAction Inquire
				$VlanMode = 'Untagged'
			}
			# ...but the VLAN ID is null...
			elseif ($null -eq $VlanId) {
				Write-Warning -Message "VlanMode is '$VlanMode' but VlanId is null; VMNetworkAdapter '$($VMNetworkAdapter.Name)' will be untagged" -WarningAction Inquire
				$VlanMode = 'Untagged'
			}
		}


		# get VLAN for network adapter
		try {
			$VMNetworkAdapterVlan = Get-VMNetworkAdapterVlan -VMNetworkAdapter $VMNetworkAdapter
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VLAN for VMNetworkAdapter")
			throw $_
		}

		# if VLAN is null or mode is Isolation...
		if ($VlanMode -eq 'Untagged' -or $VlanMode -eq 'Isolation') {
			# ...and VLAN mode not untagged...
			if ($VMNetworkAdapterVlan.OperationMode -ne 'Untagged') {
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
		elseif ($VlanMode -eq 'Trunk') {
			# ...and VLAN mode is not access or not VLAN list is not requested VLANs...
			if ($VMNetworkAdapterVlan.OperationMode -ne 'Trunk' -or $VMNetworkAdapterVlan.NativeVlanId -ne $VlanId -or $VMNetworkAdapter.AllowedVlanIdListString -ne $VlanIdList) {
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
		else {
			# ...and VLAN mode is not access or not VLAN list is not requested VLANs...
			if ($VMNetworkAdapterVlan.OperationMode -ne 'Access' -or $VMNetworkAdapterVlan.AccessVlanId -ne $VlanId) {
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
		if ($null -ne $SetVMNetworkAdapterVlan) {
			# ...set VLAN for VMNetworkAdapter
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - $SetVMNetworkAdapterVlanAnnounce")
				$VMNetworkAdapterVlan = Set-VMNetworkAdapterVlan @SetVMNetworkAdapterVlan
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set VLAN for VMNetworkAdapter")
				throw $_
			}
			# refresh VMNetworkAdapter
			$VMNetworkAdapter = $VMNetworkAdapterVlan.ParentAdapter
		}

		# get Isolation for network adapter
		try {
			$VMNetworkAdapterIsolation = Get-VMNetworkAdapterIsolation -VMNetworkAdapter $VMNetworkAdapter
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve Isolation for VMNetworkAdapter")
			throw $_
		}

		# if VlanMode is Isolation...
		if ($VlanMode -eq 'Isolation') {
			if ($null -eq $VlanId -or $VlanId -eq 0) {
				if ($VMNetworkAdapterIsolation.IsolationMode -ne 'Vlan' -or $VMNetworkAdapterIsolation.AllowUntaggedTraffic -eq $true -or $VMNetworkAdapterIsolation.DefaultIsolationID -ne 0) {
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
			else {
				if ($VMNetworkAdapterIsolation.IsolationMode -ne 'Vlan' -or $VMNetworkAdapterIsolation.AllowUntaggedTraffic -eq $false -or $VMNetworkAdapterIsolation.DefaultIsolationID -ne $VlanId) {
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
		else {
			if ($VMNetworkAdapterIsolation.IsolationMode -ne 'None') {
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
		if ($null -ne $SetVMNetworkAdapterIsolation) {
			# ...set Isolation for VMNetworkAdapter
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - $SetVMNetworkAdapterIsolationAnnounce")
				Set-VMNetworkAdapterIsolation @SetVMNetworkAdapterIsolation
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set VLAN for VMNetworkAdapter")
				throw $_
			}

			# refresh VMNetworkAdapter
			$VMNetworkAdapter = $VMNetworkAdapterVlan.ParentAdapter
		}

		# check if priority tag needs to be enabled
		if ($VlanMode -eq 'Isolation' -and $VMNetworkAdapter.IeeePriorityTag -eq 'Off') {
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
		if ($VlanMode -ne 'Isolation' -and $VMNetworkAdapter.IeeePriorityTag -eq 'On') {
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
		if ($null -ne $SetVMNetworkAdapter) {
			# ...set Isolation for VMNetworkAdapter
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - $SetVMNetworkAdapterAnnounce")
				$VMNetworkAdapter = Set-VMNetworkAdapter @SetVMNetworkAdapter
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set IeeePriorityTag for VMNetworkAdapter")
				throw $_
			}
		}

		# return VMNetworkAdapter after VLAN update
		return $VMNetworkAdapter
	}

	function Set-VMNetworkAdapterMacAddress {
		[CmdletBinding()]
		param(
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
		if ($PSBoundParameters['MacAddress']) {
			# declare provided MAC address
			Write-Host ("$Hostname,$ComputerName,$Name - ...using MAC address from parameter")
			# assign provided MAC address
			$StaticMacAddress = $MacAddress
		}
		# if MAC address was provided via prefix and IP address...
		elseif ($PSBoundParameters['IPAddress'] -and $PSBoundParameters['MacAddressPrefix']) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...creating MAC address from parameters")
			# create MAC address suffix by converting IPAddress octets to hexadecimal
			$MacAddressSuffix = ($IPAddress.Split('.') | ForEach-Object { ([int]$_).ToString('X2') }) -join $null
			# assign MAC address from prefix and suffix
			$StaticMacAddress = ($MacAddressPrefix, $MacAddressSuffix) -join $null
		}
		# if MAC address was not provided and VMNetworkAdapter has default MAC address
		elseif ($VMNetworkAdapter.MacAddress -eq '000000000000') {
			# retrieve MAC address from host
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...retrieving next MAC address from host")
				$StaticMacAddress = Get-VMHostNextMacAddress -ComputerName $ComputerName
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve next MAC address from host")
				throw $_
			}
		}
		# if MAC address was not provided and VMNetworkAdapter has non-default MAC address
		else {
			Write-Host ("$Hostname,$ComputerName,$Name - ...using existing MAC address: '$($VMNetworkAdapter.MacAddress)'")
			return $VMNetworkAdapter
		}

		# if static MAC addresss not defined or matches existing MAC address...
		if ($null -eq $StaticMacAddress -or $VMNetworkAdapter.MacAddress -eq $StaticMacAddress) {
			# ...return
			Write-Host ("$Hostname,$ComputerName,$Name - ...verified MAC address: '$($VMNetworkAdapter.MacAddress)'")
			return $VMNetworkAdapter
		}
		else {
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
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...setting MAC address to: '$StaticMacAddress'")
			$VMNetworkAdapter = Set-VMNetworkAdapter @SetVMNetworkAdapter
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set MAC address")
			throw $_
		}

		# return updated VMNetworkAdapter
		return $VMNetworkAdapter
	}

	function Set-VMSecuritySettings {
		[CmdletBinding()]
		param(
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower()
		)

		# get VM from parameters
		try {
			# cast return as type to force terminating error
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			throw $_
		}

		# define parameters for Get-VMKeyProtector
		$GetVMKeyProtector = @{
			VM          = $VM
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# get key protector
		try {
			$VMKeyProtector = Get-VMKeyProtector @GetVMKeyProtector
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM key protector")
			throw $_
		}

		# define parameters for ConvertTo-HgsKeyProtector
		$ConvertToHgsKeyProtector = @{
			Bytes       = $VMKeyProtector
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# test key protector
		try {
			$null = ConvertTo-HgsKeyProtector @ConvertToHgsKeyProtector
			Write-Host ("$Hostname,$ComputerName,$Name - ...found VM key protector")
		}
		catch {
			# define parameters for Set-VMKeyProtector
			$SetVMKeyProtector = @{
				VM                   = $VM
				NewLocalKeyProtector = $true
				ErrorAction          = [System.Management.Automation.ActionPreference]::Stop
			}

			# set key protector
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...creating key protector for VM")
				Set-VMKeyProtector @SetVMKeyProtector
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not create VM key protector")
				throw $_
			}
		}

		# define arguments for virtual TPM
		$EnableVMTPM = @{
			VM          = $VM
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# enable virtual TPM
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...enabling virtual TPM")
			Enable-VMTPM @EnableVMTPM
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not enable virtual TPM")
			throw $_
		}
	}

	function Set-VMSystemSettings {
		[CmdletBinding()]
		param(
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			# define system settings parameters
			[hashtable]$SystemSettings
		)

		# get VM from parameters
		try {
			# cast return as type to force terminating error
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			throw $_
		}

		# define CIM instance for VM system settings
		$GetCimInstanceForVM = @{
			VM          = $VM
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve original VM system settings and host management service via CIM
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...retrieving CIM instance for VM...")
			$CimInstanceForVM = Get-CimInstanceForVM @GetCimInstanceForVM
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve CIM instance for VM")
			throw $_
		}

		# define counter for changes
		$SystemSettingsCounter = [int32]0

		# modify VM system settings
		foreach ($SystemSetting in $SystemSettings.Keys) {
			if ($CimInstanceForVM.$SystemSetting -eq $SystemSettings[$SystemSetting]) {
				Write-Host ("$Hostname,$ComputerName,$Name - ...found '$SystemSetting' set to '$($SystemSettings[$SystemSetting])'")
			}
			else {
				Write-Host ("$Hostname,$ComputerName,$Name - ...updating '$SystemSetting' from '$($CimInstanceForVM.$SystemSetting)' to '$($SystemSettings[$SystemSetting])'")
				$CimInstanceForVM.$SystemSetting = $SystemSettings[$SystemSetting]
				$SystemSettingsCounter++
			}
		}

		# check counter for changes
		if ($SystemSettingsCounter -eq 0) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...existing firmware settings match requested settings")
			return
		}

		# serialize and encode VM system settings
		try {
			$CimSerializer = [Microsoft.Management.Infrastructure.Serialization.CimSerializer]::Create()
			$CimSerialized = $CimSerializer.Serialize($CimInstanceForVM, [Microsoft.Management.Infrastructure.Serialization.InstanceSerializationOptions]::None)
			$CimEncodedData = [System.Text.Encoding]::Unicode.GetString($CimSerialized)
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not serialize the CIM objects for VM firmware")
			throw $_
		}

		# define CIM instance for VM management service
		$GetCimInstanceForVMMS = @{
			ComputerName = $ComputerName
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve CIM instance for host management service
		Write-Host ("$Hostname,$ComputerName,$Name - ...retrieving CIM instance for VM management service")
		try {
			$CimInstanceForVMMS = Get-CimInstanceForVMMS @GetCimInstanceForVMMS
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve CIM instance for VM management service")
			throw $_
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
		try {
			$CimMethod = Invoke-CimMethod @InvokeCimMethod
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not call method to update firmware settings via CIM")
			throw $_
		}

		# check CIM return value
		if ($CimMethod.ReturnValue -eq 0) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...firmware settings updated...")
		}
		else {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: firmware settings not updated, CIM returned: '$($CimMethod.ReturnValue)'")
		}
	}

	function Set-VMFirstBootDevice {
		[CmdletBinding()]
		param(
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			# define first boot device
			[ValidateSet('VMHardDiskDrive', 'VMDvdDrive', 'VMNetworkAdapter')]
			[string]$FirstBootDeviceType = 'HardDiskDrive',
			[object]$FirstBootDevice
		)

		# get VM from parameters
		try {
			# cast return as type to force terminating error
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			throw $_
		}

		# if first boot device not provided...
		if ($null -eq $FirstBootDevice) {
			# switch on first boot device type
			switch ($FirstBootDeviceType) {
				'VMDvdDrive' {
					# define parameters for Get-VMDvdDrive
					$GetVMDvdDrive = @{
						VM          = $VM
						ErrorAction = [System.Management.Automation.ActionPreference]::Stop
					}

					# retrieve DVD drive
					try {
						$VMDvdDrive = Get-VMDvdDrive @GetVMDvdDrive
					}
					catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve DVD drives from VM")
						throw $_
					}

					# if multiple DVD drives found...
					if ($VMDvdDrive.Count -gt 1) {
						# sort drives by controller and LUN then select first drive
						Write-Host ("$Hostname,$ComputerName,$Name - found multiple DVD drives on VM; selecting first drive")
						$VMDvdDrive = $VMDvdDrive | Sort-Object -Property ControllerNumber, ControllerLocation | Select-Object -First 1
					}

					# define DVD drive as first boot device
					$FirstBootDevice = $VMDvdDrive
				}
				'VMHardDiskDrive' {
					# define parameters for Get-VMHardDiskDrive
					$GetVMHardDiskDrive = @{
						VM          = $VM
						ErrorAction = [System.Management.Automation.ActionPreference]::Stop
					}

					# retrieve hard disk drives
					try {
						$VMHardDiskDrive = Get-VMHardDiskDrive @GetVMHardDiskDrive
					}
					catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve hard disk drives from VM")
						throw $_
					}

					# if multiple hard disk drives found...
					if ($VMHardDiskDrive.Count -gt 1) {
						# sort drives by controller and LUN then select first drive
						Write-Host ("$Hostname,$ComputerName,$Name - found multiple hard disk drives on VM; selecting first drive")
						$VMHardDiskDrive = $VMHardDiskDrive | Sort-Object -Property ControllerNumber, ControllerLocation | Select-Object -First 1
					}

					# define hard disk drive as first boot device
					$FirstBootDevice = $VMHardDiskDrive
				}

				'VMNetworkAdapter' {
					# define parameters for Get-VMNetworkAdapter
					$GetVMNetworkAdapter = @{
						VM          = $VM
						ErrorAction = [System.Management.Automation.ActionPreference]::Stop
					}

					# retrieve network adapter
					try {
						$VMNetworkAdapter = Get-VMNetworkAdapter @GetVMNetworkAdapter
					}
					catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve hard disk drives from VM")
						throw $_
					}

					# if multiple hard disk drives found...
					if ($VMNetworkAdapter.Count -gt 1) {
						# sort drives by controller and LUN then select first drive
						Write-Host ("$Hostname,$ComputerName,$Name - found multiple network adapters on VM; selecting first adapter alphabetically")
						$VMNetworkAdapter = $VMNetworkAdapter | Sort-Object -Property Name | Select-Object -First 1
					}

					# define network adapter as first boot device
					$FirstBootDevice = $VMNetworkAdapter
				}
			}
		}

		# define parameters for Set-VMFirmware
		$SetVMFirmware = @{
			VM          = $VM
			BootOrder   = $FirstBootDevice
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# attach ISO to DVD drive
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...setting boot order in VM firmware")
			Set-VMFirmware @SetVMFirmware
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set boot order in VM firmware")
			throw $_
		}
	}

	function Add-VHDFromParams {
		[CmdletBinding()]
		param(
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			# define VHD parameters
			[Parameter(Mandatory = $true)]
			[string]$Path,
			[string]$ControllerType,
			[uint16]$ControllerNumber,
			[uint16]$ControllerLocation,
			[switch]$PreserveDrives
		)

		# get VM from parameters
		try {
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			throw $_
		}

		# if controller type is empty...
		if ([string]::IsNullOrEmpty($ControllerType)) {
			# if generation 1 VM...
			if ($VM.Generation -eq 1) {
				$ControllerType = 'IDE'
			}
			else {
				$ControllerType = 'SCSI'
			}
		}

		# switch on controller type
		switch ($ControllerType) {
			'IDE' {
				# if VM generation is not 1...
				if ($VM.Generation -ne 1) {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: found '$ControllerType' controller type requested on generation $($VM.Generation) VM")
					return
				}
				# if controller number not valid...
				if ($PSBoundParameters.ContainsKey('ControllerNumber') -and $ControllerNumber -notin 0..1) {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: found unsupported '$ControllerNumber' controller number for '$ControllerType' controller type")
					return
				}
				# if controller location not valid...
				if ($PSBoundParameters.ContainsKey('ControllerLocation') -and $ControllerLocation -notin 0..1) {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: found unsupported '$ControllerLocation' controller location for '$ControllerType' controller type")
					return
				}
			}
			'SCSI' {
				# if controller number provided...
				if ($PSBoundParameters.ContainsKey('ControllerNumber')) {
					# if scsi controller with requested number does not exist on VM...
					while ($null -eq (Get-VMScsiController -VM $VM -ControllerNumber $ControllerNumber)) {
						# ...create scsi controller on VM
						try {
							Write-Host ("$Hostname,$ComputerName,$Name - adding VMScsiController to VM")
							Add-VMScsiController -VM $VM -ErrorAction Stop
						}
						catch {
							Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add VMScsiController to VM")
							throw $_
						}
					}
				}
			}
			Default {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: found unsupported '$ControllerType' controller type")
				throw $_
			}
		}

		# define required parameters for Get-VMHardDiskDrive
		$GetVMHardDiskDrive = @{
			VM               = $VM
			ControllerNumber = $ControllerNumber
			ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
		}

		# define optional parameters for Get-VMHardDiskDrive
		if ($PSBoundParameters['ControllerNumber']) { $GetVMHardDiskDrive['ControllerNumber'] = $ControllerNumber }
		if ($PSBoundParameters['ControllerLocation']) { $GetVMHardDiskDrive['ControllerLocation'] = $ControllerLocation }

		# get all drives with matching parameters
		try {
			$VMHardDiskDrives = Get-VMHardDiskDrive @GetVMHardDiskDrive
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VMHardDiskDrives from VM")
			throw $_
		}

		# if path found on drives...
		if ($Path -in $VMHardDiskDrives.Path) {
			# ...return
			return
		}

		# retrieve existing drives
		try {
			$VMHardDiskDrives = Get-VMHardDiskDrive -VM $VM -ErrorAction Stop
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VMHardDiskDrives from VM")
			throw $_
		}

		# remove requested drive from other locations
		if ($PSBoundParameters['ControllerNumber']) {
			# ...get existing drives with requested path not on requested controller
			$VMHardDiskDrivesWithPath = $VMHardDiskDrives | Where-Object { $_.Path -eq $Path -and $_.ControllerNumber -ne $ControllerNumber }
			# if existing drives exists...
			foreach ($VMHardDiskDrive in $VMHardDiskDrivesWithPath) {
				# ...remove drives from VM
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...removing requested VMHardDiskDrive from unexpected controller on VM")
					Remove-VMHardDiskDrive -VMHardDiskDrive $VMHardDiskDrive -ErrorAction Stop
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove errant VMHardDiskDrive from VM")
					throw $_
				}
			}
		}

		# remove other drives from requested location
		if ($PSBoundParameters['ControllerLocation']) {
			# ...get existing drives without requested path on requested controller and requested location
			$VMHardDiskDrivesSansPath = $VMHardDiskDrives | Where-Object { $_.Path -ne $Path -and $_.ControllerNumber -eq $ControllerNumber -and $_.ControllerLocation -eq $ControllerLocation }
			# if existing drives exists...
			foreach ($VMHardDiskDrive in $VMHardDiskDrivesSansPath) {
				# ...remove drives from VM
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...removing unexpected VMHardDiskDrive from requested controller location and number on VM")
					Remove-VMHardDiskDrive -VMHardDiskDrive $VMHardDiskDrive -ErrorAction Stop
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove VMHardDiskDrive from VM")
					throw $_
				}
			}
		}

		# define arguments for drive
		$AddVMHardDiskDrive = @{
			VM               = $VM
			Path             = $Path
			ControllerType   = $ControllerType
			ControllerNumber = $ControllerNumber
			ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
		}

		# define optional arguments for drive
		if ($PSBoundParameters['ControllerLocation']) {
			$AddVMHardDiskDrive['ControllerLocation'] = $ControllerLocation
		}

		# add requested drive to requested location
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...adding VMHardDiskDrive to VM with path: '$Path'")
			Add-VMHardDiskDrive @AddVMHardDiskDrive
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add VMHardDiskDrive to VM")
			throw $_
		}

		# if preserve drives requested...
		if ($PreserveDrives) {
			# ...restore removed drives
			foreach ($VMHardDiskDrive in $VMHardDiskDrivesSansPath) {
				# define path and controller number of drive
				$AddVMHardDiskDrive = @{
					VM               = $VM
					Path             = $VMHardDiskDrive.Path
					ControllerNumber = $VMHardDiskDrive.ControllerNumber
					ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
				}
				# add drive to VM
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...restoring VMHardDiskDrive to VM with path: '$($VMHardDiskDrive.Path)'")
					Add-VMHardDiskDrive @AddVMHardDiskDrive
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not restore VMHardDiskDrive to VM")
					throw $_
				}
			}
		}
	}

	function Copy-VHDFromParams {
		param (
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			# define VHD parameters
			[Parameter(Mandatory)]
			[string]$Path,
			[string]$DestinationPath
		)

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# get VM from parameters
		try {
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			throw $_
		}

		# update argument list for Test-Path
		$InvokeCommand['ArgumentList']['Path'] = $Path

		# test deployment path
		try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				# import module to load TestPathType enum
				Import-Module -Name 'Microsoft.PowerShell.Management'
				# define parameters for Test-Path
				$TestPath = @{
					Path        = $ArgumentList['Path']
					PathType    = [Microsoft.PowerShell.Commands.TestPathType]::Leaf
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				# test path
				Test-Path @TestPath
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not check provided path")
			throw $_
		}

		# evaluate deployment path
		if ($TestPath) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...found source VHD: $Path")
		}
		else {
			Write-Host ("$Hostname,$ComputerName,$Name - ...skipping VHD attach, host did not find file: '$Path'")
			return
		}

		# if DestinationPath provided...
		if ($PSBoundParameters.ContainsKey('DestinationPath')) {
			# if hard drives do not contain VHD with provided destination path...
			if (!$VM.HardDrives.Where({ $_.Path -eq $DestinationPath })) {
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping VHD copy, could not locate target VHD on VM with path: $DestinationPath")
				return
			}
			else {
				Write-Host ("$Hostname,$ComputerName,$Name - ...found target VHD: $DestinationPath")
			}
		}
		# if DestinationPath not provided...
		else {
			# select path of first hard drive by controller number then controller location
			$DestinationPath = $VM.HardDrives | Sort-Object -Property 'ControllerNumber', 'ControllerLocation' | Select-Object -First 1 -ExpandProperty 'Path'

			# if destination path is null or empty...
			if ([System.String]::IsNullOrEmpty($DestinationPath)) {
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping VHD copy, could not locate the first VHD on VM")
				return
			}
			else {
				Write-Host ("$Hostname,$ComputerName,$Name - ...located first VHD: $DestinationPath")
			}
		}

		# update argument list for Get-Item
		$InvokeCommand['ArgumentList']['Path'] = $DestinationPath

		# retrieve first hard drive
		try {
			$GetItem = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				$GetItem = @{
					Path        = $ArgumentList['Path']
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				Get-Item @GetItem
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve target VHD: '$DestinationPath'")
			throw $_
		}

		# evaluate first hard drive
		if ($GetItem.Length -gt 4MB) {
			Write-Warning ("$Hostname,$ComputerName,$Name - found target VHD larger than expected: '$(Format-Bytes -Size $GetItem.Length)'")
			Write-Warning ("$Hostname,$ComputerName,$Name - replace VHD?") -WarningAction Inquire
		}

		# update argument list for Copy-Item
		$InvokeCommand['ArgumentList']['Path'] = $Path
		$InvokeCommand['ArgumentList']['Destination'] = $DestinationPath

		# copy deployment path to VHD
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...copying source VHD")
			$CopyItem = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				$CopyItem = @{
					Path        = $ArgumentList['Path']
					Destination = $ArgumentList['Destination']
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				Copy-Item @CopyItem
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not copy VHD from provided path to destination: '$DestinationPath'")
			throw $_
		}

		# update argument list for Get-ACL
		$InvokeCommand['ArgumentList']['Path'] = $DestinationPath
		$InvokeCommand['ArgumentList']['VMId'] = $VM.Id
		$InvokeCommand['ArgumentList'].Remove('Destination')

		# update permissions
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...updating target VHD ACL")
			Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
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
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not update ACL for VHD: '$DestinationPath'")
			throw $_
		}
	}

	function Edit-VHDFromParams {
		param (
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			# define VHD parameters
			[string]$DestinationPath,
			# define unattend file parameters
			[Parameter(Mandatory)]
			[string]$UnattendFile,
			[hashtable]$ExpandStrings = @{}
		)

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# update argument list for Test-Path
		$InvokeCommand['ArgumentList']['Path'] = $UnattendFile

		# test unattend file
		try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				# import module to load TestPathType enum
				Import-Module -Name 'Microsoft.PowerShell.Management'
				# define parameters for Test-Path
				$TestPath = @{
					Path        = $ArgumentList['Path']
					PathType    = [Microsoft.PowerShell.Commands.TestPathType]::Leaf
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				# test path
				Test-Path @TestPath
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not check provided path for unattend file")
			throw $_
		}

		# evaluate unattend file
		if (!$TestPath) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...skipping VHD edit, host did not find unattend file: '$UnattendFile'")
			return
		}

		# get VM from parameters
		try {
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			throw $_
		}

		# if DestinationPath provided...
		if ($PSBoundParameters.ContainsKey('DestinationPath')) {
			# if hard drives do not contain VHD with provided destination path...
			if (!$VM.HardDrives.Where({ $_.Path -eq $DestinationPath })) {
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping VHD edit, could not locate target VHD on VM with path: $DestinationPath")
				return
			}
			else {
				Write-Host ("$Hostname,$ComputerName,$Name - ...found target VHD: $DestinationPath")
			}
		}
		# if DestinationPath not provided...
		else {
			# select path of first hard drive by controller number then controller location
			$DestinationPath = $VM.HardDrives | Sort-Object -Property 'ControllerNumber', 'ControllerLocation' | Select-Object -First 1 -ExpandProperty 'Path'

			# if destination path is null or empty...
			if ([System.String]::IsNullOrEmpty($DestinationPath)) {
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping VHD edit, could not locate the first VHD on VM")
				return
			}
			else {
				Write-Host ("$Hostname,$ComputerName,$Name - ...located first VHD: $DestinationPath")
			}
		}

		# update argument list for Get-Item
		$InvokeCommand['ArgumentList']['Path'] = $DestinationPath

		# retrieve target VHD
		try {
			$GetItem = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				$GetItem = @{
					Path        = $ArgumentList['Path']
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				Get-Item @GetItem
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve target VHD: '$DestinationPath'")
			throw $_
		}

		# update argument list for Mount-VHD
		$InvokeCommand['ArgumentList']['Path'] = $DestinationPath

		# mount VHD
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...mounting target VHD")
			Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				# define parameters for Mount-VHD
				$MountVHD = @{
					Path        = $ArgumentList['Path']
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				# mount VHD
				Mount-VHD @MountVHD
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not mount target VHD: '$($_.Exception.Message)'")
			throw $_
		}

		# retrieve volume path
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...retrieving volume path")
			$Root = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				# retrieve disk object from path
				$Disk = Get-Disk | Sort-Object -Property 'Number' | Where-Object { $_.Location -eq $ArgumentList['Path'] }

				# retrieve first basic partition on disk
				$Partition = Get-Partition -Disk $Disk | Sort-Object -Property 'PartitionNumber' | Where-Object { $_.Type -eq 'Basic' } | Select-Object -First 1

				# retrieve first volume on partition
				$Volume = Get-Volume -Partition $Partition | Select-Object -First 1

				# return volume path
				return $Volume.Path
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve volume path: '$($_.Exception.Message)'")
			throw $_
		}

		# update argument list for PSDrive
		$InvokeCommand['ArgumentList']['Name'] = $Name
		$InvokeCommand['ArgumentList']['Root'] = $Root

		# create PSDrive
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...creating PSDrive")
			$PSDriveName = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				# define parameters for New-PSDrive
				$NewPSDrive = @{
					Name        = $ArgumentList['Name']
					Root        = $ArgumentList['Root']
					PSProvider  = 'FileSystem'
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				# create PSDrive
				$PSDrive = New-PSDrive @NewPSDrive
				# return PSDrive name
				return $PSDrive.Name
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not create PSDrive: '$($_.Exception.Message)'")
			throw $_
		}

		# define unattend file on VHD
		$UnattendFileOnVHD = '{0}:\Windows\Panther\unattend.xml' -f $PSDriveName

		# update argument list for Copy-Item with unattend files on VHD
		$InvokeCommand['ArgumentList']['Path'] = $UnattendFile
		$InvokeCommand['ArgumentList']['Destination'] = $UnattendFileOnVHD

		# copy file to VHD
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...updating target VHD with unattend file: '$UnattendFile'")
			Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				$CopyItem = @{
					Path        = $ArgumentList['Path']
					Destination = $ArgumentList['Destination']
					Force       = $true
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				Copy-Item @CopyItem
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not copy file: '$UnattendFile'")
			throw $_
		}

		# update argument list for Get-Content and Set-Content
		$InvokeCommand['ArgumentList']['Path'] = $UnattendFileOnVHD

		# get content of file on VHD
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...retrieving content from unattend file: '$UnattendFileOnVHD'")
			$Content = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				$GetContent = @{
					Path        = $ArgumentList['Path']
					Raw         = $true
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				Get-Content @GetContent
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve content from unattend file: '$UnattendFileOnVHD'")
			throw $_
		}

		# resolve expand strings in content
		try {
			$Content = Resolve-ExpandStringsInXML -String $Content -ExpandStrings $ExpandStrings
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not resolve expand strings in content from unattend file: '$UnattendFileOnVHD'")
			throw $_
		}

		# update argument list for Set-Content
		$InvokeCommand['ArgumentList']['Value'] = $Content

		# set content of file on VHD
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...writing content to unattend file: '$UnattendFileOnVHD'")
			$Content = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				# define parameters for Set-Content
				$SetContent = @{
					Path        = $ArgumentList['Path']
					Value       = $ArgumentList['Value']
					NoNewline   = $true
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				# update content in unattend file
				Set-Content @SetContent
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not write content to unattend file: '$UnattendFileOnVHD'")
			throw $_
		}

		# remove PSDrive
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...removing PSDrive")
			Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				# define parameters for Remove-PSDrive
				$RemovePSDrive = @{
					Name        = $ArgumentList['Name']
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				# remove PSDrive
				Remove-PSDrive @RemovePSDrive
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove PSDrive: '$($_.Exception.Message)'")
			throw $_
		}

		# update argument list for Dismount-VHD
		$InvokeCommand['ArgumentList']['Path'] = $DestinationPath

		# dismount VHD
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...dismounting target VHD after updates")
			Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				# define parameters for Dismount-VHD
				$DismountVHD = @{
					Path        = $ArgumentList['Path']
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				# dismount VHD
				Dismount-VHD @DismountVHD
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not dismount target VHD: '$($_.Exception.Message)'")
			throw $_
		}
	}

	function New-VHDFromParams {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[Parameter(Mandatory = $true)]
			[string]$Path,
			[Parameter(Mandatory = $true)]
			[uint64]$SizeBytes
		)

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['Path'] = $Path

		# get parent path
		try {
			Write-Verbose ("$Hostname,$ComputerName,$Name - getting parent path for VHD")
			$ParentPath = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				Split-Path -Path $ArgumentList['Path'] -Parent -ErrorAction Stop
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not get parent path")
			throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['ParentPath'] = $ParentPath

		# verify parent path
		try {
			Write-Verbose ("$Hostname,$ComputerName,$Name - testing parent path for VHD")
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				# import module to load TestPathType enum
				Import-Module -Name 'Microsoft.PowerShell.Management'
				# define parameters for Test-Path
				$TestPath = @{
					Path        = $ArgumentList['ParentPath']
					PathType    = [Microsoft.PowerShell.Commands.TestPathType]::Container
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				# test path
				Test-Path @TestPath
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not check provided parent path")
			throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['TestPath'] = $TestPath

		# verify parent path
		try {
			Write-Verbose ("$Hostname,$ComputerName,$Name - verifying parent path for VHD")
			Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				if (-not $ArgumentList['TestPath']) {
					$null = New-Item -Path $ArgumentList['ParentPath'] -ItemType 'Directory' -ErrorAction Stop
				}
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not verify parent path")
			throw $_
		}

		# define arguments for Get-VHD
		$GetVHD = @{
			ComputerName = $ComputerName
			Path         = $Path
			ErrorAction  = [System.Management.Automation.ActionPreference]::SilentlyContinue
		}

		# get existing VHD
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - checking for VHD with Path: '$Path'")
			$VHD = Get-VHD @GetVHD
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not get VHD")
			throw $_
		}

		# if VHD found...
		if ($null -ne $VHD) {
			# report VHD found
			Write-Host ("$Hostname,$ComputerName,$Name - ...found existing VHD with Path: '$Path'")
			# if use existing VHDs not provided...
			if (!$UseExistingVHDs) {
				# warn and inquire
				Write-Warning -Message ("$Hostname,$ComputerName,$Name - continue and use existing VHD?") -WarningAction Inquire
			}
			# return
			return
		}

		# define arguments for New-VHD
		$NewVHD = @{
			ComputerName = $ComputerName
			Path         = $Path
			SizeBytes    = $SizeBytes
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# create the VHD
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - creating VHD with Path: '$Path'")
			$null = New-VHD @NewVHD
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not create VHD")
			throw $_
		}
	}

	function New-VmFromParams {
		[CmdletBinding()]
		param(
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
		if ($UseDefaultPathOnHost) {
			try {
				$Path = Get-VMHost -ComputerName $ComputerName | Select-Object -ExpandProperty 'VirtualMachinePath'
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VirtualMachinePath on host")
				throw $_
			}
			Write-Host ("$Hostname,$ComputerName,$Name - ...using default VM path: '$Path")
		}
		else {
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
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - creating VM...")
			$VM = New-VM @NewVM
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not create VM")
			throw $_
		}

		# remove default network adapter
		try {
			Get-VMNetworkAdapter -VM $VM | Remove-VMNetworkAdapter -Confirm:$false
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove initial VMNetworkAdapter")
			throw $_
		}

		# define parameters for integration services
		$EnableVMIntegrationService = @{
			VM          = $VM
			Name        = 'Guest Service Interface'
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# enable integration services
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...enabling guest services")
			Enable-VMIntegrationService @EnableVMIntegrationService
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not enable guest services")
			throw $_
		}

		# define parameters for VM processor
		$SetVMProcessor = @{
			VM                             = $VM
			Count                          = $ProcessorCount
			ExposeVirtualizationExtensions = $true
			ErrorAction                    = [System.Management.Automation.ActionPreference]::Stop
		}

		# if SMT should be disabled...
		if ($DisableSMT) {
			$SetVMProcessor['HwThreadCountPerCore'] = 1
		}

		# configure VM processor
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...configuring processor")
			Set-VMProcessor @SetVMProcessor
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not configure processor")
			throw $_
		}

		# validate minimum memory
		if ($null -ne $MemoryMinimumBytes -and $MemoryMinimumBytes -gt 0 -and $MemoryMinimumBytes -gt $MemoryStartupBytes) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...overriding MemoryMinimumBytes; provided value is not less than or equal to MemoryStartupBytes")
			$MemoryMinimumBytes = $MemoryStartupBytes
		}

		# validate maximum memory
		if ($null -ne $MemoryMaximumBytes -and $MemoryMaximumBytes -gt 0 -and $MemoryMaximumBytes -lt $MemoryStartupBytes) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...overriding MemoryMaximumBytes; provided value is not greater than or equal to MemoryStartupBytes")
			$MemoryMaximumBytes = $MemoryStartupBytes
		}

		# configure memory
		if ($MemoryMinimumBytes -and $MemoryMaximumBytes) {
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
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...enabling dynamic memory (start, min, max): $MemoryValues")
				Set-VMMemory @SetVMMemory
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set dynamic memory (start, min, max): $MemoryValues")
				throw $_
			}
		}

		# if virtual TPM requested...
		if ($EnableVMTPM) {
			# define arguments for VM security settings
			$SetVMSecuritySettings = @{
				VM = $VM
			}

			# set VM security settings
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - updating security settings...")
				Set-VMSecuritySettings @SetVMSecuritySettings
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not update security settings")
				throw $_
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
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - updating system settings...")
			Set-VMSystemSettings @SetVMSystemSettings
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not update system settings")
			throw $_
		}

		# return VM object
		return $VM
	}

	function Remove-VMFromClusterName {
		[CmdletBinding()]
		param(
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			# define cluster parameters
			[Parameter(Mandatory = $true)]
			[string]$ClusterName
		)

		# get VM from parameters
		try {
			$VM = Get-VMFromParameters -ComputerName $ComputerName -VM $VM
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM")
			throw $_
		}

		# define parameters for Get-ClusterGroup
		$GetClusterGroup = @{
			Cluster     = $ClusterName
			VMId        = $VM.Id
			ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
		}

		# retrieve existing cluster group
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - checking cluster for VM...")
			$ClusterGroup = Get-ClusterGroup @GetClusterGroup
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: getting cluster group for VM")
			throw $_
		}

		# if cluster group not found...
		if ($null -eq $ClusterGroup) {
			# declare and return
			Write-Host ("$Hostname,$ComputerName,$Name - ...VM not found in cluster: $ClusterName")
			return
		}

		# define parameters for Remove-ClusterGroup
		$RemoveClusterGroup = @{
			Cluster         = $ClusterName
			VMId            = $VM.Id
			RemoveResources = $true
			Force           = $true
			ErrorAction     = [System.Management.Automation.ActionPreference]::SilentlyContinue
		}

		# remove cluster group
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...VM found in cluster, removing from cluster: $ClusterName")
			Remove-ClusterGroup @RemoveClusterGroup
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing VM from cluster")
			throw $_
		}

		# declare and return
		Write-Host ("$Hostname,$ComputerName,$Name - ...removed VM from cluster")
		return
	}

	function Resolve-ExpandStringsInXML {
		param(
			[Parameter(Mandatory)]
			[string]$String,
			[Parameter(Mandatory)]
			[hashtable]$ExpandStrings
		)

		# if administrator password provided...
		if ($ExpandStrings.ContainsKey('AdministratorPassword')) {
			# uncomment administrator password section in unattend file
			$String = $String.Replace('<!-- <AdministratorPassword>', '<AdministratorPassword>')
			$String = $String.Replace('</AdministratorPassword> -->', '</AdministratorPassword>')
		}
		# if administrator password not provided...
		else {
			# hide administrator password expand string from the expand strings loop
			$String = $String -replace '%ADMINISTRATORPASSWORD%', '<%>ADMINISTRATORPASSWORD<%>'
		}

		# if domain join username and password provided...
		if ($ExpandStrings.ContainsKey('Username') -and $ExpandStrings.ContainsKey('Password')) {
			# uncomment domain join section in unattend file
			$String = $String.Replace('<!-- <identification>', '<identification>')
			$String = $String.Replace('</identification> -->', '</identification>')
			# uncomment domain accounts section in unattend file
			$String = $String.Replace('<!-- <DomainAccounts>', '<DomainAccounts>')
			$String = $String.Replace('</DomainAccounts> -->', '</DomainAccounts>')
		}
		# if domain join username and password not provided...
		else {
			# hide domain join expand strings from the expand strings loop
			$String = $String.Replace('%USERNAME%', '<%>USERNAME<%>')
			$String = $String.Replace('%PASSWORD%', '<%>PASSWORD<%>')
			$String = $String.Replace('%DOMAINNAME%', '<%>DOMAINNAME<%>')
			$String = $String.Replace('%ORGANIZATIONALUNIT%', '<%>ORGANIZATIONALUNIT<%>')
		}

		# while content contains XML element with expand string as value...
		while ($String -match '<\w+>%(?<ExpandString>\w+)%</\w+>') {
			# retrieve original XML element
			$OriginalString = $Matches[0]
			# retrieve expand string
			$ExpandString = $Matches['ExpandString']
			# if value for expand string provided...
			if ($ExpandStrings.ContainsKey($ExpandString)) {
				# replace the expand string with the provided value
				$ModifiedString = $OriginalString -replace "%$ExpandString%", $ExpandStrings[$ExpandString]
			}
			else {
				# comment out the original XML element
				$ModifiedString = '<!-- {0} -->' -f ($OriginalString -replace '%', '<%>')
			}
			# replace original XML element with modified XML element
			$String = $String -replace $OriginalString, $ModifiedString
		}

		# return updated string
		return $String
	}
}

process {
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
	try {
		$JsonData = [array](Get-Content -Path $Json -ErrorAction Stop | ConvertFrom-Json)
	}
	catch {
		Write-Warning -Message "could not read configuration file: '$Json'"
		throw $_
	}

	# process each VMname
	:VMName foreach ($Name in $VMName) {
		# check if JSON contains VM
		if ($null -eq $JsonData.$Name) {
			Write-Host ("$Hostname - VM not found in Json: '$Name'")
			continue
		}

		# override ComputerName with bound parameters if provided
		if ($PSBoundParameters.ContainsKey('ComputerName')) {
			$ComputerName = $PSBoundParameters['ComputerName']
			Write-Warning ("overriding ComputerName from JSON: '$($JsonData.$Name.ComputerName)'")
		}
		else {
			$ComputerName = $JsonData.$Name.ComputerName
		}

		# override VirtualMachinePath with bound parameters if provided
		if ($PSBoundParameters.ContainsKey('Path')) {
			$Path = $PSBoundParameters['Path']
			Write-Warning ("overriding Path from JSON: '$($JsonData.$Name.Path)'")
		}
		else {
			$Path = $JsonData.$Name.Path
		}

		# if VM has host...
		if ($null -ne $ComputerName) {
			# define parameters for Get-ClusterName
			$GetClusterName = @{
				ComputerName = $ComputerName
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# check if host is clustered
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - checking if host is clustered...")
				$ClusterName = Get-ClusterName @GetClusterName
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: checking if host is clustered")
				throw $_
			}

			# define parameters for Get-VMFromComputerName
			$GetVMFromComputerName = @{
				Name         = $Name
				ComputerName = $ComputerName
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# if clustername not defined...
			if ([string]::IsNullOrEmpty($ClusterName)) {
				# declare and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...host is not clustered")
			}
			else {
				# declare and define optional parameters for Get-VMFromComputerName
				Write-Host ("$Hostname,$ComputerName,$Name - ...host is in cluster: '$ClusterName'")
				$GetVMFromComputerName['ClusterName'] = $ClusterName
			}

			# retrieve VM
			try {
				$VM = Get-VMFromComputerName @GetVMFromComputerName
			}
			catch {
				throw $_
			}

			# check VM
			if ($VM -eq 'multiple') {
				continue VMName
			}
		}

		# if VM is on a different computer...
		if ($null -ne $VM -and $ComputerName -ne $VM.ComputerName) {
			# declare and begin
			Write-Host ("$Hostname,$ComputerName,$Name - VM found on another computer...")

			# update computer name
			try {
				$ComputerName = $VM.ComputerName.ToLower()
			}
			catch {
				throw $_
			}

			# declare and continue
			Write-Host ("$Hostname,$ComputerName,$Name - ....updated computer name")
		}

		# if VM is online requested...
		if ($null -ne $VM -and $VM.State -ne 'Off') {
			# if should continue prompt returns false...
			if (!$PSCmdLet.ShouldContinue('VM is not offline! Power off and reconfigure VM?', $VM.Name, $true, [ref]$YesToAll, [ref]$NoToAll)) {
				continue VMName
			}

			# define parameters for Stop-VM
			$StopVM = @{
				VM      = $VM
				TurnOff = $true
				Confirm = $false
			}

			# stop VM
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - stopping VM on host...")
				Stop-VM @StopVM
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: stopping VM")
				throw $_
			}

			# report
			Write-Host ("$Hostname,$ComputerName,$Name - ...VM powered off")
		}

		# if VM is on a cluster...
		if ($null -ne $VM -and -not [string]::IsNullOrEmpty($ClusterName)) {
			# define required parameters for Add-VMToClusterName
			$RemoveVMFromClusterName = @{
				VM          = $VM
				ClusterName = $ClusterName
			}

			# remove VM from cluster
			try {
				Remove-VMFromClusterName @RemoveVMFromClusterName
			}
			catch {
				throw $_
			}
		}

		# if VM not found...
		if ($null -eq $VM -and $null -ne $ComputerName) {
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
			if ($null -ne $JsonData.$Name.ProcessorCount) {
				$NewVMFromParams['ProcessorCount'] = $JsonData.$Name.ProcessorCount
				Write-Host ("$Hostname,$ComputerName,$Name -   ProcessorCount: $($NewVMFromParams['ProcessorCount'])")
			}
			if ($null -ne $JsonData.$Name.MemoryStartupBytes) {
				$NewVMFromParams['MemoryStartupBytes'] = $JsonData.$Name.MemoryStartupBytes
				Write-Host ("$Hostname,$ComputerName,$Name -   MemoryStartupBytes: $(Format-Bytes -Size $($NewVMFromParams['MemoryStartupBytes']))")
			}
			if ($null -ne $JsonData.$Name.MemoryMinimumBytes) {
				$NewVMFromParams['MemoryMinimumBytes'] = $JsonData.$Name.MemoryMinimumBytes
				Write-Host ("$Hostname,$ComputerName,$Name -   MemoryMinimumBytes: $(Format-Bytes -Size $($NewVMFromParams['MemoryMinimumBytes']))")
			}
			if ($null -ne $JsonData.$Name.MemoryMaximumBytes) {
				$NewVMFromParams['MemoryMaximumBytes'] = $JsonData.$Name.MemoryMaximumBytes
				Write-Host ("$Hostname,$ComputerName,$Name -   MemoryMaximumBytes: $(Format-Bytes -Size $($NewVMFromParams['MemoryMaximumBytes']))")
			}
			if ($null -ne $JsonData.$Name.DisableSMT) {
				$NewVMFromParams['DisableSMT'] = $JsonData.$Name.DisableSMT
				Write-Host ("$Hostname,$ComputerName,$Name -   DisableSMT: $($NewVMFromParams['DisableSMT'])")
			}
			if ($null -ne $JsonData.$Name.EnableVMTPM) {
				$NewVMFromParams['EnableVMTPM'] = $JsonData.$Name.EnableVMTPM
				Write-Host ("$Hostname,$ComputerName,$Name -   EnableVMTPM: $($NewVMFromParams['EnableVMTPM'])")
			}
			if ($null -ne $JsonData.$Name.Generation) {
				$NewVMFromParams['Generation'] = $JsonData.$Name.Generation
				Write-Host ("$Hostname,$ComputerName,$Name -   Generation: $($NewVMFromParams['Generation'])")
			}

			# create VM from provided parameters
			try {
				$VM = New-VmFromParams @NewVMFromParams
			}
			catch {
				Write-Verbose 'caught VM create error'
				throw $_
			}
		}

		# if VM has hard drives...
		if ($null -ne $VM -and $null -ne $JsonData.$Name.VMHardDiskDrives) {
			# loop through hard drives
			foreach ($VMHardDiskDrive in $JsonData.$Name.VMHardDiskDrives) {
				# if path provided...
				if ($PSBoundParameters.ContainsKey('Path')) {
					# retrieve modified VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path.Replace($JsonData.$Name.Path, $Path)
				}
				else {
					# retrieve original VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path
				}

				# define parameters
				$NewVHDFromParams = @{
					ComputerName = $ComputerName
					Path         = $VMHardDiskDrivePath
					SizeBytes    = $VMHardDiskDrive.SizeBytes
				}

				# create VHD
				try {
					New-VHDFromParams @NewVHDFromParams
				}
				catch {
					throw $_
				}
			}

			# filter hard drives with controller number and controller location
			$VMHardDiskDrivesWithNumberAndLocation = $JsonData.$Name.VMHardDiskDrives | Where-Object { $null -ne $_.ControllerNumber -and $null -ne $_.ControllerLocation }

			# attach hard drives with controller number and controller location
			foreach ($VMHardDiskDrive in $VMHardDiskDrivesWithNumberAndLocation) {
				# if path provided...
				if ($PSBoundParameters.ContainsKey('Path')) {
					# retrieve modified VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path.Replace($JsonData.$Name.Path, $Path)
				}
				else {
					# retrieve original VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path
				}

				# define parameters
				$AddVHDFromParams = @{
					ComputerName       = $ComputerName
					VM                 = $VM
					Path               = $VMHardDiskDrivePath
					ControllerType     = $VMHardDiskDrive.ControllerType
					ControllerNumber   = $VMHardDiskDrive.ControllerNumber
					ControllerLocation = $VMHardDiskDrive.ControllerLocation
				}

				# add VHD to VM
				try {
					Add-VHDFromParams @AddVHDFromParams
				}
				catch {
					throw $_
				}
			}

			# filter hard drives with controller number and without controller location
			$VMHardDiskDrivesWithNumberWithoutLocation = $JsonData.$Name.VMHardDiskDrives | Where-Object { $null -ne $_.ControllerNumber -and $null -eq $_.ControllerLocation }

			# attach hard drives with controller number and without controller location
			foreach ($VMHardDiskDrive in $VMHardDiskDrivesWithNumberWithoutLocation) {
				# if path provided...
				if ($PSBoundParameters.ContainsKey('Path')) {
					# retrieve modified VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path.Replace($JsonData.$Name.Path, $Path)
				}
				else {
					# retrieve original VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path
				}

				# define parameters
				$AddVHDFromParams = @{
					ComputerName     = $ComputerName
					VM               = $VM
					Path             = $VMHardDiskDrivePath
					ControllerType   = $VMHardDiskDrive.ControllerType
					ControllerNumber = $VMHardDiskDrive.ControllerNumber
				}

				# add VHD to VM
				try {
					Add-VHDFromParams @AddVHDFromParams
				}
				catch {
					throw $_
				}
			}

			# filter hard drives without controller number but with controller location
			$VMHardDiskDrivesWithoutNumberWithLocation = $JsonData.$Name.VMHardDiskDrives | Where-Object { $null -eq $_.ControllerNumber -and $null -ne $_.ControllerLocation }

			# attach hard drives without controller number but with controller location
			foreach ($VMHardDiskDrive in $VMHardDiskDrivesWithoutNumberWithLocation) {
				# if path provided...
				if ($PSBoundParameters.ContainsKey('Path')) {
					# retrieve modified VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path.Replace($JsonData.$Name.Path, $Path)
				}
				else {
					# retrieve original VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path
				}

				# define parameters
				$AddVHDFromParams = @{
					ComputerName       = $ComputerName
					VM                 = $VM
					Path               = $VMHardDiskDrivePath
					ControllerType     = $VMHardDiskDrive.ControllerType
					ControllerLocation = $VMHardDiskDrive.ControllerLocation
				}

				# add VHD to VM
				try {
					Add-VHDFromParams @AddVHDFromParams
				}
				catch {
					throw $_
				}
			}

			# attach hard drives without controller number or controller location
			$VMHardDiskDrivesWithoutNumberWithoutLocation = $JsonData.$Name.VMHardDiskDrives | Where-Object { $null -eq $_.ControllerNumber -and $null -eq $_.ControllerLocation }

			# attach hard drives without controller number or controller location
			foreach ($VMHardDiskDrive in $VMHardDiskDrivesWithoutNumberWithoutLocation) {
				# if path provided...
				if ($PSBoundParameters.ContainsKey('Path')) {
					# retrieve modified VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path.Replace($JsonData.$Name.Path, $Path)
				}
				else {
					# retrieve original VHD path
					$VMHardDiskDrivePath = $VMHardDiskDrive.Path
				}

				# add VHD to VM
				$AddVHDFromParams = @{
					ComputerName   = $ComputerName
					VM             = $VM
					Path           = $VMHardDiskDrivePath
					ControllerType = $VMHardDiskDrive.ControllerType
				}

				# add VHD to VM
				try {
					Add-VHDFromParams @AddVHDFromParams
				}
				catch {
					throw $_
				}
			}
		}

		# if VM has network adapters...
		if ($null -ne $VM -and $null -ne $JsonData.$Name.VMNetworkAdapters) {
			# loop through VM network adapters
			foreach ($VMNetworkAdapterEntry in $JsonData.$Name.VMNetworkAdapters) {
				# define required parameters for VMNetworkAdapter
				$AddVMNetworkAdapterToVM = @{
					ComputerName       = $ComputerName
					VM                 = $VM
					NetworkAdapterName = $VMNetworkAdapterEntry.NetworkAdapterName
				}

				# report state
				Write-Host ("$Hostname,$ComputerName,$Name - checking VMNetworkAdapter with Name: '$($VMNetworkAdapterEntry.NetworkAdapterName)'")

				# define optional parameters for VMNetworkAdapter
				if ($null -ne $VMNetworkAdapterEntry.SwitchName) {
					$AddVMNetworkAdapterToVM['SwitchName'] = $VMNetworkAdapterEntry.SwitchName
				}
				if ($null -ne $VMNetworkAdapterEntry.MacAddressSpoofing) {
					$AddVMNetworkAdapterToVM['MacAddressSpoofing'] = $VMNetworkAdapterEntry.MacAddressSpoofing
				}
				if ($null -ne $VMNetworkAdapterEntry.AllowTeaming) {
					$AddVMNetworkAdapterToVM['AllowTeaming'] = $VMNetworkAdapterEntry.AllowTeaming
				}

				# add VMNetworkAdapter to VM and get VMNetworkAdapter
				try {
					$VMNetworkAdapter = Add-VMNetworkAdapterToVM @AddVMNetworkAdapterToVM
				}
				catch {
					throw $_
				}

				# define required parameters for VLAN
				$SetVMNetworkAdapterVlanId = @{
					VMNetworkAdapter = $VMNetworkAdapter
				}

				# define optional parameters for VLAN
				if ($null -ne $VMNetworkAdapterEntry.VlanMode) {
					$SetVMNetworkAdapterVlanId['VlanMode'] = $VMNetworkAdapterEntry.VlanMode
				}
				if ($null -ne $VMNetworkAdapterEntry.VlanId) {
					$SetVMNetworkAdapterVlanId['VlanId'] = $VMNetworkAdapterEntry.VlanId
				}
				if ($null -ne $VMNetworkAdapterEntry.VlanIdList) {
					$SetVMNetworkAdapterVlanId['VlanIdList'] = $VMNetworkAdapterEntry.VlanIdList
				}

				# set VLAN on VMNetworkAdapter and get updated VMNetworkAdapter
				try {
					$VMNetworkAdapter = Set-VMNetworkAdapterVlanId @SetVMNetworkAdapterVlanId
				}
				catch {
					throw $_
				}

				# define required parameters for MAC address
				$SetVMNetworkAdapterMacAddress = @{
					VMNetworkAdapter = $VMNetworkAdapter
				}

				# define optional parameters for MAC address
				if ($null -ne $VMNetworkAdapterEntry.IPAddress) {
					$SetVMNetworkAdapterMacAddress['IPAddress'] = $VMNetworkAdapterEntry.IPAddress
				}
				if ($null -ne $VMNetworkAdapterEntry.MacAddress) {
					$SetVMNetworkAdapterMacAddress['MacAddress'] = $VMNetworkAdapterEntry.MacAddress
				}
				if ($null -ne $VMNetworkAdapterEntry.MacAddressPrefix) {
					$SetVMNetworkAdapterMacAddress['MacAddressPrefix'] = $VMNetworkAdapterEntry.MacAddressPrefix
				}

				# set MAC address on VMNetworkAdapter and get updated VMNetworkAdapter
				try {
					$VMNetworkAdapter = Set-VMNetworkAdapterMacAddress @SetVMNetworkAdapterMacAddress
				}
				catch {
					throw $_
				}

				# add VM IP address and MAC address to DHCP server
				if ($null -ne $VMNetworkAdapterEntry.DhcpServer -and $null -ne $VMNetworkAdapterEntry.DhcpScope -and $null -ne $VMNetworkAdapterEntry.IPAddress) {
					# define required parameters for DHCP reservation
					$AddVMNetworkAdapterToDHCP = @{
						ComputerName = $VMNetworkAdapterEntry.DhcpServer
						ScopeId      = $VMNetworkAdapterEntry.DhcpScope
						IPAddress    = $VMNetworkAdapterEntry.IPAddress
						MacAddress   = $VMNetworkAdapter.MacAddress
					}

					# define optional parameters for DHCP reservation
					if (![System.String]::IsNullOrEmpty($VMNetworkAdapterEntry.IPGateway)) {
						$AddVMNetworkAdapterToDHCP['Router'] = $VMNetworkAdapterEntry.IPGateway
					}
					if (![System.String]::IsNullOrEmpty($VMNetworkAdapterEntry.DnsServers)) {
						$AddVMNetworkAdapterToDHCP['DnsServer'] = $VMNetworkAdapterEntry.DnsServers
					}

					# define override parameters for DHCP reservation
					if ($PSBoundParameters.ContainsKey('DhcpServer')) {
						$AddVMNetworkAdapterToDHCP['ComputerName'] = $DhcpServer
					}

					# create DHCP reservation
					try {
						Add-VMNetworkAdapterToDHCP @AddVMNetworkAdapterToDHCP
					}
					catch {
						throw $_
					}
				}
			}
		}

		# if VM has OS deployment...
		if ($null -ne $VM -and $null -ne $JsonData.$Name.OSDeployment) {
			# if SkipProvisioning set...
			if ($SkipProvisioning) {
				# declare and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping deployment, SkipProvisioning set")
			}
			# if SkipProvisioning not set...
			else {
				# loop through OS deployments
				foreach ($OSDeployment in $JsonData.$Name.OSDeployment) {
					# if Method is not present...
					if ([string]::IsNullOrEmpty($OSDeployment.Method)) {
						Write-Host ("$Hostname,$ComputerName,$Name - ...skipping deployment, no provisioning method present")
					}
					# if Method is present...
					else {
						# swithc on Method
						switch ($OSDeployment.Method) {
							'ISO' {
								# report state
								Write-Host ("$Hostname,$ComputerName,$Name - VM will be provisioned via ISO file")

								# define parameters for Add-IsoToVM
								$AddIsoToVM = @{
									VM   = $VM
									Path = $OSDeployment.FilePath
								}

								# mount ISO file on VM
								try {
									Add-IsoToVM @AddIsoToVM
								}
								catch {
									Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add ISO to VM")
									throw $_
								}

								# define parameters for Set-VMFirstBootDevice
								$SetVMFirstBootDevice = @{
									VM                  = $VM
									FirstBootDeviceType = 'VMDvdDrive'
								}

								# set DVD drive as first boot device
								try {
									Set-VMFirstBootDevice @SetVMFirstBootDevice
								}
								catch {
									Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set first boot device to DVD drive")
									throw $_
								}
							}
							'SCCM' {
								# report state
								Write-Host ("$Hostname,$ComputerName,$Name - VM will be provisioned via PXE boot and SCCM")

								# if device variables provided...
								if ($OSDeployment.DeviceVariables) {
									# convert property from JSON to hashtable
									try {
										$DeviceVariablesHashtable = ConvertTo-Collection -InputObject $OSDeployment.DeviceVariables
									}
									catch {
										Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not create hashtable from DeviceVariables in OS Deployment")
										throw $_
									}
								}
								else {
									# create empty hashtable
									$DeviceVariablesHashtable = @{}
								}

								# define parameters for Add-DeviceToSccm
								$AddDeviceToSccm = @{
									VM              = $VM
									Server          = $OSDeployment.Server
									Collections     = $OSDeployment.Collections
									DeviceVariables = $DeviceVariablesHashtable
								}

								# add VM to SCCM
								try {
									Add-DeviceToSccm @AddDeviceToSccm
								}
								catch {
									Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not add VM to SCCM")
									throw $_
								}

								# define parameters for Set-VMFirstBootDevice
								$SetVMFirstBootDevice = @{
									VM                  = $VM
									FirstBootDeviceType = 'VMNetworkAdapter'
								}

								# set DVD drive as first boot device
								try {
									Set-VMFirstBootDevice @SetVMFirstBootDevice
								}
								catch {
									Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set first boot device to network adapter")
									throw $_
								}
							}
							'VHD' {
								# report state
								Write-Host ("$Hostname,$ComputerName,$Name - VM will be provisioned via VHD file")

								# define required parameters for Copy-VHDFromParams
								$CopyVHDFromParams = @{
									VM   = $VM
									Path = $OSDeployment.FilePath
								}

								# define optional parameters for Copy-VHDFromParams
								if (![string]::IsNullOrEmpty($OSDeployment.DestinationPath)) {
									$CopyVHDFromParams['DestinationPath'] = $OSDeployment.DestinationPath
								}
								# If (![string]::IsNullOrEmpty($OSDeployment.ControllerNumber)) {
								# 	 $CopyVHDFromParams['ControllerNumber'] = $OSDeployment.ControllerNumber
								# }
								# If (![string]::IsNullOrEmpty($OSDeployment.ControllerLocation)) {
								# 	 $CopyVHDFromParams['ControllerLocation'] = $OSDeployment.ControllerLocation
								# }

								# replace new VM disk with existing VHD file
								try {
									Copy-VHDFromParams @CopyVHDFromParams
								}
								catch {
									Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not copy VHD to VM")
									throw $_
								}

								# if unattend file defined...
								if (![string]::IsNullOrEmpty($OSDeployment.UnattendFile)) {
									# report state
									Write-Host ("$Hostname,$ComputerName,$Name - VM will be configured via XML file")

									# if expand strings defined in JSON file...
									if ($null -ne $OSDeployment.ExpandStrings) {
										# create hashtable from expand strings property
										try {
											$ExpandStringsHashtable = ConvertTo-Collection -InputObject $OSDeployment.ExpandStrings
										}
										catch {
											Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not create hashtable from ExpandStrings in OS Deployment")
											throw $_
										}

										# define expand string source
										$ExpandSource = 'ExpandStrings in OS Deployment'

										# loop through expand strings from JSON file
										foreach ($ExpandString in $ExpandStringsHashtable.Keys) {
											# if expand string from JSON file already present in hashtable...
											if ($ExpandStrings.ContainsKey($ExpandString)) {
												# report state
												Write-Host ("$Hostname,$ComputerName,$Name - ...skipping value of '$ExpandString' expand string from $ExpandSource; value already set")
											}
											# if expand string from JSON file is not a string or value type...
											elseif ($ExpandStringsHashtable[$ExpandString] -isnot [string] -and -not $ExpandStringsHashtable[$ExpandString].GetType().IsValueType) {
												# report state
												Write-Host ("$Hostname,$ComputerName,$Name - ...skipping value of '$ExpandString' expand string from $ExpandSource; value is not string or value type")
											}
											else {
												# report state
												Write-Host ("$Hostname,$ComputerName,$Name - ...adding value of '$ExpandString' expand string from $ExpandSource")

												# add expand string from JSON file to hashtable
												$ExpandStrings[$ExpandString] = $ExpandStringsHashtable[$ExpandString]
											}
										}
									}

									# if AD Computer object defined in JSON file...
									if ($null -ne $JsonData.$Name.ADComputer) {
										# retrieve first entry from ADComputer collection
										$ADComputer = $JsonData.$Name.ADComputer | Select-Object -First 1

										# create hashtable from AD Computer object
										try {
											$ADComputerHashtable = ConvertTo-Collection -InputObject $ADComputer
										}
										catch {
											Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not create hashtable from ADComputer")
											throw $_
										}

										# define expand string source
										$ExpandSource = 'properties in AD Computer'

										# loop through AD Computer properties defined in JSON file
										foreach ($ExpandString in $ADComputerHashtable.Keys) {
											# if AD Computer property from JSON file already present in hashtable...
											if ($ExpandStrings.ContainsKey($ExpandString)) {
												# report state
												Write-Host ("$Hostname,$ComputerName,$Name - ...skipping value of '$ExpandString' expand string from $ExpandSource; value already set")
											}
											# if AD Computer property from JSON file is not a string or value type...
											elseif ($ADComputerHashtable[$ExpandString] -isnot [string] -and -not $ADComputerHashtable[$ExpandString].GetType().IsValueType) {
												# report state
												Write-Host ("$Hostname,$ComputerName,$Name - ...skipping value of '$ExpandString' expand string from $ExpandSource; value is not string or value type")
											}
											else {
												# report state
												Write-Host ("$Hostname,$ComputerName,$Name - ...adding value of '$ExpandString' expand string from $ExpandSource")

												# add AD Computer property from JSON file to hashtable
												$ExpandStrings[$ExpandString] = $ADComputerHashtable[$ExpandString]
											}
										}
									}

									# if administrator password provided...
									if ($PSBoundParameters.ContainsKey('LocalAdminCredential')) {
										# define epxand string source
										$ExpandSource = 'LocalAdminCredential parameter'

										# define expand string
										$ExpandString = 'AdministratorPassword'
										
										# if expand string already present in hashtable...
										if ($ExpandStrings.ContainsKey($ExpandString)) {
											# report state
											Write-Host ("$Hostname,$ComputerName,$Name - ...skipping value of '$ExpandString' expand string from $ExpandSource; value already set")
										}
										else {
											# retrieve plaintext password from credential object
											try {
												$PlainText = $LocalAdminCredential.GetNetworkCredential().Password
											}
											catch {
												throw $_
											}

											# append required string to plaintext password
											$AppendedPlainText = '{0}?AdministratorPassword' -f $PlainText

											# encode appended password
											try {
												$EncodedAdministratorPassword = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($AppendedPlainText))
											}
											catch {
												throw $_
											}

											# report state
											Write-Host ("$Hostname,$ComputerName,$Name - ...adding value of '$ExpandString' expand string from $ExpandSource")

											# add encoded plaintext password to expand strings hashtable
											$ExpandStrings[$ExpandString] = $EncodedAdministratorPassword
										}
									}

									# if domain join credential provided...
									if ($PSBoundParameters.ContainsKey('DomainJoinCredential')) {
										# define epxand string source
										$ExpandSource = 'DomainJoinCredential parameter'

										# define expand string
										$ExpandString = 'Username'

										# if expand string already present in hashtable...
										if ($ExpandStrings.ContainsKey($ExpandString)) {
											# report state
											Write-Host ("$Hostname,$ComputerName,$Name - ...skipping value of '$ExpandString' expand string from $ExpandSource; value already set")
										}
										else {
											# report state
											Write-Host ("$Hostname,$ComputerName,$Name - ...adding value of '$ExpandString' expand string from $ExpandSource")

											# add plaintext unattended join password to expand strings hashtable
											$ExpandStrings[$ExpandString] = $DomainJoinCredential.GetNetworkCredential().Username
										}

										# define expand string
										$ExpandString = 'Password'

										# if expand string already present in hashtable...
										if ($ExpandStrings.ContainsKey($ExpandString)) {
											# report state
											Write-Host ("$Hostname,$ComputerName,$Name - ...skipping value of '$ExpandString' expand string from $ExpandSource; value already set")
										}
										else {
											# report state
											Write-Host ("$Hostname,$ComputerName,$Name - ...adding value of '$ExpandString' expand string from $ExpandSource")

											# add plaintext unattended join password to expand strings hashtable
											$ExpandStrings[$ExpandString] = $DomainJoinCredential.GetNetworkCredential().Password
										}
									}

									# if expand strings does not contain computer name...
									if (!$ExpandStrings.ContainsKey('ComputerName')) {
										# add VM name as computer name to expand strings hashtable
										$ExpandStrings['ComputerName'] = $Name.Split('.')[0]
									}

									# define required parameters for Edit-VHDFromParams
									$EditVHDFromParams = @{
										VM            = $VM
										UnattendFile  = $OSDeployment.UnattendFile
										ExpandStrings = $ExpandStrings
									}

									# define optional parameters for Edit-VHDFromParams
									if (![string]::IsNullOrEmpty($OSDeployment.DestinationPath)) {
										$EditVHDFromParams['DestinationPath'] = $OSDeployment.DestinationPath
									}

									# edit VHD file to include unattend file
									try {
										Edit-VHDFromParams @EditVHDFromParams
									}
									catch {
										Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not edit VHD for VM")
										throw $_
									}
								}

								# define parameters for Set-VMFirstBootDevice
								$SetVMFirstBootDevice = @{
									VM                  = $VM
									FirstBootDeviceType = 'VMHardDiskDrive'
								}

								# set DVD drive as first boot device
								try {
									Set-VMFirstBootDevice @SetVMFirstBootDevice
								}
								catch {
									Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set first boot device to hard disk drive")
									throw $_
								}
							}
							default {
								Write-Host ("$Hostname,$ComputerName,$Name - ...skipping deployment, unknown provisioning method present: '$($OSDeployment.Method)'")
							}
						}
					}
				}
			}
		}

		# if VM is on a cluster...
		if ($null -ne $VM -and -not [string]::IsNullOrEmpty($ClusterName)) {
			# if DoNotCluster is set...
			if ($JsonData.$Name.DoNotCluster) {
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping clustering, DoNotCluster was set")
			}
			# if SkipClustering is set...
			elseif ($SkipClustering) {
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping clustering, SkipClustering was set")
			}
			# if DoNotCluster and SkipClustering are not set...
			else {
				# define required parameters for Add-VMToClusterName
				$AddVMToClusterName = @{
					VM          = $VM
					ClusterName = $ClusterName
				}

				# define optional parameters for Add-VMToClusterName
				if ($null -ne $JsonData.$Name.ClusterPriority) {
					$AddVMToClusterName['ClusterPriority'] = $JsonData.$Name.ClusterPriority
				}
				if ($null -ne $JsonData.$Name.ClusterAffinityRules) {
					$AddVMToClusterName['ClusterAffinityRules'] = $JsonData.$Name.ClusterAffinityRules
				}
				if ($null -ne $JsonData.$Name.DisableHeartbeat) {
					$AddVMToClusterName['DisableHeartbeat'] = $JsonData.$Name.DisableHeartbeat
				}

				# add VM to cluster
				try {
					$ClusterGroup = Add-VMToClusterName @AddVMToClusterName
				}
				catch {
					throw $_
				}
			}
		}

		# if VM is in a cluster group...
		if ($null -ne $VM -and $null -ne $ClusterGroup) {
			# if cluster group is not online and SkipStart set...
			if ($ClusterGroup.State -eq 'Offline' -and $SkipStart) {
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping Start, SkipStart was set...")
			}
			# if cluster group is not online and SkipStart not set...
			elseif ($ClusterGroup.State -eq 'Offline') {
				# declare and begin
				Write-Host ("$Hostname,$ComputerName,$Name - VM cluster group is offline, starting VM on cluster...")

				# define required parameters for Start-ClusterGroup
				$StartClusterGroup = @{
					Cluster     = $ClusterName
					Name        = $Name
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}

				# define optional parameters for Start-ClusterGroup
				if ($ChooseBestNode) {
					$StartClusterGroup.Add('ChooseBestNode', $true)
				}

				# start cluster group
				try {
					$ClusterGroup = Start-ClusterGroup @StartClusterGroup
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: starting VM on cluster")
					throw $_
				}

				# report state
				Write-Host ("$Hostname,$ComputerName,$Name - ...started VM on cluster")
			}
			# if cluster group is online and ForceRestart set...
			elseif ($ClusterGroup.State -eq 'Online' -and $ForceRestart) {
				# declare and begin
				Write-Host ("$Hostname,$ComputerName,$Name - VM cluster group is not offline but ForceRestart set, restarting VM on cluster...")

				# define parameters for Stop-ClusterGroup
				$StopClusterGroup = @{
					Cluster     = $ClusterName
					Name        = $Name
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}

				# stop cluster group
				try {
					$ClusterGroup = Stop-ClusterGroup @StopClusterGroup
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: stopping VM on cluster")
					throw $_
				}

				# define required parameters for Start-ClusterGroup
				$StartClusterGroup = @{
					Cluster     = $ClusterName
					Name        = $Name
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}

				# define optional parameters for Start-ClusterGroup
				if ($ChooseBestNode) {
					$StartClusterGroup.Add('ChooseBestNode', $true)
				}

				# start cluster group
				try {
					$ClusterGroup = Start-ClusterGroup @StartClusterGroup
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: starting VM on cluster")
					throw $_
				}

				# report state
				Write-Host ("$Hostname,$ComputerName,$Name - ...restarted VM on cluster")
				continue
			}
			# if cluster group is online and ForceRestart not set...
			elseif ($ClusterGroup.State -eq 'Online') {
				# report state
				Write-Host ("$Hostname,$ComputerName,$Name - ...found VM running on cluster")
			}
			# if cluster group is not in an expected state...
			else {
				# report state and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...found VM cluster group in unexpected state: $($ClusterGroup.State)")
				continue
			}
		}

		# if VM is not in a cluster group...
		if ($null -ne $VM -and $null -eq $ClusterGroup) {
			# if VM is not online and SkipStart set...
			if ($VM.State -eq 'Off' -and $SkipStart) {
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping Start, SkipStart was set...")
			}
			# if VM is not online and SkipStart not set...
			elseif ($VM.State -eq 'Off') {
				# ...start VM
				Write-Host ("$Hostname,$ComputerName,$Name - starting VM on host...")

				# start VM
				try {
					Start-VM -VM $VM
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: starting VM")
					throw $_
				}

				# report state
				Write-Host ("$Hostname,$ComputerName,$Name - ...started VM on host")
			}
			# if VM is online and ForceRestart set...
			elseif ($VM.State -eq 'Running' -and $ForceRestart) {
				# ...restart VM
				Write-Host ("$Hostname,$ComputerName,$Name - restarting VM on host...")

				# restart VM
				try {
					Restart-VM -VM $VM -Force
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: restarting VM")
					throw $_
				}

				# report state
				Write-Host ("$Hostname,$ComputerName,$Name - ...restarted VM on host")
			}
			# if VM is online and ForceRestart not set...
			elseif ($VM.State -eq 'Running') {
				# report state
				Write-Host ("$Hostname,$ComputerName,$Name - ...found VM running on host")
			}
			# if VM is not in an expected state...
			else {
				# report state and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...found VM in unexpected state: $($VM.State)")
				continue
			}
		}

		# if skip VM connect not requested...
		if ($null -ne $VM -and -not $SkipVMConnect) {
			# start VM connect with hypervisor as first argument and VM as second argument
			try { 
				Start-Process -FilePath 'vmconnect.exe' -ArgumentList $ComputerName, $Name
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: connecting to VM")
				throw $_
			}
		}
	}
}

end {
	# loop through keys in sessions hashtable
	foreach ($SessionName in $script:PSSessions.Keys) {
		# remove session
		try {
			$script:PSSessions[$SessionName] | Remove-PSSession
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing '$SessionName' session")
		}
	}
}
