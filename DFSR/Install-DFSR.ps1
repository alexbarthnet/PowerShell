[CmdletBinding()]
Param(
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
If ($WindowsFeature.ExitCode -eq 'Success') {
    # restart service to address WMI issues
    Restart-Service -Name 'DFSR'
}

# define common parameters
$Dfsr = @{ DomainName = $DomainName; GroupName = $GroupName }

# create content path if not found
If (![System.IO.Directory]::Exists($ContentPath)) { 
    $null = [System.IO.Directory]::CreateDirectory($ContentPath)
}

# retrieve existing DFSR groups
$DfsReplicationGroup = Get-DfsReplicationGroup @Dfsr

# if DFSR group not found...
If (!$DfsReplicationGroup) { 
    # create DFSR group
    New-DfsReplicationGroup @Dfsr

    # create DFSR folder
    New-DfsReplicatedFolder @Dfsr -FolderName $GroupName
}

# if account name provided
If ($AccountName) {
    # delegate permissions to the DFSR group if necessary
    Grant-DfsrDelegation @Dfsr -AccountName $AccountName -Force
}

# retrieve DFS members and split into former and current members
$DfsrFormerMembers, $DfsrMembers = (Get-DfsrMember @Dfsr).Where({ [string]::IsNullOrEmpty($_.ComputerName) }, [System.Management.Automation.WhereOperatorSelectionMode]::Split)

# if group has no members or force primary member was set...
If ($DfsrMembers.Count -eq 0 -or $ForcePrimaryMember) {
    # set primary member to true
    $PrimaryMember = $true
# if group has only computer as member...
} ElseIf ($DfsrMembers.Count -eq 1 -and $DfsrMembers.ComputerName -eq $ComputerName) {
    # set primary member to true
    $PrimaryMember = $true
# if group has multiple members...
} Else {
    # set primary member to false
    $PrimaryMember = $false
}

# loop through former members
ForEach ($Guid in $DfsrFormerMembers.Identifier.Guid) { 
    # remove former members
    Start-Process -Wait -NoNewWindow -FilePath 'dfsradmin.exe' -ArgumentList 'mem', 'delete', "/RgName:$GroupName", "/MemGuid:$Guid"
}

# if computer is not a member...
If ($ComputerName -notin $DfsrMembers.ComputerName) { 
    # join DFSR group
    Add-DfsrMember @Dfsr -ComputerName $ComputerName

    # allow 30 seconds for AD replication
    Start-Sleep -Seconds 30
}

# retrieve connections from current computer
$DfsrConnections = Get-DfsrConnection @Dfsr | Where-Object { $_.SourceComputerName -eq $ComputerName }

# retrieve other computers in DFSR group without connection to current computer
$DestinationComputerNames = (Get-DfsrMember @Dfsr | Where-Object { $_.ComputerName -ne $ComputerName -and $_.ComputerName -notin $DfsrConnections.DestinationComputerName }).ComputerName

# create connections with current computer
ForEach ($DestinationComputerName in $DestinationComputerNames) { Add-DfsrConnection @Dfsr -SourceComputerName $ComputerName -DestinationComputerName $DestinationComputerName }

# retrieve new connections
$NewDfsrConnections = Get-DfsrConnection @Dfsr | Where-Object { $_.SourceComputerName -eq $ComputerName -and $_.DestinationComputerName -in $DestinationComputerNames }

# report new connections
$NewDfsrConnections | Format-Table -Property GroupName, SourceComputerName, DestinationComputerName, DomainName, Enabled, Identifier

# define local content path for DFSR membership
Set-DfsrMembership @Dfsr -ComputerName $ComputerName -FolderName $GroupName -ContentPath $ContentPath -PrimaryMember $PrimaryMember -Force

# if new connections created and not primary member...
If ($NewDfsrConnections -and -not $PrimaryMember) { 
    # stop service on current computer
    Stop-Service -Name 'DFSR'

    # allow 30 seconds for AD replication
    Start-Sleep -Seconds 30

    # update configuration on remote computers
    $DestinationComputerNames | Update-DfsrConfigurationFromAD -Verbose

    # allow 30 seconds for service on remote computers to update
    Start-Sleep -Seconds 30

    # start service on current computer
    Start-Service -Name 'DFSR'
}
