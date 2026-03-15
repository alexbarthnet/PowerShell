#requires -Modules 'Hyper-V', FailoverClusters, DhcpServer

[CmdletBinding(SupportsShouldProcess)]
param(
	[Parameter(Position = 0, Mandatory)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	[Parameter(Position = 1, Mandatory, ValueFromPipeline)]
	[string[]]$VMName,
	[Parameter(Position = 2, Mandatory)]
	[string[]]$NetworkAdapterName,
	[Parameter(Position = 3)]
	[string]$ComputerName,
	[Parameter(Position = 4)]
	[string]$DhcpServer,
	[Parameter()]
	[switch]$SkipClustering,
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

	function Get-VMHostCurrentMacAddress {
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

		# return current MAC address
		try {
			return [System.BitConverter]::ToString($CurrentMacAddress).Replace('-', $null)
		}
		catch {
			throw $_
		}
	}

	function Update-VMHostCurrentMacAddress {
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
			$UpdateMacAddress = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				# increment last byte in current MAC address
				$ArgumentList['CurrentMacAddress'][-1]++
				# update current MAC address property
				$Value = Set-ItemProperty -Path $ArgumentList['Path'] -Name $ArgumentList['Name'] -Value $ArgumentList['CurrentMacAddress'] -PassThru
				# return updated MAC address
				try {
					return [System.BitConverter]::ToString($Value.CurrentMacAddress).Replace('-', $null)
				}
				catch {
					throw $_
				}
			}
		}
		catch {
			throw $_
		}

		# report updated MAC address
		Write-Host ("$Hostname,$ComputerName - updated CurrentMacAddress registry value: $UpdateMacAddress")
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
			[string]$StaticMacAddress,
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

			# if static MAC address is not correct or dynamic MAC address enabled...
			if ($VMNetworkAdapter.MacAddress -ne $StaticMacAddress -or $VMNetworkAdapter.DynamicMacAddressEnabled) {
				# define parameters for Set-VMNetworkAdapter
				$SetVMNetworkAdapter = @{
					VMNetworkAdapter = $VMNetworkAdapter
					StaticMacAddress = $StaticMacAddress
					Passthru         = $true
					ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
				}

				# enable device naming on adapter
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...setting static MAC address on VMNetworkAdapter: '$NetworkAdapterName'")
					$VMNetworkAdapter = Set-VMNetworkAdapter @SetVMNetworkAdapter
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not set static MAC address on VMNetworkAdapter for VM")
					throw $_
				}
			}

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
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not enable device naming on VMNetworkAdapter for VM")
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
				VM               = $VM
				Name             = $NetworkAdapterName
				StaticMacAddress = $StaticMacAddress
				DeviceNaming     = 'On'
				Passthru         = $true
				ErrorAction      = [System.Management.Automation.ActionPreference]::Stop
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
		if ($null -eq $VM) {
			Write-Warning -Message ("$Hostname,$ComputerName,$Name - VM not found")
			continue VMName
		}

		# if VM has network adapters...
		if ($null -ne $VM -and $null -ne $JsonData.$Name.VMNetworkAdapters) {
			# retrieve all VM network adapters
			$VMNetworkAdapters = $JsonData.$Name.VMNetworkAdapters

			# filter named VM network adapters
			$VMNetworkAdapters = $VMNetworkAdapters | Where-Object { $_.NetworkAdapterName -in $NetworkAdapterName }

			# loop through VM network adapters
			:NextVMNetworkAdapterEntry foreach ($VMNetworkAdapterEntry in $VMNetworkAdapters) {
				# report state
				Write-Host ("$Hostname,$ComputerName,$Name - checking VMNetworkAdapter with Name: '$($VMNetworkAdapterEntry.NetworkAdapterName)'")

				# reset the static address
				$StaticMacAddress = $null
				$CurrentMacAddressRetrieved = $false

				# if MAC address was provided...
				if ($null -ne $VMNetworkAdapterEntry.MacAddress) {
					# retrieve MAC address from JSON entry
					$StaticMacAddress = $VMNetworkAdapterEntry.MacAddress
					# report MAC address and source
					Write-Host ("$Hostname,$ComputerName,$Name - ...retrieved MAC address from JSON: $StaticMacAddress")
				}
				# if MAC address was provided via prefix and IP address...
				elseif ($null -ne $VMNetworkAdapterEntry.MacAddressPrefix -and $null -ne $VMNetworkAdapterEntry.IPAddress) {
					# create MAC address suffix by converting IPAddress octets to hexadecimal
					$MacAddressSuffix = ($VMNetworkAdapterEntry.IPAddress.Split('.') | ForEach-Object { ([int]$_).ToString('X2') }) -join $null
					# assign MAC address from prefix and suffix
					$StaticMacAddress = ($VMNetworkAdapterEntry.MacAddressPrefix.ToUpperInvariant(), $MacAddressSuffix) -join $null
					# report MAC address and source
					Write-Host ("$Hostname,$ComputerName,$Name - ...created MAC address from IP address and MAC address prefix: $StaticMacAddress")
				}
				# if MAC address not provided...
				else {
					# retrieve current MAC address from host
					try {
						Write-Host ("$Hostname,$ComputerName,$Name - ...retrieving current MAC address from host")
						$StaticMacAddress = Get-VMHostCurrentMacAddress -ComputerName $ComputerName
					}
					catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve current MAC address from host")
						throw $_
					}
					# update boolean
					$CurrentMacAddressRetrieved = $true
					# report MAC address and source
					Write-Host ("$Hostname,$ComputerName,$Name - ...retrieved current MAC address from host: $StaticMacAddress")
				}

				# if static MAC address is null...
				if ($null -eq $StaticMacAddress) {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve or create MAC address for '$($VMNetworkAdapterEntry.NetworkAdapterName)' network adapter")
					throw $_
				}

				# define required parameters for VMNetworkAdapter
				$AddVMNetworkAdapterToVM = @{
					ComputerName       = $ComputerName
					VM                 = $VM
					StaticMacAddress   = $StaticMacAddress
					NetworkAdapterName = $VMNetworkAdapterEntry.NetworkAdapterName
				}

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

				# if current MAC address retrieved...
				if ($CurrentMacAddressRetrieved) {
					# retrieve MAC address from host
					try {
						Write-Host ("$Hostname,$ComputerName,$Name - ...updating current MAC address from host")
						Update-VMHostCurrentMacAddress -ComputerName $ComputerName
					}
					catch {
						Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve current MAC address from host")
						throw $_
					}
					# report MAC address was updated
					Write-Host ("$Hostname,$ComputerName,$Name - ...incremented current MAC address on host: $StaticAddress")
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
