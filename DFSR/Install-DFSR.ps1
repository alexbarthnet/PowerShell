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
    [switch]$ForcePrimaryMember
)

# import module
Import-Module -Name ServerManager

# install feature
$WindowsFeature = Install-WindowsFeature -Name 'FS-DFS-Replication' -IncludeManagementTools

# if feature installed...
if ($WindowsFeature.ExitCode -eq 'Success') {
    # restart service to address WMI issues
    Restart-Service -Name 'DFSR'
}

# define common parameters
$Dfsr = @{ DomainName = $DomainName; GroupName = $GroupName }

# create content path if not found
if (![System.IO.Directory]::Exists($ContentPath)) { 
    $null = [System.IO.Directory]::CreateDirectory($ContentPath)
}

# retrieve existing DFSR groups
$DfsReplicationGroup = Get-DfsReplicationGroup @Dfsr

# if DFSR group not found...
if (!$DfsReplicationGroup) { 
    # create DFSR group
    try {
        New-DfsReplicationGroup @Dfsr
    }
    catch {
        Write-Warning -Message "could not create '$GroupName' DFS-R group: $($_.Exception.Message)"
        return $_
    }

    # create DFSR folder
    try {
        New-DfsReplicatedFolder @Dfsr -FolderName $GroupName
    }
    catch {
        Write-Warning -Message "could not create '$GroupName' folder in '$GroupName' DFS-R group: $($_.Exception.Message)"
        return $_
    }
}

# if account name provided
if ($AccountName) {
    # delegate permissions to the DFSR group if necessary
    try {
        Grant-DfsrDelegation @Dfsr -AccountName $AccountName -Force
    }
    catch {
        Write-Warning -Message "could not grant DFS-R delegation to '$AccountName' account on '$GroupName' DFS-R group: $($_.Exception.Message)"
        return $_
    }
}

# retrieve DFS members and split into former and current members
$DfsrFormerMembers, $DfsrMembers = (Get-DfsrMember @Dfsr).Where({ [string]::IsNullOrEmpty($_.ComputerName) }, [System.Management.Automation.WhereOperatorSelectionMode]::Split)

# if group has no members or force primary member was set...
if ($DfsrMembers.Count -eq 0 -or $ForcePrimaryMember) {
    # set primary member to true
    $PrimaryMember = $true
    # if group has only computer as member...
}
elseif ($DfsrMembers.Count -eq 1 -and $DfsrMembers.ComputerName -eq $ComputerName) {
    # set primary member to true
    $PrimaryMember = $true
    # if group has multiple members...
}
else {
    # set primary member to false
    $PrimaryMember = $false
}

# loop through former members
foreach ($Guid in $DfsrFormerMembers.Identifier.Guid) { 
    # remove former members
    Start-Process -Wait -NoNewWindow -FilePath 'dfsradmin.exe' -ArgumentList 'mem', 'delete', "/RgName:$GroupName", "/MemGuid:$Guid"
}

# if computer is not a member...
if ($ComputerName -notin $DfsrMembers.ComputerName) { 
    # join DFSR group
    try {
        Add-DfsrMember @Dfsr -ComputerName $ComputerName
    }
    catch {
        Write-Warning -Message "could not add '$ComputerName' computer to '$GroupName' DFS-R group: $($_.Exception.Message)"
        return $_
    }

    # allow 30 seconds for AD replication
    Start-Sleep -Seconds 30
}

# retrieve connections from current computer
$DfsrConnections = Get-DfsrConnection @Dfsr | Where-Object { $_.SourceComputerName -eq $ComputerName }

# retrieve other computers in DFSR group without connection to current computer
$DestinationComputers = Get-DfsrMember @Dfsr | Where-Object { $_.ComputerName -ne $ComputerName -and $_.ComputerName -notin $DfsrConnections.DestinationComputerName }

# loop through destination computers
foreach ($DestinationComputerName in $DestinationComputers.Names) { 
    # create connection with current computer
    try {
        Add-DfsrConnection @Dfsr -SourceComputerName $ComputerName -DestinationComputerName $DestinationComputerName
    }
    catch {
        Write-Warning -Message "could not create DFS-R connection with '$DestinationComputerName' computer in '$GroupName' DFS-R group: $($_.Exception.Message)"
        return $_
    }
}

# retrieve new connections
$NewDfsrConnections = Get-DfsrConnection @Dfsr | Where-Object { $_.SourceComputerName -eq $ComputerName -and $_.DestinationComputerName -in $DestinationComputers.Names }

# if new connections created...
if ($NewDfsrConnections) {
    # report new connections
    Write-Host "created new DFS-R connection:"
    $NewDfsrConnections | Format-Table -Property GroupName, SourceComputerName, DestinationComputerName, DomainName, Enabled, Identifier
}

# define local content path for DFSR membership
try {
    Set-DfsrMembership @Dfsr -ComputerName $ComputerName -FolderName $GroupName -ContentPath $ContentPath -PrimaryMember $PrimaryMember -Force
}
catch {
    Write-Warning -Message "could not set DFS-R membership in '$GroupName' DFS-R group: $($_.Exception.Message)"
    return $_
}

# if new connections created and not primary member...
if ($NewDfsrConnections -and -not $PrimaryMember) { 
    # stop service on current computer
    Stop-Service -Name 'DFSR'

    # report state
    Write-Host 'Pausing 30 seconds for AD replication'

    # allow 30 seconds for AD replication
    Start-Sleep -Seconds 30

    # update configuration on remote computers
    $DestinationComputers.Names | Update-DfsrConfigurationFromAD -Verbose

    # report state
    Write-Host 'Pausing 30 seconds for remote computers to update'

    # allow 30 seconds for service on remote computers to update
    Start-Sleep -Seconds 30

    # start service on current computer
    Start-Service -Name 'DFSR'
}
