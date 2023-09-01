#Requires -Modules "Hyper-V","FailoverClusters"

[CmdletBinding()]
param (
	# array of VM objects or VM names
	[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
	[object]$VM,
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
		Return $ClusterName
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
		$SourceComputerName = $VM.ComputerName

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
		Write-Host "$ComputerName - adding '$NTAccount' to Administrators group..."

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
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
		Write-Host "$ComputerName - ...added '$NTAccount' to Administrators group"

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
			Throw $_
		}

		# declare state
		Write-Host "$SourceComputerName - ...verified access to UNC path"

		################################################
		# remove VM from source cluster
		################################################

		# declare state
		Write-Host "$SourceComputerName - preparing VM for offline migration..."

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
			Write-Host "$SourceComputerName - ...removed VM from source cluster"
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
			Write-Host "$SourceComputerName - ...shut down VM"
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
		Write-Host "$SourceComputerName - ...VM ready for offline migration"

		################################################
		# export VM
		################################################

		# declare state
		Write-Host "$SourceComputerName - exporting VM..."

		# define parameters for Export-VM
		$ExportVM = @{
			VM          = $VM
			Path        = $Path
			Passthru    = $true
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# export VM
		Try {
			$OldVM = Export-VM @ExportVM
		}
		Catch {
			Write-Warning -Message "VM export failed: $($_.ToString())"
		}

		# declare state
		If ($OldVM) {
			Write-Host "$SourceComputerName - ...exported VM"
		}

		################################################
		# remove source to Administrators group on target
		################################################

		# declare state
		Write-Host "$ComputerName - removing '$NTAccount' from Administrators group..."

		# get hashtable for InvokeCommand splat
		Try {
			$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
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
		Write-Host "$ComputerName - ...removed '$NTAccount' from Administrators group"
	}

	Function Import-VMOnComputer {
		Param(
			[Parameter(Mandatory = $true)][ValidateScript({ $_ -is [Microsoft.HyperV.PowerShell.VirtualMachine] })]
			[object]$VM,
			[Parameter(Mandatory = $true)]
			[string]$ComputerName
		)

		################################################
		# define strings
		################################################

		$Id = $VM.Id
		$Name = $VM.Name
		$Vmcx = "$Name\Virtual Machines\$Id.vmcx"

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
		# compare VM
		################################################

		# declare state
		Write-Host "$Hostname,$ComputerName - comparing VM with target..."

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

		# process each incompatibility
		ForEach ($Incompatibility in $CompatibilityReport.Incompatibilities) {
			Write-Warning -Message "Target computer reported an incompatibility: '$($Incompatibility.Message)'"
		}

		# return
		If ($CompatibilityReport.Incompatibilities.Count -gt 0) {
			Return $CompatibilityReport.VM
		}

		# declare state
		Write-Host "$Hostname,$ComputerName - ...VM compared to target"

		################################################
		# import VM
		################################################

		# declare state
		Write-Host "$Hostname,$ComputerName - importing VM..."

		# define required parameters for Import-VM
		$ImportVM = @{
			CompatibilityReport = $CompatibilityReport
			ErrorAction         = [System.Management.Automation.ActionPreference]::Stop
		}

		# import VM on target computer
		Try {
			$NewVM = Import-VM @ImportVM
		}
		Catch {
			Write-Warning -Message "VM import failed: $($_.ToString())"
		}

		# declare state
		If ($NewVM) {
			Write-Host "$Hostname,$ComputerName - ...imported VM"
		}

		# return VM
		Return $NewVM
	}

	Function Remove-VMOnComputer {
		Param(
			[Parameter(Mandatory = $true)][ValidateScript({ $_ -is [Microsoft.HyperV.PowerShell.VirtualMachine] })]
			[object]$VM,
			[Parameter()]
			[string]$ComputerName = $VM.ComputerName.ToLowerInvariant()
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
		Write-Host "$Hostname,$ComputerName - removing VM..."

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
		Write-Host "$Hostname,$ComputerName - ...VM removed"

		################################################
		# remove VM files
		################################################

		# declare state
		Write-Host "$Hostname,$ComputerName - removing VHDs..."

		# remove VM hard disk drive files
		ForEach ($VHDPath in $VHDPaths) {
			# update argument list
			$InvokeCommand['ArgumentList']['Path'] = $VHDPath

			# remove VHD on source computer
			Try {
				Invoke-Command @InvokeCommand -ScriptBlock {
					Param($ArgumentList)

					# define parameters for Remove-Item
					$RemoveItem = @{
						Path        = $ArgumentList['Path']
						Force       = $true
						ErrorAction = [System.Management.Automation.ActionPreference]::Stop
					}

					# remove VHD
					Remove-Item @RemoveItem
				}
			}
			Catch {
				Throw $_
			}

			# declare state
			Write-Host "$Hostname,$ComputerName - ...removed: $VHDPath"
		}

		################################################
		# remove VM folders
		################################################

		# declare state
		Write-Host "$Hostname,$ComputerName - removing VM folders..."

		# remove VM path folders
		ForEach ($VMPath in $VMPaths) {
			# update argument list
			$InvokeCommand['ArgumentList']['Path'] = $VMPath

			# get any files in VM path
			Try {
				$ChildItems = Invoke-Command @InvokeCommand -ScriptBlock {
					Param($ArgumentList)

					# define parameters for Get-ChildItem
					$GetChildItem = @{
						Path        = $ArgumentList['Path']
						File        = $true
						Force       = $true
						Recurse     = $true
						ErrorAction = [System.Management.Automation.ActionPreference]::Stop
					}

					# get child items
					Get-ChildItem @GetChildItem
				}
			}
			Catch {
				Throw $_
			}

			# if child items found...
			If ($null -ne $ChildItems) {
				# ...warn and return
				Write-Warning -Message "Path is not empty: '$VMpath' on '$ComputerName'"
				Return
			}

			# remove VHD on source computer
			Try {
				Invoke-Command @InvokeCommand -ScriptBlock {
					Param($ArgumentList)

					# define parameters for Remove-Item
					$RemoveItem = @{
						Path        = $ArgumentList['Path']
						Force       = $true
						Recurse     = $true
						ErrorAction = [System.Management.Automation.ActionPreference]::Stop
					}

					# remove item
					Remove-Item @RemoveItem
				}
			}
			Catch {
				Throw $_
			}

			# declare state
			Write-Host "$Hostname,$ComputerName - ...removed: $VMPath"
		}
	}

	Function Restore-VMOnComputer {
		Param(
			[Parameter(Mandatory = $true)][ValidateScript({ $_ -is [Microsoft.HyperV.PowerShell.VirtualMachine] })]
			[object]$VM,
			[Parameter()]
			[string]$ComputerName = $VM.ComputerName.ToLowerInvariant()
		)

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
			Write-Host "$Hostname,$ClusterName - adding VM to cluster..."

			# define paramters for Add-ClusterVirtualMachineRole
			$AddClusterVirtualMachineRole = @{
				Cluster     = $ClusterName
				VMId        = $VM.Id
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
			Write-Host "$Hostname,$ClusterName - ...VM clustered"
		}

		################################################
		# restore VM start action on computer
		################################################

		# if computer is not clustered...
		If ([string]::IsNullOrEmpty($ClusterName)) {
			# declare state
			Write-Host "$Hostname,$ComputerName - restoring VM start action configuration..."

			# define parameters for Set-VM
			$SetVM = @{
				VM                   = $VM
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
			Write-Host "$Hostname,$ComputerName - ...VM configuration restored"
		}

		################################################
		# start VM on computer
		################################################

		# if VM was running before export...
		If ($State -eq 'Running' -or $Restart) {
			# declare state
			Write-Host "$Hostname,$ComputerName - starting VM..."

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
			Write-Host "$Hostname,$ComputerName - ...VM started"
		}
	}

	# declare state
	Write-Host "$Hostname - checking path on destination..."

	# get hashtable for InvokeCommand splat
	Try {
		$InvokeCommand = Get-PSSessionInvoke -ComputerName $ComputerName
	}
	Catch {
		Throw $_
	}

	# update argument list
	$InvokeCommand['ArgumentList']['GetItem'] = @{
		Path        = $Path
		ErrorAction	= [System.Management.Automation.ActionPreference]::Stop
	}

	# test path on destination
	Try {
		$null = Invoke-Command @InvokeCommand -ScriptBlock {
			Param($ArgumentList)

			# define parameters for Get-Item
			$GetItem = $ArgumentList['GetItem']

			# get path
			Get-Item @GetItem
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
	Try {
		$SharePath = $Path.Replace($SmbShare.Path, "\\$ComputerName\$($SmbShare.Name)\")
	}
	Catch {
		Throw $_
	}

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
	Write-Host "$Hostname - checking target computer for VM..."

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
	If ($TargetVM -and $TargetVM.VirtualMachineType -eq 'RealizedVirtualMachine') {
		# warn and return
		Write-Warning 'VM has already been migrated to target server'
		$TargetVM | Format-List *
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

	# declare state
	Write-Host "$Hostname - ...VM not found via target computer"

	################################################
	# export VM
	################################################

	# export VM to path
	If ($OldVM) {
		Try {
			$OldVM = Export-VMToComputer -VM $VM -ComputerName $ComputerName -Path $Path
		}
		Catch {
			Throw $_
		}
	}

	################################################
	# import VM
	################################################

	# import VM on target computer
	If ($OldVM) {
		Try {
			$NewVM = Import-VMOnComputer -VM $VM -ComputerName $ComputerName
		}
		Catch {
			Throw $_
		}
	}

	################################################
	# restore VM
	################################################

	# if VM was imported to target cluster...
	If ($NewVM -and $NewVM.VirtualMachineType -eq 'RealizedVirtualMachine') {
		# ...restore imported VM
		Try {
			Restore-VMOnComputer -VM $NewVM
		}
		Catch {
			Throw $_
		}
	}
	# if VM export or import failed...
	Else {
		# ...restore original VM
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

	# if VM was imported to target cluster...
	If ($NewVM -and $NewVM.VirtualMachineType -eq 'RealizedVirtualMachine') {
		# ...remove original VM
		Try {
			Remove-VMOnComputer -VM $VM
		}
		Catch {
			Throw $_
		}

	}
	# if VM exported but import failed...
	ElseIf ($NewVM -and $NewVM.VirtualMachineType -ne 'RealizedVirtualMachine') {
		# ...remove exported VM from target
		Try {
			Remove-VMOnComputer -VM $NewVM
		}
		Catch {
			Throw $_
		}
	}
}

End {

}
