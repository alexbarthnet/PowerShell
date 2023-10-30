Param(
	[Parameter(Mandatory = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json,
	[Parameter(ValueFromPipeline = $True)]
	[string[]]$VMName,
	[string]$ComputerName,
	[string]$SnapshotName,
	[switch]$SkipClusterCheck,
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

	Function Get-ClusterStatus {
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
			Invoke-Command @InvokeCommand -ScriptBlock {
				$GetService = @{
					Name        = 'ClusSvc'
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				Get-Service @GetService | Select-Object -ExpandProperty 'Status'
			}
		}
		Catch {
			Throw $_
		}
	}

	Function Stop-ClusterOnComputerName {
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

		# stop cluster
		Try {
			Invoke-Command @InvokeCommand -ScriptBlock {
				$StopCluster = @{
					Force       = $true
					ErrorAction = [System.Management.Automation.ActionPreference]::Stop
				}
				Stop-Cluster @StopCluster
			}
		}
		Catch {
			Throw $_
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
			# define paramters for Get-ClusterNodeNames
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
}

Process {
	# import JSON data
	Try {
		$JsonData = Get-Content -Path $Json | ConvertFrom-Json
	}
	Catch {
		Write-Host "`nERROR: could not read configuration file: '$Json'"
		Throw $_
	}

	# create hashtable for VM objects found
	$VMObjects = [ordered]@{}

	# process each VMName for shutdown
	:VMName ForEach ($Name in $VMName) {
		# check if JSON contains VM
		If ($null -eq $JsonData.$Name) {
			Write-Host ("$Hostname - VM not found in Json: '$Name")
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

	# check VM for cluster
	:VMCluster ForEach ($Name in $VMObjects.Keys) {
		# get VM from hashtable
		$VM = $VMObjects[$Name]
		$ComputerName = $VM.ComputerName

		# if SkipClusterCheck set...
		If ($SkipClusterCheck) {
			# declare then move to next object
			Write-Host ("$Hostname,$ComputerName,$Name - SkipClusterCheck set, skipping cluster check")
			Continue VMCluster
		}

		# if VM is already off...
		If ($VM.State -eq 'Off') {
			# declare then move to next object
			Write-Host ("$Hostname,$ComputerName,$Name - VM is powered off, skipping cluster check")
			Continue VMCluster
		}

		# define parameters for Get-ClusterName
		$GetClusterName = @{
			ComputerName = $Name
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}
			
		# check if host is clustered
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - checking if VM is clustered...")
			$VMClusterName = Get-ClusterName @GetClusterName
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: checking if VM is clustered")
			Throw $_
		}
			
		# if VM clustername not defined...
		If ([string]::IsNullOrEmpty($VMClusterName)) {
			# declare then move to next object
			Write-Host ("$Hostname,$ComputerName,$Name - ...VM is not clustered")
			Continue VMCluster
		}
		Else {
			# declare and continue
			Write-Host ("$Hostname,$ComputerName,$Name - ...VM is in cluster: '$VMClusterName'")
		}

		# if VM is in a cluster...
		If ($null -ne $VM -and -not [string]::IsNullOrEmpty($VMClusterName)) {
			# define required parameters for Get-ClusterStatus
			$GetClusterStatus = @{
				ComputerName = $Name
			}

			# get cluster status
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - checking cluster service on VM...")
				$ClusterStatus = Get-ClusterStatus @GetClusterStatus
			}
			Catch {
				Throw $_
			}

			# declare cluster status
			Write-Host ("$Hostname,$ComputerName,$Name - ...cluster service is '$($ClusterStatus.Value)'")
		}

		# if VM is in a cluster and the cluster service is running...
		If ($null -ne $VM -and $ClusterStatus.Value -eq 'Running') {
			# define required parameters for Stop-ClusterOnComputerName
			$StopClusterOnComputerName = @{
				ComputerName = $Name
			}

			# stop cluster on VM
			Try {
				Write-Host ("$Hostname,$ComputerName,$Name - stopping cluster on VM...")
				Stop-ClusterOnComputerName @StopClusterOnComputerName
			}
			Catch {
				Throw $_
			}

			# declare complete
			Write-Host ("$Hostname,$ComputerName,$Name - ...cluster was stopped")
		}

	}

	# stop each VM found
	ForEach ($Name in $VMObjects.Keys) {
		# get VM from hashtable
		$VM = $VMObjects[$Name]
		$ComputerName = $VM.ComputerName

		# turn off the VM if running
		If ($VM.State -ne 'Off') {
			# define parameters for Stop-VM
			$StopVM = @{
				VM          = $VM
				Force       = $true
				Confirm     = $false
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
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
		Else {
			# report
			Write-Host ("$Hostname,$ComputerName,$Name - VM power off skipped, VM already powered off")
		}
	}

	# checkpoint each VM found
	ForEach ($Name in $VMObjects.Keys) {
		# get VM from hashtable
		$VM = $VMObjects[$Name]
		$ComputerName = $VM.ComputerName

		# define required parameters for Checkpoint-VM
		$CheckpointVM = @{
			VM          = $VM
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# define optional parameters for Checkpoint-VM
		If ($PSBoundParameters.ContainsKey('SnapshotName')) {
			$CheckpointVM['SnapshotName'] = $SnapshotName
		}

		# checkpoint VM
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - creating checkpoint for VM...")
			Checkpoint-VM @CheckpointVM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: creating checkpoint VM")
			Throw $_
		}

		# report
		Write-Host ("$Hostname,$ComputerName,$Name - ...created checkpoint for VM")
	}

	# restart each VM found
	ForEach ($Name in $VMObjects.Keys) {
		# get VM from hashtable
		$VM = $VMObjects[$Name]
		$ComputerName = $VM.ComputerName

		# define parameters for Start-VM
		$StartVM = @{
			VM          = $VM
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# start VM
		Try {
			Write-Host ("$Hostname,$ComputerName,$Name - starting VM on host...")
			Start-VM @StartVM
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName,$Name - ERROR: starting VM on host")
			Throw $_
		}

		# report
		Write-Host ("$Hostname,$ComputerName,$Name - ...started VM on host")
	}
}

End {
	# remove sessions
}