#Requires -Modules "Hyper-V","FailoverClusters"

[CmdletBinding(DefaultParameterSetName = 'Name')]
param (
	# string for filtering name of VM switch on target computer
	[Parameter(DontShow)]
	[string]$SwitchNameHint = 'compute',
	# hostname of local computer
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant(),
	# VM name(s)
	[Parameter(ParameterSetName = 'Name', Mandatory = $true, ValueFromPipeline = $true)]
	[string]$Name,
	# VM object(s)
	[Parameter(ParameterSetName = 'VM', Mandatory = $true, ValueFromPipeline = $true)]
	[Microsoft.HyperV.PowerShell.VirtualMachine]$VM,
	# computer name of source computer
	[string]$ComputerName = $Hostname,
	# computer name of target computer
	[Parameter(Mandatory = $true)]
	[string]$DestinationHost,
	# name of VM switch on target computer
	[string]$SwitchName,
	# path on target computer
	[string]$DestinationStoragePath,
	# path for virtual machine
	[string]$VirtualMachinePath,
	# array of hashtables for VHDs
	[object[]]$VHDs = @(),
	# switch to skip warning about VM shut down for quick migration
	[switch]$Force,
	# switch to remove planned VMs on destination before move
	[switch]$RemovePlannedVMs,
	# switch to skip VM version update before move
	[switch]$SkipVersionUpdate,
	# switch to skip key protector update after move
	[switch]$SkipKeyProtectorUpdate,
	# switch to skip CSV storage check
	[switch]$SkipClusteredStorageCheck
)

begin {
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

	function Get-ClusterSharedVolumePaths {
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
			$ClusterSharedVolumePaths = Invoke-Command @InvokeCommand -ScriptBlock {
				# retrieve cluster shared volumes
				$ClusterSharedVolumes = Get-ClusterSharedVolume
				# retrieve cluster shared volume paths
				$ClusterSharedVolumes.SharedVolumeInfo.FriendlyVolumeName
			}
		}
		catch {
			throw $_
		}

		# return the cluster shared volume paths
		if ($ClusterSharedVolumePaths) {
			return $ClusterSharedVolumePaths
		}
		else {
			return $null
		}
	}

	function Assert-PathCreated {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$Path,
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			# number of attempts to assert path action; default is 6 attempts
			[uint16]$Attempts = 6,
			# path type to test; default is container
			[Microsoft.PowerShell.Commands.TestPathType]$PathType = [Microsoft.PowerShell.Commands.TestPathType]::Container
		)

		################################################
		# prepare session
		################################################

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['Path'] = $Path
		$InvokeCommand['ArgumentList']['PathType'] = $PathType

		################################################
		# test path
		################################################

		# test path before attempting to create path
		try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				Test-Path -Path $ArgumentList['Path'] -PathType $ArgumentList['PathType']
			}
		}
		catch {
			throw $_
		}

		# if path found before attempting to create path...
		if ($TestPath) {
			return $true
		}

		################################################
		# create item
		################################################

		# initialize counter for attempts
		[uint16]$Counter = 0

		# while counter less than attempts and path not found...
		while ($Counter -le $Attempts -and -not $TestPath) {
			# attempt to create path
			try {
				Invoke-Command @InvokeCommand -ScriptBlock {
					param($ArgumentList)

					# define parameters
					$NewItem = @{
						Path        = $ArgumentList['Path']
						Force       = $true
						ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
					}

					# if path type is container...
					if ($ArgumentList['PathType'] -eq [Microsoft.PowerShell.Commands.TestPathType]::Container) {
						# add item type of directory to parameters
						$NewItem['ItemType'] = 'Directory'
					}

					# create item
					$null = New-Item @NewItem
				}
			}
			catch {
				throw $_
			}

			# test path after attempting to create path
			try {
				$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
					param($ArgumentList)
					Test-Path -Path $ArgumentList['Path'] -PathType $ArgumentList['PathType']
				}
			}
			catch {
				throw $_
			}

			# if path found after attempt to create path...
			if ($TestPath) {
				# return true
				return $true
			}

			# increment counter
			$Counter++

			# sleep
			Start-Sleep -Seconds 5
		}

		################################################
		# return failure
		################################################

		# return false after attempts did not succeed
		return $false
	}

	function Assert-PathNotFound {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$Path,
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			# path type to test; default is container
			[Microsoft.PowerShell.Commands.TestPathType]$PathType = [Microsoft.PowerShell.Commands.TestPathType]::Container
		)

		################################################
		# prepare session
		################################################

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['Path'] = $Path
		$InvokeCommand['ArgumentList']['PathType'] = $PathType

		################################################
		# test path itself
		################################################

		# test path before attempting to remove path
		try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				Test-Path -Path $ArgumentList['Path'] -PathType $ArgumentList['PathType']
			}
		}
		catch {
			throw $_
		}

		# return inverted results from Test-Path
		return !$TestPath
	}

	function Assert-PathRemoved {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[string]$Path,
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			# switch to skip remove when files present in path
			[switch]$SkipWhenFilesPresent,
			# filter for files to exclude when searching for files present in path
			[string]$ExcludedFileFilter,
			# number of attempts to assert path action; default is 6 attempts
			[uint16]$Attempts = 6,
			# path type to test; default is container
			[Microsoft.PowerShell.Commands.TestPathType]$PathType = [Microsoft.PowerShell.Commands.TestPathType]::Container
		)

		################################################
		# prepare session
		################################################

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['Path'] = $Path
		$InvokeCommand['ArgumentList']['PathType'] = $PathType
		$InvokeCommand['ArgumentList']['ExcludeFiles'] = $ExcludeFiles

		################################################
		# test path itself
		################################################

		# test path before attempting to remove path
		try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)
				Test-Path -Path $ArgumentList['Path'] -PathType $ArgumentList['PathType']
			}
		}
		catch {
			throw $_
		}

		# if path not found before first attempt to remove path...
		if (!$TestPath) {
			return $true
		}

		################################################
		# test path for files if requested
		################################################

		# if skip when files present requested and path type is a container...
		if ($SkipWhenFilesPresent -and $PathType -eq [Microsoft.PowerShell.Commands.TestPathType]::Container) {
			# test if files exist in path
			try {
				$FilesInPath = Invoke-Command @InvokeCommand -ScriptBlock {
					param($ArgumentList)

					# define required parameters
					$GetChildItems = @{
						Path        = $ArgumentList['Path']
						File        = $true
						Force       = $true
						Recurse     = $true
						ErrorAction = [System.Management.Automation.ActionPreference]::Stop
					}

					# define optional parameters
					if (![string]::IsNullOrEmpty($ArgumentList['ExcludedFileFilter'])) {
						$GetChildItems['Exclude'] = $ArgumentList['ExcludedFileFilter']
					}

					# retrieve file items in path
					$FileItems = Get-ChildItem @GetChildItems

					# if file items found...
					if ($FileItems) {
						return $true
					}
					# if file items not found...
					else {
						return $false
					}
				}
			}
			catch {
				throw $_
			}

			# if files exist in path...
			if ($FilesInPath) {
				Write-Warning -Message "found files in '$Path' path on '$ComputerName' computer"
				return $false
			}
		}

		################################################
		# remove item
		################################################

		# initialize counter for attempts
		[uint16]$Counter = 0

		# while counter less than attempts and path still found...
		while ($Counter -le $Attempts -and $TestPath) {
			# attempt to remove path
			try {
				Invoke-Command @InvokeCommand -ScriptBlock {
					param($ArgumentList)

					# define parameters
					$RemoveItem = @{
						Path        = $ArgumentList['Path']
						Force       = $true
						ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
					}

					# if path type is container...
					if ($ArgumentList['PathType'] -eq [Microsoft.PowerShell.Commands.TestPathType]::Container) {
						# add recurse to parameters
						$RemoveItem['Recurse'] = $true
					}

					# remove item
					$null = Remove-Item @RemoveItem
				}
			}
			catch {
				throw $_
			}

			# test path after attempting to remove path
			try {
				$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
					param($ArgumentList)
					Test-Path -Path $ArgumentList['Path'] -PathType $ArgumentList['PathType']
				}
			}
			catch {
				throw $_
			}

			# if path not found after attempt to remove path...
			if (!$TestPath) {
				# return true
				return $true
			}

			# increment counter
			$Counter++

			# sleep
			Start-Sleep -Seconds 5
		}

		################################################
		# return failure
		################################################

		# return false after attempts did not succeed
		return $false
	}

	function Assert-VMNotFound {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			# switch to skip warning when VMs found
			[switch]$Quiet
		)

		################################################
		# define objects from VM properties
		################################################

		$VMId = $VM.Id.ToString()

		################################################
		# prepare session
		################################################

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['VMId'] = $VMId

		################################################
		# locate planned VM
		################################################

		# retrieve name of planned VM if found by Id
		try {
			$PlannedVM = Invoke-Command @InvokeCommand -ScriptBlock {
				param($ArgumentList)

				# retrieve planned VM by Id
				$CimInstance = Get-CimInstance -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_PlannedComputerSystem' -Filter "Name = '$($ArgumentList['VMId'])'"

				# if planned VM found by Id...
				if ($CimInstance) {
					# return VM name
					return $CimInstance.ElementName
				}
				# if planned VM not found by Id...
				else {
					# return empty string
					return [string]::Empty
				}
			}
		}
		catch {
			throw $_
		}

		################################################
		# locate realized VM
		################################################

		# retrieve name of realized VM if found by Id
		try {
			$RealizedVM = Invoke-Command @InvokeCommand -ScriptBlock {
				# import argument list hashtable
				param($ArgumentList)

				# retrieve realized VM by Id
				$CimInstance = Get-CimInstance -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_ComputerSystem' -Filter "Name = '$($ArgumentList['VMId'])'"

				# if realized VM found by Id...
				if ($CimInstance) {
					# return VM name
					return $CimInstance.ElementName
				}
				# if realized VM not found by Id...
				else {
					# return empty string
					return [string]::Empty
				}
			}
		}
		catch {
			throw $_
		}

		################################################
		# return state
		################################################

		# if planned VM and realized VM are empty strings...
		if ([string]::IsNullOrEmpty($PlannedVM) -and [string]::IsNullOrEmpty($RealizedVM)) {
			# return true
			return $true
		}

		# if planned VM found and quiet not requested...
		if (![string]::IsNullOrEmpty($PlannedVM) -and !$Quiet) {
			# declare state
			Write-Warning -Message "found planned VM by Id with '$PlannedVM' name on '$ComputerName' computer"
		}

		# if realized VM found...
		if (![string]::IsNullOrEmpty($RealizedVM) -and !$Quiet) {
			# declare state
			Write-Warning -Message "found realized VM by Id with '$RealizedVM' name on '$ComputerName' computer"
		}

		# return false
		return $false
	}

	function Assert-VMRemoved {
		[CmdletBinding()]
		param(
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[Parameter(Mandatory = $false)][ValidateSet('PlannedVM', 'RealizedVM', 'VM')]
			[string]$Mode = 'VM',
			# number of attempts to assert path action; default is 6 attempts
			[uint16]$Attempts = 6
		)

		################################################
		# prepare session
		################################################

		# get hashtable for InvokeCommand splat
		try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['Id'] = $VM.Id

		################################################
		# locate VMs before removal
		################################################

		# if planned VM requested by mode...
		if ($Mode -eq 'PlannedVM' -or $Mode -eq 'VM') {
			# retrieve CIM instance for planned VM by Id
			try {
				$PlannedVM = Invoke-Command @InvokeCommand -ScriptBlock {
					param($ArgumentList)
					Get-CimInstance -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_PlannedComputerSystem' -Filter "Name = '$($ArgumentList['Id'])'"
				}
			}
			catch {
				throw $_
			}
		}

		# if realized VM requested by mode...
		if ($Mode -eq 'RealizedVM' -or $Mode -eq 'VM') {
			# retrieve CIM instance for realized VM by Id
			try {
				$RealizedVM = Invoke-Command @InvokeCommand -ScriptBlock {
					param($ArgumentList)
					Get-CimInstance -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_ComputerSystem' -Filter "Name = '$($ArgumentList['Id'])'"
				}
			}
			catch {
				throw $_
			}
		}

		# if planned VM and realized VM not found before first attempt to remove VM...
		if (!$PlannedVM -and !$RealizedVM) {
			# return
			return $true
		}

		################################################
		# remove planned VM
		################################################

		# if planned VM found...
		if ($PlannedVM) {
			# if planned VM found still in migrating state...
			if ($PlannedVM.OperationalStatus -contains '32774') {
				# declare state
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...found planned VM in migrating state, waiting for planned VM to exit state..."

				# initialize counter
				$Counter = [int32]0

				# while counter less than attempts and planned VM found still in migrating state...
				while ($Counter -lt $Attempts -and $PlannedVM.OperationalStatus -contains '32774') {
					# increment counter
					$Counter++

					# sleep
					Start-Sleep -Seconds 5

					# retrieve CIM instance for planned VM by Id
					try {
						$PlannedVM = Invoke-Command @InvokeCommand -ScriptBlock {
							param($ArgumentList)
							Get-CimInstance -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_PlannedComputerSystem' -Filter "Name = '$($ArgumentList['Id'])'"
						}
					}
					catch {
						throw $_
					}
				}

				# if planned VM not found in migrating state...
				if ($PlannedVM.OperationalStatus -contains '32774') {
					# declare state and set boolean
					Write-Warning -Message 'found planned VM still in migrating state after 30 seconds'
					$PlannedVMStuckInMigratingState = $true
				}
				else {
					# declare state
					Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...found planned VM has exited migrating state, removing VM..."
				}
			}
			else {
				# declare state
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...found planned VM, removing VM..."
			}

			# initialize counter
			$Counter = [int32]1

			# while counter less than attempts and planned VM found not in migrating state...
			while ($Counter -lt $Attempts -and $PlannedVM -and -not $PlannedVMStuckInMigratingState) {
				# remove planned VM by Id
				try {
					$null = Invoke-Command @InvokeCommand -ScriptBlock {
						param($ArgumentList)
						$VM = Get-VM -Id $ArgumentList['Id']
						$VM | Remove-VM -Force
					}
				}
				catch {
					throw $_
				}

				# increment counter
				$Counter++

				# sleep
				Start-Sleep -Seconds 5

				# retrieve CIM instance for planned VM by Id
				try {
					$PlannedVM = Invoke-Command @InvokeCommand -ScriptBlock {
						param($ArgumentList)
						Get-CimInstance -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_PlannedComputerSystem' -Filter "Name = '$($ArgumentList['Id'])'"
					}
				}
				catch {
					throw $_
				}
			}

			# if planned VM still found...
			if ($PlannedVM) {
				# declare state
				Write-Warning -Message 'could not remove planned VM after 30 seconds'
			}
		}

		################################################
		# remove realized VM
		################################################

		# if realized VM found...
		if ($RealizedVM) {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...found realized VM, removing VM..."

			# initialize counter
			$Counter = [int32]0

			# while counter less than attempts and realized VM found...
			while ($Counter -lt $Attempts -and $RealizedVM) {
				# increment counter
				$Counter++

				# remove realized VM by Id
				try {
					$null = Invoke-Command @InvokeCommand -ScriptBlock {
						param($ArgumentList)
						$VM = Get-VM -Id $ArgumentList['Id']
						$VM | Remove-VM -Force
					}
				}
				catch {
					throw $_
				}

				# sleep
				Start-Sleep -Seconds 5

				# retrieve CIM instance for realized VM by Id
				try {
					$RealizedVM = Invoke-Command @InvokeCommand -ScriptBlock {
						param($ArgumentList)
						Get-CimInstance -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_ComputerSystem' -Filter "Name = '$($ArgumentList['Id'])'"
					}
				}
				catch {
					throw $_
				}
			}

			# if realized VM still found...
			if ($RealizedVM) {
				# declare state
				Write-Warning -Message 'could not remove realized VM after 30 seconds'
			}
		}

		################################################
		# return state
		################################################

		# if planned VM and realized VM not found after attempts to remove...
		if (!$PlannedVM -and !$RealizedVM) {
			return $true
		}
		# if planned VM and realized VM not found after attempts to remove...
		else {
			return $false
		}
	}

	function Resolve-VMCompatibilityReport {
		param(
			[Parameter(Mandatory)]
			[Microsoft.HyperV.PowerShell.VMCompatibilityReport]$CompatibilityReport
		)

		# add note properties to compatibility report
		Add-Member -InputObject $CompatibilityReport -MemberType 'NoteProperty' -Name 'CannotResolve' -Value $false
		Add-Member -InputObject $CompatibilityReport -MemberType 'NoteProperty' -Name 'CannotResolveMessages' -Value ([System.Collections.Generic.List[string]]::new())

		# extract computer name from compatibility report
		$ComputerName = $CompatibilityReport.VM.ComputerName

		# if one or more VM switch references incompatibilites reported...
		if (33012 -in $CompatibilityReport.Incompatibilities.MessageID) {
			# define parameters for Get-VMSwitch
			$GetVMSwitch = @{
				ComputerName = $ComputerName
				# SwitchType   = [Microsoft.HyperV.PowerShell.VMSwitchType]::External
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# get external VM switches
			try {
				$VMSwitch = Get-VMSwitch @GetVMSwitch
			}
			catch {
				throw $_
			}

			# get external VM switch names
			$SwitchNames = $VMSwitch | Select-Object -ExpandProperty Name

			# if switchname parameter provided but not found in external VM switch names...
			if ($script:PSBoundParameters.ContainsKey('SwitchName') -and $script:PSBoundParameters['SwitchName'] -notin $SwitchNames ) {
				# warn and inquire
				Write-Warning -Message "could not locate '$script:SwitchName' switch on '$ComputerName' computer; attempt to connect VM to another available external switch?" -WarningAction Inquire

				# clear SwitchName
				$null = $SwitchName
			}
		}

		# process each incompatibility
		:NextIncompatibility foreach ($Incompatibility in $CompatibilityReport.Incompatibilities) {
			switch ($Incompatibility.MessageID) {
				# target does not have VM switch references in VM configuration
				33012 {
					# get VM network adapter from report
					try {
						$VMNetworkAdapterName = $Incompatibility.Source.Name
					}
					catch {
						$CompatibilityReport.CannotResolve = $true
						$CompatibilityReport.CannotResolveMessages.Add("Could not retrieve VM network adapter name from incompatibility object: '$($_.Exception.Message)'")
						continue NextIncompatibility
					}

					# if switch name not provided or forced to null...
					if ([string]::IsNullOrEmpty($SwitchName)) {
						# switch on count of switchnames
						switch ($SwitchNames.Count) {
							# no external switches found
							0 {
								# clear switch n ame
								$SwitchName = $null

								# warn and inquire about disconnecting VM
								Write-Warning -Message "No external switches found on '$ComputerName' destination. VM network adapter '$VMNetworkAdapterName' on '$Name' VM will not be connected after import." -WarningAction Inquire
							}
							# one external switch found
							1 {
								# assign switch name
								$SwitchName = $SwitchNames

								# warn about new switch name
								Write-Warning -Message "Found '$SwitchName' external switch on '$ComputerName' destination. VM network adapter '$VMNetworkAdapterName' on '$Name' VM will be connected to VM switch '$SwitchNames'" -WarningAction Continue
							}
							# multiple external switches found
							default {
								# warn about switch name hint
								Write-Warning -Message "Multiple external switches found on '$ComputerName' destination. Will use '$SwitchNameHint' switch name hint to locate available external switch" -WarningAction Continue

								# get external "compute" switches by name
								$SwitchNamesMatchingHint = $SwitchNames | Where-Object { $_.Contains($SwitchNameHint) }

								# check count of switches matching hint
								switch ($SwitchNamesMatchingHint.Count) {
									# no external switches with compute in the name found
									0 {
										# select first external switch after sorting by name
										$SwitchName = $SwitchNames | Sort-Object | Select-Object -First 1

										# warn about reconnect to new switch
										Write-Warning -Message "Will connect '$VMNetworkAdapterName' VM network adapter on '$Name' VM to first available external switch: '$SwitchName'" -WarningAction Continue
									}
									# one external switch found
									1 {
										# select single external switch matching switch name hint
										$SwitchName = $SwitchNamesMatchingHint

										# warn about reconnect to new switch
										Write-Warning -Message "Will connect '$VMNetworkAdapterName' VM network adapter on '$Name' VM to the external switch matching '$SwitchNameHint' switch name hint: $SwitchName" -WarningAction Continue
									}
									default {
										# select first external switch matching switch name hint after sorting by name
										$SwitchName = $SwitchNamesMatchingHint | Sort-Object | Select-Object -First 1

										# warn about reconnect to new switch
										Write-Warning -Message "Will connect '$VMNetworkAdapterName' VM network adapter on '$Name' VM to first available external switch matching '$SwitchNameHint' switch name hint: $SwitchName" -WarningAction Continue
									}
								}
							}
						}
					}

					# if switch name is null...
					if ([string]::IsNullOrEmpty($SwitchName)) {
						# ...disconnect VM network adapter
						try {
							$Incompatibility.Source | Disconnect-VMNetworkAdapter
						}
						catch {
							$CompatibilityReport.CannotResolve = $true
							$CompatibilityReport.CannotResolveMessages.Add("Could not disconnect '$VMNetworkAdapterName' VM network adapter on '$Name' VM to address VM switch incompatibility: '$($_.Exception.Message)'")
							continue NextIncompatibility
						}
					}
					# if switch name is not null...
					else {
						# ...reconnect VM network adapter to new switch
						try {
							$Incompatibility.Source | Connect-VMNetworkAdapter -SwitchName $SwitchName
							# $Incompatibility.Source | Disconnect-VMNetworkAdapter -Passthru | Connect-VMNetworkAdapter -SwitchName $SwitchName
						}
						catch {
							$CompatibilityReport.CannotResolve = $true
							$CompatibilityReport.CannotResolveMessages.Add("Could not connect '$VMNetworkAdapterName' VM network adapter on '$Name' VM to '$SwitchName' switch to address VM switch incompatibility: '$($_.Exception.Message)'")
							continue NextIncompatibility
						}
					}
				}
				# target has an incompatibility with imported VM not addressed above
				default {
					$CompatibilityReport.CannotResolve = $true
					$CompatibilityReport.CannotResolveMessages.Add("found unhandled incompatibility with '$($Incompatibility.MessageID) and message: '$($Incompatibility.Message)'")
					continue NextIncompatibility
				}
			}
		}

		# return updated compatibility object
		return $CompatibilityReport
	}

	function Move-VMToComputer {
		param(
			[Parameter(Mandatory)]
			[object]$VM,
			[Parameter(Mandatory)]
			[string]$DestinationHost,
			[Parameter(Mandatory)]
			[hashtable]$Parameters
		)

		################################################
		# define strings
		################################################

		$Name = $VM.Name.ToLowerInvariant()
		$ComputerName = $VM.ComputerName.ToLowerInvariant()

		################################################
		# compare VM
		################################################

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - comparing VM with destination host: $DestinationHost"

		# compare VM with target computer
		try {
			$CompatibilityReport = Compare-VM -VM $VM -DestinationHost $DestinationHost @Parameters
		}
		catch {
			Write-Warning -Message "could not compare VM: $($_.Exception.Message)"
			return $_
		}

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM compared"

		# save original compatibility report to global scope
		New-Variable -Name 'OriginalCompatibilityReport' -Value $CompatibilityReport -Scope Global -Force

		################################################
		# resolve incompatibilities
		################################################

		# if incompatibilities found...
		if ($CompatibilityReport.Incompatibilities.Count) {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - resolving compatibility report for VM..."

			# resolve incompatibilities
			try {
				$CompatibilityReport = Resolve-VMCompatibilityReport -CompatibilityReport $CompatibilityReport
			}
			catch {
				Write-Warning -Message "could not resolve incompatibilities: $($_.Exception.Message)"
				return $CompatibilityReport.VM
			}

			# save resolved compatibility report to global scope
			New-Variable -Name 'ResolvedCompatibilityReport' -Value $CompatibilityReport -Scope Global -Force

			# if incompatibilities could not be resolved...
			if ($CompatibilityReport.CannotResolve) {
				# loop through cannot resolve messages
				foreach ($CannotResolveMessage in $CompatibilityReport.CannotResolveMessages) {
					# report message
					Write-Warning -Message "found cannot resolve message: $CannotResolveMessage"
				}

				# return VM from compatibility report
				return $CompatibilityReport.VM
			}

			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...resolved compatibility report for VM"
		}

		################################################
		# move VM
		################################################

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - moving VM..."

		# move VM to target computer
		try {
			$MovedVM = Move-VM -CompatibilityReport $CompatibilityReport -Passthru
		}
		catch {
			Write-Warning -Message "could not move VM: $($_.Exception.Message)"
		}

		# if VM move completed...
		if ($MovedVM) {
			# report and return VM returned by move function
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...move completed"
			return $MovedVM
		}
		else {
			# report and return VM from compatibility report
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...move failed"
			return $CompatibilityReport.VM
		}
	}

	function Remove-VMOnComputer {
		param(
			[Parameter(Mandatory = $true)][ValidateScript({ $_ -is [Microsoft.HyperV.PowerShell.VirtualMachine] })]
			[object]$VM
		)

		################################################
		# define strings
		################################################

		$Name = $VM.Name.ToLowerInvariant()
		$ComputerName = $VM.ComputerName.ToLowerInvariant()

		################################################
		# get VM paths
		################################################

		# define VM path list
		$VMPaths = [System.Collections.Generic.List[string]]::new()

		# get VM hard disk drive
		$VHDPaths = Get-VMHardDiskDrive -VM $VM | Select-Object -ExpandProperty Path

		# loop through VHD parent paths
		foreach ($VHDPath in $VHDPaths) {
			# get VHD parent path from VHD path
			$VHDParentPath = Split-Path -Path $VHDPath -Parent

			# trim VHD parent path
			$VHDParentPath = $VHDParentPath.TrimEnd('\')

			# if VHD parent path property not in VM path list and not null or empty...
			if ($VHDParentPath -notin $VMPaths -and -not [string]::IsNullOrEmpty($VHDParentPath)) {
				# add VHD parent path to VM path list
				$VMPaths.Add($VHDParentPath)
			}
		}

		# define VM path properties
		$VMPathProperties = 'Path', 'ConfigurationLocation', 'CheckpointFileLocation', 'SmartPagingFilePath', 'SnapshotFileLocation'

		# add VM path properties to VM path list
		foreach ($VMPathProperty in $VMPathProperties) {
			# get VM path from VM property
			$VMPath = $VM | Select-Object -ExpandProperty $VMPathProperty

			# trim VM path
			$VMPath = $VMPath.TrimEnd('\')

			# if VM path property not in VM path list and not null or empty...
			if ($VMPath -notin $VMPaths -and -not [string]::IsNullOrEmpty($VMPath)) {
				# add VM path property to VM path list
				$VMPaths.Add($VMPath)
			}
		}

		################################################
		# remove VM
		################################################

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - checking VM..."

		# define parameters
		$AssertVMNotFound = @{
			VM           = $VM
			ComputerName = $ComputerName
			Quiet        = $true
		}

		# check VM
		try {
			$VMNotFound = Assert-VMNotFound @AssertVMNotFound
		}
		catch {
			throw $_
		}

		# if VM not found...
		if ($VMNotFound) {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM not found"
		}
		else {
			# define parameters
			$AssertVMRemoved = @{
				VM           = $VM
				ComputerName = $ComputerName
			}

			# remove VM
			try {
				$VMRemoved = Assert-VMRemoved @AssertVMRemoved
			}
			catch {
				throw $_
			}

			# if VM removed...
			if ($VMRemoved) {
				# declare state
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...removed VM"
			}
			else {
				# return; warnings issued by function
				return
			}
		}

		################################################
		# remove VM files
		################################################

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - removing VHDs..."

		# remove VM hard disk drive files
		foreach ($VHDPath in $VHDPaths) {
			# define parameters
			$AssertPathNotFound = @{
				Path         = $VHDPath
				ComputerName = $ComputerName
				PathType     = [Microsoft.PowerShell.Commands.TestPathType]::Leaf
			}

			# test path
			try {
				$PathNotFound = Assert-PathNotFound @AssertPathNotFound
			}
			catch {
				throw $_
			}

			# if path not found...
			if ($PathNotFound) {
				# declare state
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VHD not found: $VHDPath"
			}
			else {
				# declare state
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...removing VHD: $VHDPath"

				# define parameters
				$AssertPathRemoved = @{
					Path         = $VHDPath
					ComputerName = $ComputerName
					PathType     = [Microsoft.PowerShell.Commands.TestPathType]::Leaf
				}

				# remove path
				try {
					$PathRemoved = Assert-PathRemoved @AssertPathRemoved
				}
				catch {
					throw $_
				}

				# if path removed...
				if ($PathRemoved) {
					# declare state
					Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VHD removed"
				}
			}
		}

		################################################
		# remove VM folders
		################################################

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - removing VM folders..."

		# remove VM path folders
		foreach ($VMPath in $VMPaths) {
			# define parameters
			$AssertPathNotFound = @{
				Path         = $VMPath
				ComputerName = $ComputerName
				PathType     = [Microsoft.PowerShell.Commands.TestPathType]::Container
			}

			# test path
			try {
				$PathNotFound = Assert-PathNotFound @AssertPathNotFound
			}
			catch {
				throw $_
			}

			# if path not found...
			if ($PathNotFound) {
				# declare state
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM folder not found: $VMPath"
			}
			else {
				# declare state
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...removing VM folder: $VMPath"

				# define parameters
				$AssertPathRemoved = @{
					Path                 = $VMPath
					ComputerName         = $ComputerName
					SkipWhenFilesPresent = $true
					ExcludedFileFilter   = '{0}.*' -f $VM.Id
					PathType             = [Microsoft.PowerShell.Commands.TestPathType]::Container
				}

				# remove path
				try {
					$PathRemoved = Assert-PathRemoved @AssertPathRemoved
				}
				catch {
					throw $_
				}

				# if path removed...
				if ($PathRemoved) {
					# declare state
					Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM folder removed"
				}
			}
		}
	}

	function Restore-VMOnComputer {
		param(
			[Parameter(Mandatory = $true)][ValidateScript({ $_ -is [Microsoft.HyperV.PowerShell.VirtualMachine] })]
			[object]$VM
		)

		################################################
		# define strings
		################################################

		$Name = $VM.Name.ToLowerInvariant()
		$ComputerName = $VM.ComputerName.ToLowerInvariant()

		################################################
		# get cluster name from computer name
		################################################

		# get cluster for target server
		try {
			$ClusterName = Get-ClusterName -ComputerName $ComputerName
		}
		catch {
			throw $_
		}

		################################################
		# add VM to cluster
		################################################

		# if computer is clustered...
		if ($ClusterName) {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - adding VM to '$ClusterName' cluster..."

			# define parameters for Add-ClusterVirtualMachineRole
			$AddClusterVirtualMachineRole = @{
				Cluster        = $ClusterName
				VirtualMachine = $Name
				ErrorAction    = [System.Management.Automation.ActionPreference]::Stop
			}

			# add VM to cluster by ID
			try {
				$ClusterGroup = Add-ClusterVirtualMachineRole @AddClusterVirtualMachineRole
			}
			catch {
				throw $_
			}

			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM clustered"

			# if original priority retrieved and cluster group priority does not match original priority...
			if ($script:Priority -and $ClusterGroup.Priority -ne $script:Priority) {
				# update cluster group
				try {
					$ClusterGroup.Priority = $script:Priority
				}
				catch {
					throw $_
				}

				# declare state
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...updated cluster group priority to original value: $($script:Priority)"
			}
		}

		################################################
		# refresh VM key protector
		################################################

		# # if skip key protector update not present requested and VM on new computer...
		# if (!$script:SkipKeyProtectorUpdate.IsPresent -and $script:DestinationHost -eq $ComputerName) {
		# 	# declare state
		# 	Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - updating VM key protector..."

		# 	# define parameters for Set-VMKeyProtector
		# 	$SetVMKeyProtector = @{
		# 		VM                   = $VM
		# 		NewLocalKeyProtector = $true
		# 		ErrorAction          = [System.Management.Automation.ActionPreference]::Stop
		# 	}

		# 	# update VM key protector
		# 	try {
		# 		Set-VMKeyProtector @SetVMKeyProtector
		# 	}
		# 	catch {
		# 		throw $_
		# 	}

		# 	# declare state
		# 	Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...updated VM key protector"
		# }

		################################################
		# restore VM start action on computer
		################################################

		# if computer is not clustered...
		if ([string]::IsNullOrEmpty($ClusterName)) {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - restoring VM start action configuration..."

			# define parameters for Set-VM
			$SetVM = @{
				VM                   = $VM
				AutomaticStartAction = $script:AutomaticStartAction
				ErrorAction          = [System.Management.Automation.ActionPreference]::Stop
			}

			# restore automatic start action
			try {
				Set-VM @SetVM
			}
			catch {
				throw $_
			}

			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM configuration restored"
		}

		################################################
		# start VM on computer
		################################################

		# if VM was running before move...
		if ($State -eq 'Running' -and $VM.State -ne 'Running') {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - starting VM..."

			# define parameters for Start-VM
			$StartVM = @{
				VM          = $VM
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# start VM on computer
			try {
				Start-VM @StartVM
			}
			catch {
				throw $_
			}

			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM started"
		}
	}
}

process {
	################################################
	# check for VM on source computer
	################################################

	# if VM provided...
	if ($PSBoundParameters.ContainsKey('VM')) {
		# retrieve name from VM
		$Name = $VM.Name.ToLowerInvariant()
	}

	# declare state
	Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - checking source computer for VM..."

	# if name provided...
	if ($PSCmdlet.ParameterSetName.StartsWith('Name')) {
		# define required parameters for Get-VM
		$GetVM = @{
			Name         = $Name
			ComputerName = $ComputerName
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# get VM object from input
		try {
			$VM = Get-VM @GetVM
		}
		catch {
			throw $_
		}
	}

	# check for snapshot
	if ($VM.ParentSnapshotId) {
		Write-Warning 'VM has an active snapshot. Remove or consolidate snapshots before migration'
		return
	}

	# get VM properties
	$Id = $VM.Id
	$ComputerName = $VM.ComputerName.ToLowerInvariant()

	# check for Protected Users
	if ($Hostname -ne $ComputerName -and ([Security.Principal.WindowsIdentity]::GetCurrent().Groups | Where-Object { $_.Value -match '-525$' })) {
		throw [System.UnauthorizedAccessException]::new('Users in the Protected Users group must run this script from the source hypervisor')
	}

	# get VM configuration for restoration
	$State = $VM.State
	$AutomaticStartAction = $VM.AutomaticStartAction

	################################################
	# check for VM on source cluster
	################################################

	# get cluster for source computer
	try {
		$SourceClusterName = Get-ClusterName -ComputerName $ComputerName
	}
	catch {
		throw $_
	}

	# if source computer is clustered...
	if ($SourceClusterName) {
		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - checking if VM clustered on source computer..."

		# validate source cluster is accessible
		try {
			$null = Get-Cluster -Name $SourceClusterName -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not reach '$SourceClusterName' cluster: $($_.Exception.Message)"
			return $_
		}

		# define parameters for Get-ClusterGroup
		$GetClusterGroup = @{
			Cluster     = $SourceClusterName
			VMId        = $Id
			ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
		}

		# get cluster group for VM on source cluster
		$SourceClusterGroup = Get-ClusterGroup @GetClusterGroup

		# clear errors due to the nature of looking up VMs by Id
		$Error.Clear()

		# if source cluster group found...
		if ($SourceClusterGroup) {
			# retrieve cluster priority
			$script:Priority = $SourceClusterGroup.Priority

			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM found on '$SourceClusterName' cluster with '$script:Priority' priority; will remove from cluster before migration"
		}
		else {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM not found on '$SourceClusterName' cluster"
		}
	}

	################################################
	# check if target computer is clustered
	################################################

	# get cluster for target computer
	try {
		$TargetClusterName = Get-ClusterName -ComputerName $DestinationHost
	}
	catch {
		throw $_
	}

	# if target computer is clustered...
	if ($TargetClusterName) {
		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$DestinationHost,$Name - checking if VM clustered on target computer..."

		# retrieve target cluster nodes
		try {
			$TargetClusterNodes = Get-ClusterNode -Cluster $TargetClusterName -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not retrieves nodes from '$TargetClusterName' cluster: $($_.Exception.Message)"
			return $_
		}

		# define parameters for Get-ClusterGroup
		$GetClusterGroup = @{
			Cluster     = $TargetClusterName
			VMId        = $Id
			ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
		}

		# get cluster group for VM on source cluster
		$TargetClusterGroup = Get-ClusterGroup @GetClusterGroup

		# clear errors due to the nature of looking up VMs by Id
		$Error.Clear()

		# if target cluster group found...
		if ($TargetClusterGroup) {
			# declare state
			Write-Warning -Message "found VM on '$($TargetClusterGroup.OwnerNode.Name)' node in '$TargetClusterName' cluster"
			return
		}
		else {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$DestinationHost,$Name - ...VM not found on '$TargetClusterName' cluster"
		}
	}

	################################################
	# check for VM on target computer
	################################################

	# define sorted set for target computer names
	$TargetComputerNames = [System.Collections.Generic.SortedSet[System.String]]::new()

	# if target computer is clustered...
	if ($TargetClusterName) {
		# define host type
		$HostType = 'target cluster node'

		# loop through nodes in target cluster
		foreach ($TargetClusterNode in $TargetClusterNodes) {
			# add node name to sorted set
			$null = $TargetComputerNames.Add($TargetClusterNode.Name)
		}
	}
	# if target computer is not clustered...
	else {
		# define host type
		$HostType = 'destination host'

		# add destination host to sorted set
		$TargetClusterNames.Add($DestinationHost)
	}

	# loop through target computer names
	foreach ($TargetComputerName in $TargetComputerNames) {
		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$TargetComputerName,$Name - checking $HostType for VM..."

		# if remove planned VM is present...
		if ($RemovePlannedVMs.IsPresent) {
			# define required parameters
			$AssertVMRemoved = @{
				VM           = $VM
				ComputerName = $DestinationHost
				Mode         = 'PlannedVM'
			}

			# ensure VM not found on destination host
			try {
				$VMNotFound = Assert-VMRemoved @AssertVMRemoved
			}
			catch {
				throw $_
			}
		}

		# define required parameters
		$AssertVMNotFound = @{
			VM           = $VM
			ComputerName = $DestinationHost
		}

		# ensure VM not found on destination host
		try {
			$VMNotFound = Assert-VMNotFound @AssertVMNotFound
		}
		catch {
			throw $_
		}

		# if VM found on destination host
		if (!$VMNotFound) {
			# return immediately; warnings were issued by function
			return
		}
	}

	################################################
	# define initial parameters for function
	################################################

	# define parameters
	$Parameters = @{
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	################################################
	# get VM paths on source computer
	################################################

	# define VM path list
	$VMPaths = [System.Collections.Generic.List[string]]::new()

	# if destination storage path provided...
	if ($PSBoundParameters.ContainsKey('DestinationStoragePath')) {
		# add destination storage path to list
		$VMPaths.Add($DestinationStoragePath)

		# add destination storage path to parameters
		$Parameters['DestinationStoragePath'] = $DestinationStoragePath

		# add include storage to parameters - required to move VHDs to destination storage
		$Parameters['IncludeStorage'] = $true
	}

	# if destination storage path not provided...
	if (!$PSBoundParameters.ContainsKey('DestinationStoragePath')) {
		# if virtual machine path not provided as parameter...
		if (!$PSBoundParameters.ContainsKey('VirtualMachinePath')) {
			# assume virtual machine path is same as path property on VM
			$VirtualMachinePath = $VM | Select-Object -ExpandProperty 'Path'
		}

		# add virtual machine path to list
		$VMPaths.Add($VirtualMachinePath)

		# add virtual machine path to parameters
		$Parameters['VirtualMachinePath'] = $VirtualMachinePath

		# define mapping of VM properties to Move-VM parameters
		$VMPathPropertyMap = @{
			SmartPagingFilePath  = 'SmartPagingFilePath'
			SnapshotFileLocation = 'SnapshotFilePath'
		}

		# add VM path properties to VM path list
		:NextVMPathProperty foreach ($VMPathProperty in $VMPathPropertyMap.Keys) {
			# if VM path property not provided as parameter...
			if (!$PSBoundParameters.ContainsKey($VMPathProperty)) {
				continue NextVMPathProperty
			}

			# get VM path from parameter
			$VMPath = $PSBoundParameters[$VMPathProperty]

			# trim VM path
			$VMPath = $VMPath.TrimEnd('\')

			# if VM path property in VM path list or null or empty...
			if ($VMPath -in $VMPaths -or [string]::IsNullOrEmpty($VMPath)) {
				continue NextVMPathProperty
			}

			# add VM path to list
			$VMPaths.Add($VMPath)

			# retrieve parameter name from hashtable
			$ParameterName = $VMPathPropertyMap[$VMPathProperty]

			# add VM path to parameters
			$Parameters[$ParameterName] = $VMPath
		}
	}

	################################################
	# get VHD paths on source computer
	################################################

	# if destination storage path parameter not provided...
	if (!$PSBoundParameters.ContainsKey('DestinationStoragePath')) {
		# get VM hard disk drive
		$VHDPaths = Get-VMHardDiskDrive -VM $VM | Select-Object -ExpandProperty Path

		# if VHDs hashtable array not provided...
		if (!$PSBoundParameters.ContainsKey('VHDs')) {
			# create list for VHD strings
			$VHDsStringList = [System.Collections.Generic.List[string]]::new()

			# get VHD paths from array of VHD hashtables
			foreach ($VHDPath in $VHDPaths) {
				# define VHD hashtable as string
				$VHDString = "@{ SourceFilePath = '$VHDPath'; 'DestinationFilePath' = '$VHDPath' }"

				# add VHD hashtable as string to list
				$VHDsStringList.Add($VHDString)

				# declare state
				Write-Verbose "created VHD hashtable string: $VHDString"
			}

			# define expression compatible string
			$VHDsString = "@($($VHDsStringList -join ', '))"

			# convert string into array of hashtables
			$VHDs = Invoke-Expression -Command $VHDsString
		}

		# define lists for file paths
		$SourceFilePaths = [System.Collections.Generic.List[string]]::new()
		$DestinationFilePaths = [System.Collections.Generic.List[string]]::new()

		# define booleans for invalid VHD array members
		$InvalidVHDArrayMember = $false

		# loop through VHDs
		foreach ($VHD in $VHDs) {
			# if VHD is not a hashtable...
			if ($VHD -isnot [hashtable]) {
				Write-Warning -Message 'invalid VHDs parameter: found array member that is not a hashtable'
				$InvalidVHDArrayMember = $true
				continue
			}

			# if source file path key missing...
			if (!$VHD.ContainsKey('SourceFilePath')) {
				# warn and update boolean
				Write-Warning -Message "invalid VHDs parameter: found hashtable in array missing required 'SourceFilePath' key"
				$InvalidVHDArrayMember = $true
				continue
			}
			else {
				$SourceFilePath = $VHD['SourceFilePath']
			}

			# if destination file path key missing...
			if (!$VHD.ContainsKey('DestinationFilePath')) {
				# warn and update boolean
				Write-Warning -Message "invalid VHDs parameter: found hashtable in array missing required 'DestinationFilePath' key"
				$InvalidVHDArrayMember = $true
				continue
			}
			else {
				$DestinationFilePath = $VHD['DestinationFilePath']
			}

			# if source file path value null or empty...
			if ([string]::IsNullOrEmpty($SourceFilePath)) {
				# warn and update boolean
				Write-Warning -Message "invalid VHDs parameter: found hashtable where 'SourceFilePath' value is null or empty"
				$InvalidVHDArrayMember = $true
				continue
			}
			else {
				$SourceFilePaths.Add($SourceFilePath)
			}

			# if destination file path value null or empty...
			if ([string]::IsNullOrEmpty($DestinationFilePath)) {
				# warn and update boolean
				Write-Warning -Message "invalid VHDs parameter: found hashtable where 'DestinationFilePath' value is null or empty"
				$InvalidVHDArrayMember = $true
				continue NextVHD
			}
			else {
				# add destination file path to list
				$DestinationFilePaths.Add($DestinationFilePath)
			}
		}

		# if any invalid VHD array members found...
		if ($InvalidVHDArrayMember) {
			return
		}

		# define boolean for missing source file paths
		$SourceFilePathMissing = $false

		# loop through source file paths
		foreach ($VHDPath in $SourceFilePaths) {
			# assert source file path exists
			try {
				$TestPath = Assert-PathCreated -Path $VHD['SourceFilePath'] -ComputerName $ComputerName -PathType 'Leaf'
			}
			catch {
				throw $_
			}

			# if source file path not found...
			if (!$TestPath) {
				# warn and update boolean
				Write-Warning -Message "could not locate file for '$($VHD['SourceFilePath'])' path in 'SourceFilePath' value"
				$SourceFilePathMissing = $true
			}
		}

		# if any source file paths are missing...
		if ($SourceFilePathMissing) {
			return
		}

		# loop through destination file paths
		foreach ($VHDPath in $DestinationFilePaths) {
			# get VHD parent path from VHD path
			$VHDParentPath = Split-Path -Path $VHDPath -Parent

			# trim VHD parent path
			$VHDParentPath = $VHDParentPath.TrimEnd('\')

			# if VHD parent path property not in VM path list and not null or empty...
			if ($VHDParentPath -notin $VMPaths -and -not [string]::IsNullOrEmpty($VHDParentPath)) {
				# add VHD parent path to VM path list
				$VMPaths.Add($VHDParentPath)
			}
		}

		# add destination storage path to parameters
		$Parameters['VHDs'] = $VHDs
	}

	################################################
	# test VM paths against CSVs on target
	################################################

	# if target computer is clustered and skip of clustered storage check not requested...
	if ($TargetClusterName -and -not $SkipClusteredStorageCheck) {
		# retrieve CSV paths from target computer
		try {
			$ClusterSharedVolumePaths = Get-ClusterSharedVolumePaths -ComputerName $DestinationHost
		}
		catch {
			throw $_
		}

		# define boolean
		$VMPathsNotClustered = $false

		# loop through VM paths...
		:NextVMPath foreach ($VMPath in $VMPaths) {
			# loop through CSV paths
			foreach ($ClusterSharedVolumePath in $ClusterSharedVolumePaths) {
				# if VM path starts with CSV path...
				if ($VMPath.StartsWith($ClusterSharedVolumePath, [System.StringComparison]::InvariantCultureIgnoreCase)) {
					# continue with next VM path
					continue NextVMPath
				}
			}

			# warn and update boolean
			Write-Warning -Message "found '$VMPath' path would not be on a Cluster Shared Volume on '$DestinationHost' computer"
			$VMPathsNotClustered = $true
		}

		# if any VM paths are not clustered...
		if ($VMPathsNotClustered) {
			return
		}
	}

	################################################
	# assert path on target computer
	################################################

	# declare state
	Write-Host "$([datetime]::Now.ToString('s')),$DestinationHost,$Name - checking path(s) on destination..."

	# loop through paths...
	foreach ($VMPath in $VMPaths) {
		# ensure path is created
		try {
			$PathCreated = Assert-PathCreated -Path $VMPath -ComputerName $DestinationHost
		}
		catch {
			throw $_
		}

		# if path is not created...
		if (!$PathCreated) {
			Write-Warning -Message "could not create '$VMPath' path on '$DestinationHost' computer"
			return
		}

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$DestinationHost,$Name - ...path found: $VMPath"
	}

	################################################
	# remove VM from source cluster
	################################################

	# if VM clustered on source computer...
	if ($SourceClusterGroup) {
		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - removing VM from '$SourceClusterName' cluster..."

		# remove cluster group and resources
		try {
			Remove-ClusterGroup -Cluster $SourceClusterName -VMId $VM.Id -RemoveResources -Force
		}
		catch {
			return $_
		}

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM removed from '$SourceClusterName' cluster"
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - waiting for VM to refresh after cluster removal..."

		# while VM reports as clustered...
		while ($VM.IsClustered) {
			# update VM object after cluster removal
			try {
				$VM = Get-VM -Id $VM.Id -ComputerName $VM.ComputerName
			}
			catch {
				return $_
			}
		}

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM refreshed after cluster removal"
	}

	################################################
	# prepare VM for move
	################################################

	# if Force switch not present...
	If (!$Force.IsPresent) {
		Write-Warning -Message "found '$Name' VM and QuickMigration requested; continue to shut down VM" -WarningAction Inquire
	}

	# stop VM before move
	Try {
		$VM = Stop-VM -VM $VM -Force -Passthru
	}
	Catch {
		Return $_
	}

	# if skip version update not present...
	if (!$SkipVersionUpdate.IsPresent) {
		# define parameters for Get-VMHostSupportedVersion
		$GetVMHostSupportedVersion = @{
			ComputerName = $ComputerName
			Default      = $true
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# get default (latest) supported version from hypervisor
		Try {
			$VMHostSupportedVersion = Get-VMHostSupportedVersion @GetVMHostSupportedVersion
		}
		Catch {
			Throw $_
		}

		# if VM version is less than highest supported VM version...
		If ([decimal]$VM.Version -lt [decimal]$VMHostSupportedVersion.Version.ToString()) {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - updating VM version from: $($VM.Version)"

			# define required parameters for Update-VMVersion
			$UpdateVMVersion = @{
				VM          = $VM
				Passthru    = $true
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# define optional parameters for Update-VMVersion
			If ($script:PSBoundParameters.ContainsKey('Force')) {
				$UpdateVMVersion['Force'] = $script:Force
			}

			# update VM version
			try {
				$VM = Update-VMVersion @UpdateVMVersion
			}
			catch {
				Write-Warning -Message "Failed to update VM version: $($_.ToString())"
			}

			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...updated VM version: $($VM.Version)"
		}
	}

	################################################
	# move VM
	################################################

	# move VM to target computer
	try {
		$MovedVM = Move-VMToComputer -VM $VM -DestinationHost $DestinationHost -Parameters $Parameters
	}
	catch {
		Write-Warning -Message "could not move VM: $($_.Exception.Message)"
	}

	################################################
	# restore VM
	################################################

	# if VM moved to target...
	if ($MovedVM -and $MovedVM.VirtualMachineType -eq 'RealizedVirtualMachine') {
		# restore moved VM
		try {
			Restore-VMOnComputer -VM $MovedVM
		}
		catch {
			Write-Warning -Message "could not restore migrated VM: $($_.Exception.Message)"
		}
	}
	# if VM move failed...
	else {
		# restore original VM
		try {
			Restore-VMOnComputer -VM $VM
		}
		catch {
			Write-Warning -Message "could not restore original VM: $($_.Exception.Message)"
		}
	}

	################################################
	# remove VM
	################################################

	# if VM moved to target...
	if ($MovedVM -and $MovedVM.VirtualMachineType -eq 'RealizedVirtualMachine') {
		# remove remnants of original VM
		try {
			Remove-VMOnComputer -VM $VM
		}
		catch {
			Write-Warning -Message "could not remove remnants of original VM: $($_.Exception.Message)"
		}

	}
	# if VM move failed and reference to planned VM exists...
	elseif ($MovedVM -and $MovedVM.VirtualMachineType -eq 'PlannedVirtualMachine') {
		# remove remnants of failed VM move
		try {
			Remove-VMOnComputer -VM $MovedVM
		}
		catch {
			Write-Warning -Message "could not remove remnants of planned VM: $($_.Exception.Message)"
		}
	}
}

end {
	# loop through sessions
	foreach ($SessionName in $script:PSSessions.Keys) {
		# remove sessions created by this script
		try {
			Remove-PSSession -Session $script:PSSessions[$SessionName]
		}
		catch {
			return $_
		}
	}
}
