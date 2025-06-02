#Requires -Modules "Hyper-V","FailoverClusters"

[CmdletBinding()]
param (
	# string for filtering name of VM switch on target computer
	[Parameter(DontShow)]
	[string]$SwitchNameHint = 'compute',
	# hostname of local computer
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant(),
	# VM object(s)
	[Parameter(ParameterSetName = 'VM', Mandatory = $true, ValueFromPipeline = $true)]
	[Microsoft.HyperV.PowerShell.VirtualMachine]$VM,
	# VM name(s)
	[Parameter(ParameterSetName = 'Name', Mandatory = $true, ValueFromPipeline = $true)]
	[string]$Name,
	# computer name of target computer
	[Parameter(Mandatory = $true)]
	[string]$DestinationHost,
	# path on target computer
	[Parameter()]
	[string]$DestinationStoragePath,
	# name of VM switch on target computer
	[Parameter()]
	[string]$SwitchName,
	# force shutdown of running VM
	[Parameter()]
	[switch]$Force,
	# start stopped VM after migration
	[Parameter()]
	[switch]$Restart,
	# upgrade VM version after import
	[Parameter()]
	[switch]$UpdateVmVersion,
	# computer name of source computer
	[Parameter()]
	[string]$ComputerName = $Hostname
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

	Function Test-PathOnDestinationHost {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$Path,
			[Parameter(Mandatory = $true)]
			[string]$DestinationHost,
			[switch]$IsEmpty
		)

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $DestinationHost
		}
		Catch {
			Throw $_
		}

		# update argument list
		$InvokeCommand['ArgumentList']['Path'] = $Path

		# test path before attempting to create path
		Try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				Test-Path -Path $ArgumentList['Path'] -PathType Container
			}
		}
		Catch {
			Throw $_
		}

		# if IsEmtpy requested...
		If ($TestPath -and $IsEmpty) {
			# retrieve file items in path
			Try {
				$Items = Invoke-Command @InvokeCommand -ScriptBlock {
					Param($ArgumentList)
					Get-ChildItem -Path $ArgumentList['Path'] -File -Force -Recurse
				}
			}
			Catch {
				Throw $_
			}

			# if file items found...
			If ($Items) {
				Return $false
			}
		}

		# return test path result
		Return $TestPath
	}

	Function Assert-PathCreated {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$Path,
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

		# update argument list
		$InvokeCommand['ArgumentList']['Path'] = $Path

		# test path before attempting to create path
		Try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				Test-Path -Path $ArgumentList['Path'] -PathType Container
			}
		}
		Catch {
			Throw $_
		}

		# if path found before attempting to create path...
		If ($TestPath) {
			Return $true
		}

		# create path
		Try {
			Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				$null = New-Item -Path $ArgumentList['Path'] -ItemType Directory -Force
			}
		}
		Catch {
			Throw $_
		}

		# test path before attempting to create path
		Try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				Test-Path -Path $ArgumentList['Path'] -PathType Container
			}
		}
		Catch {
			Throw $_
		}

		# return test path result
		Return $TestPath
	}

	Function Assert-PathRemoved {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$Path,
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

		# update argument list
		$InvokeCommand['ArgumentList']['Path'] = $Path

		# test path before attempting to remove path
		Try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				Test-Path -Path $ArgumentList['Path'] -PathType Container
			}
		}
		Catch {
			Throw $_
		}

		# if path not found before attempting to remove path...
		If (!$TestPath) {
			Return $true
		}

		# if path found before attempting to remove path...
		If ($TestPath) {
			# remove path
			Try {
				Invoke-Command @InvokeCommand -ScriptBlock {
					Param($ArgumentList)
					$null = Remove-Item -Path $ArgumentList['Path'] -Recurse -Force -ErrorAction SilentlyContinue
				}
			}
			Catch {
				Throw $_
			}
		}

		# test path before attempting to remove path
		Try {
			$TestPath = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)
				Test-Path -Path $ArgumentList['Path'] -PathType Container
			}
		}
		Catch {
			Throw $_
		}

		# return test path result (inverted for remove)
		Return !$TestPath
	}

	Function Export-VMToComputer {
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

		$Id = $VM.Id
		$Name = $VM.Name.ToLowerInvariant()
		$SourceComputerName = $VM.ComputerName.ToLowerInvariant()
		$TargetComputerName = $ComputerName.ToLowerInvariant()

		################################################
		# get source computer identity
		################################################

		# declare state
		Write-Host "$SourceComputerName - retrieving computer identity..."

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

		# declare state
		Write-Host "$SourceComputerName - ...retrieved NTAccount for computer"

		################################################
		# add source to Administrators group on target
		################################################

		# declare state
		Write-Host "$TargetComputerName - adding '$NTAccount' to Administrators group..."

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $TargetComputerName
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
		Write-Host "$TargetComputerName - ...added '$NTAccount' to Administrators group"

		################################################
		# test path from source
		################################################

		# declare state
		Write-Host "$SourceComputerName - verifying access to UNC path..."

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $SourceComputerName
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
		Write-Host "$SourceComputerName - ...verified access to UNC path"

		################################################
		# remove VM from source cluster
		################################################

		# declare state
		Write-Host "$SourceComputerName,$Name - preparing VM for offline migration..."

		# get source computer cluster name
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
			Write-Host "$SourceComputerName,$Name - ...removed VM from source cluster"
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
			Write-Host "$SourceComputerName,$Name - ...shut down VM"
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
		Write-Host "$SourceComputerName,$Name - ...VM ready for offline migration"

		################################################
		# export VM
		################################################

		# declare state
		Write-Host "$SourceComputerName,$Name - exporting VM..."

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
			Write-Host "$SourceComputerName,$Name - ...exported VM"
		}

		################################################
		# remove source from Administrators group on target
		################################################

		# declare state
		Write-Host "$TargetComputerName - removing '$NTAccount' from Administrators group..."

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $TargetComputerName
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
		Write-Host "$TargetComputerName - ...removed '$NTAccount' from Administrators group"

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

		$Id = $VM.Id
		$Name = $VM.Name.ToLowerInvariant()
		$Vmcx = "$Name\Virtual Machines\$Id.vmcx"
		$ComputerName = $ComputerName.ToLowerInvariant()

		################################################
		# check paths on target computer
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
		$InvokeCommand['ArgumentList']['Vmcx'] = $Vmcx

		# create target path
		Try {
			$PathForImport = Invoke-Command @InvokeCommand -ScriptBlock {
				Param($ArgumentList)

				# define parameters for Join-Path
				$JoinPath = @{
					Path      = $ArgumentList['Path']
					ChildPath = $ArgumentList['Vmcx']
				}

				# get full path to VMCX file
				Join-Path @JoinPath
			}
		}
		Catch {
			Throw $_
		}

		################################################
		# get target computer objects
		################################################

		# define parameters for Get-VMSwitch
		$GetVMSwitch = @{
			ComputerName = $ComputerName
			SwitchType   = [Microsoft.HyperV.PowerShell.VMSwitchType]::External
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
		Try {
			$SwitchNames = $VMSwitch | Select-Object -ExpandProperty Name
		}
		Catch {
			Throw $_
		}

		################################################
		# compare VM
		################################################

		# declare state
		Write-Host "$ComputerName,$Name - comparing VM with target..."

		# define parameters for Compare-VM
		$CompareVM = @{
			Path         = $PathForImport
			ComputerName = $ComputerName
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# compare VM with target computer
		Try {
			$CompatibilityReport = Compare-VM @CompareVM
		}
		Catch {
			Throw $_
		}

		################################################
		# address VM incompatibility with target
		################################################

		# process each incompatibility
		ForEach ($Incompatibility in $CompatibilityReport.Incompatibilities) {
			switch ($Incompatibility.MessageID) {
				# target does not have VM switch references in VM configuration
				33012 {
					# get VM network adapter from report
					Try {
						$VMNetworkAdapterName = $Incompatibility.Source.Name
					}
					Catch {
						Write-Warning -Message 'Could not retrieve VM network adapter name from incompatibility object'
						Throw $_
					}

					# if switchname parameter not found in external VM switch names...
					If ( $SwitchName -notin $SwitchNames ) {
						# ...clear SwitchName
						$null = $SwitchName
					}

					# if switch name not provided or forced to null...
					If ([string]::IsNullOrEmpty($SwitchName)) {
						# switch on count of switchnames
						switch ($SwitchNames.Count) {
							# no external switches found
							0 {
								Write-Warning -Message "No external switches found on target server. VM network adapter '$VMNetworkAdapterName' will not be connected after import." -WarningAction Inquire
								$SwitchName = $null
							}
							# one external switch found
							1 {
								Write-Warning -Message "VM network adapter '$VMNetworkAdapterName' will be connected to VM switch '$SwitchNames'" -WarningAction Continue
								$SwitchName = $SwitchNames
							}
							# multiple external switches found
							Default {
								# get external "compute" switches by name
								$ComputeSwitchNames = $SwitchNames | Where-Object { $_.Contains($SwitchNameHint) }
								switch ($ComputeSwitchNames.Count) {
									# no external switches with compute in the name found
									0 {
										# sort external switches by name and select first switch
										$SwitchName = $SwitchNames | Sort-Object | Select-Object -First 1
										Write-Warning -Message "VM network adapter '$VMNetworkAdapterName' will be connected to first available external switch: '$SwitchNames'" -WarningAction Continue
										$SwitchName = $ComputeSwitchNames
									}
									# one external switch found
									1 {
										$SwitchName = $ComputeSwitchNames
										Write-Warning -Message "VM network adapter '$VMNetworkAdapterName' will be connected to the located external 'compute' switch: '$SwitchNames'" -WarningAction Continue
									}
									Default {
										# sort external "compute" switches by name and select first switch
										$SwitchName = $ComputeSwitchNames | Sort-Object | Select-Object -First 1
										Write-Warning -Message "VM network adapter '$VMNetworkAdapterName' will be connected to first available external 'compute' switch '$SwitchNames'" -WarningAction Continue
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
							Write-Warning -Message 'Could not disconnect VM network adapter to address VM switch incompatibility'
							Throw $_
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
							Write-Warning -Message 'Could not reconnect VM network adapter to address VM switch incompatibility'
							Throw $_
						}
					}
				}
				# target has an incompatibility with imported VM not addressed above
				Default {
					$CannotImport = $true
					Write-Warning -Message "Target computer reported an unhandled incompatibility: '$($Incompatibility.Message)'"
				}
			}
		}

		# return
		If ($CannotImport) {
			Return $CompatibilityReport.VM
		}

		# declare state
		Write-Host "$ComputerName,$Name - ...VM compared to target"

		################################################
		# import VM
		################################################

		# declare state
		Write-Host "$ComputerName,$Name - importing VM..."

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
			Write-Host "$ComputerName,$Name - ...imported VM"
		}

		################################################
		# update VM version
		################################################

		# if VM version upgrade skip requested...
		If (!$UpdateVmVersion) {
			# ...return VM before version upgrade
			Return $ImportedVM
		}

		# define parameters for Get-VMHost
		$GetVMHost = @{
			ComputerName = $ComputerName
			ErrorAction  = [System.Management.Automation.ActionPreference]::Stop
		}

		# get VM host
		Try {
			$VMHost = Get-VMHost @GetVMHost
		}
		Catch {
			Throw $_
		}

		# get VM host highest supported VM version
		Try {
			$HighestSupportedVmVersion = $VMHost.SupportedVmVersions | ForEach-Object { [decimal]$_ } | Sort-Object | Select-Object -Last 1
		}
		Catch {
			Throw $_
		}

		# if VM version is less than highest supported VM version...
		If ($ImportedVM.Version -lt $HighestSupportedVmVersion) {
			# declare state
			Write-Host "$ComputerName,$Name - updating VM version from: $($ImportedVM.Version)"

			# define required parameters for Update-VMVersion
			$UpdateVMVersion = @{
				VM          = $ImportedVM
				Passthru    = $true
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
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
				Write-Host "$ComputerName,$Name - ...updated VM version: $($ImportedVM.Version)"
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

		$Id = $VM.Id.Guid
		$Name = $VM.Name.ToLowerInvariant()
		$ComputerName = $VM.ComputerName.ToLowerInvariant()

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

		################################################
		# get VM paths
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
		# remove VM object
		################################################

		# declare state
		Write-Host "$ComputerName,$Name - removing VM..."

		# define parameters for Remove-VM
		$RemoveVM = @{
			VM          = $VM
			Force       = $true
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# remove VM on computer
		Try {
			Remove-VM @RemoveVM
		}
		Catch {
			Throw $_
		}

		# declare state
		Write-Host "$ComputerName,$Name - ...VM removed"

		################################################
		# remove VM files
		################################################

		# declare state
		Write-Host "$ComputerName,$Name - removing VHDs..."

		# remove VM hard disk drive files
		ForEach ($VHDPath in $VHDPaths) {
			# declare state
			Write-Host "$ComputerName,$Name - ...removing VHD: $VHDPath"

			# update argument list with parameters for Remove-Item
			$InvokeCommand['ArgumentList']['RemoveItem'] = @{
				Path        = $VHDPath
				Force       = $true
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# remove VHD on source computer
			Try {
				Invoke-Command @InvokeCommand -ScriptBlock {
					Param($ArgumentList)

					# define parameters for Remove-Item
					$RemoveItem = $ArgumentList['RemoveItem']

					# remove VHD
					Remove-Item @RemoveItem

					# test VHD
					$TestPath = Test-Path -Path $RemoveItem['Path'] -PathType Leaf

					# if VHD still exists...
					If ($TestPath) {
						# declare state
						Write-Warning 'VHD queued for removal but still present; waiting for up to 30 seconds'

						# initialize counter
						$Counter = [int32]1
					}

					# while VHD still exist and counter lesss than 7...
					While ($TestPath -and $Counter -lt 7) {
						# increment counter
						$Counter++
						# sleep
						Start-Sleep -Seconds 5
						# test VHD
						$TestPath = Test-Path -Path $RemoveItem['Path'] -PathType Leaf
					}

					# if VHD still exists...
					If ($TestPath) {
						# declare state
						Write-Warning 'VHD not removed after 30 seconds'
					}
				}
			}
			Catch {
				Throw $_
			}

			# declare state
			Write-Host "$ComputerName,$Name - ...removed VHD"
		}

		################################################
		# remove VM folders
		################################################

		# declare state
		Write-Host "$ComputerName,$Name - removing VM files..."

		# remove VM path folders
		ForEach ($VMPath in $VMPaths) {
			# update argument list
			$InvokeCommand['ArgumentList']['Path'] = $VMPath

		}

		################################################
		# remove VM folders
		################################################

		# declare state
		Write-Host "$ComputerName,$Name - removing VM folders..."

		# remove VM path folders
		ForEach ($VMPath in $VMPaths) {
			# update argument list with parameters for Get-ChildItem
			$InvokeCommand['ArgumentList']['GetChildItem'] = @{
				Path        = $VMPath
				File        = $true
				Force       = $true
				Recurse     = $true
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# get any files in VM path
			Try {
				$ChildItems = Invoke-Command @InvokeCommand -ScriptBlock {
					Param($ArgumentList)

					# define parameters for Get-ChildItem
					$GetChildItem = $ArgumentList['GetChildItem']

					# get child items
					Get-ChildItem @GetChildItem
				}
			}
			Catch {
				Throw $_
			}

			# if child items found...
			If ($ChildItems | Where-Object { $_.BaseName -ne $Id }) {
				# ...warn and return
				Write-Warning -Message "Path is not empty: '$VMpath' on '$ComputerName'"
				Return
			}

			# update argument list with parameters for Get-ChildItem
			$InvokeCommand['ArgumentList']['RemoveItem'] = @{
				Path        = $VMPath
				Force       = $true
				Recurse     = $true
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# remove VHD on source computer
			Try {
				Invoke-Command @InvokeCommand -ScriptBlock {
					Param($ArgumentList)

					# define parameters for Remove-Item
					$RemoveItem = $ArgumentList['RemoveItem']

					# remove item
					Remove-Item @RemoveItem
				}
			}
			Catch {
				Throw $_
			}

			# declare state
			Write-Host "$ComputerName,$Name - ...removed: $VMPath"
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
			Write-Host "$ComputerName,$ClusterName - adding VM to cluster..."

			# define parameters for Add-ClusterVirtualMachineRole
			$AddClusterVirtualMachineRole = @{
				Cluster        = $ClusterName
				VirtualMachine = $Name
				ErrorAction    = [System.Management.Automation.ActionPreference]::Stop
			}

			# add VM to cluster by ID
			Try {
				$null = Add-ClusterVirtualMachineRole @AddClusterVirtualMachineRole
			}
			Catch {
				Throw $_
			}

			# declare state
			Write-Host "$ComputerName,$ClusterName - ...VM clustered"

			# define parameters for Get-ClusterGroup
			$GetClusterGroup = @{
				Cluster     = $ClusterName
				VMId        = $VM.Id
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# retrieve cluster group
			Try {
				$ClusterGroup = Get-ClusterGroup @GetClusterGroup
			}
			Catch {
				Throw $_
			}

			# update cluster group
			Try {
				$ClusterGroup.Priority = $script:Priority
			}
			Catch {
				Throw $_
			}

			# declare state
			Write-Host "$ComputerName,$ClusterName - ...VM cluster group updated"
		}

		################################################
		# restore VM start action on computer
		################################################

		# if computer is not clustered...
		If ([string]::IsNullOrEmpty($ClusterName)) {
			# declare state
			Write-Host "$ComputerName,$Name - restoring VM start action configuration..."

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
			Write-Host "$ComputerName,$Name - ...VM configuration restored"
		}

		################################################
		# start VM on computer
		################################################

		# if VM was running before export...
		If ($State -eq 'Running' -or $Restart) {
			# declare state
			Write-Host "$ComputerName,$Name - starting VM..."

            # if VM already running...
            If ($VM.State -eq 'Running') {
                # declare state and return
                Write-Host "$ComputerName,$Name - ...VM already started"
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
			Write-Host "$ComputerName,$Name - ...VM started"
		}
	}
}

Process {
	################################################
	# check for VM on source computer
	################################################

	# if name provided...
	If ($PSCmdlet.ParameterSetName -eq 'Name') {
		# define required parameters for Get-VM
		$GetVM = @{
			Name        = $Name
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# define optional parameters for Get-VM
		If ($PSBoundParameters['ComputerName']) {
			$GetVM['ComputerName'] = $ComputerName
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
	$Name = $VM.Name.ToLowerInvariant()
	$SourceComputerName = $VM.ComputerName.ToLowerInvariant()

	# check for Protected Users
	If ($Hostname -ne $SourceComputerName -and ([Security.Principal.WindowsIdentity]::GetCurrent().Groups | Where-Object { $_.Value -match '-525$' })) {
		Throw [System.UnauthorizedAccessException]::new('Users in the Protected Users group must run this script from the source hypervisor')
	}

	# get VM configuration for restoration
	$State = $VM.State
	$AutomaticStartAction = $VM.AutomaticStartAction

	################################################
	# retrieve path if not provided
	################################################

	# if destination storage path not provided as parameter...
	If (!$PSBoundParameters.ContainsKey('DestinationStoragePath')) {
		# assume destination storage path is same as VM path
		$DestinationStoragePath = $VM | Select-Object -ExpandProperty 'Path' | Split-Path -Parent
	}

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
		Write-Host "$ComputerName,$Name - checking if VM clustered on source computer..."

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

		# if source cluster group found...
		If ($SourceClusterGroup) {
			# retrieve cluster priority
			$Priority = $SourceClusterGroup.Priority

			# declare state
			Write-Host "$ComputerName,$Name - ...VM found on '$SourceClusterName' cluster with '$Priority' priority; will remove from cluster before migration"
		}
		Else {
			# declare state
			Write-Host "$ComputerName,$Name - ...VM not clustered on source computer"
		}
	}

	################################################
	# check for VM on target computer
	################################################

	# declare state
	Write-Host "$DestinationHost,$Name - checking if VM already migrated to target computer..."

	# define parameters for Get-VM on target computer
	$GetVM = @{
		Id           = $Id
		ComputerName = $DestinationHost
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
	If ($TargetVM -and $TargetVM.VirtualMachineType -eq 'RealizedVirtualMachine') {
		# warn and return
		Write-Warning -Message "found VM on '$DestinationHost' destination host with matching Id: $Id"
		Return
	}

	################################################
	# check for VM on target cluster
	################################################

	# get cluster for target server
	Try {
		$TargetClusterName = Get-ClusterName -ComputerName $DestinationHost
	}
	Catch {
		Throw $_
	}

	# if target computer is clustered...
	If ($TargetClusterName) {
		# declare state
		Write-Host "$DestinationHost,$Name - checking if VM already clustered on target computer..."

		# define parameters for Get-ClusterGroup
		$GetClusterGroup = @{
			Cluster     = $TargetClusterName
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

		# if cluster group for VM found on target cluster...
		If ($TargetClusterGroup) {
			# warn and return
			Write-Warning 'VM has already been migrated to target cluster'
			Return
		}

		# declare state
		Write-Host "$DestinationHost,$Name - ...VM not found via target computer"
	}


	################################################
	# get VM paths
	################################################

	# define VM path list
	$VMPaths = [System.Collections.Generic.List[string]]::new()

	# add destination storage path to list
	$VMPaths.Add($DestinationStoragePath)

	################################################
	# get target CSVs from target cluster
	################################################

	# if target computer is clustered...
	If ($TargetClusterName) {
		# eetrieve CSVs from target computer
		Try {
			$ClusterSharedVolumePaths = Get-ClusterSharedVolume -Cluster $TargetClusterName | Select-Object -ExpandProperty SharedVolumeInfo | Select-Object -ExpandProperty FriendlyVolumeName
		}
		Catch {
			Return $_
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
	Write-Host "$DestinationHost - checking path on destination..."

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
		Write-Host "$DestinationHost - ...path found: $VMPath"
	}

	################################################
	# build UNC path from source computer
	################################################

	# declare state
	Write-Host "$ComputerName - building UNC path..."

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
	Write-Host "$ComputerName - ...UNC path built: $SharePath"

	################################################
	# export VM
	################################################

	# export VM to path
	Try {
		$ExportedVM = Export-VMToComputer -VM $VM -ComputerName $DestinationHost -Path $SharePath
	}
	Catch {
		Throw $_
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
			Throw $_
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
			Throw $_
		}
	}
	# if VM export or import failed...
	Else {
		# restore original VM
		Try {
			Restore-VMOnComputer -VM $VM
		}
		Catch {
			Throw $_
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
			Throw $_
		}

	}
	# if VM exported but import failed...
	ElseIf ($ImportedVM -and $ImportedVM.VirtualMachineType -ne 'RealizedVirtualMachine') {
		# remove exported VM from target
		Try {
			Remove-VMOnComputer -VM $ImportedVM
		}
		Catch {
			Throw $_
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
