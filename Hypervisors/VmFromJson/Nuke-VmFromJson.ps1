[CmdletBinding()]
param(
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	[Parameter(ValueFromPipeline = $True)]
	[string[]]$VMName,
	[Parameter()]
	[string]$ComputerName,
	[Parameter()]
	[switch]$UseDefaultPathOnHost,
	[Parameter()]
	[switch]$PreserveHardDrives,
	[Parameter()]
	[switch]$RemoveNetworkObjects,
	[Parameter()]
	[switch]$SkipProvisioning,
	[Parameter()]
	[switch]$Force,
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
)

begin {
	# set error action preference
	$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

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
		if ($script:PSSessions.ContainsKey($ComputerName) -and $script:PSSessions[$ComputerName] -is [System.Management.Automation.Runspaces.PSSession]) {
			# ...return true as session can already be referenced
			return $true
		}
		else {
			# ...try to create a session
			try {
				$script:PSSessions[$ComputerName] = New-PSSession -ComputerName $ComputerName -Name $ComputerName -Authentication Default
			}
			catch {
				return $false
			}
			# ...validate session
			if ($script:PSSessions[$ComputerName] -is [System.Management.Automation.Runspaces.PSSession]) {
				return $true
			}
			else {
				return $false
			}
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
				# define parameters for Get-ClusterNode
				$GetClusterNode = @{
					ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
				}

				# retrieve names of cluster nodes
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
				$ComputerName = $VM.ComputerName
			}
			else {
				# get computer name from hostname
				$ComputerName = $Hostname
			}
		}

		# define parameters for Get-VM
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

	function Move-ClusterSharedVolumeForPath {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[Parameter(Mandatory = $true)]
			[string]$Path
		)

		# define parameters for Get-ClusterName
		$GetClusterName = @{
			ComputerName = $ComputerName
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# check if host is clustered
		try {
			$ClusterName = Get-ClusterName @GetClusterName
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: checking if host is clustered")
			throw $_
		}

		# if cluster name not found...
		if ([string]::IsNullOrEmpty($ClusterName)) {
			# ...return to caller
			return
		}

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# update argument list for Invoke-Command
		$InvokeCommand['ArgumentList']['ClusterName'] = $ClusterName
		$InvokeCommand['ArgumentList']['ComputerName'] = $ComputerName

		# check cluster shared volumes
		Invoke-Command @InvokeCommand -ScriptBlock {
			param($ArgumentList)
			# define parameters for Get-ClusterSharedVolume
			$GetClusterSharedVolume = @{
				Cluster     = $ArgumentList['ClusterName']
				ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
			}

			# retrieve names of cluster nodes
			$ClusterSharedVolumes = Get-ClusterSharedVolume @GetClusterSharedVolume

			# process each volume
			foreach ($ClusterSharedVolume in $ClusterSharedVolumes) {
				$CsvFriendlyName = $ClusterSharedVolume.SharedVolumeInfo.FriendlyVolumeName
				# is path on CSV?
				$PathOnVolume = $Path.StartsWith($CsvFriendlyName, [System.StringComparison]::InvariantCultureIgnoreCase)
				# is CSV owned by requested computer?
				$VolumeOnHost = $ClusterSharedVolume.OwnerNode.Name -eq $ArgumentList['ComputerName']
				# if path on volume and volume on host or path not on volume...
				if (-not $PathOnVolume -or ($PathOnVolume -and $VolumeOnHost)) {
					# ...filter volume out of collection
					$ClusterSharedVolumes = $ClusterSharedVolumes | Where-Object { $_.SharedVolumeInfo.FriendlyVolumeName -ne $CsvFriendlyName }
				}
			}

			# process each remaining volume
			foreach ($ClusterSharedVolume in $ClusterSharedVolumes) {
				# define parameters for Move-ClusterSharedVolume
				$MoveClusterSharedVolume = @{
					Name        = $ClusterSharedVolume.Name
					Node        = $ArgumentList['ComputerName']
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}

				# move cluster shared volume to requested computer
				$null = Move-ClusterSharedVolume @MoveClusterSharedVolume
			}
		}
	}

	function Remove-DeviceFromSccm {
		param (
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			# define OSD parameters
			[string]$DeploymentServer
		)

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $DeploymentServer
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

		# retrive BIOS GUID from CIM data
		if ([string]::IsNullOrEmpty($CimInstanceForVM.BIOSGUID)) {
			Write-Host ("$Hostname,$ComputerName,$Name - WARNING: BIOS GUID for VM is empty; skipping SCCM provisioning...")
			return
		}
		else {
			Write-Host ("$Hostname,$ComputerName,$Name - ...found BIOS GUID for VM")
			$BIOSGUID = $CimInstanceForVM.BIOSGUID
		}

		# get CM module path
		try {
			$CMModulePath = Get-CMModulePath -ComputerName $DeploymentServer -ErrorAction Stop
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

		# get CM site code
		try {
			$CMSiteCode = Get-CMSiteCode -ComputerName $DeploymentServer -ErrorAction Stop
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
		$InvokeCommand['ArgumentList']['ComputerName'] = $DeploymentServer
		$InvokeCommand['ArgumentList']['Name'] = $Name

		# update arguments for Invoke-Command - deployment
		$InvokeCommand['ArgumentList']['ModulePath'] = $CMModulePath
		$InvokeCommand['ArgumentList']['SiteCode'] = $CMSiteCode
		$InvokeCommand['ArgumentList']['BIOSGUID'] = $BIOSGUID

		# connect to SCCM remotely
		Write-Host ("$Hostname,$ComputerName,$Name - connecting to SCCM: $DeploymentServer")
		Invoke-Command @InvokeCommand -ScriptBlock {
			param($ArgumentList)

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

				# if device found by name with unexpected BIOSGUID...
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

				# if device found by SMBIOSGUID and with unexpected name...
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

			# if Device not found...
			if ($null -eq $Device) {
				# return
				return
			}
			# if Device found...
			else {
				# retrieve resource ID
				$ResourceId = $Device.ResourceId

				# report and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...found existing device with resource ID: '$ResourceId'")
			}

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

			# remove device
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - removing device with resource ID: $ResourceId")
				Remove-CMResource -ResourceId $ResourceId -Force
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing device by resource ID")
				throw $_
			}

			# report and return
			Write-Host ("$Hostname,$ComputerName,$Name - ...removed device from SCCM")
			return
		}
	}

	function Remove-DeviceFromWds {
		[CmdletBinding()]
		param (
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			# define OSD parameters
			[Parameter(Mandatory)]
			[string]$DeploymentServer
		)

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $DeploymentServer
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

		# retrive BIOS GUID from CIM data
		if ([string]::IsNullOrEmpty($CimInstanceForVM.BIOSGUID)) {
			Write-Host ("$Hostname,$ComputerName,$Name - WARNING: BIOS GUID for VM is empty; skipping WDS cleanup...")
			return
		}
		else {
			Write-Host ("$Hostname,$ComputerName,$Name - ...found BIOS GUID for VM: '$($CimInstanceForVM.BIOSGUID)'")
			$BIOSGUID = $CimInstanceForVM.BIOSGUID
		}

		# update arguments for Invoke-Command
		$InvokeCommand['ArgumentList']['Hostname'] = $Hostname
		$InvokeCommand['ArgumentList']['ComputerName'] = $DeploymentServer
		$InvokeCommand['ArgumentList']['DeviceName'] = $Name
		$InvokeCommand['ArgumentList']['DeviceID'] = $BIOSGUID

		# add VM to WDS
		Invoke-Command @InvokeCommand -ScriptBlock {
			param($ArgumentList)

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
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - checking WDS server...")
				$Disabled = Get-ItemProperty @GetItemProperty | Select-Object -ExpandProperty 'Disabled'
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not check WDS integration")
				throw $_
			}

			# if WDS Active Directory integration is not disabled...
			if ($Disabled -eq 0) {
				# ...declare and return
				Write-Host ("$Hostname,$ComputerName,$Name - WARNING: WDS server is in Active Directory mode; skipping WDS cleanup...")
				return
			}

			# define parameters for Get-WdsClient
			$GetWdsClient = @{
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# retrieve existing WDS clients
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - checking for matching WDS devices...")
				$WdsClient = Get-WdsClient @GetWdsClient
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve existing WDS devices")
				throw $_
			}

			# create objects for device
			$DeviceID = $ArgumentList['DeviceID']

			# filter WDS clients
			$WdsClient = $WdsClient | Where-Object { $_.DeviceId -eq "{$DeviceId}" -or $_.DeviceName -eq $Name }

			# if no WDS clients found...
			if ($null -eq $WdsClient) {
				# ...declare and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...no matching WDS device found")
			}
			# if WDS clients found with matching DeviceId...
			elseif ($null -ne ($WdsClient | Where-Object { $_.DeviceId -eq "{$DeviceId}" })) {
				# ...remove existing WDS clients by DeviceId
				Write-Host ("$Hostname,$ComputerName,$Name - ...removing existing WDS devices with matching DeviceID")

				# define parameters for Remove-WdsClient
				$RemoveWdsClient = @{
					DeviceId    = $DeviceId
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}

				# remove WDS clients with matching DeviceId
				try {
					Remove-WdsClient @RemoveWdsClient
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove existing WDS devices with matching DeviceID")
					throw $_
				}
			}
			# if WDS clients found with matching DeviceName...
			elseif ($null -ne ($WdsClient | Where-Object { $_.DeviceName -eq $Name })) {
				# ...remove existing WDS clients by DeviceName
				Write-Host ("$Hostname,$ComputerName,$Name - ...removing existing WDS devices with matching DeviceName")

				# define parameters for Remove-WdsClient
				$RemoveWdsClient = @{
					DeviceName  = $Name
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}

				# remove WDS clients with matching DeviceName
				try {
					Remove-WdsClient @RemoveWdsClient
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove existing WDS devices with matching DeviceName")
					throw $_
				}
			}
		}
	}

	function Remove-EmptyPath {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[Parameter(Mandatory = $true)]
			[string]$Path
		)

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not get initial hashtable for Invoke-Command")
			throw $_
		}

		# update argument list for removing paths
		$InvokeCommand['ArgumentList']['Path'] = $Path

		# test path
		try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				# define parameters for Test-Path
				$TestPath = @{
					Path        = $ArgumentList['Path']
					PathType    = [Microsoft.PowerShell.Commands.TestPathType]::Container
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

		# if path not found...
		if (!$TestPath) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...skipping empty path removal, path not found: '$Path'")
			return
		}

		# update argument list for reporting
		$InvokeCommand['ArgumentList']['Hostname'] = $Hostname
		$InvokeCommand['ArgumentList']['ComputerName'] = $ComputerName
		$InvokeCommand['ArgumentList']['Name'] = $Name

		# remove empty path
		Invoke-Command @InvokeCommand -ScriptBlock {
			param($ArgumentList)

			# create objects for reporting
			$Hostname = $ArgumentList['Hostname']
			$ComputerName = $ArgumentList['ComputerName']
			$Name = $ArgumentList['Name']

			# create object for path
			$Path = $ArgumentList['Path']

			# define parameters for Get-ChildItem
			$GetChildItem = @{
				Path        = $Path
				Recurse     = $true
				Force       = $true
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# retrieve items in path
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...checking path for child items: '$Path'")
				$ChildItems = Get-ChildItem @GetChildItem
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not check path for child items")
				throw $_
			}

			# if items are in path...
			if ($null -ne $ChildItems) {
				# warn and return
				Write-Host ("$Hostname,$ComputerName,$Name - WARNING: path not empty: '$Path'")
				return
			}

			# define parameters for Remove-Item
			$RemoveItem = @{
				Path        = $Path
				Confirm     = $false
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# remove path
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...removing path: '$Path'")
				Remove-Item @RemoveItem
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove path")
				throw $_
			}
		}
	}

	function Remove-ItemsFromPath {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[Parameter(Mandatory = $true)]
			[string]$Path,
			[Parameter(Mandatory = $true)]
			[string[]]$Items
		)

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not get initial hashtable for Invoke-Command")
			throw $_
		}

		# update argument list for removing files
		$InvokeCommand['ArgumentList']['Path'] = $Path

		# test path
		try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				# define parameters for Test-Path
				$TestPath = @{
					Path        = $ArgumentList['Path']
					PathType    = [Microsoft.PowerShell.Commands.TestPathType]::Container
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

		# if path not found...
		if (!$TestPath) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...skipping item removal, path not found: '$Path'")
			return
		}

		# update argument list for reporting
		$InvokeCommand['ArgumentList']['Hostname'] = $Hostname
		$InvokeCommand['ArgumentList']['ComputerName'] = $ComputerName
		$InvokeCommand['ArgumentList']['Name'] = $Name

		# update argument list for removing files
		$InvokeCommand['ArgumentList']['Items'] = $Items

		# remove items from path
		Invoke-Command @InvokeCommand -ScriptBlock {
			param($ArgumentList)

			# create objects for reporting
			$Hostname = $ArgumentList['Hostname']
			$ComputerName = $ArgumentList['ComputerName']
			$Name = $ArgumentList['Name']

			# create object for path
			$Path = $ArgumentList['Path']

			# define parameters for Get-ChildItem
			$GetChildItem = @{
				Path        = $Path
				File        = $true
				Recurse     = $true
				Force       = $true
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# retrieve files in path
			try {
				$ChildItems = Get-ChildItem @GetChildItem
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve items in path: '$Path'")
				throw $_
			}

			# create object for path
			$Items = $ArgumentList['Items']

			# retrieve files where items contains the name, basename, or fullname of the item
			$ItemsToRemove = $ChildItems | Where-Object { $_.Name -in $Items -or $_.BaseName -in $Items -or $_.Fullname -in $Items }

			# if there are no items to remove...
			if ($null -eq $ItemsToRemove) {
				# declare and return
				Write-Host ("$Hostname,$ComputerName,$Name - ...path is empty")
				return
			}

			# process files
			foreach ($ItemToRemove in $ItemsToRemove) {
				# define parameters for Remove-Item
				$RemoveItem = @{
					Path        = $ItemToRemove.FullName
					Confirm     = $false
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}

				# remove item
				try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...removing item: '$($ItemToRemove.FullName)'")
					Remove-Item @RemoveItem
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove item")
					throw $_
				}
			}
		}
	}

	function Remove-VHD {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[Parameter(Mandatory = $true)]
			[string]$Path
		)

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not get initial hashtable for Invoke-Command")
			throw $_
		}

		# update argument list for removing files
		$InvokeCommand['ArgumentList']['Path'] = $Path

		# test path
		try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
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

		# if path found...
		if ($TestPath) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...found source VHD: '$Path'")
		}
		else {
			Write-Host ("$Hostname,$ComputerName,$Name - ...skipping VHD remove, host did not find file: '$Path'")
			return
		}

		# dismount VHD from system before removal
		try {
			Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				# define parameters for Dismount-DiskImage
				$DismountDiskImage = @{
					ImagePath   = $ArgumentList['Path']
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				# define parameters for VHD files
				if ($ArgumentList['Path'].EndsWith('.VHD', [System.StringComparison]::InvariantCultureIgnoreCase)) {
					$DismountDiskImage['StorageType'] = 'VHD'
				}
				# define parameters for VHDX files
				if ($ArgumentList['Path'].EndsWith('.VHDX', [System.StringComparison]::InvariantCultureIgnoreCase)) {
					$DismountDiskImage['StorageType'] = 'VHDX'
				}

				# dismount disk image from system
				$null = Dismount-DiskImage @DismountDiskImage
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: dismounting disk image")
			throw $_
		}

		# if VHD, rotate CSV
		if ($Path.EndsWith('.VHD', [System.StringComparison]::InvariantCultureIgnoreCase)) {
			try {
				# define parameters for Remove-Item
				$MoveClusterSharedVolumeForPath = @{
					ComputerName = $ComputerName
					Path         = $Path
					ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
				}
				# move cluster shared volume
				Move-ClusterSharedVolumeForPath @MoveClusterSharedVolumeForPath
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: moving CSV for VHD removal")
				throw $_
			}
		}

		# remove VHD from system after dismount
		try {
			Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				# define parameters for Remove-Item
				$RemoveItem = @{
					Path        = $ArgumentList['Path']
					Force       = $true
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				# remove VHD file
				Remove-Item @RemoveItem
			}
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing VHD")
			throw $_
		}

		# declare and return
		Write-Host ("$Hostname,$ComputerName,$Name - ...removed VHD")
		return
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

	function Remove-VMFromDnsServer {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$Name,
			[string]$ZoneName = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name,
			[string]$ComputerName = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
		)

		# define parameters for Get-DnsServerResourceRecord
		$GetDnsServerResourceRecord = @{
			ComputerName = $ComputerName
			ZoneName     = $ZoneName
			Name         = $Name
			RRType       = 'A'
			ErrorAction  = [System.Management.Automation.ActionPreference]::SilentlyContinue
		}

		# get DNS record
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - checking DNS record...")
			$DnsServerResourceRecord = Get-DnsServerResourceRecord @GetDnsServerResourceRecord
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving DNS record")
			throw $_
		}

		# if DNS record not found...
		if ($null -eq $DnsServerResourceRecord) {
			# declare and return
			Write-Host ("$Hostname,$ComputerName,$Name - ...DNS record not found")
			return
		}

		# define parameters for Remove-DnsServerResourceRecord
		$RemoveDnsServerResourceRecord = @{
			ComputerName = $ComputerName
			ZoneName     = $ZoneName
			Name         = $Name
			RRType       = 'A'
			Force        = $true
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# remove DNS record
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...found DNS record; removing...")
			Remove-DnsServerResourceRecord @RemoveDnsServerResourceRecord
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing DNS record")
			throw $_
		}

		# declare and return
		Write-Host ("$Hostname,$ComputerName,$Name - ...removed DNS record")
		return
	}

	function Remove-VMFromDomain {
		[CmdletBinding()]
		param(
			[string]$Name,
			[string]$ComputerName = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name
		)

		# define parameters for Get-ADObject
		$GetADObject = @{
			Server      = $ComputerName
			Filter      = "Name -eq '$Name' -and ObjectClass -eq 'computer'"
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# get computer object
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - checking computer object...")
			$ADObject = Get-ADObject @GetADObject
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving computer object")
			throw $_
		}

		# if computer object not found...
		if ($null -eq $ADObject) {
			# declare and return
			Write-Host ("$Hostname,$ComputerName,$Name - ...computer object not found")
			return
		}

		# define parameters for Remove-ADObject
		$RemoveADObject = @{
			Identity    = $ADObject
			Server      = $ComputerName
			Confirm     = $false
			Recursive   = $true
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# remove computer object
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...found computer object; removing...")
			Remove-ADObject @RemoveADObject
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing computer object")
			throw $_
		}

		# declare and return
		Write-Host ("$Hostname,$ComputerName,$Name - ...removed computer object")
		return
	}

	function Remove-VMNetworkAdapterFromDHCP {
		[CmdletBinding()]
		param(
			[string]$ComputerName,
			[string]$ScopeId,
			[string]$IPAddress
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
			Write-Host ("$Hostname,$ComputerName,$Name - ...DHCP scope not found, skipping DHCP cleanup")
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

		# validate DHCP reservations
		if ($null -eq $Reservations) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...no reservations found, skipping DHCP cleanup")
			return
		}

		# filter DHCP reservations
		Write-Host ("$Hostname,$ComputerName,$Name - checking for DHCP reservations with...")
		Write-Host ("$Hostname,$ComputerName,$Name - ...IP Address : '$IPAddress'")
		$Reservations = $Reservations | Where-Object { $_.IPAddress -eq $IPAddress }

		# check DHCP reservations
		if ($null -eq $Reservations) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...no matching DHCP reservations found")
			return
		}

		# define parameters for Remove-DhcpServerv4Reservation
		$RemoveDhcpServerv4Reservation = @{
			ComputerName = $ComputerName
			IPAddress    = $IPAddress
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# remove DHCP reservation
		try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...removing DHCP reservation with matching IP address")
			Remove-DhcpServerv4Reservation @RemoveDhcpServerv4Reservation
		}
		catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing DHCP reservation")
			throw $_
		}

		# declare action
		Write-Host ("$Hostname,$ComputerName,$Name - ...removed DHCP reservation(s)")

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
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving DHCP failover")
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
		# check if VMParams contains VM
		if ($null -eq $JsonData.$Name) {
			Write-Host ("$Hostname - VM not found in Json: '$Name'")
			continue
		}

		# override ComputerName with bound parameters if provided
		if ($PSBoundParameters['ComputerName']) {
			$ComputerName = $ComputerName
			Write-Host ("$Hostname,$ComputerName,$Name - WARNING: overriding ComputerName from JSON: '$($JsonData.$Name.ComputerName)'")
		}
		else {
			$ComputerName = $JsonData.$Name.ComputerName
		}

		# override VirtualMachinePath with bound parameters if provided
		if ($PSBoundParameters['Path']) {
			Write-Host ("$Hostname,$ComputerName,$Name - WARNING: overriding Path from JSON: '$($JsonData.$Name.Path)'")
		}
		else {
			$Path = $JsonData.$Name.Path
		}

		# define list for paths
		$VMPaths = [System.Collections.Generic.List[string]]::new()
		$VMPaths.Add("$Path\$Name")

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

		# if VM has OS deployment...
		if ($null -ne $VM -and $null -ne $JsonData.$Name.OSDeployment) {
			# ...retrieve OS deployment method
			$DeploymentMethod = $JsonData.$Name.OSDeployment.DeploymentMethod

			# if SkipProvisioning set...
			if ($SkipProvisioning) {
				# declare and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping OSD cleanup, SkipProvisioning set")
			}
			# if SkipProvisioning not set...
			else {
				# retrieve OS deployment method
				$DeploymentMethod = $JsonData.$Name.OSDeployment.DeploymentMethod
				# if DeploymentMethod is not present...
				if ([string]::IsNullOrEmpty($DeploymentMethod)) {
					Write-Host ("$Hostname,$ComputerName,$Name - ...skipping OSD cleanup, no method found")
				}
				# if DeploymentMethod is present...
				else {
					# check deployment method
					switch ($DeploymentMethod) {
						'ISO' {
							# declare and continue
							Write-Host ("$Hostname,$ComputerName,$Name - skipping OSD cleanup; ISO removed from VM during VM removal")
						}
						'WDS' {
							# declare and begin
							Write-Host ("$Hostname,$ComputerName,$Name - removing VM from WDS...")

							# define parameters for Remove-DeviceFromWds
							$RemoveDeviceFromWds = @{
								VM               = $VM
								DeploymentServer = $JsonData.$Name.OSDeployment.DeploymentServer
							}

							# remove VM from WDS
							try {
								Remove-DeviceFromWds @RemoveDeviceFromWds
							}
							catch {
								throw $_
							}
						}
						'SCCM' {
							# declare and begin
							Write-Host ("$Hostname,$ComputerName,$Name - removing VM from SCCM...")

							# define parameters for Remove-DeviceFromSccm
							$RemoveDeviceFromSccm = @{
								VM               = $VM
								DeploymentServer = $JsonData.$Name.OSDeployment.DeploymentServer
							}

							# remove VM from SCCM
							try {
								Remove-DeviceFromSccm @RemoveDeviceFromSccm
							}
							catch {
								throw $_
							}
						}
						Default {
							Write-Host ("$Hostname,$ComputerName,$Name - ...skipping OSD cleanup, unknown method provided: '$DeploymentMethod'")
						}
					}
				}
			}
		}

		# get VM snapshots...
		if ($null -ne $VM) {
			# get parent snapshots
			try {
				$VMSnapshots = Get-VMSnapshot -VM $VM
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM snapshots")
				throw $_
			}
		}

		# if VM has snapshots...
		if ($null -ne $VM -and $null -ne $VMSnapshots) {
			# process snapshots
			foreach ($VMSnapshot in $VMSnapshots) {
				# remove snapshot and child snapshots
				try {
					Remove-VMSnapshot -VMSnapshot $VMSnapshot -IncludeAllChildSnapshots
				}
				catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove VM snapshots")
					throw $_
				}
			}

			# define values for while loop and reporting
			$While = @{
				Action     = 'disks to merge after snapshot removal' # action being waited for
				Expression = '$VM.SecondaryStatus' # expression that evaluates true while action is in progress and false when action is complete
				Multiplier = [int32]0 # counter for current loop
				WaitTime   = [int32]0 # counter for total seconds in while loop
				Seconds    = [int32]5 # sleep time for each pass of while loop; multiplied by loop counter to gradually add time to each loop
				Limit      = [int32]8 # maximum passes to complete; default limit of 8 with 5 seconds allows 180 seconds for the action to complete
			}

			# wait for VM to return to normal operation
			Write-Host ("$Hostname,$ComputerName,$Name - waiting for $($While.Action)...")
			while ((Invoke-Expression -Command $While.Expression) -and $While.Multiplier -lt $While.Limit) {
				# increment multiplier
				$While.Multiplier++

				# record total time
				$While.WaitTime += ($While.Seconds * $While.Multiplier)

				# declare updated wait time then sleep
				Write-Host ("$Hostname,$ComputerName,$Name - ...waiting an additional '$($While.Seconds * $While.Multiplier)' seconds")
				Start-Sleep -Seconds ($While.Seconds * $While.Multiplier)
			}

			# if VM still has a secondary status found...
			if ($VM.SecondaryStatus) {
				# ...declare wait time and return
				Write-Host ("$Hostname,$ComputerName,$Name - WARNING: waited '$($While.WaitTime)' for $($While.Action)")
				Write-Host ("$Hostname,$ComputerName,$Name - ...check Hyper-V before continuing")
				return $null
			}
			else {
				# ...declare wait time and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...waited '$($While.WaitTime)' seconds for $($While.Action)")
			}
		}

		# get VM storage paths
		if ($null -ne $VM -and -not $PreserveHardDrives) {
			# define lists
			$VHDPaths = [System.Collections.Generic.List[string]]::new()

			# retrieve VHDs attached to VM
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - retrieving VHDs attached to VM")
				$VHDs = Get-VMHardDiskDrive -VM $VM
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VHDs from VM")
				throw $_
			}

			# process VHDs
			foreach ($VHD in $VHDs) {
				# if VHD is shared...
				if ($VHD.SupportPersistentReservations) {
					# declare warning
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: found shared VHD: '$($VHD.Path)'")
				}
				else {
					# add VHD path to list
					Write-Host ("$Hostname,$ComputerName,$Name - ...found VHD to remove: '$($VHD.Path)'")
					$VHDPaths.Add($VHD.Path)
				}
			}
		}

		# get VM paths
		if ($null -ne $VM) {
			# get path information
			$VMPaths.Add($VM.CheckpointFileLocation)
			$VMPaths.Add($VM.ConfigurationLocation)
			$VMPaths.Add($VM.SmartPagingFilePath)
			$VMPaths.Add($VM.SnapshotFileLocation)
			$VMPaths.Add($VM.Path)

			# add known child paths
			$VMPaths.Add(($VM.Path, 'Virtual Machines' -join '\'))
			$VMPaths.Add(($VM.Path, 'Virtual Hard Disks' -join '\'))

			# get GUID
			$VMid = $VM.id
		}

		# remove VM from host
		if ($null -ne $VM) {
			# turn off the VM if running
			if ($VM.State -ne 'Off') {
				# if Force net set...
				if (-not $Force) {
					# warn and inquire
					Write-Warning 'VM is not offline! Stop VM and remove?' -WarningAction Inquire
				}

				# define parameters for Remove-VM
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

			# define parameters for Remove-VM
			$RemoveVM = @{
				VM      = $VM
				Force   = $true
				Confirm = $false
			}

			# remove the VM
			try {
				Write-Host ("$Hostname,$ComputerName,$Name - removing VM from host...")
				Remove-VM @RemoveVM
			}
			catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing VM")
				throw $_
			}

			# report
			Write-Host ("$Hostname,$ComputerName,$Name - ...VM removed")
		}

		# remove VHDs from host
		if ($null -ne $VHDPaths) {
			foreach ($Path in $VHDPaths) {
				# declare and begin
				Write-Host ("$Hostname,$ComputerName,$Name - removing VHD: '$Path'")

				# define parameters for Remove-VHD
				$RemoveVHD = @{
					Path         = $Path
					ComputerName = $ComputerName
				}

				# remove VHD from host
				try {
					Remove-VHD @RemoveVHD
				}
				catch {
					throw $_
				}

				# add VHD parent path to VMPaths
				$VHDPath = Split-Path -Path $Path -Parent
				$VMPaths.Add($VHDPath)
			}

			# clear VHD paths
			$null = $VHDPaths
		}

		# remove files and folders from VM paths
		if ($null -ne $VMPaths) {
			# filter VM paths
			$VMPaths = $VMPaths | Select-Object -Unique | Sort-Object -Descending

			# define list for VM items
			$Items = [System.Collections.Generic.List[System.String]]::new()

			# add required items
			$Items.Add($Name)

			# add optional items
			if ($null -ne $VMId) {
				$Items.Add($VMId)
			}

			# remove files from paths
			foreach ($Path in $VMPaths) {
				# declare and begin
				Write-Host ("$Hostname,$ComputerName,$Name - removing VM files from path: '$Path'")

				# define parameters for Remove-ItemsFromPath
				$RemoveItemsFromPath = @{
					ComputerName = $ComputerName
					Path         = $Path
					Items        = $Items
				}

				# remove VHD from host
				try {
					Remove-ItemsFromPath @RemoveItemsFromPath
				}
				catch {
					throw $_
				}
			}

			# remove paths
			foreach ($Path in $VMPaths) {
				# declare and begin
				Write-Host ("$Hostname,$ComputerName,$Name - removing VM path: '$Path'")

				# define parameters for Remove-EmptyPath
				$RemoveEmptyPath = @{
					ComputerName = $ComputerName
					Path         = $Path
				}

				# remove VHD from host
				try {
					Remove-EmptyPath @RemoveEmptyPath
				}
				catch {
					throw $_
				}
			}

			# clear VM paths
			$null = $VMPaths
		}

		# remove network objects
		if ($RemoveNetworkObjects) {
			# process each VMNetworkAdapter defined in JSON
			foreach ($VMNetworkAdapter in $JsonData.$Name.VMNetworkAdapters) {
				if ($null -ne $VMNetworkAdapter.DhcpServer -and $null -ne $VMNetworkAdapter.DhcpScope -and $null -ne $VMNetworkAdapter.IPAddress) {
					# define parameters for Remove-VMNetworkAdapterFromDHCP
					$RemoveVMNetworkAdapterFromDHCP = @{
						ComputerName = $VMNetworkAdapter.DhcpServer
						ScopeId      = $VMNetworkAdapter.DhcpScope
						IPAddress    = $VMNetworkAdapter.IPAddress
					}

					# remove VMNetworkAdapter from DHCP
					try {
						Remove-VMNetworkAdapterFromDHCP @RemoveVMNetworkAdapterFromDHCP
					}
					catch {
						throw $_
					}
				}
			}

			# define parameters for Remove-VMFromDnsServer
			$RemoveVMFromDnsServer = @{
				Name = $Name
			}

			# remove VM from DNS
			try {
				Remove-VMFromDnsServer @RemoveVMFromDnsServer
			}
			catch {
				throw $_
			}

			# define parameters for Remove-VMFromDomain
			$RemoveVMFromDomain = @{
				Name = $Name
			}

			# remove VM from domain
			try {
				Remove-VMFromDomain @RemoveVMFromDomain
			}
			catch {
				throw $_
			}
		}
	}
}
