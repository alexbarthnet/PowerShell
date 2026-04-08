[CmdletBinding()]
param(
    [Parameter(DontShow)]
    [string]$ComputerName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
    [Parameter(DontShow)]
    [string]$DomainName = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().Name,
    [Parameter(Position = 0, Mandatory)]
    [string]$GroupName,
    [Parameter(Position = 1, Mandatory)]
    [string]$ContentPath,
    [Parameter(Position = 2)]
    [string]$AccountName,
    [Parameter(Position = 3)]
    [switch]$ForcePrimaryMember, 
    [Parameter(Position = 4)]
    [switch]$SkipContentPathPermissions
)

# define error preference
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop

# import module
try {
    Import-Module -Name ServerManager
}
catch {
    Write-Warning -Message "could not load 'ServerManager' module: $($_.Exception.Message)"
    return $_
}

# install DFS-R feature
try {
    $WindowsFeature = Install-WindowsFeature -Name 'FS-DFS-Replication' -IncludeManagementTools
}
catch {
    Write-Warning -Message "could not install 'FS-DFS-Replication' feature: $($_.Exception.Message)"
    return $_
}

# if DFS-R feature installed...
if ($WindowsFeature.ExitCode -eq 'Success') {
    # restart DFS-R service to address WMI issues
    Restart-Service -Name 'DFSR'
}

# define common parameters
$Dfsr = @{ DomainName = $DomainName; GroupName = $GroupName }

# create content path if not found
if (![System.IO.Directory]::Exists($ContentPath)) { 
    $null = [System.IO.Directory]::CreateDirectory($ContentPath)
}

# retrieve existing DFS-R group
$DfsReplicationGroup = Get-DfsReplicationGroup @Dfsr

# if DFS-R group not found...
if (!$DfsReplicationGroup) { 
    # create DFS-R group
    try {
        $DfsReplicationGroup = New-DfsReplicationGroup @Dfsr
    }
    catch {
        Write-Warning -Message "could not create '$GroupName' DFS-R group: $($_.Exception.Message)"
        return $_
    }
    # report state
    Write-Host "Created '$GroupName' DFS-R group"
}
else {
    # report state
    Write-Host "Located '$GroupName' DFS-R group"
}

# retrieve existing DFS-R folder
$DfsReplicatedFolder = Get-DfsReplicatedFolder @Dfsr -FolderName $GroupName

# if DFS-R folder not found...
if (!$DfsReplicatedFolder) {
    # create DFS-R folder
    try {
        $null = New-DfsReplicatedFolder @Dfsr -FolderName $GroupName
    }
    catch {
        Write-Warning -Message "could not create '$GroupName' folder in '$GroupName' DFS-R group: $($_.Exception.Message)"
        return $_
    }
    # report state
    Write-Host "Created '$GroupName' folder in '$GroupName' DFS-R group"
}
else {
    # report state
    Write-Host "Located '$GroupName' folder in '$GroupName' DFS-R group"
}

# if account name provided...
if ($AccountName) {
    # retrieve existing DFS-R delegation
    $DfsrDelegation = Get-DfsrDelegation @Dfsr | Where-Object { $_.AccountName -eq $AccountName }

    # if DFS-R delegation not found...
    if (!$DfsrDelegation) {
        # create DFS-R delegation
        try {
            $DfsrDelegation = Grant-DfsrDelegation @Dfsr -AccountName $AccountName -Force
        }
        catch {
            Write-Warning -Message "could not grant DFS-R delegation to '$AccountName' account on '$GroupName' DFS-R group: $($_.Exception.Message)"
            return $_
        }
        # report state
        Write-Host "Granted '$GroupName' DFS-R delegation to '$AccountName' account on '$GroupName' DFS-R group"
    }
    else {
        # report state
        Write-Host "Located '$GroupName' DFS-R delegation to '$AccountName' account on '$GroupName' DFS-R group"
    }
}

# retrieve DFS-R members
try {
    $DfsrMembers = Get-DfsrMember @Dfsr
}
catch {
    Write-Warning -Message "could not retrieve members in '$GroupName' DFS-R group: $($_.Exception.Message)"
    return $_
}

# split DFS-R members into former and current members
try {
    $DfsrFormerMembers, $DfsrCurrentMembers = $DfsrMembers.Where({ [string]::IsNullOrEmpty($_.ComputerName) }, [System.Management.Automation.WhereOperatorSelectionMode]::Split)
}
catch {
    Write-Warning -Message "could not split members in '$GroupName' DFS-R group: $($_.Exception.Message)"
    return $_
}

# if force primary member was provided...
if ($ForcePrimaryMember) {
    # set primary member to true
    $PrimaryMember = $true
    # report state
    Write-Host "Found 'ForcePrimaryMember' parameter: will set '$ComputerName' as primary member of '$GroupName' DFS-R group"
}
# if DFS-R group has no members or force primary member was set...
elseif ($DfsrCurrentMembers.Count -eq 0) {
    # set primary member to true
    $PrimaryMember = $true
    # report state
    Write-Host "Found '$GroupName' DFS-R group has no members: will set '$ComputerName' as primary member"
}
# if DFS-R group has current computer as only member...
elseif ($DfsrCurrentMembers.Count -eq 1 -and $DfsrCurrentMembers.ComputerName -eq $ComputerName) {
    # set primary member to true
    $PrimaryMember = $true
    # report state
    Write-Host "Found '$GroupName' DFS-R group has current computer as only member: will set '$ComputerName' as primary member"
}
# if DFS-R group has multiple members...
else {
    # set primary member to false
    $PrimaryMember = $false
    # report state
    Write-Host "Found '$GroupName' DFS-R group has multiple members: will set '$ComputerName' as secondary member"
}

# retrieve DFS-R admin command
try { 
    $DfsrAdminCommand = Get-Command -Name 'DfsrAdmin.exe' -ErrorAction 'Stop'
}
catch { 
    Write-Warning "could not locate 'DfsrAdmin.exe' command: former members cannot be automatically removed on this system"
}

# if DFS-R group has former members...
if ($DfsrFormerMembers.Count) {
    # loop through former members
    foreach ($Guid in $DfsrFormerMembers.Identifier.Guid) { 
        # if DFS-R admin command found...
        if ($DfsrAdminCommand) {
            # remove former members
            Start-Process -Wait -NoNewWindow -FilePath 'dfsradmin.exe' -ArgumentList 'mem', 'delete', "/RgName:$GroupName", "/MemGuid:$Guid"
        }
        # if DFS-R admin command not found...
        else {
            Write-Warning -Message "found GUID of former member: $Guid"
        }
    }
}

# if computer is not a member...
if ($ComputerName -notin $DfsrCurrentMembers.ComputerName) { 
    # join DFSR group
    try {
        $null = Add-DfsrMember @Dfsr -ComputerName $ComputerName
    }
    catch {
        Write-Warning -Message "could not add '$ComputerName' computer to '$GroupName' DFS-R group: $($_.Exception.Message)"
        return $_
    }
    # report state
    Write-Host "Added '$ComputerName' as a member of '$GroupName' DFS-R group"
}
# if computer is a member...
else {
    # report state
    Write-Host "Found '$ComputerName' is a member of '$GroupName' DFS-R group"
}

# retrieve membership
try {
    $DfsrMembership = Get-DfsrMembership @Dfsr -ComputerName $ComputerName
}
catch {
    Write-Warning -Message "could not retrieve membership in '$GroupName' DFS-R group: $($_.Exception.Message)"
    return $_
}

# if primary member is set but member is not primary...
if ($PrimaryMember -and -not $DfsrMembership.PrimaryMember) {
    # set check content path to false
    $CheckContentPath = $false
    # set update membership to true
    $UpdateMembership = $true
    # report state
    Write-Host "Will update membership of '$ComputerName' in '$GroupName' DFS-R group to set computer as primary member"
}
elseif ($ContentPath -ne $DfsrMembership.ContentPath) {
    # set check content path to true
    $CheckContentPath = $true
    # set update membership to true
    $UpdateMembership = $true
    # report state
    Write-Host "Will update membership of '$ComputerName' in '$GroupName' DFS-R group to set '$ContentPath' as content path"
}
# if no conditions met...
else {
    # set check content path to false
    $CheckContentPath = $false
    # set update membership to false
    $UpdateMembership = $false
    # report state
    Write-Host "Found expected membership of '$ComputerName' in '$GroupName' DFS-R group"
}

# if content path check required...
if ($CheckContentPath) {
    # if content path contains child items...
    if (Get-ChildItem -Path $ContentPath) {
        Write-Warning -Message "found existing items in '$ContentPath' content path when adding new member or updating existing member"
        return
    }
}

# if membership update required...
if ($UpdateMembership) {
    # define local content path for DFSR membership
    try {
        $null = Set-DfsrMembership @Dfsr -ComputerName $ComputerName -FolderName $GroupName -ContentPath $ContentPath -PrimaryMember $PrimaryMember -Force
    }
    catch {
        Write-Warning -Message "could not set DFS-R membership in '$GroupName' DFS-R group: $($_.Exception.Message)"
        return $_
    }

    # report state
    Write-Host "Updated DFS-R membership: set '$ContentPath' on '$ComputerName' as content path for '$GroupName' folder in '$GroupName' DFS-R group"
}

# retrieve DFS-R connections
try {
    $DfsrConnections = Get-DfsrConnection @Dfsr
}
catch {
    Write-Warning -Message "could not retrieve connections in '$GroupName' DFS-R group: $($_.Exception.Message)"
    return $_
}

# retrieve connections from local computer
$DfsrLocalConnections = $DfsrConnections | Where-Object { $_.SourceComputerName -eq $ComputerName }

# retrieve destination computers which are other computers in DFSR group without connection to current computer
$DestinationComputers = $DfsrCurrentMembers | Where-Object { $_.ComputerName -ne $ComputerName -and $_.ComputerName -notin $DfsrLocalConnections.DestinationComputerName }

# loop through destination computers
foreach ($DestinationComputerName in $DestinationComputers.ComputerName) { 
    # create connection with current computer
    try {
        $null = Add-DfsrConnection @Dfsr -SourceComputerName $ComputerName -DestinationComputerName $DestinationComputerName
    }
    catch {
        Write-Warning -Message "could not create DFS-R connection between '$ComputerName' and '$DestinationComputerName' computer in '$GroupName' DFS-R group: $($_.Exception.Message)"
        return $_
    }
    # report state
    Write-Host "Created DFS-R connection between '$ComputerName' and '$DestinationComputerName' computer in '$GroupName' DFS-R group"
}

# if destination computers exist and not the primary member...
if ($DestinationComputers -and -not $PrimaryMember) {
    # stop service on current computer
    Stop-Service -Name 'DFSR'

    # report state and allow 30 seconds for AD replication
    Write-Host 'Pausing 30 seconds for AD replication of new connections'
    Start-Sleep -Seconds 30

    # loop through destination computers
    foreach ($ComputerName in $DestinationComputers.ComputerName) {
        # update configuration on remote computers
        try {
            Update-DfsrConfigurationFromAD -ComputerName $ComputerName
        }
        catch {
            Write-Warning -Message "could not update '$ComputerName' with DFS-R configuration from AD: $($_.Exception.Message)"
        }
        # report state
        Write-Host "Updated '$ComputerName' with DFS-R configuration from AD"
    }

    # report state and allow 30 seconds for existing DFS-R member to update
    Write-Host 'Pausing 30 seconds for existing DFS-R member to update'
    Start-Sleep -Seconds 30

    # start service on current computer
    Start-Service -Name 'DFSR'

    # if no DFSR local connections exist...
    if (!$DfsrLocalConnections) {
        # report state
        Write-Host "Waiting for initial replication to complete"

        # define values for while loop and reporting
        $While = @{
            Active     = $true # boolean of while loop state
            Action     = 'initial replication to complete' # action being waited for
            Warning    = 'check DFS-R event logs' # warning text when action not completed within allocated time
            Expression = '([array](Get-EventLog -LogName "DFS Replication")).Where({ $_.EventId -eq 4104 }).Count -eq 0' # expression that evaluates true while action is in progress and false when action is complete
            Multiplier = [int32]0 # counter for current loop
            WaitTime   = [int32]0 # counter for total seconds in while loop
            Seconds    = [int32]5 # sleep time for each pass of while loop; multiplied by loop counter to gradually add time to each loop
            Limit      = [int32]8 # maximum passes to complete; default limit of 8 with 5 seconds allows 180 seconds for the action to complete
        }

        # declare state
        Write-Host "...waiting for $($While.Action)..."

        # evaluate expression before while loop
        $While.Active = Invoke-Expression -Command $While.Expression

        # while expression is not resolved to false or limit not reached...
        while ($While.Active -and $While.Multiplier -lt $While.Limit) {
            # increment multiplier
            $While.Multiplier++

            # record total time
            $While.WaitTime += ($While.Seconds * $While.Multiplier)

            # declare updated wait time then sleep
            Write-Host "...waiting an additional '$($While.Seconds * $While.Multiplier)' seconds"
            Start-Sleep -Seconds ($While.Seconds * $While.Multiplier)

            # re-evaluate expression
            $While.Active = Invoke-Expression -Command $While.Expression
        }

        # if expression last resolved to true...
        if ($While.Active) {
            # ...declare wait time and return
            Write-Host -ForegroundColor Yellow "WARNING: waited '$($While.WaitTime)' for $($While.Action) without success; $($While.Warning)"
        }
        # if expression last resolved to false...
        else {
            # ...declare wait time and continue
            Write-Host "...waited '$($While.WaitTime)' seconds for $($While.Action)"
        }
    }
}

# if account name not provided and skip content path permissions not present...
if ($PSBoundParameters.ContainsKey('AccountName') -and -not $SkipContentPathPermissions.IsPresent) {
    # retrieve identity reference for account name via SID translation
    try {
        $IdentityReference = [System.Security.Principal.NTAccount]::new($AccountName).Translate([System.Security.Principal.SecurityIdentifier]).Translate([System.Security.Principal.NTAccount])
    }
    catch {
        Write-Warning -Message "could not translate '$AccountName' account name to security identifier: $($_.Exception.Message)"
        return $_
    }

    # create new access rule
    try {
        $NewAccessRule = [System.Security.AccessControl.FileSystemAccessRule]::new($IdentityReference, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
    }
    catch {
        Write-Warning -Message "could not create file system access rule for '$AccountName' account name: $($_.Exception.Message)"
        return $_
    }

    # retrieve ACL
    try {
        $Acl = Get-Acl -Path $ContentPath
    }
    catch {
        Write-Warning -Message "could not retrieve ACL for '$ContentPath' content path: $($_.Exception.Message)"
        return $_
    }

    # loop through access rules
    :NextAccessRule foreach ($AccessRule in $Acl.Access) {
        # if FileSystemRights on access rule do not match new access rule...
        if ($AccessRule.FileSystemRights -ne $NewAccessRule.FileSystemRights) {
            continue NextAccessRule
        }

        # if AccessControlType on access rule do not match new access rule...
        if ($AccessRule.AccessControlType -ne $NewAccessRule.AccessControlType) {
            continue NextAccessRule
        }

        # if IdentityReference on access rule do not match new access rule...
        if ($AccessRule.IdentityReference -ne $NewAccessRule.IdentityReference) {
            continue NextAccessRule
        }

        # if IsInherited on access rule do not match new access rule...
        if ($AccessRule.IsInherited -ne $NewAccessRule.IsInherited) {
            continue NextAccessRule
        }

        # if InheritanceFlags on access rule do not match new access rule...
        if ($AccessRule.InheritanceFlags -ne $NewAccessRule.InheritanceFlags) {
            continue NextAccessRule
        }

        # if PropagationFlags on access rule do not match new access rule...
        if ($AccessRule.PropagationFlags -ne $NewAccessRule.PropagationFlags) {
            continue NextAccessRule
        }

        # report state
        Write-Host "Found '$AccountName' account has full control on '$ContentPath' path"

        # clear new access rule and break loop
        $NewAccessRule = $null
        break NextAccessRule
    }

    # if new access rule still exists...
    if ($null -ne $NewAccessRule) {
        # add access rule to ACL
        try {
            $Acl.AddAccessRule($AccessRule)
        }
        catch {
            Write-Warning -Message "could not update ACL for '$ContentPath' content path: $($_.Exception.Message)"
            return $_
        }

        # update ACL
        try {
            $Acl | Set-Acl -Path $ContentPath
        }
        catch {
            Write-Warning -Message "could not apply ACL to '$ContentPath' content path: $($_.Exception.Message)"
            return $_
        }

        # report state
        Write-Host "Granted '$AccountName' account full control on '$ContentPath' path"
    }
}
