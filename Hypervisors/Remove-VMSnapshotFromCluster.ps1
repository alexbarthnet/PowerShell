#Requires -Modules "Hyper-V","FailoverClusters","Deduplication"

[CmdletBinding(DefaultParameterSetName = 'Name')]
param (
	# VM object(s)
	[Parameter(Position = 0, ParameterSetName = 'VM', Mandatory = $true, ValueFromPipeline = $true)]
	[Microsoft.HyperV.PowerShell.VirtualMachine]$VM,
	# VM name(s)
	[Parameter(Position = 0, ParameterSetName = 'Name', Mandatory = $true, ValueFromPipeline = $true)]
	[string]$Name,
	# computer name of source computer
	[Parameter(Position = 1, ParameterSetName = 'Name')]
	[string]$ComputerName = [System.Environment]::MachineName.ToLowerInvariant()
)

begin {
	function Test-PSSessionByName {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName
		)

		# if computername matches hostname...
		if ($ComputerName -eq [System.Environment]::MachineName.ToLowerInvariant()) {
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
				$script:PSSessions[$ComputerName] = New-PSSession -ComputerName $ComputerName -Name $ComputerName -Authentication Kerberos
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
		if ($ComputerName -eq [System.Environment]::MachineName.ToLowerInvariant()) {
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
		if ($ClusterName) {
			return $ClusterName.ToLowerInvariant()
		}
		else {
			return $null
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

	function Get-ClusterSharedVolumePathsAndNodes {
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
			$ClusterSharedVolumePathsAndNodes = Invoke-Command @InvokeCommand -ScriptBlock {
				# retrieve cluster shared volumes
				$ClusterSharedVolumes = Get-ClusterSharedVolume

				# define hashtable
				$ClusterSharedVolumePathsAndNodes = @{}

				# loop through cluster shared volumes
				foreach ($ClusterSharedVolume in $ClusterSharedVolumes) {
					$ClusterSharedVolumePathsAndNodes.Add($ClusterSharedVolume.SharedVolumeInfo.FriendlyVolumeName, $ClusterSharedVolume.OwnerNode.Name)
				}

				# return hashtable
				return $ClusterSharedVolumePathsAndNodes
			}
		}
		catch {
			throw $_
		}

		# return the cluster shared volume paths and nodes
		if ($ClusterSharedVolumePathsAndNodes) {
			return $ClusterSharedVolumePathsAndNodes
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
				Write-Host ("$ComputerName,$Name - ERROR: retrieving cluster node names from computer name")
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
			Write-Host ("$ComputerName,$Name - checking for VM on host: '$ComputerNameForGetVM'")

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
				Write-Host ("$ComputerName,$Name - WARNING: could not connect to host: '$ComputerNameForGetVM'")
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
				Write-Host ("$ComputerName,$Name - ERROR: retrieving VMs from host")
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
				Write-Host ("$ComputerName,$Name - ....VM not found on provided host")
				return $null
			}
			# one VM found
			1 {
				# declare then return VM
				Write-Host ("$ComputerName,$Name - ....VM found via provided host")
				return $VMList[0]
			}
			# multiple VMs found
			Default {
				# declare and report then return null
				Write-Host ("$ComputerName,$Name - ERROR: multiple VMs found with name")
				foreach ($VMObject in $VMList) {
					Write-Host ("$ComputerName,$Name - ...found VM on '$($VMObject.ComputerName)' with Id: '$($VMObject.Id)'")
				}
				return 'multiple'
			}
		}
	}

	function Get-DedupJobCountForVolume {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[Parameter(Mandatory = $true)]
			[string]$Volume
		)

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# update argument list with volume and states to ignore
		$InvokeCommand['ArgumentList']['Volume'] = $Volume
		$InvokeCommand['ArgumentList']['States'] = @('Canceled', 'Completed')

		# get count of deduplication jobs
		try {
			$DedupJobCount = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)

				# import objects from argument list
				foreach ($Argument in $ArgumentList.Keys) {
					New-Variable -Name $Argument -Value $ArgumentList[$Argument] -Force
				}

				# retrieve deduplication jobs to stop before stopping jobs
				try {
					$DedupJobs = ([array](Get-DedupJob)).Where({ $_.Volume -eq $Volume -and $_.State -notin $States })
				}
				catch {
					throw $_
				}

				# return count of deduplication jobs
				return $DedupJobs.Count
			}
		}
		catch {
			throw $_
		}

		# return count of deduplication jobs
		return $DedupJobCount
	}

	function Stop-DedupJobForVMOnVolume {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[Parameter(Mandatory = $true)]
			[string]$Name,
			[Parameter(Mandatory = $true)]
			[string]$Volume
		)

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# update argument list with computer name, volume, and states to ignore
		$InvokeCommand['ArgumentList']['ComputerName'] = $ComputerName
		$InvokeCommand['ArgumentList']['Name'] = $Name
		$InvokeCommand['ArgumentList']['Volume'] = $Volume
		$InvokeCommand['ArgumentList']['States'] = @('Canceled', 'Completed')

		# stop deduplication jobs
		try {
			Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)

				# import objects from argument list
				foreach ($Argument in $ArgumentList.Keys) {
					New-Variable -Name $Argument -Value $ArgumentList[$Argument] -Force
				}

				# report state
				Write-Host ("$ComputerName,$Name - retrieving deduplication jobs for '$Volume' volume not in '$($States -join "' or '")' state...")

				# retrieve deduplication jobs to stop before stopping jobs
				try {
					$DedupJobs = ([array](Get-DedupJob)).Where({ $_.Volume -eq $Volume -and $_.State -notin $States })
				}
				catch {
					throw $_
				}

				# if no deduplication jobs found...
				if ($DedupJobs.Count -eq 0) {
					# report job count and return
					Write-Host ("$ComputerName, $Name - ...found '$($DedupJobs.Count)' job(s) to stop")
					return
				}

				# report state
				Write-Host ("$ComputerName,$Name - ...found '$($DedupJobs.Count)' job(s) to stop; stopping job(s)...")

				# loop through deduplication jobs to stop
				foreach ($DedupJob in $DedupJobs) {
					# report state
					Write-Host ("$ComputerName,$Name - ...stopping '$($DedupJob.Id)' job: $($DedupJob.ScheduleType) $($DedupJob.Type)")

					# stop deduplication job
					try {
						Stop-DedupJob -Id $DedupJob.Id
					}
					catch {
						throw $_
					}
				}

				# define values for while loop and reporting
				$While = @{
					Active     = $true # boolean of while loop state
					Action     = 'deduplication jobs to stop' # action being waited for
					Warning    = 'check deduplication jobs on hypervisor' # warning text when action not completed within allocated time
					Expression = '([array](Get-DedupJob)).Where({ $_.Volume -eq $Volume -and $_.State -notin $States }).Count -gt 0' # expression that evaluates true while action is in progress and false when action is complete
					Multiplier = [int32]0 # counter for current loop
					WaitTime   = [int32]0 # counter for total seconds in while loop
					Seconds    = [int32]5 # sleep time for each pass of while loop; multiplied by loop counter to gradually add time to each loop
					Limit      = [int32]8 # maximum passes to complete; default limit of 8 with 5 seconds allows 180 seconds for the action to complete
				}

				# declare state
				Write-Host ("$ComputerName,$Name - ...waiting for $($While.Action)...")

				# evaluate expression before while loop
				$While.Active = Invoke-Expression -Command $While.Expression

				# while expression is not resolved to false or limit not reached...
				while ($While.Active -and $While.Multiplier -lt $While.Limit) {
					# increment multiplier
					$While.Multiplier++

					# record total time
					$While.WaitTime += ($While.Seconds * $While.Multiplier)

					# declare updated wait time then sleep
					Write-Host ("$ComputerName,$Name - ...waiting an additional '$($While.Seconds * $While.Multiplier)' seconds")
					Start-Sleep -Seconds ($While.Seconds * $While.Multiplier)

					# re-evaluate expression
					$While.Active = Invoke-Expression -Command $While.Expression
				}

				# if expression last resolved to true...
				if ($While.Active) {
					# ...declare wait time and return
					Write-Host ("$ComputerName,$Name - WARNING: waited '$($While.WaitTime)' for $($While.Action) without success")
					Write-Host ("$ComputerName,$Name - ...$($While.Warning)")
				}
				# if expression last resolved to false...
				else {
					# ...declare wait time and continue
					Write-Host ("$ComputerName,$Name - ...waited '$($While.WaitTime)' seconds for $($While.Action)")
				}
			}
		}
		catch {
			throw $_
		}
	}

	function Test-DedupVolume {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[Parameter(Mandatory = $true)]
			[string]$Volume
		)

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['Volume'] = $Volume

		# test for cluster
		try {
			$DedupVolumeEnabled = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)

				# retrieve dedupe volume
				try {
					$DedupVolume = Get-DedupVolume -Volume $ArgumentList['Volume']
				}
				catch {
					throw $_
				}

				# return value of enabled property
				return $DedupVolume.Enabled
			}
		}
		catch {
			throw $_
		}

		# return the dedup state for the volume
		return $DedupVolumeEnabled
	}

	function Update-DedupVolume {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[Parameter(Mandatory = $true)]
			[string]$Volume,
			[Parameter(Mandatory = $true)][ValidateSet('Disable', 'Enable')]
			[string]$Action
		)

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['Volume'] = $Volume
		$InvokeCommand['ArgumentList']['Action'] = $Action

		# test for cluster
		try {
			$DedupVolumeEnabled = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)

				# update dedupe volume
				switch ($ArgumentList['Action']) {
					'Disable' {
						# disable dedupe on the volume
						$DedupVolume = Disable-DedupVolume -Volume $ArgumentList['Volume']

						# return value of enabled property
						return $DedupVolume.Enabled
					}
					'Enable' {
						# enable dedupe on the volume
						$DedupVolume = Enable-DedupVolume -Volume $ArgumentList['Volume']

						# return value of enabled property
						return $DedupVolume.Enabled
					}
				}
			}
		}
		catch {
			throw $_
		}

		# return the dedup state for the volume
		return $DedupVolumeEnabled
	}
}

process {
	################################################
	# check for VM on source computer
	################################################

	# if VM provided...
	if ($PSBoundParameters.ContainsKey('VM')) {
		# retrieve name and computer name from VM
		$Name = $VM.Name.ToLowerInvariant()
		$ComputerName = $VM.ComputerName.ToLowerInvariant()
	}

	# define parameters for Get-ClusterName
	$GetClusterName = @{
		ComputerName = $ComputerName
		ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
	}

	# check if host is clustered
	try {
		Write-Host ("$ComputerName,$Name - checking if host is clustered...")
		$ClusterName = Get-ClusterName @GetClusterName
	}
	catch {
		Write-Host ("$ComputerName,$Name - ERROR: checking if host is clustered")
		throw $_
	}

	# if clustername not defined...
	if ([string]::IsNullOrEmpty($ClusterName)) {
		# declare and return
		Write-Host ("$ComputerName,$Name - ...host is not clustered; use Remove-VMSnapshot to remove any VM snapshots")
		return
	}

	# retrieve cluster shared volume paths and nodes
	try {
		$ClusterSharedVolumePathsAndNodes = Get-ClusterSharedVolumePathsAndNodes -ComputerName $ComputerName
	}
	catch {
		Write-Host ("$ComputerName,$Name - ERROR: retrieving cluster shared volume paths and nodes")
		throw $_
	}

	# if count of CSV paths and nodes in hashtable does not match...
	if ($ClusterSharedVolumePathsAndNodes.Keys.Count -ne $ClusterSharedVolumePathsAndNodes.Values.Count) {
		# define warning text
		$WarningText1 = 'WARNING: found one or more CSVs without an owner or a CSV without a CSV object without a path; perform one of the following tasks to address this issue'
		$WarningText2 = '1. update ownership of CSV to an active node'
		$WarningText3 = '2. review CSV paths to validate all volumes are correctly configured'

		# declare warning and return
		Write-Host ("$ComputerName,$Name - $WarningText1`r`n$WarningText2`r`n$WarningText3") -ForegroundColor Yellow
		return
	}

	# if name provided...
	if ($PSBoundParameters.ContainsKey('Name')) {
		# define parameters for Get-VMFromComputerName
		$GetVMFromComputerName = @{
			Name         = $Name
			ComputerName = $ComputerName
			ClusterName  = $ClusterName
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
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
			Write-Host ("$ComputerName,$Name - ERROR: multiple VMs found with provided name")
			return
		}

		# if VM is on a different computer...
		if ($ComputerName -ne $VM.ComputerName) {
			# declare and begin
			Write-Host ("$ComputerName,$Name - VM found on another cluster node...")

			# update computer name
			try {
				$ComputerName = $VM.ComputerName.ToLower()
			}
			catch {
				throw $_
			}

			# declare and continue
			Write-Host ("$ComputerName,$Name - ....updated computer name")
		}
	}

	# report state
	Write-Host ("$ComputerName,$Name - checking for VM snapshots...")

	# if no snapshots found...
	if (!$VM.ParentSnapshotId) {
		# report and return
		Write-Host ("$ComputerName,$Name - ...no VM snapshots found")
		return
	}

	# get parent snapshots
	try {
		$VMSnapshots = Get-VMSnapshot -VM $VM
	}
	catch {
		Write-Host ("$ComputerName,$Name - ERROR: could not retrieve VM snapshots")
		throw $_
	}

	# if no snapshots found...
	if ($null -eq $VMSnapshots) {
		# report and return
		Write-Host ("$ComputerName,$Name - ...no VM snapshots found")
		return
	}

	# report state
	Write-Host ("$ComputerName,$Name - ...found '$($VMSnapshots.Count)' VM snapshots")

	# retrieve VHDs attached to VM
	try {
		Write-Host ("$ComputerName,$Name - retrieving VHDs attached to VM")
		$VHDs = Get-VMHardDiskDrive -VM $VM
	}
	catch {
		Write-Host ("$ComputerName,$Name - ERROR: could not retrieve VHDs from VM")
		throw $_
	}

	# define list for VHDs
	$VHDPaths = [System.Collections.Generic.List[string]]::new()

	# loop through VHDs attached to VM
	foreach ($VHD in $VHDs) {
		# if VHD is shared...
		if ($VHD.SupportPersistentReservations) {
			# declare warning
			Write-Host ("$ComputerName,$Name - WARNING: found shared VHD: '$($VHD.Path)'")
		}
		else {
			# add VHD path to list
			Write-Host ("$ComputerName,$Name - ...found VHD to check: '$($VHD.Path)'")
			$VHDPaths.Add($VHD.Path)
		}
	}

	# report state
	Write-Host ("$ComputerName,$Name - checking VHDs attached to VM...")

	# define list for CSV paths and nodes
	$CSVPathsWithVHDs = [System.Collections.Generic.List[string]]::new()
	$CSVNodesWithVHDs = [System.Collections.Generic.List[string]]::new()

	# loop through VHD paths
	foreach ($VHDPath in $VHDPaths) {
		# loop through CSV hashtable
		foreach ($CSVPath in $ClusterSharedVolumePathsAndNodes.Keys) {
			# if VHD path starts with CSV path...
			if ($VHDPath.StartsWith($CSVPath, [System.StringComparison]::InvariantCultureIgnoreCase)) {
				# add CSV path to list
				$CSVPathsWithVHDs.Add($CSVPath)
				# add CSV node to list
				$CSVNodesWithVHDs.Add($ClusterSharedVolumePathsAndNodes[$CSVPath])
			}
		}
	}

	# if count of VHD paths is greater than count of individual volumes
	if ($VHDPaths.Count -gt $CSVPathsWithVHDs.Count) {
		# define warning text
		$WarningText1 = 'WARNING: found one or more VHDs not on CSVs; perform one of the following tasks to address this issue'
		$WarningText2 = '1. migrate VHDs to a common CSV'
		$WarningText3 = '2. manually remove VM snapshots if all VHDs are on unclustered volumes'

		# declare warning and return
		Write-Host ("$ComputerName,$Name - $WarningText1`r`n$WarningText2`r`n$WarningText3") -ForegroundColor Yellow
		return
	}

	# define unique nodes and volumes as string array
	[string[]]$Nodes = $CSVNodesWithVHDs | Select-Object -Unique

	# if VHDs on CSVs owned by different cluster nodes...
	if ($Nodes.Count -gt 1) {
		# define warning text
		$WarningText1 = 'WARNING: found VHDs on CSVs owned by different cluster nodes; perform one of the following tasks to address this issue'
		$WarningText2 = '1. migrate VHDs to a common CSV'
		$WarningText3 = '2. move one or more CSV to the same cluster node'

		# declare warning
		Write-Host ("$ComputerName,$Name - $WarningText1`r`n$WarningText2`r`n$WarningText3") -ForegroundColor Yellow
		return
	}
	else {
		# define single node
		$Node = $Nodes | Select-Object -First 1
	}

	# report state
	Write-Host ("$ComputerName,$Name - ...found all VHDs on volume owned by '$Node' host; checking VM...")

	# if node for CSV is not current computer...
	if ($Node -ne $ComputerName) {
		# report state
		Write-Host ("$ComputerName,$Name - ...found VM not owned same host; moving VM...")

		# define parameters
		$MoveClusterVirtualMachineRole = @{
			VMId          = $VM.Id
			Node          = $Node
			ClusterName   = $ClusterName
			MigrationType = [Microsoft.FailoverClusters.NativeHelp.NativeGroupHelp+VmMigrationType]::Live
			ErrorAction   = [System.Management.Automation.ActionPreference]::Stop
		}

		# move virtual machine
		try {
			Move-ClusterVirtualMachineRole @MoveClusterVirtualMachineRole
		}
		catch {
			Write-Host ("$ComputerName,$Name - ERROR: could not move VM to '$Node' node")
			throw $_
		}

		# report state
		Write-Host ("$ComputerName,$Name - ...moved VM to host: '$Node'")

		# define parameters
		$GetVMAfterMove = @{
			Id           = $VM.Id
			ComputerName = $Node
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# refresh VM object after move
		try {
			$VM = Get-VM @GetVMAfterMove
		}
		catch {
			Write-Host ("$ComputerName,$Name - ERROR: could not retrieve VM on '$Node' node")
			throw $_
		}

		# update computer name
		try {
			$ComputerName = $VM.ComputerName.ToLower()
		}
		catch {
			Write-Host ("$ComputerName,$Name - ERROR: could not retrieve computer name from VM retrieved after move")
			throw $_
		}

		# report state
		Write-Host ("$ComputerName,$Name - ....updated computer name.")
	}
	else {
		# report state
		Write-Host ("$ComputerName,$Name - ...found VM owned same host")
	}

	# define unique volumes as string array
	[string[]]$Volumes = $CSVPathsWithVHDs | Select-Object -Unique

	# report state
	Write-Host ("$ComputerName,$Name - checking '$($Volumes.Count)' volumes for Windows Deduplication...")

	# define list for volumes with deduplication
	$VolumesWithDedup = [System.Collections.Generic.SortedSet[string]]::new()

	# loop through volumes
	:NextVolume foreach ($Volume in $Volumes) {
		# test if volume has deduplication enabled before remove
		try {
			$DedupEnabledBeforeRemove = Test-DedupVolume -ComputerName $ComputerName -Volume $Volume
		}
		catch {
			throw $_
		}

		# if deduplication not enabled on volume before remove...
		if (!$DedupEnabledBeforeRemove) {
			# report state
			Write-Host ("$ComputerName,$Name - ...found Windows Deduplication not enabled on '$Volume' volume")
			continue NextVolume
		}

		# add volume to sorted set
		$null = $VolumesWithDedup.Add($Volume)

		# report state
		Write-Host ("$ComputerName,$Name - ...disabling Windows Deduplication on '$Volume' volume...")

		# update volume and disable dedupe
		try {
			$DedupEnabled = Update-DedupVolume -ComputerName $ComputerName -Volume $Volume -Action 'Disable'
		}
		catch {
			throw $_
		}

		# if dedup enabled after disabling...
		if ($DedupEnabled) {
			# warn and return
			Write-Host ("$ComputerName,$Name - WARNING: found Windows dedupe enabled on '$Volume' volume after disabling")
			return
		}

		# report state
		Write-Host ("$ComputerName,$Name - ...disabled Windows Deduplication on '$Volume' volume; checking for jobs...")

		# retrieve dedup job count
		try {
			$DedupJobCount = Get-DedupJobCountForVolume -ComputerName $ComputerName -Volume $Volume
		}
		catch {
			throw $_
		}

		# report state
		Write-Host ("$ComputerName,$Name - ...found '$DedupJobCount' jobs for '$Volume' volume")

		# if no dedup jobs found...
		if ($DedupJobCount -gt 0) {
			# update volume and disable dedupe
			try {
				Stop-DedupJobForVMOnVolume -ComputerName $ComputerName -Volume $Volume -Name $Name
			}
			catch {
				throw $_
			}

			# retrieve dedup job count after stop
			try {
				$DedupJobCountAfterStop = Get-DedupJobCountForVolume -ComputerName $ComputerName -Volume $Volume
			}
			catch {
				throw $_
			}

			# if dedup jobs found after stop...
			if ($DedupJobCountAfterStop -gt 0) {
				Write-Host ("$ComputerName,$Name - WARNING: found '$DedupJobCountAfterStop' dedupe job(s) after stopping and waiting for jobs to end")
				return
			}
		}
	}

	# report state
	Write-Host ("$ComputerName,$Name - removing VM snapshots...")

	# get parent snapshots
	try {
		$VMSnapshots = Get-VMSnapshot -VM $VM
	}
	catch {
		Write-Host ("$ComputerName,$Name - ERROR: could not retrieve VM snapshots")
		throw $_
	}

	# process snapshots
	foreach ($VMSnapshot in $VMSnapshots) {
		# remove snapshot and child snapshots
		try {
			Remove-VMSnapshot -VMSnapshot $VMSnapshot -IncludeAllChildSnapshots
		}
		catch {
			Write-Host ("$ComputerName,$Name - ERROR: could not remove VM snapshots")
			throw $_
		}
	}

	# define values for while loop and reporting
	$While = @{
		Active     = $true # boolean of while loop state
		Action     = 'disks to merge after snapshot removal' # action being waited for
		Warning    = 'check hypervisors before continuing' # warning text when action not completed within allocated time
		Expression = '(Get-VM -ComputerName $ComputerName -Id $VM.Id).SecondaryOperationalStatus' # expression that evaluates true while action is in progress and false when action is complete
		Multiplier = [int32]0 # counter for current loop
		WaitTime   = [int32]0 # counter for total seconds in while loop
		Seconds    = [int32]5 # sleep time for each pass of while loop; multiplied by loop counter to gradually add time to each loop
		Limit      = [int32]8 # maximum passes to complete; default limit of 8 with 5 seconds allows 180 seconds for the action to complete
	}

	# declare state
	Write-Host ("$ComputerName,$Name - ...waiting for $($While.Action)...")

	# evaluate expression before while loop
	$While.Active = Invoke-Expression -Command $While.Expression

	# while expression is not resolved to false or limit not reached...
	while ($While.Active -and $While.Multiplier -lt $While.Limit) {
		# increment multiplier
		$While.Multiplier++

		# record total time
		$While.WaitTime += ($While.Seconds * $While.Multiplier)

		# declare updated wait time then sleep
		Write-Host ("$ComputerName,$Name - ...waiting an additional '$($While.Seconds * $While.Multiplier)' seconds")
		Start-Sleep -Seconds ($While.Seconds * $While.Multiplier)

		# re-evaluate expression
		$While.Active = Invoke-Expression -Command $While.Expression
	}

	# if expression last resolved to true...
	if ($While.Active) {
		# ...declare wait time and return
		Write-Host ("$ComputerName,$Name - WARNING: waited '$($While.WaitTime)' for $($While.Action) without success")
		Write-Host ("$ComputerName,$Name - ...$($While.Warning)")
	}
	# if expression last resolved to false...
	else {
		# ...declare wait time and continue
		Write-Host ("$ComputerName,$Name - ...waited '$($While.WaitTime)' seconds for $($While.Action)")
	}


	# sleep an additional second to ensure VM hard drives update after snapshot removal
	Start-Sleep -Seconds 1

	# if volume has deduplication enabled before remove...
	if ($DedupEnabledBeforeRemove) {
		# report state
		Write-Host ("$ComputerName,$Name - re-enabling Windows Deduplication on configured volumes...")

		# loop through volumes with deduplication enabled
		foreach ($Volume in $VolumesWithDedup) {
			# report state
			Write-Host ("$ComputerName,$Name - ...enabling Windows Deduplication on '$Volume' volume...")

			# update volume and disable dedupe
			try {
				$DedupEnabled = Update-DedupVolume -ComputerName $ComputerName -Volume $Volume -Action 'Enable'
			}
			catch {
				throw $_
			}

			# if dedup enabled...
			if (!$DedupEnabled) {
				# report state
				Write-Host ("$ComputerName,$Name - WARNING: found Windows dedupe disabled on '$Volume' volume after enabling")
				return
			}

			# report state
			Write-Host ("$ComputerName,$Name - ...enabled Windows Deduplication on '$Volume' volume")
		}
	}
}