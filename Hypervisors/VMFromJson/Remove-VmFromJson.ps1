[CmdletBinding()]
Param(
	[Parameter(Position = 0, Mandatory)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	[Parameter(Position = 1, ValueFromPipeline)]
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

Begin {
	# set error action preference
	$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

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
		If ($script:PSSessions[$ComputerName] -is [System.Management.Automation.Runspaces.PSSession]) {
			# if session is open and available...
			If ($script:PSSessions[$ComputerName].State -eq 'Opened' -and $script:PSSessions[$ComputerName].Availability -eq 'Available') {
				# ...return true as session can already be referenced
				Return $true
			}
		}

		# create a new session
		Try {
			$script:PSSessions[$ComputerName] = New-PSSession -ComputerName $ComputerName -Name $ComputerName -Authentication Default
		}
		Catch {
			Return $false
		}

		# ...validate session
		If ($script:PSSessions[$ComputerName] -is [System.Management.Automation.Runspaces.PSSession]) {
			# if session is open and available...
			If ($script:PSSessions[$ComputerName].State -eq 'Opened' -and $script:PSSessions[$ComputerName].Availability -eq 'Available') {
				# ...return true as session can already be referenced
				Return $true
			}
			Else {
				Return $false
			}
		}
		Else {
			Return $false
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
				# define parameters for Get-ClusterNode
				$GetClusterNode = @{
					ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
				}

				# retrieve names of cluster nodes
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
				$ComputerName = $VM.ComputerName
			}
			Else {
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

	Function Move-ClusterSharedVolumeForPath {
		[CmdletBinding()]
		Param(
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
		Try {
			$ClusterName = Get-ClusterName @GetClusterName
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: checking if host is clustered")
			Throw $_
		}

		# if cluster name not found...
		If ([string]::IsNullOrEmpty($ClusterName)) {
			# ...return to caller
			Return
		}

		# define parameters for Get-ClusterSharedVolume
		$GetClusterSharedVolume = @{
			Cluster     = $ClusterName
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve cluster shared volumes
		Try {
			$ClusterSharedVolumes = Get-ClusterSharedVolume @GetClusterSharedVolume
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving cluster shared volumes")
			Throw $_
		}

		# loop through cluster shared volumes
		:NextClusterSharedVolume ForEach ($ClusterSharedVolume in $ClusterSharedVolumes) {
			# if CSV already on current host...
			If ($ClusterSharedVolume.OwnerNode.Name -eq $ComputerName) {
				Continue NextClusterSharedVolume
			}

			# if path on CVS...
			If (!$Path.StartsWith($ClusterSharedVolume.SharedVolumeInfo.FriendlyVolumeName, [System.StringComparison]::InvariantCultureIgnoreCase)) {
				Continue NextClusterSharedVolume
			}

			# define parameters for Move-ClusterSharedVolume
			$MoveClusterSharedVolume = @{
				Name        = $ClusterSharedVolume.Name
				Node        = $ComputerName
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# move cluster shared volume to requested computer
			Try {
				$null = Move-ClusterSharedVolume @MoveClusterSharedVolume
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: moving '$($ClusterSharedVolume.Name)' cluster shared volume to current node")
				Throw $_
			}

			# report state
			Write-Host ("$Hostname,$ComputerName,$Name - moved '$($ClusterSharedVolume.Name)' cluster shared volume to current node")
		}
	}

	Function Remove-DeviceFromSccm {
		param (
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			# define OSD parameters
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
			Write-Host ("$Hostname,$ComputerName,$Name - WARNING: BIOS GUID for VM is empty; skipping SCCM provisioning...")
			Return
		}
		Else {
			Write-Host ("$Hostname,$ComputerName,$Name - ...found BIOS GUID for VM")
			$BIOSGUID = $CimInstanceForVM.BIOSGUID
		}

		# get CM module path
		Try {
			$CMModulePath = Get-CMModulePath -ComputerName $DeploymentServer -ErrorAction Stop
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

		# get CM site code
		Try {
			$CMSiteCode = Get-CMSiteCode -ComputerName $DeploymentServer -ErrorAction Stop
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
		$InvokeCommand['ArgumentList']['ComputerName'] = $DeploymentServer
		$InvokeCommand['ArgumentList']['Name'] = $Name

		# update arguments for Invoke-Command - deployment
		$InvokeCommand['ArgumentList']['ModulePath'] = $CMModulePath
		$InvokeCommand['ArgumentList']['SiteCode'] = $CMSiteCode
		$InvokeCommand['ArgumentList']['BIOSGUID'] = $BIOSGUID

		# connect to SCCM remotely
		Write-Host ("$Hostname,$ComputerName,$Name - connecting to SCCM: $DeploymentServer")
		Invoke-Command @InvokeCommand -ScriptBlock {
			Param($ArgumentList)

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

				# if device found by name with unexpected BIOSGUID...
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

				# if device found by SMBIOSGUID and with unexpected name...
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

			# if Device not found...
			If ($null -eq $Device) {
				# return
				Return
			}
			# if Device found...
			Else {
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

			# remove device
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - removing device with resource ID: $ResourceId")
				Remove-CMResource -ResourceId $ResourceId -Force
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing device by resource ID")
				Throw $_
			}

			# report and return
			Write-Host ("$Hostname,$ComputerName,$Name - ...removed device from SCCM")
			Return
		}
	}

	Function Remove-EmptyPath {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[Parameter(Mandatory = $true)]
			[string]$Path
		)

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not get initial hashtable for Invoke-Command")
			Throw $_
		}

		# update argument list for removing paths
		$InvokeCommand['ArgumentList']['Path'] = $Path

		# test path
		Try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
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
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not check provided path")
			Throw $_
		}

		# if path not found...
		If (!$TestPath) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...skipping empty path removal, path not found: '$Path'")
			Return
		}

		# update argument list for reporting
		$InvokeCommand['ArgumentList']['Hostname'] = $Hostname
		$InvokeCommand['ArgumentList']['ComputerName'] = $ComputerName
		$InvokeCommand['ArgumentList']['Name'] = $Name

		# remove empty path
		Invoke-Command @InvokeCommand -ScriptBlock {
			Param($ArgumentList)

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
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...checking path for child items: '$Path'")
				$ChildItems = Get-ChildItem @GetChildItem
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not check path for child items")
				Throw $_
			}

			# if items are in path...
			If ($null -ne $ChildItems) {
				# warn and return
				Write-Host ("$Hostname,$ComputerName,$Name - WARNING: path not empty: '$Path'")
				Return
			}

			# define parameters for Remove-Item
			$RemoveItem = @{
				Path        = $Path
				Confirm     = $false
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# remove path
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - ...removing path: '$Path'")
				Remove-Item @RemoveItem
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove path")
				Throw $_
			}
		}
	}

	Function Remove-ItemsFromPath {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[Parameter(Mandatory = $true)]
			[string]$Path,
			[Parameter(Mandatory = $true)]
			[string[]]$Items
		)

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not get initial hashtable for Invoke-Command")
			Throw $_
		}

		# update argument list for removing files
		$InvokeCommand['ArgumentList']['Path'] = $Path

		# test path
		Try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
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
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not check provided path")
			Throw $_
		}

		# if path not found...
		If (!$TestPath) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...skipping item removal, path not found: '$Path'")
			Return
		}

		# update argument list for reporting
		$InvokeCommand['ArgumentList']['Hostname'] = $Hostname
		$InvokeCommand['ArgumentList']['ComputerName'] = $ComputerName
		$InvokeCommand['ArgumentList']['Name'] = $Name

		# update argument list for removing files
		$InvokeCommand['ArgumentList']['Items'] = $Items

		# remove items from path
		Invoke-Command @InvokeCommand -ScriptBlock {
			Param($ArgumentList)

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
			Try {
				$ChildItems = Get-ChildItem @GetChildItem
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve items in path: '$Path'")
				Throw $_
			}

			# create object for path
			$Items = $ArgumentList['Items']

			# retrieve files where items contains the name, basename, or fullname of the item
			$ItemsToRemove = $ChildItems | Where-Object { $_.Name -in $Items -or $_.BaseName -in $Items -or $_.Fullname -in $Items }

			# if there are no items to remove...
			If ($null -eq $ItemsToRemove) {
				# declare and return
				Write-Host ("$Hostname,$ComputerName,$Name - ...path is empty")
				Return
			}

			# process files
			ForEach ($ItemToRemove in $ItemsToRemove) {
				# define parameters for Remove-Item
				$RemoveItem = @{
					Path        = $ItemToRemove.FullName
					Confirm     = $false
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}

				# remove item
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - ...removing item: '$($ItemToRemove.FullName)'")
					Remove-Item @RemoveItem
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove item")
					Throw $_
				}
			}
		}
	}

	Function Remove-VHD {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[Parameter(Mandatory = $true)]
			[string]$Path
		)

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not get initial hashtable for Invoke-Command")
			Throw $_
		}

		# update argument list for removing files
		$InvokeCommand['ArgumentList']['Path'] = $Path

		# test path
		Try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
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
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not check provided path")
			Throw $_
		}

		# if path found...
		If ($TestPath) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...found source VHD: '$Path'")
		}
		Else {
			Write-Host ("$Hostname,$ComputerName,$Name - ...skipping VHD remove, host did not find file: '$Path'")
			Return
		}

		# dismount VHD from system before removal
		Try {
			Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				# define parameters for Dismount-DiskImage
				$DismountDiskImage = @{
					ImagePath   = $ArgumentList['Path']
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				# define parameters for VHD files
				If ($ArgumentList['Path'].EndsWith('.VHD', [System.StringComparison]::InvariantCultureIgnoreCase)) {
					$DismountDiskImage['StorageType'] = 'VHD'
				}
				# define parameters for VHDX files
				If ($ArgumentList['Path'].EndsWith('.VHDX', [System.StringComparison]::InvariantCultureIgnoreCase)) {
					$DismountDiskImage['StorageType'] = 'VHDX'
				}

				# dismount disk image from system
				$null = Dismount-DiskImage @DismountDiskImage
			}
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: dismounting disk image")
			Throw $_
		}

		# if VHD, rotate CSV
		If ($Path.EndsWith('.VHD', [System.StringComparison]::InvariantCultureIgnoreCase)) {
			Try {
				# define parameters for Remove-Item
				$MoveClusterSharedVolumeForPath = @{
					ComputerName = $ComputerName
					Path         = $Path
					ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
				}
				# move cluster shared volume
				Move-ClusterSharedVolumeForPath @MoveClusterSharedVolumeForPath
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: moving CSV for VHD removal")
				Throw $_
			}
		}

		# remove VHD from system after dismount
		Try {
			Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
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
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing VHD")
			Throw $_
		}

		# declare and return
		Write-Host ("$Hostname,$ComputerName,$Name - ...removed VHD")
		Return
	}

	Function Remove-VMFromClusterName {
		[CmdletBinding()]
		Param(
			# define VM parameters
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[string]$ComputerName = $VM.ComputerName.ToLower(),
			# define cluster parameters
			[Parameter(Mandatory = $true)]
			[string]$ClusterName
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
			VMId        = $VM.Id
			ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
		}

		# retrieve existing cluster group
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - checking cluster for VM...")
			$ClusterGroup = Get-ClusterGroup @GetClusterGroup
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: getting cluster group for VM")
			Throw $_
		}

		# if cluster group not found...
		If ($null -eq $ClusterGroup) {
			# declare and return
			Write-Host ("$Hostname,$ComputerName,$Name - ...VM not found in cluster: $ClusterName")
			Return
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
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...VM found in cluster, removing from cluster: $ClusterName")
			Remove-ClusterGroup @RemoveClusterGroup
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing VM from cluster")
			Throw $_
		}

		# declare and return
		Write-Host ("$Hostname,$ComputerName,$Name - ...removed VM from cluster")
		Return
	}

	Function Remove-VMFromDnsServer {
		[CmdletBinding()]
		Param(
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
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - checking DNS record...")
			$DnsServerResourceRecord = Get-DnsServerResourceRecord @GetDnsServerResourceRecord
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving DNS record")
			Throw $_
		}

		# if DNS record not found...
		If ($null -eq $DnsServerResourceRecord) {
			# declare and return
			Write-Host ("$Hostname,$ComputerName,$Name - ...DNS record not found")
			Return
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
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...found DNS record; removing...")
			Remove-DnsServerResourceRecord @RemoveDnsServerResourceRecord
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing DNS record")
			Throw $_
		}

		# declare and return
		Write-Host ("$Hostname,$ComputerName,$Name - ...removed DNS record")
		Return
	}

	Function Remove-VMFromDomain {
		[CmdletBinding()]
		Param(
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
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - checking computer object...")
			$ADObject = Get-ADObject @GetADObject
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving computer object")
			Throw $_
		}

		# if computer object not found...
		If ($null -eq $ADObject) {
			# declare and return
			Write-Host ("$Hostname,$ComputerName,$Name - ...computer object not found")
			Return
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
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...found computer object; removing...")
			Remove-ADObject @RemoveADObject
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing computer object")
			Throw $_
		}

		# declare and return
		Write-Host ("$Hostname,$ComputerName,$Name - ...removed computer object")
		Return
	}

	Function Remove-VMNetworkAdapterFromDHCP {
		[CmdletBinding()]
		Param(
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
			Write-Host ("$Hostname,$ComputerName,$Name - ...DHCP scope not found, skipping DHCP cleanup")
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

		# validate DHCP reservations
		If ($null -eq $Reservations) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...no reservations found, skipping DHCP cleanup")
			Return
		}

		# filter DHCP reservations
		Write-Host ("$Hostname,$ComputerName,$Name - checking for DHCP reservations with...")
		Write-Host ("$Hostname,$ComputerName,$Name - ...IP Address : '$IPAddress'")
		$Reservations = $Reservations | Where-Object { $_.IPAddress -eq $IPAddress }

		# check DHCP reservations
		If ($null -eq $Reservations) {
			Write-Host ("$Hostname,$ComputerName,$Name - ...no matching DHCP reservations found")
			Return
		}

		# define parameters for Remove-DhcpServerv4Reservation
		$RemoveDhcpServerv4Reservation = @{
			ComputerName = $ComputerName
			IPAddress    = $IPAddress
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# remove DHCP reservation
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - ...removing DHCP reservation with matching IP address")
			Remove-DhcpServerv4Reservation @RemoveDhcpServerv4Reservation
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing DHCP reservation")
			Throw $_
		}

		# declare action
		Write-Host ("$Hostname,$ComputerName,$Name - ...removed DHCP reservation(s)")

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
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: retrieving DHCP failover")
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
		# check if VMParams contains VM
		If ($null -eq $JsonData.$Name) {
			Write-Host ("$Hostname - VM not found in Json: '$Name'")
			Continue
		}

		# override ComputerName with bound parameters if provided
		If ($PSBoundParameters['ComputerName']) {
			$ComputerName = $ComputerName
			Write-Host ("$Hostname,$ComputerName,$Name - WARNING: overriding ComputerName from JSON: '$($JsonData.$Name.ComputerName)'")
		}
		Else {
			$ComputerName = $JsonData.$Name.ComputerName
		}

		# override VirtualMachinePath with bound parameters if provided
		If ($PSBoundParameters['Path']) {
			Write-Host ("$Hostname,$ComputerName,$Name - WARNING: overriding Path from JSON: '$($JsonData.$Name.Path)'")
		}
		Else {
			$Path = $JsonData.$Name.Path
		}

		# define list for paths
		$VMPaths = [System.Collections.Generic.List[string]]::new()
		$VMPaths.Add("$Path\$Name")

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

		# if VM is on a cluster...
		If ($null -ne $VM -and -not [string]::IsNullOrEmpty($ClusterName)) {
			# define required parameters for Add-VMToClusterName
			$RemoveVMFromClusterName = @{
				VM          = $VM
				ClusterName = $ClusterName
			}

			# remove VM from cluster
			Try {
				Remove-VMFromClusterName @RemoveVMFromClusterName
			}
			Catch {
				Throw $_
			}
		}

		# if VM has OS deployment...
		If ($null -ne $VM -and $null -ne $JsonData.$Name.OSDeployment) {
			# ...retrieve OS deployment method
			$DeploymentMethod = $JsonData.$Name.OSDeployment.DeploymentMethod

			# if SkipProvisioning set...
			If ($SkipProvisioning) {
				# declare and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...skipping OSD cleanup, SkipProvisioning set")
			}
			# if SkipProvisioning not set...
			Else {
				# retrieve OS deployment method
				$DeploymentMethod = $JsonData.$Name.OSDeployment.DeploymentMethod
				# if DeploymentMethod is not present...
				If ([string]::IsNullOrEmpty($DeploymentMethod)) {
					Write-Host ("$Hostname,$ComputerName,$Name - ...skipping OSD cleanup, no method found")
				}
				# if DeploymentMethod is present...
				Else {
					# check deployment method
					switch ($DeploymentMethod) {
						'SCCM' {
							# declare and begin
							Write-Host ("$Hostname,$ComputerName,$Name - removing VM from SCCM...")

							# define parameters for Remove-DeviceFromSccm
							$RemoveDeviceFromSccm = @{
								VM               = $VM
								DeploymentServer = $JsonData.$Name.OSDeployment.DeploymentServer
							}

							# remove VM from SCCM
							Try {
								Remove-DeviceFromSccm @RemoveDeviceFromSccm
							}
							Catch {
								Throw $_
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
		If ($null -ne $VM) {
			# get parent snapshots
			Try {
				$VMSnapshots = Get-VMSnapshot -VM $VM
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VM snapshots")
				Throw $_
			}
		}

		# if VM has snapshots...
		If ($null -ne $VM -and $null -ne $VMSnapshots) {
			# process snapshots
			ForEach ($VMSnapshot in $VMSnapshots) {
				# remove snapshot and child snapshots
				Try {
					Remove-VMSnapshot -VMSnapshot $VMSnapshot -IncludeAllChildSnapshots
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not remove VM snapshots")
					Throw $_
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
			While ((Invoke-Expression -Command $While.Expression) -and $While.Multiplier -lt $While.Limit) {
				# increment multiplier
				$While.Multiplier++

				# record total time
				$While.WaitTime += ($While.Seconds * $While.Multiplier)

				# declare updated wait time then sleep
				Write-Host ("$Hostname,$ComputerName,$Name - ...waiting an additional '$($While.Seconds * $While.Multiplier)' seconds")
				Start-Sleep -Seconds ($While.Seconds * $While.Multiplier)
			}

			# if VM still has a secondary status found...
			If ($VM.SecondaryStatus) {
				# ...declare wait time and return
				Write-Host ("$Hostname,$ComputerName,$Name - WARNING: waited '$($While.WaitTime)' for $($While.Action)")
				Write-Host ("$Hostname,$ComputerName,$Name - ...check Hyper-V before continuing")
				Return $null
			}
			Else {
				# ...declare wait time and continue
				Write-Host ("$Hostname,$ComputerName,$Name - ...waited '$($While.WaitTime)' seconds for $($While.Action)")
			}
		}

		# get VM storage paths
		If ($null -ne $VM -and -not $PreserveHardDrives) {
			# define lists
			$VHDPaths = [System.Collections.Generic.List[string]]::new()

			# retrieve VHDs attached to VM
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - retrieving VHDs attached to VM")
				$VHDs = Get-VMHardDiskDrive -VM $VM
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not retrieve VHDs from VM")
				Throw $_
			}

			# process VHDs
			ForEach ($VHD in $VHDs) {
				# if VHD is shared...
				If ($VHD.SupportPersistentReservations) {
					# declare warning
					Write-Host ("$Hostname,$ComputerName,$Name - WARNING: found shared VHD: '$($VHD.Path)'")
				}
				Else {
					# add VHD path to list
					Write-Host ("$Hostname,$ComputerName,$Name - ...found VHD from VM to remove: '$($VHD.Path)'")
					$VHDPaths.Add($VHD.Path)
				}
			}

			# retrieve VHDs from JSON
			$VHDPathsFromJson = $JsonData.$Name.VMHardDiskDrives.Path

			# loop through VHDs
			ForEach ($VHDPath in $VHDPathsFromJson) {
				# if VHD path not in list...
				If ($VHDPath -notin $VHDs) {
					# add VHD path to list
					Write-Host ("$Hostname,$ComputerName,$Name - ...found VHD from JSON to remove: '$VHDPath'")
					$VHDPaths.Add($VHDPath)
				}
			}
		}

		# get VM paths
		If ($null -ne $VM) {
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
		If ($null -ne $VM) {
			# turn off the VM if running
			If ($VM.State -ne 'Off') {
				# if Force net set...
				If (-not $Force) {
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
				Try {
					Write-Host ("$Hostname,$ComputerName,$Name - stopping VM on host...")
					Stop-VM @StopVM
				}
				Catch {
					Write-Host ("$Hostname,$ComputerName,$Name - ERROR: stopping VM")
					Throw $_
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
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - removing VM from host...")
				Remove-VM @RemoveVM
			}
			Catch {
				Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing VM")
				Throw $_
			}

			# report
			Write-Host ("$Hostname,$ComputerName,$Name - ...VM removed")
		}

		# remove VHDs from host
		If ($null -ne $VHDPaths) {
			ForEach ($Path in $VHDPaths) {
				# declare and begin
				Write-Host ("$Hostname,$ComputerName,$Name - removing VHD: '$Path'")

				# define parameters for Remove-VHD
				$RemoveVHD = @{
					Path         = $Path
					ComputerName = $ComputerName
				}

				# remove VHD from host
				Try {
					Remove-VHD @RemoveVHD
				}
				Catch {
					Throw $_
				}

				# add VHD parent path to VMPaths
				$VHDPath = Split-Path -Path $Path -Parent
				$VMPaths.Add($VHDPath)
			}

			# clear VHD paths
			$null = $VHDPaths
		}

		# remove files and folders from VM paths
		If ($null -ne $VMPaths) {
			# filter VM paths
			$VMPaths = $VMPaths | Select-Object -Unique | Sort-Object -Descending

			# define list for VM items
			$Items = [System.Collections.Generic.List[System.String]]::new()

			# add required items
			$Items.Add($Name)

			# add optional items
			If ($null -ne $VMId) {
				$Items.Add($VMId)
			}

			# remove files from paths
			ForEach ($Path in $VMPaths) {
				# declare and begin
				Write-Host ("$Hostname,$ComputerName,$Name - removing VM files from path: '$Path'")

				# define parameters for Remove-ItemsFromPath
				$RemoveItemsFromPath = @{
					ComputerName = $ComputerName
					Path         = $Path
					Items        = $Items
				}

				# remove VHD from host
				Try {
					Remove-ItemsFromPath @RemoveItemsFromPath
				}
				Catch {
					Throw $_
				}
			}

			# remove paths
			ForEach ($Path in $VMPaths) {
				# declare and begin
				Write-Host ("$Hostname,$ComputerName,$Name - removing VM path: '$Path'")

				# define parameters for Remove-EmptyPath
				$RemoveEmptyPath = @{
					ComputerName = $ComputerName
					Path         = $Path
				}

				# remove VHD from host
				Try {
					Remove-EmptyPath @RemoveEmptyPath
				}
				Catch {
					Throw $_
				}
			}

			# clear VM paths
			$null = $VMPaths
		}

		# remove network objects
		If ($RemoveNetworkObjects) {
			# process each VMNetworkAdapter defined in JSON
			ForEach ($VMNetworkAdapter in $JsonData.$Name.VMNetworkAdapters) {
				If ($null -ne $VMNetworkAdapter.DhcpServer -and $null -ne $VMNetworkAdapter.DhcpScope -and $null -ne $VMNetworkAdapter.IPAddress) {
					# define parameters for Remove-VMNetworkAdapterFromDHCP
					$RemoveVMNetworkAdapterFromDHCP = @{
						ComputerName = $VMNetworkAdapter.DhcpServer
						ScopeId      = $VMNetworkAdapter.DhcpScope
						IPAddress    = $VMNetworkAdapter.IPAddress
					}

					# remove VMNetworkAdapter from DHCP
					Try {
						Remove-VMNetworkAdapterFromDHCP @RemoveVMNetworkAdapterFromDHCP
					}
					Catch {
						Throw $_
					}
				}
			}

			# define parameters for Remove-VMFromDnsServer
			$RemoveVMFromDnsServer = @{
				Name = $Name
			}

			# remove VM from DNS
			Try {
				Remove-VMFromDnsServer @RemoveVMFromDnsServer
			}
			Catch {
				Throw $_
			}

			# define parameters for Remove-VMFromDomain
			$RemoveVMFromDomain = @{
				Name = $Name
			}

			# remove VM from domain
			Try {
				Remove-VMFromDomain @RemoveVMFromDomain
			}
			Catch {
				Throw $_
			}
		}
	}
}

End {
	# loop through keys in sessions hashtable
	ForEach ($SessionName in $script:PSSessions.Keys) {
		# remove session
		Try {
			$script:PSSessions[$SessionName] | Remove-PSSession
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: removing '$SessionName' session")
		}
	}
}
