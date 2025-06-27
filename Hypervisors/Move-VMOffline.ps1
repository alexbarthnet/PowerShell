#Requires -Modules "Hyper-V","FailoverClusters"

[CmdletBinding()]
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
	# force shutdown of running VM
	[switch]$Force,
	# start stopped VM after migration
	[switch]$Restart,
	# upgrade VM version after import
	[switch]$UpdateVmVersion,
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
		# test path
		################################################

		# test path
		Try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				Test-Path -Path $ArgumentList['Path'] -PathType $ArgumentList['PathType']
			}
		}
		Catch {
			Throw $_
		}

		# return inverted value
		If ($TestPath) {
			Return $false
		}
		Else {
			Return $true
		}
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
		$InvokeCommand['ArgumentList']['ExcludedFileFilter'] = $ExcludedFileFilter

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
			# number of attempts to assert path action; default is 6 attempts
			[uint16]$Attempts = 6
		)

		################################################
		# define objects from VM properties
		################################################

		$Name = $VM.Name.ToLowerInvariant()
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
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - found planned VM in migrating state, waiting for planned VM to exit state..."

				# initialize counter
				$Counter = [int32]1

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
					# declare state
					Write-Warning -Message 'found planned VM still in migrating state after 30 seconds'
				}
				Else {
					# declare state
					Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...planned VM exited migrating state, removing planned VM..."
				}
			}
			Else {
				# declare state
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - found planned VM, removing..."
			}

			# initialize counter
			$Counter = [int32]1

			# while counter less than attempts and planned VM found...
			While ($Counter -lt $Attempts -and $PlannedVM) {
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
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - found VM, removing..."

			# initialize counter
			$Counter = [int32]1

			# while counter less than attempts and realized VM found...
			While ($Counter -lt $Attempts -and $RealizedVM) {
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

				# increment counter
				$Counter++

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

								# check
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

	Function Get-SmbShareForPath {
		Param(
			[Parameter(Mandatory = $true)]
			[string]$Path,
			[Parameter(Mandatory = $true)]
			[string]$ComputerName
		)

		# get SMB shares on target computer
		Try {
			$SmbShares = Get-SmbShare -CimSession $ComputerName -Special $true
		}
		Catch {
			Throw $_
		}

		# get first SMB share where path parameter starts with share path and share path not null or empty
		$SmbShare = $SmbShares | Sort-Object -Property 'Path' | Where-Object { $Path.StartsWith($_.Path, [System.StringComparison]::InvariantCultureIgnoreCase) -and -not [string]::IsNullOrEmpty($_.Path) } | Select-Object -First 1

		# define share path from path parameter and SMB share
		Try {
			$SharePath = $Path.Replace($SmbShare.Path, "\\$ComputerName\$($SmbShare.Name)\")
		}
		Catch {
			Throw $_
		}

		# return share path
		Return $SharePath
	}

	Function Export-VMToComputer {
		Param(
			[Parameter(Mandatory = $true)][ValidateScript({ $_ -is [Microsoft.HyperV.PowerShell.VirtualMachine] })]
			[object]$VM,
			[Parameter(Mandatory = $true)]
			[string]$DestinationHost,
			[Parameter(Mandatory = $true)]
			[string]$Path
		)

		################################################
		# define strings
		################################################

		$Id = $VM.Id
		$Name = $VM.Name.ToLowerInvariant()
		$ComputerName = $VM.ComputerName.ToLowerInvariant()

		################################################
		# get source computer identity
		################################################

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName - retrieving computer identity..."

		# define parameters for Get-CimInstance
		$GetCimInstance = @{
			ComputerName = $ComputerName
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

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName - ...retrieved NTAccount for computer"

		################################################
		# add source to Administrators group on target
		################################################

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$DestinationHost - adding '$NTAccount' to Administrators group..."

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $DestinationHost
		}
		Catch {
			Throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['LocalGroupMember'] = @{
			Group       = 'Administrators'
			Member      = $NTAccount
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# check target computer administrators group for source computer
		Try {
			$null = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)

				# define parameters for Get-LocalGroupMember and Add-LocalGroupMember
				$LocalGroupMember = $ArgumentList['LocalGroupMember']

				# verify source computer membership
				Try {
					# get source computer from target Administrators group
					Get-LocalGroupMember @LocalGroupMember
				}
				Catch {
					Try {
						# add source computer to target Administrators group
						Add-LocalGroupMember @LocalGroupMember
					}
					Catch {
						Throw $_
					}
				}
			}
		}
		Catch {
			Throw $_
		}

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$DestinationHost - ...added '$NTAccount' to Administrators group"

		################################################
		# test path from source
		################################################

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName - verifying access to UNC path..."

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
		}
		Catch {
			Throw $_
		}

		# update argument list with parameters for Get-Item
		$InvokeCommand['ArgumentList']['GetItem'] = @{
			Path        = $Path
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# test path on source
		Try {
			$null = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)

				# define parameters for Get-Item
				$GetItem = $ArgumentList['GetItem']

				# verify share path
				Get-Item @GetItem
			}
		}
		Catch {
			Write-Warning -Message "$($_.ToString())"
			Return
		}

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName - ...verified access to UNC path"

		################################################
		# remove VM from source cluster
		################################################

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - preparing VM for offline migration..."

		# get source computer cluster name
		Try {
			$SourceClusterName = Get-ClusterName -ComputerName $ComputerName
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

			# get cluster group for VM
			Try {
				$SourceClusterGroup = Get-ClusterGroup @GetClusterGroup
			}
			Catch {
				Throw $_
			}
		}

		# if source computer cluster has cluster group for VM...
		If ($SourceClusterGroup) {
			# define parameters for Get-ClusterGroup
			$RemoveClusterGroup = @{
				Cluster         = $SourceClusterName
				VMId            = $Id
				RemoveResources = $true
				Force           = $true
				ErrorAction     = [System.Management.Automation.ActionPreference]::Stop
			}

			# remove cluster group for VM
			Try {
				Remove-ClusterGroup @RemoveClusterGroup
			}
			Catch {
				Throw $_
			}

			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...removed VM from source cluster"
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

			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...shut down VM"
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
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM ready for offline migration"

		################################################
		# export VM
		################################################

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - exporting VM..."

		# define parameters for Export-VM
		$ExportVM = @{
			VM          = $VM
			Path        = $Path
			Passthru    = $true
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# export VM
		Try {
			$ExportedVM = Export-VM @ExportVM
		}
		Catch {
			Write-Warning -Message "VM export failed: $($_.ToString())"
		}

		# declare state
		If ($ExportedVM) {
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...exported VM"
		}

		################################################
		# remove source from Administrators group on target
		################################################

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$DestinationHost - removing '$NTAccount' from Administrators group..."

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $DestinationHost
		}
		Catch {
			Throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['LocalGroupMember'] = @{
			Group       = 'Administrators'
			Member      = $NTAccount
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# remove list of source computers from target computer administrators group
		Try {
			Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)

				# define parameters for Remove-LocalGroupMember
				$LocalGroupMember = $ArgumentList['LocalGroupMember']

				# remove source from target Administrators group
				Remove-LocalGroupMember @LocalGroupMember
			}
		}
		Catch {
			Throw $_
		}

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$DestinationHost - ...removed '$NTAccount' from Administrators group"

		# return objects
		If ($ExportedVM) {
			Return $ExportedVM
		}
		Else {
			Return $null
		}
	}

	Function Import-VMOnComputer {
		Param(
			[Parameter(Mandatory = $true)][ValidateScript({ $_ -is [Microsoft.HyperV.PowerShell.VirtualMachine] })]
			[object]$VM,
			[Parameter(Mandatory = $true)]
			[string]$ComputerName,
			[Parameter(Mandatory = $true)]
			[string]$Path
		)

		################################################
		# define strings
		################################################

		$Name = $VM.Name.ToLowerInvariant()
		$ComputerName = $ComputerName.ToLowerInvariant()

		################################################
		# build VMCX path for VM import
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
		$InvokeCommand['ArgumentList']['Name'] = $Name
		$InvokeCommand['ArgumentList']['Path'] = $Path

		# create target path
		Try {
			$PathForImport = Invoke-Command @InvokeCommand -ScriptBlock {
				# import arguments
				Param($ArgumentList)

				# define child path for VMCX file
				$ChildPath = '{0}\Virtual Machines\{1}.vmcx' -f $ArgumentList['Name'], $ArgumentList['Id']

				# define complete path to VMCX file
				Join-Path -Path $ArgumentList['Path'] -ChildPath $ChildPath
			}
		}
		Catch {
			Throw $_
		}

		################################################
		# compare VM
		################################################

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - comparing VM with target..."

		# define parameters for Compare-VM
		$CompareVM = @{
			Path         = $PathForImport
			ComputerName = $ComputerName
		}

		# compare VM with target computer
		Try {
			$CompatibilityReport = Compare-VM @CompareVM -ErrorAction 'Stop'
		}
		Catch [Microsoft.HyperV.PowerShell.VirtualizationException] {
			# if inner exception reports an invalid parameter (32773) during the 'Delete' operation of the compare...
			If ($_.Exception.InnerException.ErrorCode -eq 32773 -and $_.Exception.InnerException.Operation -eq 'Delete') {
				# compare VM with target computer a second time and ignore errors
				$CompatibilityReport = Compare-VM @CompareVM -ErrorAction 'Ignore'
			}
			Else {
				Throw $_
			}
		}
		Catch {
			Throw $_
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
		# import VM
		################################################

		# declare state
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - importing VM..."

		# define required parameters for Import-VM
		$ImportVM = @{
			CompatibilityReport = $CompatibilityReport
			ErrorAction         = [System.Management.Automation.ActionPreference]::Stop
		}

		# import VM on target computer
		Try {
			$ImportedVM = Import-VM @ImportVM
		}
		Catch {
			Write-Warning -Message "VM import failed: $($_.ToString())"
		}

		# declare state
		If ($ImportedVM) {
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...imported VM"
		}

		################################################
		# update VM version
		################################################

		# if VM version upgrade skip requested...
		If (!$UpdateVmVersion) {
			# ...return VM before version upgrade
			Return $ImportedVM
		}

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
		If ([decimal]$ImportedVM.Version -lt [decimal]$VMHostSupportedVersion.Version.ToString()) {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - updating VM version from: $($ImportedVM.Version)"

			# define required parameters for Update-VMVersion
			$UpdateVMVersion = @{
				VM          = $ImportedVM
				Passthru    = $true
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# define optional parameters for Update-VMVersion
			If ($script:PSBoundParameters.ContainsKey('Force')) {
				$UpdateVMVersion['Force'] = $script:Force
			}

			# update VM version
			Try {
				$ImportedVM = Update-VMVersion @UpdateVMVersion
			}
			Catch {
				Write-Warning -Message "Failed to update VM version: $($_.ToString())"
			}

			# declare state
			If ($ImportedVM.Version -eq $HighestSupportedVmVersion) {
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...updated VM version to: $($ImportedVM.Version)"
			}
		}

		# return VM
		Return $ImportedVM
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
		Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - removing VM..."

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
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...updated VM start restored"
		}

		################################################
		# start VM on computer
		################################################

		# if VM was running before export...
		If ($State -eq 'Running' -or $Restart) {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - starting VM..."

			# if VM already running...
			If ($VM.State -eq 'Running') {
				# declare state and return
				Write-Host "$([datetime]::Now.ToString('s')),$ComputerName,$Name - ...VM already started"
				Return
			}

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
	If ($PSCmdlet.ParameterSetName -eq 'Name') {
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

		# if VM not found on target computer...
		If ($VMNotFound) {
			# declare state
			Write-Host "$([datetime]::Now.ToString('s')),$DestinationHost,$Name - ...VM not found on $HostType"
		}
		# if VM found on destination host
		Else {
			# return immediately; warnings were issued by function
			Return
		}
	}

	################################################
	# get VM paths on source computer (sanitized)
	################################################

	# if destination storage path not provided as parameter...
	If (!$PSBoundParameters.ContainsKey('DestinationStoragePath')) {
		# assume destination storage path is same as VM path
		$DestinationStoragePath = $VM.Path
	}

	# if destination storage path ends with trailing backslash...
	If ($DestinationStoragePath.EndsWith('\')) {
		# trim trailing backslash
		$DestinationStoragePath = $DestinationStoragePath.TrimEnd('\')
	}

	# if destination storage path ends with a dedicated directory for the VM...
	If ($DestinationStoragePath.EndsWith($Name, [System.StringComparison]::InvariantCultureIgnoreCase)) {
		# remove VM folder from end of path
		$DestinationStoragePath = Split-Path -Path $DestinationStoragePath -Parent
		# warn about change
		Write-Warning -Message 'updated DestinationStoragePath to prevent twice-nested VM directory; Export-VM will create dedicated VM directory under DestinationStoragePath'
	}

	# define VM path list
	$VMPaths = [System.Collections.Generic.List[string]]::new()

	# add destination storage path to list
	$VMPaths.Add($DestinationStoragePath)

	################################################
	# test VM paths against CSVs on target
	################################################

	# if target computer is clustered...
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
	Write-Host "$([datetime]::Now.ToString('s')),$DestinationHost - checking path on destination..."

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
		Write-Host "$([datetime]::Now.ToString('s')),$DestinationHost - ...path found: $VMPath"
	}

	################################################
	# build UNC path from source computer
	################################################

	# declare state
	Write-Host "$([datetime]::Now.ToString('s')),$ComputerName - building UNC path..."

	# ensure path is created
	Try {
		$SharePath = Get-SmbShareForPath -Path $DestinationStoragePath -ComputerName $DestinationHost
	}
	Catch {
		Throw $_
	}

	# if share path is not created...
	If ([string]::IsNullOrEmpty($SharePath)) {
		Write-Warning -Message "could not create UNC path on '$ComputerName' computer to '$DestinationStoragePath' path on '$DestinationHost' computer"
		Return
	}

	# declare state
	Write-Host "$([datetime]::Now.ToString('s')),$ComputerName - ...UNC path built: $SharePath"

	################################################
	# export VM
	################################################

	# export VM to path
	Try {
		$ExportedVM = Export-VMToComputer -VM $VM -DestinationHost $DestinationHost -Path $SharePath
	}
	Catch {
		Write-Warning -Message "could not export VM: $($_.Exception.Message)"
	}

	################################################
	# import VM
	################################################

	# import VM on target computer
	If ($ExportedVM) {
		Try {
			$ImportedVM = Import-VMOnComputer -VM $VM -ComputerName $DestinationHost -Path $DestinationStoragePath
		}
		Catch {
			Write-Warning -Message "could not import VM: $($_.Exception.Message)"
		}
	}

	################################################
	# restore VM
	################################################

	# if VM was imported to target...
	If ($ImportedVM -and $ImportedVM.VirtualMachineType -eq 'RealizedVirtualMachine') {
		# restore imported VM
		Try {
			Restore-VMOnComputer -VM $ImportedVM
		}
		Catch {
			Write-Warning -Message "could not restore migrated VM: $($_.Exception.Message)"
		}
	}
	# if VM export or import failed...
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

	# if VM was imported to target...
	If ($ImportedVM -and $ImportedVM.VirtualMachineType -eq 'RealizedVirtualMachine') {
		# remove original VM
		Try {
			Remove-VMOnComputer -VM $VM
		}
		Catch {
			Write-Warning -Message "could not remove remnants of original VM: $($_.Exception.Message)"
		}

	}
	# if VM exported but import failed...
	ElseIf ($ImportedVM -and $ImportedVM.VirtualMachineType -ne 'RealizedVirtualMachine') {
		# remove exported VM from target
		Try {
			Remove-VMOnComputer -VM $ImportedVM
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
