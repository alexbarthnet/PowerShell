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
	# switch to skip CSV storage check
	[switch]$SkipClusteredStorageCheck
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
				$script:PSSessions[$ComputerName] = New-PSSession -ComputerName $ComputerName -Name $ComputerName -Authentication Kerberos
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
		If ($ClusterName) {
			Return $ClusterName.ToLowerInvariant()
		}
		Else {
			Return $null
		}
	}

	Function Get-ClusterSharedVolumePaths {
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
			$ClusterSharedVolumePaths = Invoke-Command @InvokeCommand -ScriptBlock {
				# retrieve cluster shared volumes
				$ClusterSharedVolumes = Get-ClusterSharedVolume
				# retrieve cluster shared volume paths
				$ClusterSharedVolumes.SharedVolumeInfo.FriendlyVolumeName
			}
		}
		Catch {
			Throw $_
		}

		# return the cluster shared volume paths
		If ($ClusterSharedVolumePaths) {
			Return $ClusterSharedVolumePaths
		}
		Else {
			Return $null
		}
	}

	Function Assert-PathCreated {
		[CmdletBinding()]
		Param(
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
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		Catch {
			Throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['Path'] = $Path
		$InvokeCommand['ArgumentList']['PathType'] = $PathType

		################################################
		# test path
		################################################

		# test path before attempting to create path
		Try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				Test-Path -Path $ArgumentList['Path'] -PathType $ArgumentList['PathType']
			}
		}
		Catch {
			Throw $_
		}

		# if path found before attempting to create path...
		If ($TestPath) {
			Return $true
		}

		################################################
		# create item
		################################################

		# initialize counter for attempts
		[uint16]$Counter = 0

		# while counter less than attempts and path not found...
		While ($Counter -le $Attempts -and -not $TestPath) {
			# attempt to create path
			Try {
				Invoke-Command @InvokeCommand -ScriptBlock {
					Param($ArgumentList)

					# define parameters
					$NewItem = @{
						Path        = $ArgumentList['Path']
						Force       = $true
						ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
					}

					# if path type is container...
					If ($ArgumentList['PathType'] -eq [Microsoft.PowerShell.Commands.TestPathType]::Container) {
						# add item type of directory to parameters
						$NewItem['ItemType'] = 'Directory'
					}

					# create item
					$null = New-Item @NewItem
				}
			}
			Catch {
				Throw $_
			}

			# test path after attempting to create path
			Try {
				$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
					Param($ArgumentList)
					Test-Path -Path $ArgumentList['Path'] -PathType $ArgumentList['PathType']
				}
			}
			Catch {
				Throw $_
			}

			# if path found after attempt to create path...
			If ($TestPath) {
				# return true
				Return $true
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
		Return $false
	}

	Function Assert-PathNotFound {
		[CmdletBinding()]
		Param(
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
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		Catch {
			Throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['Path'] = $Path
		$InvokeCommand['ArgumentList']['PathType'] = $PathType

		################################################
		# test path itself
		################################################

		# test path before attempting to remove path
		Try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				Test-Path -Path $ArgumentList['Path'] -PathType $ArgumentList['PathType']
			}
		}
		Catch {
			Throw $_
		}

		# return inverted results from Test-Path
		Return !$TestPath
	}

	Function Assert-PathRemoved {
		[CmdletBinding()]
		Param(
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
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		Catch {
			Throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['Path'] = $Path
		$InvokeCommand['ArgumentList']['PathType'] = $PathType
		$InvokeCommand['ArgumentList']['ExcludeFiles'] = $ExcludeFiles

		################################################
		# test path itself
		################################################

		# test path before attempting to remove path
		Try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				Test-Path -Path $ArgumentList['Path'] -PathType $ArgumentList['PathType']
			}
		}
		Catch {
			Throw $_
		}

		# if path not found before first attempt to remove path...
		If (!$TestPath) {
			Return $true
		}

		################################################
		# test path for files if requested
		################################################

		# if skip when files present requested and path type is a container...
		If ($SkipWhenFilesPresent -and $PathType -eq [Microsoft.PowerShell.Commands.TestPathType]::Container) {
			# test if files exist in path
			Try {
				$FilesInPath = Invoke-Command @InvokeCommand -ScriptBlock {
					Param($ArgumentList)

					# define required parameters
					$GetChildItems = @{
						Path        = $ArgumentList['Path']
						File        = $true
						Force       = $true
						Recurse     = $true
						ErrorAction = [System.Management.Automation.ActionPreference]::Stop
					}

					# define optional parameters
					If (![string]::IsNullOrEmpty($ArgumentList['ExcludedFileFilter'])) {
						$GetChildItems['Exclude'] = $ArgumentList['ExcludedFileFilter']
					}

					# retrieve file items in path
					$FileItems = Get-ChildItem @GetChildItems

					# if file items found...
					If ($FileItems) {
						Return $true
					}
					# if file items not found...
					Else {
						Return $false
					}
				}
			}
			Catch {
				Throw $_
			}

			# if files exist in path...
			If ($FilesInPath) {
				Write-Warning -Message "found files in '$Path' path on '$ComputerName' computer"
				Return $false
			}
		}

		################################################
		# remove item
		################################################

		# initialize counter for attempts
		[uint16]$Counter = 0

		# while counter less than attempts and path still found...
		While ($Counter -le $Attempts -and $TestPath) {
			# attempt to remove path
			Try {
				Invoke-Command @InvokeCommand -ScriptBlock {
					Param($ArgumentList)

					# define parameters
					$RemoveItem = @{
						Path        = $ArgumentList['Path']
						Force       = $true
						ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
					}

					# if path type is container...
					If ($ArgumentList['PathType'] -eq [Microsoft.PowerShell.Commands.TestPathType]::Container) {
						# add recurse to parameters
						$RemoveItem['Recurse'] = $true
					}

					# remove item
					$null = Remove-Item @RemoveItem
				}
			}
			Catch {
				Throw $_
			}

			# test path after attempting to remove path
			Try {
				$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
					Param($ArgumentList)
					Test-Path -Path $ArgumentList['Path'] -PathType $ArgumentList['PathType']
				}
			}
			Catch {
				Throw $_
			}

			# if path not found after attempt to remove path...
			If (!$TestPath) {
				# return true
				Return $true
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
		Return $false
	}

	Function Assert-VMNotFound {
		[CmdletBinding()]
		Param(
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
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		Catch {
			Throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['VMId'] = $VMId

		################################################
		# locate planned VM
		################################################

		# retrieve name of planned VM if found by Id
		Try {
			$PlannedVM = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)

				# retrieve planned VM by Id
				$CimInstance = Get-CimInstance -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_PlannedComputerSystem' -Filter "Name = '$($ArgumentList['VMId'])'"

				# if planned VM found by Id...
				If ($CimInstance) {
					# return VM name
					Return $CimInstance.ElementName
				}
				# if planned VM not found by Id...
				Else {
					# return empty string
					Return [string]::Empty
				}
			}
		}
		Catch {
			Throw $_
		}

		# if planned VM found...
		If (![string]::IsNullOrEmpty($PlannedVM)) {
			# declare state and return false
			Write-Warning -Message "found planned VM by Id with '$PlannedVM' name on '$ComputerName' computer"
			Return $false
		}

		################################################
		# locate realized VM
		################################################

		# retrieve name of realized VM if found by Id
		Try {
			$RealizedVM = Invoke-Command @InvokeCommand -ScriptBlock {
				# import argument list hashtable
				Param($ArgumentList)

				# retrieve realized VM by Id
				$CimInstance = Get-CimInstance -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_ComputerSystem' -Filter "Name = '$($ArgumentList['VMId'])'"

				# if realized VM found by Id...
				If ($CimInstance) {
					# return VM name
					Return $CimInstance.ElementName
				}
				# if realized VM not found by Id...
				Else {
					# return empty string
					Return [string]::Empty
				}
			}
		}
		Catch {
			Throw $_
		}

		################################################
		# return state
		################################################

		# if planned VM and realized VM are empty strings...
		If ([string]::IsNullOrEmpty($PlannedVM) -and [string]::IsNullOrEmpty($RealizedVM)) {
			# return true
			Return $true
		}

		# if planned VM found and quiet not requested...
		If (![string]::IsNullOrEmpty($PlannedVM) -and !$Quiet) {
			# declare state
			Write-Warning -Message "found planned VM by Id with '$PlannedVM' name on '$ComputerName' computer"
		}

		# if realized VM found...
		If (![string]::IsNullOrEmpty($RealizedVM) -and !$Quiet) {
			# declare state
			Write-Warning -Message "found realized VM by Id with '$RealizedVM' name on '$ComputerName' computer"
		}

		# return false
		Return $false
	}

	Function Assert-VMRemoved {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[object]$VM,
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			# number of attempts to assert path action; default is 6 attempts
			[uint16]$Attempts = 6
		)

		################################################
		# prepare session
		################################################

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		Catch {
			Throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['Id'] = $VM.Id

		################################################
		# locate VMs before removal
		################################################

		# retrieve CIM instance for planned VM by Id
		Try {
			$PlannedVM = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				Get-CimInstance -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_PlannedComputerSystem' -Filter "Name = '$($ArgumentList['Id'])'"
			}
		}
		Catch {
			Throw $_
		}

		# retrieve CIM instance for realized VM by Id
		Try {
			$RealizedVM = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				Get-CimInstance -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_ComputerSystem' -Filter "Name = '$($ArgumentList['Id'])'"
			}
		}
		Catch {
			Throw $_
		}

		# if planned VM and realized VM not found before first attempt to remove VM...
		If (!$PlannedVM -and !$RealizedVM) {
			# return
			Return $true
		}

		################################################
		# remove planned VM
		################################################

		# if planned VM found...
		If ($PlannedVM) {
			# if planned VM found still in migrating state...
			If ($PlannedVM.OperationalStatus -contains '32774') {
				# declare state
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...found planned VM in migrating state, waiting for planned VM to exit state..."

				# initialize counter
				$Counter = [int32]0

				# while counter less than attempts and planned VM found still in migrating state...
				While ($Counter -lt $Attempts -and $PlannedVM.OperationalStatus -contains '32774') {
					# increment counter
					$Counter++

					# sleep
					Start-Sleep -Seconds 5

					# retrieve CIM instance for planned VM by Id
					Try {
						$PlannedVM = Invoke-Command @InvokeCommand -ScriptBlock {
							Param($ArgumentList)
							Get-CimInstance -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_PlannedComputerSystem' -Filter "Name = '$($ArgumentList['Id'])'"
						}
					}
					Catch {
						Throw $_
					}
				}

				# if planned VM not found in migrating state...
				If ($PlannedVM.OperationalStatus -contains '32774') {
					# declare state and set boolean
					Write-Warning -Message 'found planned VM still in migrating state after 30 seconds'
					$PlannedVMStuckInMigratingState = $true
				}
				Else {
					# declare state
					Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...found planned VM has exited migrating state, removing VM..."
				}
			}
			Else {
				# declare state
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...found planned VM, removing VM..."
			}

			# initialize counter
			$Counter = [int32]1

			# while counter less than attempts and planned VM found not in migrating state...
			While ($Counter -lt $Attempts -and $PlannedVM -and -not $PlannedVMStuckInMigratingState) {
				# remove planned VM by Id
				Try {
					$null = Invoke-Command @InvokeCommand -ScriptBlock {
						Param($ArgumentList)
						$VM = Get-VM -Id $ArgumentList['Id']
						$VM | Remove-VM -Force
					}
				}
				Catch {
					Throw $_
				}

				# increment counter
				$Counter++

				# sleep
				Start-Sleep -Seconds 5

				# retrieve CIM instance for planned VM by Id
				Try {
					$PlannedVM = Invoke-Command @InvokeCommand -ScriptBlock {
						Param($ArgumentList)
						Get-CimInstance -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_PlannedComputerSystem' -Filter "Name = '$($ArgumentList['Id'])'"
					}
				}
				Catch {
					Throw $_
				}
			}

			# if planned VM still found...
			If ($PlannedVM) {
				# declare state
				Write-Warning -Message 'could not remove planned VM after 30 seconds'
			}
		}

		################################################
		# remove realized VM
		################################################

		# if realized VM found...
		If ($RealizedVM) {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...found realized VM, removing VM..."

			# initialize counter
			$Counter = [int32]0

			# while counter less than attempts and realized VM found...
			While ($Counter -lt $Attempts -and $RealizedVM) {
				# increment counter
				$Counter++

				# remove realized VM by Id
				Try {
					$null = Invoke-Command @InvokeCommand -ScriptBlock {
						Param($ArgumentList)
						$VM = Get-VM -Id $ArgumentList['Id']
						$VM | Remove-VM -Force
					}
				}
				Catch {
					Throw $_
				}

				# sleep
				Start-Sleep -Seconds 5

				# retrieve CIM instance for realized VM by Id
				Try {
					$RealizedVM = Invoke-Command @InvokeCommand -ScriptBlock {
						Param($ArgumentList)
						Get-CimInstance -Namespace 'Root\Virtualization\V2' -ClassName 'Msvm_ComputerSystem' -Filter "Name = '$($ArgumentList['Id'])'"
					}
				}
				Catch {
					Throw $_
				}
			}

			# if realized VM still found...
			If ($RealizedVM) {
				# declare state
				Write-Warning -Message 'could not remove realized VM after 30 seconds'
			}
		}

		################################################
		# return state
		################################################

		# if planned VM and realized VM not found after attempts to remove...
		If (!$PlannedVM -and !$RealizedVM) {
			Return $true
		}
		# if planned VM and realized VM not found after attempts to remove...
		Else {
			Return $false
		}
	}

	Function Resolve-VMCompatibilityReport {
		Param(
			[Parameter(Mandatory)]
			[Microsoft.HyperV.PowerShell.VMCompatibilityReport]$CompatibilityReport
		)

		# add note properties to compatibility report
		Add-Member -InputObject $CompatibilityReport -MemberType 'NoteProperty' -Name 'CannotResolve' -Value $false
		Add-Member -InputObject $CompatibilityReport -MemberType 'NoteProperty' -Name 'CannotResolveMessages' -Value ([System.Collections.Generic.List[string]]::new())

		# extract computer name from compatibility report
		$ComputerName = $CompatibilityReport.VM.ComputerName

		# if one or more VM switch references incompatibilites reported...
		If (33012 -in $CompatibilityReport.Incompatibilities.MessageID) {
			# define parameters for Get-VMSwitch
			$GetVMSwitch = @{
				ComputerName = $ComputerName
				# SwitchType   = [Microsoft.HyperV.PowerShell.VMSwitchType]::External
				ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
			}

			# get external VM switches
			Try {
				$VMSwitch = Get-VMSwitch @GetVMSwitch
			}
			Catch {
				Throw $_
			}

			# get external VM switch names
			$SwitchNames = $VMSwitch | Select-Object -ExpandProperty Name

			# if switchname parameter provided but not found in external VM switch names...
			If ($script:PSBoundParameters.ContainsKey('SwitchName') -and $script:PSBoundParameters['SwitchName'] -notin $SwitchNames ) {
				# warn and inquire
				Write-Warning -Message "could not locate '$script:SwitchName' switch on '$ComputerName' computer; attempt to connect VM to another available external switch?" -WarningAction Inquire

				# clear SwitchName
				$null = $SwitchName
			}
		}

		# process each incompatibility
		:NextIncompatibility ForEach ($Incompatibility in $CompatibilityReport.Incompatibilities) {
			switch ($Incompatibility.MessageID) {
				# target does not have VM switch references in VM configuration
				33012 {
					# get VM network adapter from report
					Try {
						$VMNetworkAdapterName = $Incompatibility.Source.Name
					}
					Catch {
						$CompatibilityReport.CannotResolve = $true
						$CompatibilityReport.CannotResolveMessages.Add("Could not retrieve VM network adapter name from incompatibility object: '$($_.Exception.Message)'")
						Continue NextIncompatibility
					}

					# if switch name not provided or forced to null...
					If ([string]::IsNullOrEmpty($SwitchName)) {
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
							Default {
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
									Default {
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
					If ([string]::IsNullOrEmpty($SwitchName)) {
						# ...disconnect VM network adapter
						Try {
							$Incompatibility.Source | Disconnect-VMNetworkAdapter
						}
						Catch {
							$CompatibilityReport.CannotResolve = $true
							$CompatibilityReport.CannotResolveMessages.Add("Could not disconnect '$VMNetworkAdapterName' VM network adapter on '$Name' VM to address VM switch incompatibility: '$($_.Exception.Message)'")
							Continue NextIncompatibility
						}
					}
					# if switch name is not null...
					Else {
						# ...reconnect VM network adapter to new switch
						Try {
							$Incompatibility.Source | Connect-VMNetworkAdapter -SwitchName $SwitchName
							# $Incompatibility.Source | Disconnect-VMNetworkAdapter -Passthru | Connect-VMNetworkAdapter -SwitchName $SwitchName
						}
						Catch {
							$CompatibilityReport.CannotResolve = $true
							$CompatibilityReport.CannotResolveMessages.Add("Could not connect '$VMNetworkAdapterName' VM network adapter on '$Name' VM to '$SwitchName' switch to address VM switch incompatibility: '$($_.Exception.Message)'")
							Continue NextIncompatibility
						}
					}
				}
				# target has an incompatibility with imported VM not addressed above
				Default {
					$CompatibilityReport.CannotResolve = $true
					$CompatibilityReport.CannotResolveMessages.Add("found unhandled incompatibility with '$($Incompatibility.MessageID) and message: '$($Incompatibility.Message)'")
					Continue NextIncompatibility
				}
			}
		}

		# return updated compatibility object
		Return $CompatibilityReport
	}

	Function Move-VMToComputer {
		Param(
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
		Try {
			$CompatibilityReport = Compare-VM -VM $VM -DestinationHost $DestinationHost @Parameters
		}
		Catch {
			Write-Warning -Message "could not compare VM: $($_.Exception.Message)"
			Return $_
		}

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM compared"

		# save original compatibility report to global scope
		New-Variable -Name 'OriginalCompatibilityReport' -Value $CompatibilityReport -Scope Global -Force

		################################################
		# resolve incompatibilities
		################################################

		# if incompatibilities found...
		If ($CompatibilityReport.Incompatibilities.Count) {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - resolving compatibility report for VM..."

			# resolve incompatibilities
			Try {
				$CompatibilityReport = Resolve-VMCompatibilityReport -CompatibilityReport $CompatibilityReport
			}
			Catch {
				Write-Warning -Message "could not resolve incompatibilities: $($_.Exception.Message)"
				Return $CompatibilityReport.VM
			}

			# save resolved compatibility report to global scope
			New-Variable -Name 'ResolvedCompatibilityReport' -Value $CompatibilityReport -Scope Global -Force

			# if incompatibilities could not be resolved...
			If ($CompatibilityReport.CannotResolve) {
				# loop through cannot resolve messages
				ForEach ($CannotResolveMessage in $CompatibilityReport.CannotResolveMessages) {
					# report message
					Write-Warning -Message "found cannot resolve message: $CannotResolveMessage"
				}

				# return VM from compatibility report
				Return $CompatibilityReport.VM
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
		Try {
			$MovedVM = Move-VM -CompatibilityReport $CompatibilityReport -Passthru
		}
		Catch {
			Write-Warning -Message "could not move VM: $($_.Exception.Message)"
		}

		# if VM move completed...
		If ($MovedVM) {
			# report and return VM returned by move function
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...move completed"
			Return $MovedVM
		}
		Else {
			# report and return VM from compatibility report
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...move failed"
			Return $CompatibilityReport.VM
		}
	}

	Function Remove-VMOnComputer {
		Param(
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
		ForEach ($VHDPath in $VHDPaths) {
			# get VHD parent path from VHD path
			$VHDParentPath = Split-Path -Path $VHDPath -Parent

			# trim VHD parent path
			$VHDParentPath = $VHDParentPath.TrimEnd('\')

			# if VHD parent path property not in VM path list and not null or empty...
			If ($VHDParentPath -notin $VMPaths -and -not [string]::IsNullOrEmpty($VHDParentPath)) {
				# add VHD parent path to VM path list
				$VMPaths.Add($VHDParentPath)
			}
		}

		# define VM path properties
		$VMPathProperties = 'Path', 'ConfigurationLocation', 'CheckpointFileLocation', 'SmartPagingFilePath', 'SnapshotFileLocation'

		# add VM path properties to VM path list
		ForEach ($VMPathProperty in $VMPathProperties) {
			# get VM path from VM property
			$VMPath = $VM | Select-Object -ExpandProperty $VMPathProperty

			# trim VM path
			$VMPath = $VMPath.TrimEnd('\')

			# if VM path property not in VM path list and not null or empty...
			If ($VMPath -notin $VMPaths -and -not [string]::IsNullOrEmpty($VMPath)) {
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
		}

		# check VM
		Try {
			$VMNotFound = Assert-VMNotFound @AssertVMNotFound
		}
		Catch {
			Throw $_
		}

		# if VM not found...
		If ($VMNotFound) {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM not found"
		}
		Else {
			# define parameters
			$AssertVMRemoved = @{
				VM           = $VM
				ComputerName = $ComputerName
			}

			# remove VM
			Try {
				$VMRemoved = Assert-VMRemoved @AssertVMRemoved
			}
			Catch {
				Throw $_
			}

			# if VM removed...
			If ($VMRemoved) {
				# declare state
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...removed VM"
			}
			Else {
				# return; warnings issued by function
				Return
			}
		}

		################################################
		# remove VM files
		################################################

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - checking VHDs..."

		# remove VM hard disk drive files
		ForEach ($VHDPath in $VHDPaths) {
			# define parameters
			$AssertPathNotFound = @{
				Path         = $VHDPath
				ComputerName = $ComputerName
				PathType     = [Microsoft.PowerShell.Commands.TestPathType]::Leaf
			}

			# test path
			Try {
				$PathNotFound = Assert-PathNotFound @AssertPathNotFound
			}
			Catch {
				Throw $_
			}

			# if path not found...
			If ($PathNotFound) {
				# declare state
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VHD not found: $VHDPath"
			}
			Else {
				# declare state
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...removing VHD: $VHDPath"

				# define parameters
				$AssertPathRemoved = @{
					Path         = $VHDPath
					ComputerName = $ComputerName
					PathType     = [Microsoft.PowerShell.Commands.TestPathType]::Leaf
				}

				# remove path
				Try {
					$PathRemoved = Assert-PathRemoved @AssertPathRemoved
				}
				Catch {
					Throw $_
				}

				# if path removed...
				If ($PathRemoved) {
					# declare state
					Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VHD removed"
				}
			}
		}

		################################################
		# remove VM folders
		################################################

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - checking VM folders..."

		# remove VM path folders
		ForEach ($VMPath in $VMPaths) {
			# define parameters
			$AssertPathNotFound = @{
				Path         = $VMPath
				ComputerName = $ComputerName
				PathType     = [Microsoft.PowerShell.Commands.TestPathType]::Container
			}

			# test path
			Try {
				$PathNotFound = Assert-PathNotFound @AssertPathNotFound
			}
			Catch {
				Throw $_
			}

			# if path not found...
			If ($PathNotFound) {
				# declare state
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM folder not found: $VMPath"
			}
			Else {
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
				Try {
					$PathRemoved = Assert-PathRemoved @AssertPathRemoved
				}
				Catch {
					Throw $_
				}

				# if path removed...
				If ($PathRemoved) {
					# declare state
					Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM folder removed"
				}
			}
		}
	}

	Function Restore-VMOnComputer {
		Param(
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
		Try {
			$ClusterName = Get-ClusterName -ComputerName $ComputerName
		}
		Catch {
			Throw $_
		}

		################################################
		# add VM to cluster
		################################################

		# if computer is clustered...
		If ($ClusterName) {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - adding VM to '$ClusterName' cluster..."

			# define parameters for Add-ClusterVirtualMachineRole
			$AddClusterVirtualMachineRole = @{
				Cluster        = $ClusterName
				VirtualMachine = $Name
				ErrorAction    = [System.Management.Automation.ActionPreference]::Stop
			}

			# add VM to cluster by ID
			Try {
				$ClusterGroup = Add-ClusterVirtualMachineRole @AddClusterVirtualMachineRole
			}
			Catch {
				Throw $_
			}

			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM clustered"

			# if original priority retrieved and cluster group priority does not match original priority...
			If ($script:Priority -and $ClusterGroup.Priority -ne $script:Priority) {
				# update cluster group
				Try {
					$ClusterGroup.Priority = $script:Priority
				}
				Catch {
					Throw $_
				}

				# declare state
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...updated cluster group priority to original value: $($script:Priority)"
			}
		}

		################################################
		# restore VM start action on computer
		################################################

		# if computer is not clustered...
		If ([string]::IsNullOrEmpty($ClusterName)) {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - restoring VM start action configuration..."

			# define parameters for Set-VM
			$SetVM = @{
				VM                   = $VM
				AutomaticStartAction = $script:AutomaticStartAction
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
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM configuration restored"
		}

		################################################
		# start VM on computer
		################################################

		# if VM was running before move...
		If ($State -eq 'Running' -and $VM.State -ne 'Running') {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - starting VM..."

			# define parameters for Start-VM
			$StartVM = @{
				VM          = $VM
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# start VM on computer
			Try {
				Start-VM @StartVM
			}
			Catch {
				Throw $_
			}

			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM started"
		}
	}
}

Process {
	################################################
	# check for VM on source computer
	################################################

	# if VM provided...
	If ($PSBoundParameters.ContainsKey('VM')) {
		# retrieve name from VM
		$Name = $VM.Name.ToLowerInvariant()
	}

	# declare state
	Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - checking source computer for VM..."

	# if name provided...
	If ($PSCmdlet.ParameterSetName.StartsWith('Name')) {
		# define required parameters for Get-VM
		$GetVM = @{
			Name         = $Name
			ComputerName = $ComputerName
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# get VM object from input
		Try {
			$VM = Get-VM @GetVM
		}
		Catch {
			Throw $_
		}
	}

	# check for snapshot
	If ($VM.ParentSnapshotId) {
		Write-Warning 'VM has an active snapshot. Remove or consolidate snapshots before migration'
		Return
	}

	# get VM properties
	$Id = $VM.Id
	$ComputerName = $VM.ComputerName.ToLowerInvariant()

	# check for Protected Users
	If ($Hostname -ne $ComputerName -and ([Security.Principal.WindowsIdentity]::GetCurrent().Groups | Where-Object { $_.Value -match '-525$' })) {
		Throw [System.UnauthorizedAccessException]::new('Users in the Protected Users group must run this script from the source hypervisor')
	}

	# get VM configuration for restoration
	$State = $VM.State
	$AutomaticStartAction = $VM.AutomaticStartAction

	################################################
	# check for VM on source cluster
	################################################

	# get cluster for source computer
	Try {
		$SourceClusterName = Get-ClusterName -ComputerName $ComputerName
	}
	Catch {
		Throw $_
	}

	# if source computer is clustered...
	If ($SourceClusterName) {
		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - checking if VM clustered on source computer..."

		# validate source cluster is accessible
		Try {
			$null = Get-Cluster -Name $SourceClusterName -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not reach '$SourceClusterName' cluster: $($_.Exception.Message)"
			Return $_
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
		If ($SourceClusterGroup) {
			# retrieve cluster priority
			$script:Priority = $SourceClusterGroup.Priority

			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM found on '$SourceClusterName' cluster with '$script:Priority' priority; will remove from cluster before migration"
		}
		Else {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM not found on '$SourceClusterName' cluster"
		}
	}

	################################################
	# check if target computer is clustered
	################################################

	# get cluster for target computer
	Try {
		$TargetClusterName = Get-ClusterName -ComputerName $DestinationHost
	}
	Catch {
		Throw $_
	}

	# if target computer is clustered...
	If ($TargetClusterName) {
		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$DestinationHost,$Name - checking if VM clustered on target computer..."

		# retrieve target cluster nodes
		Try {
			$TargetClusterNodes = Get-ClusterNode -Cluster $TargetClusterName -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not retrieves nodes from '$TargetClusterName' cluster: $($_.Exception.Message)"
			Return $_
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
		If ($TargetClusterGroup) {
			# declare state
			Write-Warning -Message "found VM on '$($TargetClusterGroup.OwnerNode.Name)' node in '$TargetClusterName' cluster"
			Return
		}
		Else {
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
	If ($TargetClusterName) {
		# define host type
		$HostType = 'target cluster node'

		# loop through nodes in target cluster
		ForEach ($TargetClusterNode in $TargetClusterNodes) {
			# add node name to sorted set
			$null = $TargetComputerNames.Add($TargetClusterNode.Name)
		}
	}
	# if target computer is not clustered...
	Else {
		# define host type
		$HostType = 'destination host'

		# add destination host to sorted set
		$TargetClusterNames.Add($DestinationHost)
	}

	# loop through target computer names
	ForEach ($TargetComputerName in $TargetComputerNames) {
		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$TargetComputerName,$Name - checking $HostType for VM..."

		# define required parameters
		$AssertVMNotFound = @{
			VM           = $VM
			ComputerName = $DestinationHost
		}

		# ensure VM not found on destination host
		Try {
			$VMNotFound = Assert-VMNotFound @AssertVMNotFound
		}
		Catch {
			Throw $_
		}

		# if VM found on destination host
		If (!$VMNotFound) {
			# return immediately; warnings were issued by function
			Return
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
	If ($PSBoundParameters.ContainsKey('DestinationStoragePath')) {
		# add destination storage path to list
		$VMPaths.Add($DestinationStoragePath)

		# add destination storage path to parameters
		$Parameters['DestinationStoragePath'] = $DestinationStoragePath

		# add include storage to parameters - required to move VHDs to destination storage
		$Parameters['IncludeStorage'] = $true
	}

	# if destination storage path not provided...
	If (!$PSBoundParameters.ContainsKey('DestinationStoragePath')) {
		# if virtual machine path not provided as parameter...
		If (!$PSBoundParameters.ContainsKey('VirtualMachinePath')) {
			# assume virtual machine path is same as path property on VM
			$VirtualMachinePath = $VM | Select-Object -ExpandProperty 'Path'
		}

		# add virtual machine path to list
		$VMPaths.Add($VirtualMachinePath)

		# add virtual machine path to parameters
		$Parameters['VirtualMachinePath'] = $VirtualMachinePath

		# define optional VM path properties
		$VMPathPropertyMap = @{
			SmartPagingFilePath  = 'SmartPagingFilePath'
			SnapshotFileLocation = 'SnapshotFilePath'
		}

		# add VM path properties to VM path list
		:NextVMPathProperty ForEach ($VMPathProperty in $VMPathPropertyMap.Keys) {
			# if VM path property not provided as parameter...
			If (!$PSBoundParameters.ContainsKey($VMPathProperty)) {
				Continue NextVMPathProperty
			}

			# get VM path from parameter
			$VMPath = $PSBoundParameters[$VMPathProperty]

			# trim VM path
			$VMPath = $VMPath.TrimEnd('\')

			# if VM path property in VM path list or null or empty...
			If ($VMPath -in $VMPaths -or [string]::IsNullOrEmpty($VMPath)) {
				Continue NextVMPathProperty
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
	# get VHD paths
	################################################

	# if destination storage path parameter not provided...
	If (!$PSBoundParameters.ContainsKey('DestinationStoragePath')) {
		# get VM hard disk drive
		$VHDPaths = Get-VMHardDiskDrive -VM $VM | Select-Object -ExpandProperty Path

		# if VHDs hashtable array not provided...
		If (!$PSBoundParameters.ContainsKey('VHDs')) {
			# create list for VHD strings
			$VHDsStringList = [System.Collections.Generic.List[string]]::new()

			# get VHD paths from array of VHD hashtables
			ForEach ($VHDPath in $VHDPaths) {
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
		ForEach ($VHD in $VHDs) {
			# if VHD is not a hashtable...
			If ($VHD -isnot [hashtable]) {
				Write-Warning -Message 'invalid VHDs parameter: found array member that is not a hashtable'
				$InvalidVHDArrayMember = $true
				Continue
			}

			# if source file path key missing...
			If (!$VHD.ContainsKey('SourceFilePath')) {
				# warn and update boolean
				Write-Warning -Message "invalid VHDs parameter: found hashtable in array missing required 'SourceFilePath' key"
				$InvalidVHDArrayMember = $true
				Continue
			}
			Else {
				$SourceFilePath = $VHD['SourceFilePath']
			}

			# if destination file path key missing...
			If (!$VHD.ContainsKey('DestinationFilePath')) {
				# warn and update boolean
				Write-Warning -Message "invalid VHDs parameter: found hashtable in array missing required 'DestinationFilePath' key"
				$InvalidVHDArrayMember = $true
				Continue
			}
			Else {
				$DestinationFilePath = $VHD['DestinationFilePath']
			}

			# if source file path value null or empty...
			If ([string]::IsNullOrEmpty($SourceFilePath)) {
				# warn and update boolean
				Write-Warning -Message "invalid VHDs parameter: found hashtable where 'SourceFilePath' value is null or empty"
				$InvalidVHDArrayMember = $true
				Continue
			}
			Else {
				$SourceFilePaths.Add($SourceFilePath)
			}

			# if destination file path value null or empty...
			If ([string]::IsNullOrEmpty($DestinationFilePath)) {
				# warn and update boolean
				Write-Warning -Message "invalid VHDs parameter: found hashtable where 'DestinationFilePath' value is null or empty"
				$InvalidVHDArrayMember = $true
				Continue NextVHD
			}
			Else {
				# add destination file path to list
				$DestinationFilePaths.Add($DestinationFilePath)
			}
		}

		# if any invalid VHD array members found...
		If ($InvalidVHDArrayMember) {
			Return
		}

		# define boolean for missing source file paths
		$SourceFilePathMissing = $false

		# loop through source file paths
		ForEach ($VHDPath in $SourceFilePaths) {
			# assert source file path exists
			Try {
				$TestPath = Assert-PathCreated -Path $VHD['SourceFilePath'] -ComputerName $ComputerName -PathType 'Leaf'
			}
			Catch {
				Throw $_
			}

			# if source file path not found...
			If (!$TestPath) {
				# warn and update boolean
				Write-Warning -Message "could not locate file for '$($VHD['SourceFilePath'])' path in 'SourceFilePath' value"
				$SourceFilePathMissing = $true
			}
		}

		# if any source file paths are missing...
		If ($SourceFilePathMissing) {
			Return
		}

		# loop through destination file paths
		ForEach ($VHDPath in $DestinationFilePaths) {
			# get VHD parent path from VHD path
			$VHDParentPath = Split-Path -Path $VHDPath -Parent

			# trim VHD parent path
			$VHDParentPath = $VHDParentPath.TrimEnd('\')

			# if VHD parent path property not in VM path list and not null or empty...
			If ($VHDParentPath -notin $VMPaths -and -not [string]::IsNullOrEmpty($VHDParentPath)) {
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
	If ($TargetClusterName -and -not $SkipClusteredStorageCheck) {
		# retrieve CSV paths from target computer
		Try {
			$ClusterSharedVolumePaths = Get-ClusterSharedVolumePaths -ComputerName $DestinationHost
		}
		Catch {
			Throw $_
		}

		# define boolean
		$VMPathsNotClustered = $false

		# loop through VM paths...
		:NextVMPath ForEach ($VMPath in $VMPaths) {
			# loop through CSV paths
			ForEach ($ClusterSharedVolumePath in $ClusterSharedVolumePaths) {
				# if VM path starts with CSV path...
				If ($VMPath.StartsWith($ClusterSharedVolumePath, [System.StringComparison]::InvariantCultureIgnoreCase)) {
					# continue with next VM path
					Continue NextVMPath
				}
			}

			# warn and update boolean
			Write-Warning -Message "found '$VMPath' path would not be on a Cluster Shared Volume on '$DestinationHost' computer"
			$VMPathsNotClustered = $true
		}

		# if any VM paths are not clustered...
		If ($VMPathsNotClustered) {
			Return
		}
	}

	################################################
	# assert path on target computer
	################################################

	# declare state
	Write-Host "$([datetime]::Now.ToString('s')),$DestinationHost,$Name - checking path(s) on destination..."

	# loop through paths...
	ForEach ($VMPath in $VMPaths) {
		# ensure path is created
		Try {
			$PathCreated = Assert-PathCreated -Path $VMPath -ComputerName $DestinationHost
		}
		Catch {
			Throw $_
		}

		# if path is not created...
		If (!$PathCreated) {
			Write-Warning -Message "could not create '$VMPath' path on '$DestinationHost' computer"
			Return
		}

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$DestinationHost,$Name - ...path found: $VMPath"
	}

	################################################
	# remove VM from source cluster
	################################################

	# if VM clustered on source computer...
	If ($SourceClusterGroup) {
		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - removing VM from '$SourceClusterName' cluster..."

		# remove cluster group and resources
		Try {
			Remove-ClusterGroup -Cluster $SourceClusterName -VMId $VM.Id -RemoveResources -Force
		}
		Catch {
			Return $_
		}

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM removed from '$SourceClusterName' cluster"
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - waiting for VM to refresh after cluster removal..."

		# while VM reports as clustered...
		While ($VM.IsClustered) {
			# update VM object after cluster removal
			Try {
				$VM = Get-VM -Id $VM.Id -ComputerName $VM.ComputerName
			}
			Catch {
				Return $_
			}
		}

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM refreshed after cluster removal"
	}

	################################################
	# move VM
	################################################

	# move VM to target computer
	Try {
		$MovedVM = Move-VMToComputer -VM $VM -DestinationHost $DestinationHost -Parameters $Parameters
	}
	Catch {
		Write-Warning -Message "could not move VM: $($_.Exception.Message)"
	}

	################################################
	# restore VM
	################################################

	# if VM moved to target...
	If ($MovedVM -and $MovedVM.VirtualMachineType -eq 'RealizedVirtualMachine') {
		# restore moved VM
		Try {
			Restore-VMOnComputer -VM $MovedVM
		}
		Catch {
			Write-Warning -Message "could not restore migrated VM: $($_.Exception.Message)"
		}
	}
	# if VM move failed...
	Else {
		# restore original VM
		Try {
			Restore-VMOnComputer -VM $VM
		}
		Catch {
			Write-Warning -Message "could not restore original VM: $($_.Exception.Message)"
		}
	}

	################################################
	# remove VM
	################################################

	# if VM moved to target...
	If ($MovedVM -and $MovedVM.VirtualMachineType -eq 'RealizedVirtualMachine') {
		# remove remnants of original VM
		Try {
			Remove-VMOnComputer -VM $VM
		}
		Catch {
			Write-Warning -Message "could not remove remnants of original VM: $($_.Exception.Message)"
		}

	}
	# if VM move failed and reference to planned VM exists...
	ElseIf ($MovedVM -and $MovedVM.VirtualMachineType -eq 'PlannedVirtualMachine') {
		# remove remnants of failed VM move
		Try {
			Remove-VMOnComputer -VM $MovedVM
		}
		Catch {
			Write-Warning -Message "could not remove remnants of planned VM: $($_.Exception.Message)"
		}
	}
}

End {
	# loop through sessions
	ForEach ($SessionName in $script:PSSessions.Keys) {
		# remove sessions created by this script
		Try {
			Remove-PSSession -Session $script:PSSessions[$SessionName]
		}
		Catch {
			Return $_
		}
	}
}
