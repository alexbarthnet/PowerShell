[CmdletBinding()]
param (
	# array of VM objects or VM names
	[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
	[object[]]$VM,
	# computer name of target computer
	[Parameter(Mandatory = $true)]
	[string]$ComputerName,
	# path on target computer
	[Parameter(Mandatory = $true)]
	[string]$Path,
	# computer name of source computer
	[Parameter()]
	[string]$SourceComputerName,
	# force shutdown of running VM
	[Parameter()]
	[switch]$Force,
	# start stopped VM after migration
	[Parameter()]
	[switch]$Restart,
	# hostname of local computer
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
)

Begin {
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
		Return $ClusterName
	}

	# get hashtable for InvokeCommand splat
	Try {
		$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
	}
	Catch {
		Throw $_
	}

	# declare state
	Write-Host "$Hostname - checking path on destination..."

	# test path on destination
	Try {
		$null = Invoke-Command @InvokeCommand -ScriptBlock {
			Get-Item -Path $using:Path
		}
	}
	Catch {
		Throw $_
	}

	# declare state
	Write-Host "$Hostname - ...path found: $Path"
	Write-Host "$Hostname - retrieving SMB shares..."

	# get SMB shares on target computer
	Try {
		$SmbShares = Get-SmbShare -CimSession $ComputerName -Special $true
	}
	Catch {
		Throw $_
	}

	# declare state
	Write-Host "$Hostname - ...shares found"
	Write-Host "$Hostname - building UNC path for export..."

	# get first SMB share where path parameter starts with share path and share path not null or empty
	$SmbShare = $SmbShares | Where-Object { $Path.StartsWith($_.Path, [System.StringComparison]::InvariantCultureIgnoreCase) -and -not [string]::IsNullOrEmpty($_.Path) } | Select-Object -First 1

	# define share path from path parameter and SMB share
	$SharePath = $Path.Replace($SmbShare.Path, "\\$ComputerName\$($SmbShare.Name)\")

	# declare state
	Write-Host "$Hostname - ...UNC path built: $SharePath"
}

Process {
	################################################
	# check for VM on source computer
	################################################

	# if input is not a VM object...
	If ($VM -isnot [Microsoft.HyperV.PowerShell.VirtualMachine]) {
		# declare state
		Write-Host "$Hostname - retrieving VM object by name: $VM"

		# define required parameters for Get-VM
		$GetVM = @{
			Name        = $VM
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# define optional parameters for Get-VM
		If ($PSBoundParameters['SourceComputerName']) {
			$GetVM['ComputerName'] = $SourceComputerName
		}

		# get VM object from input
		Try {
			$VM = Get-VM @GetVM
		}
		Catch {
			Throw $_
		}
	}

	# get VM properties
	$Id = $VM.Id
	$Name = $VM.Name
	$State = $VM.State
	$SourceComputerName = $VM.ComputerName
	$AutomaticStartAction = $VM.AutomaticStartAction

	################################################
	# check for VM on target computer
	################################################

	# declare state
	Write-Host "$Hostname - checking destination for VM '$Name' with Id '$Id'"

	# define parameters for Get-VM on target computer
	$GetVM = @{
		Id           = $Id
		ComputerName = $ComputerName
		ErrorAction  = [System.Management.Automation.ActionPreference]::SilentlyContinue
	}

	# get VM from target server
	Try {
		$TargetVM = Get-VM @GetVM
	}
	Catch {
		Throw $_
	}

	# if VM found on target server...
	If ($TargetVM) {
		# warn and return
		Write-Warning 'VM has already been migrated to target server'
		Return
	}

	################################################
	# check for VM on target cluster
	################################################

	# get cluster for target server
	Try {
		$ClusterName = Get-ClusterName -ComputerName $ComputerName
	}
	Catch {
		Throw $_
	}

	# if target computer is clustered...
	If ($ClusterName) {
		# define parameters for Get-ClusterGroup
		$GetClusterGroup = @{
			Cluster     = $ClusterName
			VMId        = $Id
			ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
		}

		# get cluster group for VM on target cluster
		Try {
			$TargetClusterGroup = Get-ClusterGroup @GetClusterGroup
		}
		Catch {
			Throw $_
		}
	}

	# if cluster group for VM found on target cluster...
	If ($TargetClusterGroup) {
		# warn and return
		Write-Warning 'VM has already been migrated to target cluster'
		Return
	}

	################################################
	# remove VM from source cluster
	################################################

	# declare state
	Write-Host "$Hostname - ...VM not found on destination"
	Write-Host "$Hostname - preparing VM for offline migration..."

	# get cluster for source computer
	Try {
		$SourceClusterName = Get-ClusterName -ComputerName $SourceComputerName
	}
	Catch {
		Throw $_
	}

	# if source computer is clustered...
	If ($SourceClusterName) {
		# define parameters for Get-ClusterGroup
		$GetClusterGroup = @{
			Cluster     = $SourceClusterName
			VMId        = $Id
			ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
		}

		# get cluster group for VM on source cluster
		Try {
			$SourceClusterGroup = Get-ClusterGroup @GetClusterGroup
		}
		Catch {
			Throw $_
		}
	}

	# remove VM from source cluster
	If ($SourceClusterGroup) {
		# define parameters for Get-ClusterGroup
		$RemoveClusterGroup = @{
			Cluster         = $SourceClusterName
			VMId            = $Id
			RemoveResources = $true
			Force           = $true
			ErrorAction     = [System.Management.Automation.ActionPreference]::Stop
		}

		# remove cluster group for VM on source cluster
		Try {
			Remove-ClusterGroup @RemoveClusterGroup
		}
		Catch {
			Throw $_
		}
	}

	################################################
	# prepare VM for export
	################################################

	# if VM is running...
	If ($State -eq 'running') {
		# check parameters
		If ($Force) {
			$WarningAction = [System.Management.Automation.ActionPreference]::Continue
		}
		Else {
			$WarningAction = [System.Management.Automation.ActionPreference]::Inquire
		}

		# declare shut down for running VM
		Write-Warning -Message 'VM is currently running and will be shut down for offline migration' -WarningAction $WarningAction

		# define parameters for Stop-VM
		$StopVM = @{
			VM          = $VM
			Force       = $true
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# stop VM before export
		Try {
			Stop-VM @StopVM
		}
		Catch {
			Throw $_
		}
	}

	# define parameters for Set-VM
	$SetVM = @{
		VM                   = $VM
		AutomaticStartAction = [Microsoft.HyperV.PowerShell.StartAction]::Nothing
		ErrorAction          = [System.Management.Automation.ActionPreference]::Stop
	}

	# set VM automatic start action
	Try {
		Set-VM @SetVM
	}
	Catch {
		Throw $_
	}

	# declare state
	Write-Host "$Hostname - ...VM ready for offline migration"

	################################################
	# get source computer identity
	################################################

	# declare state
	Write-Host "$Hostname - adding source computer to Administrators group on destination computer..."

	# define parameters for Get-CimInstance
	$GetCimInstance = @{
		ComputerName = $SourceComputerName
		ClassName    = 'Win32_ComputerSystem'
		Property     = 'Name', 'Domain'
	}

	# get CIM instance of source computer system
	Try {
		$ComputerSystem = Get-CimInstance @GetCimInstance
	}
	Catch {
		Throw $_
	}

	# translate source computer UPN to NT account
	Try {
		$NTAccount = [System.Security.Principal.NTAccount]::new("$($ComputerSystem.Name)$@$($ComputerSystem.Domain)").Translate([System.Security.Principal.SecurityIdentifier]).Translate([System.Security.Principal.NTAccount]).Value
	}
	Catch {
		Throw $_
	}

	################################################
	# add source to Administrators group on target
	################################################

	# define parameters for Get-LocalGroupMember and Add-LocalGroupMember
	$LocalGroupMember = @{
		Group       = 'Administrators'
		Member      = $NTAccount
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# check target computer administrators group for source computer
	Try {
		$null = Invoke-Command @InvokeCommand -ScriptBlock {
			Get-LocalGroupMember @using:LocalGroupMember
		}
	}
	Catch {
		# create source computer list
		If ($null -eq $SourceComputerList) {
			$SourceComputerList = [System.Collections.Generic.List[string]]::new()
		}

		# if source computer not in list
		If ($NTAccount -notin $SourceComputerList) {
			# ... add source computer to list
			$SourceComputerList.Add($NTAccount)
		}

		# add source computer to target computer administrators group
		Try {
			$null = Invoke-Command @InvokeCommand -ScriptBlock {
				Add-LocalGroupMember @using:LocalGroupMember
			}
		}
		Catch {
			Throw $_
		}
	}

	# declare state
	Write-Host "$Hostname - ...source computer added"

	################################################
	# export VM
	################################################

	# declare state
	Write-Host "$Hostname - exporting VM..."

	# define parameters for Export-VM
	$ExportVM = @{
		VM          = $VM
		Path        = $SharePath
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# export VM
	Try {
		Export-VM @ExportVM
	}
	Catch {
		Throw $_
	}

	# declare state
	Write-Host "$Hostname - ...exported VM"

	################################################
	# define paths on target computer
	################################################

	# declare state
	Write-Host "$Hostname - importing VM..."

	# define file on target computer
	$VmcxPath = "$Name\Virtual Machines\$Id.vmcx"

	# create target path
	Try {
		$PathForImport = Invoke-Command @InvokeCommand -ScriptBlock {
			Join-Path -Path $using:Path -ChildPath $using:VmcxPath
		}
	}
	Catch {
		Throw $_
	}

	################################################
	# import VM
	################################################

	# define parameters for Import-VM
	$ImportVM = @{
		ComputerName = $ComputerName
		Path         = $PathForImport
		Register     = $true
		ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
	}

	# import VM on target computer
	Try {
		$NewVM = Import-VM @ImportVM
	}
	Catch {
		Throw $_
	}

	# declare state
	Write-Host "$Hostname - ...VM imported"

	################################################
	# add VM to target cluster
	################################################

	# if target computer is clustered...
	If ($ClusterName) {
		# declare state
		Write-Host "$Hostname - adding VM to cluster..."

		# define paramters for Add-ClusterVirtualMachineRole
		$AddClusterVirtualMachineRole = @{
			Cluster     = $ClusterName
			VMId        = $NewVM.Id
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# add VM to cluster by ID
		Try {
			$null = Add-ClusterVirtualMachineRole @AddClusterVirtualMachineRole
		}
		Catch {
			Throw $_
		}

		# declare state
		Write-Host "$Hostname - ...VM clustered"
	}

	################################################
	# restore VM start action on target computer
	################################################

	# if target computer is not clustered...
	If ([string]::IsNullOrEmpty($ClusterName)) {
		# declare state
		Write-Host "$Hostname - restoring VM start action configuration..."

		# define parameters for Set-VM
		$SetVM = @{
			VM                   = $NewVM
			AutomaticStartAction = $AutomaticStartAction
			ErrorAction          = [System.Management.Automation.ActionPreference]::Stop
		}

		# restore automatic start action
		Try {
			Set-VM @SetVM
		}
		Catch {
			Throw $_
		}

		# declare state
		Write-Host "$Hostname - ...VM configuration restored"
	}

	################################################
	# start VM on target computer
	################################################

	# if VM was running on source computer...
	If ($State -eq 'running' -or $Restart) {
		# declare state
		Write-Host "$Hostname - starting VM..."

		# define parameters for Start-VM
		$StartVM = @{
			VM          = $NewVM
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# start VM on target computer
		Try {
			Start-VM @StartVM
		}
		Catch {
			Throw $_
		}

		# declare state
		Write-Host "$Hostname - ...VM started"
	}

	################################################
	# get VM paths on source computer
	################################################

	# get VM hard disk drive
	$VHDPaths = Get-VMHardDiskDrive -VM $VM | Select-Object -ExpandProperty Path

	# define VM path list
	$VMPaths = [System.Collections.Generic.List[string]]::new()

	# define VM path properties
	$VMPathProperties = 'Path', 'ConfigurationLocation', 'CheckpointFileLocation', 'SmartPagingFilePath', 'SnapshotFileLocation'

	# add VM path properties to VM path list
	ForEach ($VMPathProperty in $VMPathProperties) {
		# get value of VM path property
		$VMPath = $VM | Select-Object -ExpandProperty $VMPathProperty
		# if VM path property not in VM path list and not null or empty...
		If ($VMPath -notin $VMPaths -and -not [string]::IsNullOrEmpty($VMPath)) {
			# ...add to list
			$VMPaths.Add($VMPath)
		}
	}

	################################################
	# remove VM on source computer
	################################################

	# declare state
	Write-Host "$Hostname - removing VM from source..."

	# define parameters for Remove-VM
	$RemoveVM = @{
		VM          = $VM
		Force       = $true
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# remove VM on local computer
	Try {
		Remove-VM @RemoveVM
	}
	Catch {
		Throw $_
	}

	# declare state
	Write-Host "$Hostname - ...VM removed from source"

	################################################
	# remove VM files and paths on source computer
	################################################

	# declare state
	Write-Host "$Hostname - removing VHDs from source..."

	# get hashtable for InvokeCommand splat
	Try {
		$SourceInvokeCommand = Get-PSSessionInvoke -ComputerName $SourceComputerName
	}
	Catch {
		Throw $_
	}

	# remove VM hard disk drive files
	ForEach ($VHDPath in $VHDPaths) {
		# define parameters for Remove-Item
		$RemoveItem = @{
			Path        = $VHDPath
			Force       = $true
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# remove VHD on source computer
		Try {
			Invoke-Command @SourceInvokeCommand -ScriptBlock {
				Remove-Item @using:RemoveItem
			}
		}
		Catch {
			Throw $_
		}

		# declare state
		Write-Host "$Hostname - ...removed: $VHDPath"
	}

	# declare state
	Write-Host "$Hostname - removing VM folders from source..."

	# remove VM path folders
	ForEach ($VMPath in $VMPaths) {
		# define parameters for Get-ChildItem
		$GetChildItem = @{
			Path        = $VMPath
			File        = $true
			Force       = $true
			Recurse     = $true
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# get any files in VM path
		Try {
			$ChildItems = Invoke-Command @SourceInvokeCommand -ScriptBlock {
				Get-ChildItem @using:GetChildItem
			}
		}
		Catch {
			Throw $_
		}

		# if child items found...
		If ($null -ne $ChildItems) {
			# ...warn and return
			Write-Warning -Message "Path is not empty: '$VMpath'"
			Return
		}

		# define parameters for Remove-Item
		$RemoveItem = @{
			Path        = $VMPath
			Force       = $true
			Recurse     = $true
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# remove VHD on source computer
		Try {
			Invoke-Command @SourceInvokeCommand -ScriptBlock {
				Remove-Item @using:RemoveItem
			}
		}
		Catch {
			Throw $_
		}

		# declare state
		Write-Host "$Hostname - ...removed: $VMPath"
	}
}

End {
	# if source computer list exists...
	If ($null -ne $SourceComputerList) {
		# define parameters for Remove-LocalGroupMember
		$LocalGroupMember = @{
			Group       = 'Administrators'
			Member      = $SourceComputerList
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# remove list of source computers from target computer administrators group
		Try {
			Invoke-Command @InvokeCommand -ScriptBlock {
				Remove-LocalGroupMember @using:LocalGroupMember
			}
		}
		Catch {
			Throw $_
		}
	}
}
