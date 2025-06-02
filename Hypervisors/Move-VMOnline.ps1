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

    Function Move-VMToComputer {
        Param(
            [Parameter(Mandatory = $true)][ValidateScript({ $_ -is [Microsoft.HyperV.PowerShell.VirtualMachine] })]
            [object]$VM,
            [Parameter(Mandatory = $true)]
            [string]$DestinationHost
        )

        ################################################
        # define script-wide objects
        ################################################

        $script:StatusObject = [pscustomobject]@{ Result = $false; Action = [string]::Empty; CompatibilityReport = $null; Error = $null }
        $script:MissingPaths = [System.Collections.Generic.List[string]]::new()
        $script:CurrentPaths = [System.Collections.Generic.List[string]]::new()

        ################################################
        # define parameters for VM compatibility report
        ################################################

        # define parameters
        $CompareVM = @{
            VM              = $VM
            DestinationHost = $DestinationHost
            ErrorAction     = [System.Management.Automation.ActionPreference]::Stop
        }

        ################################################
        # retrieve VM path - primary
        ################################################

        # add path to current paths list
        $CurrentPaths.Add($VM.Path)

        # if path not provided...
        If (!$PSBoundParameters.ContainsKey('VirtualMachinePath')) {
            # retrieve path from VM
            $VirtualMachinePath = $VM.Path
        }

        # define path on destination
        $PathOnDestinationHost = $VirtualMachinePath
            
        # test parent path on destination
        Try {
            $TestPath = Test-PathOnDestinationHost -Path $PathOnDestinationHost -DestinationHost $DestinationHost
        }
        Catch {
            $StatusObject.Action = 'Test-PathOnDestinationHost for VirtualMachinePath'
            $StatusObject.Result = $false
            $StatusObject.Error = $_
            Return
        }
            
        # if path not found not found on destination and parent path not in missing paths...
        If (!$TestPath -and $PathOnDestinationHost -notin $MissingPaths) {
            # add parent path to list
            $MissingPaths.Add($PathOnDestinationHost)
        }

        # add path to compare parameters
        $CompareVM['VirtualMachinePath'] = $VirtualMachinePath

        ################################################
        # retrieve VM path - secondary
        ################################################

        # if path not in current path list...
        If ($VM.SmartPagingFilePath -notin $CurrentPaths) {
            # add path to current paths list
            $CurrentPaths.Add($VM.SmartPagingFilePath)
        }

        # add VM path to current paths list
        $CurrentPaths.Add($VM.Path)

        # if path not provided...
        If (!$PSBoundParameters.ContainsKey('SmartPagingFilePath')) {
            # retrieve path from VM
            $SmartPagingFilePath = $VM.SmartPagingFilePath
        }

        # define smart paging path
        If ($CompareVM['VirtualMachinePath'] -ne $SmartPagingFilePath) {
            # define path on destination
            $PathOnDestinationHost = $SmartPagingFilePath
            
            # test parent path on destination
            Try {
                $TestPath = Test-PathOnDestinationHost -Path $PathOnDestinationHost -DestinationHost $DestinationHost
            }
            Catch {
                $StatusObject.Action = 'Test-PathOnDestinationHost for SmartPagingFilePath'
                $StatusObject.Result = $false
                $StatusObject.Error = $_
                Return
            }

            # if path not found not found on destination and parent path not in missing paths...
            If (!$TestPath -and $PathOnDestinationHost -notin $MissingPaths) {
                # add parent path to list
                $MissingPaths.Add($PathOnDestinationHost)
            }

            # add path to compare parameters
            $CompareVM['SmartPagingFilePath'] = $SmartPagingFilePath
        }

        # if path not in current path list...
        If ($VM.SnapshotFileLocation -notin $CurrentPaths) {
            # add path to current paths list
            $CurrentPaths.Add($VM.SnapshotFileLocation)
        }

        # if path not provided...
        If (!$PSBoundParameters.ContainsKey('SnapshotFileLocation')) {
            # retrieve path from VM
            $SnapshotFileLocation = $VM.SnapshotFileLocation
        }

        # define snapshot path
        If ($CompareVM['VirtualMachinePath'] -ne $SnapshotFileLocation) {
            # define path on destination
            $PathOnDestinationHost = $SnapshotFileLocation
            
            # test parent path on destination
            Try {
                $TestPath = Test-PathOnDestinationHost -Path $PathOnDestinationHost -DestinationHost $DestinationHost
            }
            Catch {
                $StatusObject.Action = 'Test-PathOnDestinationHost for SnapshotFileLocation'
                $StatusObject.Result = $false
                $StatusObject.Error = $_
                Return
            }
            
            # if path not found not found on destination and parent path not in missing paths...
            If (!$TestPath -and $PathOnDestinationHost -notin $MissingPaths) {
                # add parent path to list
                $MissingPaths.Add($PathOnDestinationHost)
            }
            
            # add path to compare parameters
            $CompareVM['SnapshotFilePath'] = $SnapshotFileLocation
        }

        ################################################
        # retrieve VHD path
        ################################################

        # define VHD array
        $CompareVM['Vhds'] = @()

        # process each VHD
        ForEach ($VMHardDrive in $VM.HardDrives) {
            # retrieve parent path for VHD
            Try {
                $ParentPath = Split-Path -Path $VMHardDrive.Path -Parent
            }
            Catch {
                $StatusObject.Action = 'Split-Path for VMHardDrive.Path'
                $StatusObject.Result = $false
                $StatusObject.Error = $_
                Return
            }

            # if path not in current path list...
            If ($ParentPath -notin $CurrentPaths) {
                # add path to current paths list
                $CurrentPaths.Add($ParentPath)
            }

            # test parent path on destination
            Try {
                $TestPath = Test-PathOnDestinationHost -Path $ParentPath -DestinationHost $DestinationHost
            }
            Catch {
                $StatusObject.Action = 'Test-PathOnDestinationHost for VMHardDrive.Path'
                $StatusObject.Result = $false
                $StatusObject.Error = $_
                Return
            }

            # if path not found not found on destination and parent path not in missing paths...
            If (!$TestPath -and $ParentPath -notin $MissingPaths) {
                # add parent path to list
                $MissingPaths.Add($ParentPath)
            }

            # retrieve VHD source path
            $SourceFilePath = $VMHardDrive.Path

            # define VHD destination path
            $DestinationFilePath = $SourceFilePath

            # add VHD source-to-destination mapping to array
            $CompareVM['Vhds'] += @{ SourceFilePath = $SourceFilePath; DestinationFilePath = $DestinationFilePath }
        }

        ################################################
        # process list for missing paths
        ################################################

        # define boolean
        $MissingPathNotCreated = $false

        # loop through missing paths
        ForEach ($MissingPath in $MissingPaths) {
            # assert missing path on destination host
            Try {
                $PathCreated = Assert-PathCreated -Path $MissingPath -ComputerName $DestinationHost
            }
            Catch {
                $StatusObject.Action = 'Assert-PathCreated for MissingPath'
                $StatusObject.Result = $false
                $StatusObject.Error = $_
                Return
            }

            # if path created...
            If ($PathCreated) {
                # report path
                Write-Host "$DestinationHost,$Name - created path on destination host: $MissingPath"
            }
            # if path not created...
            Else {
                # warn and update boolean
                Write-Warning "$DestinationHost,$Name - could not create path on destination host: $MissingPath"
                $MissingPathNotCreated = $true
            }
        }

        # if missing path not created...
        If ($MissingPathNotCreated) {
            $StatusObject.Result = $false
            Return
        }

        ################################################
        # compare VM
        ################################################

        # move VM to target computer
        Try {
            $CompatibilityReport = Compare-VM @CompareVM
        }
        Catch {
            $StatusObject.Action = 'Compare-VM'
            $StatusObject.Result = $false
            $StatusObject.Error = $_
            Return
        }

        # declare state
        Write-Host "$ComputerName,$Name - ...VM compared to destination host: $DestinationHost"

        ################################################
        # resolve VM compatibility with target
        ################################################

        # compare VM with target computer
        Try {
            $CompatibilityReport = Resolve-VMCompatibilityReport -CompatibilityReport $CompatibilityReport
        }
        Catch {
            $StatusObject.Action = 'Resolve-VMCompatibilityReport'
            $StatusObject.CompatibilityReport = $CompatibilityReport
            $StatusObject.Result = $false
            $StatusObject.Error = $_
            Return
        }

        ################################################
        # move VM
        ################################################

        # declare state
        Write-Host "$ComputerName,$Name - moving VM..."

        # define required parameters for Import-VM
        $MoveVM = @{
            CompatibilityReport = $CompatibilityReport
            ErrorAction         = [System.Management.Automation.ActionPreference]::Stop
        }

        # move VM to target computer
        Try {
            Move-VM @MoveVM
        }
        Catch {
            $StatusObject.Action = 'Move-VM'
            $StatusObject.Result = $false
            $StatusObject.Error = $_
            Return
        }

        # update state
        $StatusObject.Action = 'Move-VM'
        $StatusObject.Result = $true
        Return
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
