#Requires -Modules "Hyper-V","FailoverClusters"

[CmdletBinding(DefaultParameterSetName = 'Default')]
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
    [Parameter(ParameterSetName = 'Consolidate')]
    [string]$DestinationStoragePath,
    # path for virtual machine
    [Parameter(ParameterSetName = 'Default')]
    [string]$VirtualMachinePath,
    # array of hashtables for VHDs
    [Parameter(ParameterSetName = 'Default')]
    [hashtable[]]$VHDs = @(),
    # name of VM switch on target computer
    [Parameter()]
    [string]$SwitchName,
    # force shutdown of running VM
    [Parameter()]
    [switch]$Force,
    # start stopped VM after migration
    [Parameter()]
    [switch]$Restart,
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

    Function Add-VMIdToClusterByComputerName {
        [CmdletBinding()]
        Param(
            [Parameter(Mandatory = $true)]
            [guid]$VMId,
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
        $InvokeCommand['ArgumentList']['VMId'] = $VMId

        # test for cluster
        Try {
            Invoke-Command @InvokeCommand -ScriptBlock {
                Param($ArgumentList)
                $null = Add-ClusterVirtualMachineRole -VMId $ArgumentList['VMId']
            }
        }
        Catch {
            Throw $_
        }
    }

    Function Resolve-VMCompatibilityReport {
        Param(
            [Parameter(Mandatory)]
            [object]$CompatibilityReport,
            [Parameter(DontShow)]
            [boolean]$CannotImport = $false
        )

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
                        $CannotImport = $true
                        $CannotImportMessage = "Could not retrieve VM network adapter name from incompatibility object: '$($_.Exception.Message)'"
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
                            $CannotImport = $true
                            $CannotImportMessage = "Could not disconnect '$VMNetworkAdapterName' VM network adapter on '$Name' VM to address VM switch incompatibility: '$($_.Exception.Message)'"
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
                            $CannotImport = $true
                            $CannotImportMessage = "Could not connect '$VMNetworkAdapterName' VM network adapter on '$Name' VM to '$SwitchName' switch to address VM switch incompatibility: '$($_.Exception.Message)'"
                            Continue NextIncompatibility
                        }
                    }
                }
                # target has an incompatibility with imported VM not addressed above
                Default {
                    $CannotImport = $true
                    $CannotImportMessage = "Found unhandled incompatibility: '$($Incompatibility.Message)'"
                    Continue NextIncompatibility
                }
            }
        }

        # declare state
        Write-Host "$DestinationHost,$Name - ...VM compared to target"

        # return custom compatibility object
        Return [PSCustomObject]@{
            CannotImport        = $CannotImport
            CannotImportMessage = $CannotImportMessage
            CompatibilityReport = $CompatibilityReport
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
			[object]$VM,
			[Parameter()][ValidateScript({ $_ -in [Microsoft.HyperV.PowerShell.StartAction].GetEnumValues() })]
			[string]$AutomaticStartAction = [Microsoft.HyperV.PowerShell.StartAction]::StartIfRunning
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
			Write-Host "$ComputerName,$Name - ...VM configuration restored"
		}

		################################################
		# start VM on computer
		################################################

		# if VM was running before export...
		If ($State -eq 'Running' -or $Restart) {
			# declare state
			Write-Host "$ComputerName,$Name - starting VM..."

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

    # declare state
    Write-Host "$ComputerName,$Name - checking source computer for VM..."

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
    $Name = $VM.Name.ToLowerInvariant()
    $ComputerName = $VM.ComputerName.ToLowerInvariant()

    # check for Protected Users
    If ($Hostname -ne $ComputerName -and ([Security.Principal.WindowsIdentity]::GetCurrent().Groups | Where-Object { $_.Value -match '-525$' })) {
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
        $DestinationStoragePath = $VM | Select-Object -ExpandProperty 'Path'
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
        $SourceClusterGroup = Get-ClusterGroup @GetClusterGroup

        # clear errors due to the nature of looking up VMs by Id
        $Error.Clear()

        # if source cluster group found...
        If ($SourceClusterGroup) {
            # retrieve cluster priority
            $Priority = $SourceClusterGroup.Priority

            # declare state
            Write-Host "$ComputerName,$Name - ...VM found on '$SourceClusterName' cluster with '$Priority' priority; will remove from cluster before migration"
        }
        Else {
            # declare state
            Write-Host "$ComputerName,$Name - ...VM not found on '$SourceClusterName' cluster"
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
    $TargetVM = Get-VM @GetVM

    # clear errors due to the nature of looking up VMs by Id
    $Error.Clear()

    # if VM found on target server...
    If ($TargetVM -and $TargetVM.VirtualMachineType -eq 'RealizedVirtualMachine') {
        # warn and return
        Write-Warning "VM has already been migrated to '$DestinationHost' computer"
        $TargetVM | Format-List *
        Return
    }

    ################################################
    # check for VM on target cluster
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
        Write-Host "$DestinationHost,$Name - checking if VM already clustered on '$TargetClusterName' cluster..."

        # define parameters for Get-ClusterGroup
        $GetClusterGroup = @{
            Cluster     = $TargetClusterName
            VMId        = $Id
            ErrorAction = [System.Management.Automation.ActionPreference]::SilentlyContinue
        }

        # get cluster group for VM on target cluster
        $TargetClusterGroup = Get-ClusterGroup @GetClusterGroup

        # clear errors due to the nature of looking up VMs by Id
        $Error.Clear()

        # if cluster group for VM found on target cluster...
        If ($TargetClusterGroup) {
            # warn and return
            Write-Warning 'VM has already been migrated to '$TargetClusterName' cluster'
            $TargetClusterGroup | Format-List *
            Return
        }

        # declare state
        Write-Host "$DestinationHost,$Name - ...VM not found on '$TargetClusterName' cluster"
    }

    ################################################
    # remove VM from source cluster
    ################################################

    # if VM clustered on source computer...
    If ($SourceClusterGroup) {
        # declare state
        Write-Host "$ComputerName,$Name - removed VM from '$SourceClusterName' cluster..."

        # remove cluster group and resources
        Try {
            Remove-ClusterGroup -VMId $VM.Id -RemoveResources -Force
        }
        Catch {
            Return $_
        }

        # declare state
        Write-Host "$ComputerName,$Name - ...VM removed from '$SourceClusterName' cluster"

        # update VM object after cluster removal
        Try {
            $VM = Get-VM -Id $VM.Id -ComputerName $VM.ComputerName
        }
        Catch {
            Return $_
        }
    }

    ################################################
    # move VM
    ################################################

    # define parameters
    $MoveVMToComputer = @{
        VM              = $VM
        DestinationHost = $DestinationHost
    }

    # move VM to target computer
    Try {
        Move-VMToComputer @MoveVMToComputer
    }
    Catch {
        Throw $_
    }

    ################################################
    # report state
    ################################################

    # if VM move completed...
    If ($StatusObject.Result -eq $true) {
        Write-Host "$ComputerName,$Name - ...move completed"
    }
    # if VM move failed...
    Else {
        Write-Host "$ComputerName,$Name - ...move failed"
        Write-Host "$ComputerName,$Name - ...failed action: $($StatusObject.Action)"
        Write-Host "$ComputerName,$Name - ...error message: $($StatusObject.Error.Exception.Message)"
    }

    ################################################
    # restore VM to cluster
    ################################################

    # if VM move completed and destination host is clustered...
    If ($StatusObject.Result -eq $true -and $TargetClusterName) {
        # report state
        Write-Host "$DestinationHost,$Name - adding VM to destination cluster..."

        # add VM to cluster on destination host
        Try {
            Add-ClusterVirtualMachineRole -Name $Name -Cluster $TargetClusterName
            # Add-VMIdToClusterByComputerName -VMId $VM.Id -ComputerName $DestinationHost
        }
        Catch {
            Return $_
        }

        # report state
        Write-Host "$DestinationHost,$Name - ...added VM to destination cluster"
    }

    # if VM move failed and VM was clustered on source computer...
    If ($StatusObject.Result -eq $false -and $SourceClusterGroup) {
        # report state
        Write-Host "$ComputerName,$Name - adding VM back to original cluster..."

        # restore VM to cluster on source computer
        Try {
            Add-ClusterVirtualMachineRole -Name $Name -Cluster $SourceClusterName
            #Add-VMIdToClusterByComputerName -VMId $VM.Id -ComputerName $ComputerName
        }
        Catch {
            Return $_
        }

        # report state
        Write-Host "$ComputerName,$Name - ...added VM back to original cluster"
    }

    ################################################
    # cleanup after VM move
    ################################################

    # if VM move completed...
    If ($StatusObject.Result -eq $true) {
        # sort current paths
        $SortedCurrentPaths = $CurrentPaths | Select-Object -Unique | Sort-Object -Descending

        # loop through current paths
        :NextCurrentPath ForEach ($CurrentPath in $SortedCurrentPaths) {
            # test if path is empty on original host
            Try {
                $TestPathIsEmpty = Test-PathOnDestinationHost -Path $CurrentPath -DestinationHost $ComputerName -IsEmpty
            }
            Catch {
                Return $_
            }

            # if path is not empty...
            If (!$TestPathIsEmpty) {
                # warn and continue to next current path
                Write-Warning -Message "$ComputerName,$Name - expected empty path; found files in path: $CurrentPath"
                Continue NextCurrentPath
            }

            # test if path is found on original host
            Try {
                $TestPath = Test-PathOnDestinationHost -Path $CurrentPath -DestinationHost $ComputerName
            }
            Catch {
                Return $_
            }

            # if path not found...
            If (!$TestPath) {
                # continue to next current path
                Continue NextCurrentPath
            }

            # report state
            Write-Host "$ComputerName,$Name - removing empty path from original host: $CurrentPath"

            # remove current path after moving VM
            Try {
                $PathRemoved = Assert-PathRemoved -Path $CurrentPath -ComputerName $ComputerName
            }
            Catch {
                Return $_
            }

            # if path removed...
            If ($PathRemoved) {
                # report state
                Write-Host "$ComputerName,$Name - ...removed empty path from original host"
            }
            # if path not removed...
            Else {
                # report state
                Write-Warning "$ComputerName,$Name - could not remove empty path from original host"
            }
        }
    }

    # if VM move failed...
    If ($StatusObject.Result -eq $false) {
        # sort missing paths
        $SortedMissingPaths = $MissingPaths | Select-Object -Unique | Sort-Object -Descending

        # loop through missing paths
        :NextMissingPath ForEach ($MissingPath in $SortedMissingPaths) {
            # test if path is empty on destination host
            Try {
                $TestPathIsEmpty = Test-PathOnDestinationHost -Path $MissingPath -DestinationHost $DestinationHost -IsEmpty
            }
            Catch {
                Return $_
            }

            # if path is not empty...
            If (!$TestPathIsEmpty) {
                # warn and continue to next missing path
                Write-Warning -Message "expected empty path; found files in path: $MissingPath"
                Continue NextMissingPath
            }

            # test if path is found on destination host
            Try {
                $TestPath = Test-PathOnDestinationHost -Path $MissingPath -DestinationHost $DestinationHost
            }
            Catch {
                Return $_
            }

            # if path not found...
            If (!$TestPath) {
                Continue NextMissingPath
            }

            # report state
            Write-Host "$DestinationHost,$Name - removing empty path from destination host: $MissingPath"

            # remove missing path created while trying to move VM
            Try {
                $PathRemoved = Assert-PathRemoved -Path $MissingPath -ComputerName $DestinationHost
            }
            Catch {
                Return $_
            }

            # if path removed...
            If ($PathRemoved) {
                # report state
                Write-Host "$DestinationHost,$Name - ...removed empty path from destination host"
            }
            # if path not removed...
            Else {
                # report state
                Write-Warning "$DestinationHost,$Name - could not remove empty path from destination host"
            }
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
