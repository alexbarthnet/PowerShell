Param(
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	[Parameter(ValueFromPipeline = $True)]
	[string[]]$VMName,
	[Parameter()]
	[string]$ComputerName,
	[Parameter()]
	[string]$VMHostPath,
	[Parameter(Mandatory = $True)]
	[string]$DestinationHost,
	[Parameter()]
	[string]$DestinationPath,
	[Parameter()]
	[switch]$Reverse,
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
		If ($null -ne $ClusterName) {
			Return $ClusterName
		}
		Else {
			Return [string]::Empty
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
}

Process {
	# import JSON data
	Try {
		$JsonData = [array](Get-Content -Path $Json -ErrorAction Stop | ConvertFrom-Json)
	}
	Catch {
		Write-Warning -Message "could not read configuration file: '$Json'"
		Throw $_
	}

	# create hashtable for VM objects found
	$VMObjects = [ordered]@{}

	# process each VMName for shutdown
	:VMName ForEach ($Name in $VMName) {
		# check if JSON contains VM
		If ($null -eq $JsonData.$Name) {
			Write-Host ("$Hostname - VM not found in Json: '$Name'")
			Continue VMName
		}

		# override ComputerName with bound parameters if provided
		If ($PSBoundParameters['ComputerName']) {
			$ComputerName = $ComputerName
			Write-Warning ("overriding ComputerName from JSON: '$($JsonData.$Name.ComputerName)'")
		}
		Else {
			$ComputerName = $JsonData.$Name.ComputerName
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

			# add VM to state hashtable
			$VMObjects[$Name] = $VM
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
		If ($null -eq $VM) {
			# declare and continue
			Write-Host ("$Hostname,$ComputerName,$Name - VM not found")
			Continue VMName
		}
	}

	# move each VM found
	ForEach ($Name in $VMObjects.Keys) {
		# get VM from hashtable
		$VM = $VMObjects[$Name]

		# set host information
		If ($Reverse) {
			$ComputerNameForMove = $DestinationHost
			$DestinationHostForMove = $VM.ComputerName
			$DestinationStoragePath = $VM.Path
		}
		Else {
			$ComputerNameForMove = $VM.ComputerName
			$DestinationHostForMove = $DestinationHost
			$DestinationStoragePath = $DestinationPath
		}

		# check if source is clustered
		Try {
			$SourceClusterName = Get-ClusterName -ComputerName $ComputerNameForMove
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not check source computer for cluster")
			Throw $_
		}

		# check if destination is clustered
		Try {
			$DestinationClusterName = Get-ClusterName -ComputerName $DestinationHostForMove
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not check destination computer for cluster")
			Throw $_
		}

		# if source and destination are clustered in the same cluster...
		If (![string]::IsNullOrEmpty($SourceClusterName) -and ![string]::IsNullOrEmpty($DestinationClusterName) -and $SourceClusterName -eq $DestinationClusterName) {
			Write-Host ("$Hostname,$ComputerName,$Name - WARNING: moving VMs within the same cluster is not yet implemented")
			# move cluster group to destination
			Continue
		}

		# if source is clustered...
		If (![string]::IsNullOrEmpty($SourceClusterName)) {
			# de-cluster VM
		}

		# define required parameters for Checkpoint-VM
		$MoveVM = @{
			VM                     = $VM
			ComputerName           = $ComputerNameForMove
			DestinationHost        = $DestinationHostForMove
			DestinationStoragePath = $DestinationStoragePath
			IncludeStorage         = $true
			ErrorAction            = [System.Management.Automation.ActionPreference]::Stop
		}

		# checkpoint VM
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - moving VM...")
			Move-VM @MoveVM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: could not move VM")
			Throw $_
		}

		# report
		Write-Host ("$Hostname,$ComputerName,$Name - ...moved VM")

		# if destination is clustered...
		If (![string]::IsNullOrEmpty($DestinationClusterName)) {
			# cluster VM
		}
	}

	# create VM list from parameters
	$vm_list = @()
	If ($VmHost -and $VmName) {
		$vm_list += (Get-Content -Path $Json -ErrorAction Stop | ConvertFrom-Json) | Where-Object { $_.VMHost -eq $VMHost -and $_.VMName -in $VMName }
	}
	ElseIf ($VmHost) {
		$vm_list += (Get-Content -Path $Json -ErrorAction Stop | ConvertFrom-Json) | Where-Object { $_.VMHost -eq $VMHost -and $_.VMName }
	}
	ElseIf ($VmName) {
		$vm_list += (Get-Content -Path $Json -ErrorAction Stop | ConvertFrom-Json) | Where-Object { $_.VMHost -and $_.VMName -in $VMName }
	}
	Else {
		$vm_list += (Get-Content -Path $Json -ErrorAction Stop | ConvertFrom-Json) | Where-Object { $_.VMHost -and $_.VMName }
	}

	# check VM list
	If ($vm_list.Count -eq 0) {
		Write-Host ("$Hostname - VM(s) not found in Json, exiting!")
		Return
	}

	Write-Host ("$Hostname - starting move for " + $vm_list.count + ' VMs')
	ForEach ($VmParams in $vm_list) {
		# define required objects from CSV
		$vm_name = $VmParams.Name
		Write-Host ("$Hostname - validating move for VM: " + $vm_name)

		# clear variables
		$vm_host_source = $null
		$vm_host_target = $null
		$vm_path_target = $null

		# set host information
		If ($Reverse) {
			$vm_host_source = $DestinationHost
			$vm_host_target = $VmParams.Host
		}
		Else {
			$vm_host_source = $VmParams.Host
			$vm_host_target = $DestinationHost
		}

		# set path information
		If ($Reverse) {
			$vm_path_target = $VmParams.Path
		}
		Else {
			$vm_path_target = $DestinationPath
		}

		# set destination path
		If (!($vm_path_target)) {
			$vm_path_target = (Get-VMHost -ComputerName $vm_host_target).VirtualMachinePath
			Write-Host ("$Hostname - ...using default VM path: $vm_path_target")
		}

		# create the VM specific path
		$vm_path_vm = Invoke-Command -ComputerName $vm_host_target -ScriptBlock { Join-Path -Path $using:vm_path_target -ChildPath $using:vm_name }

		# check if dest is clustered
		$vm_host_target_cl = $null
		$vm_host_target_cl = Get-Service -ComputerName $vm_host_target | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -eq 'Automatic' -and $_.Status -eq 'Running' }
		If ($vm_host_target_cl) {
			# check for VM on cluster
			$vm_host_target_cluster = Invoke-Command -ComputerName $vm_host_target { (Get-Cluster).Name }
			$vm_to_cl = Get-ClusterGroup -Cluster $vm_host_target_cluster | Where-Object { $_.Name -eq $vm_name -and $_.GroupType -eq 'VirtualMachine' }
			If ($vm_to_cl) {
				Write-Host ("$Hostname - ...cluster resource for VM found on destination cluster: $vm_host_target_cluster")
				Write-Host ("$Hostname - ...skipping!")
				Return
			}
		}

		# check for VM on destination host
		$vm_on_target = Get-VM -ComputerName $vm_host_target | Where-Object { $_.Name -eq $vm_name }
		If ($vm_on_target) {
			Write-Host ("$Hostname - ....VM found on destination: $vm_host_target")
			Write-Host ("$Hostname - ...skipping!")
			Return
		}

		# check if source is clustered
		$vm_host_cl = $null
		$vm_host_cl = Get-Service -ComputerName $vm_host_source | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -eq 'Automatic' -and $_.Status -eq 'Running' }
		If ($vm_host_cl) {
			# check for VM on cluster
			$vm_host_cluster = Invoke-Command -ComputerName $vm_host_source { (Get-Cluster).Name }
			$vm_on_cluster = Get-ClusterGroup -Cluster $vm_host_cluster | Where-Object { $_.Name -eq $vm_name -and $_.GroupType -eq 'VirtualMachine' }
			If ($vm_on_cluster) {
				Write-Host ("$Hostname - ...cluster resource for VM found on source cluster: $vm_host_cluster")
				# verify the resource group is on the local node
				$vm_node = $vm_on_cluster.OwnerNode.NodeName
				If ($vm_host -ne $vm_node) {
					Write-Host ("$Hostname - ...cluster resource for VM found on different host, changing host to: $vm_node")
					$vm_host = $vm_node
				}
			}
		}

		# check for VM on source host
		$vm_on_host = $null
		$vm_on_host = Get-VM -ComputerName $vm_host_source | Where-Object { $_.Name -eq $vm_name }
		If ($null -eq $vm_on_host) {
			Write-Host ("$Hostname - ....VM not found on host: $vm_host_source")
			Write-Host ("$Hostname - ...skipping!")
			Return
		}

		# remove VM from source cluster
		If ($vm_on_cluster) {
			# remove resource group from the cluster
			Write-Host ("$Hostname - ...removing cluster resource on source: " + $vm_host_cluster)
			$vm_on_cluster | Remove-ClusterGroup -RemoveResources -Force
		}

		# move VM
		If ($vm_host_target_cl) {
			Write-Host ("$Hostname - moving VM ...")
			Write-Host ("$Hostname - ...to cluster member: " + $vm_host_target)
		}
		Else {
			Write-Host ("$Hostname - moving VM ...")
			Write-Host ("$Hostname - ...to Hyper-V server: " + $vm_host_target)
		}
		try {
			Move-VM -ComputerName $vm_host -Name $vm_name -DestinationHost $vm_host_target -IncludeStorage -DestinationStoragePath $vm_path_vm
			Write-Host ("$Hostname - ...move complete!")
		}
		catch {
			Write-Host ("$Hostname - ...move failed!")
		}

		# add VM to cluster
		If ($vm_host_target_cl) {
			Write-Host ("$Hostname - ...adding to cluster: " + $vm_host_target_cluster)
			Add-ClusterVirtualMachineRole -Cluster $vm_host_target_cluster -VMName $vm_name | Out-Null
		}
	}
}
