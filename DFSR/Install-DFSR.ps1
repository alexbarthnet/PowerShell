[CmdletBinding()]
Param(
    [Parameter(DontShow)]
    $ComputerSystem = (Get-CimInstance -ClassName Win32_ComputerSystem),
    [Parameter(DontShow)]
    $ComputerName = $ComputerSystem.Name,
    [Parameter(DontShow)]
    $DomainName = $ComputerSystem.Domain,
    [Parameter(Position = 0, Mandatory)]
    $GroupName,
    [Parameter(Position = 1, Mandatory)]
    $ContentPath,
    [Parameter(Position = 2)]
    $AccountName
)

# import module
Import-Module -Name ServerManager

# install feature
$WindowsFeature = Install-WindowsFeature -Name 'FS-DFS-Replication' -IncludeManagementTools

# restart service if feature installed
If ($WindowsFeature.ExitCode -eq 'Success') { Restart-Service -Name 'DFSR' }

# define common parameters
$Dfsr = @{ DomainName = $DomainName; GroupName = $GroupName }

# create content path if not found
If (![System.IO.Directory]::Exists($ContentPath)) { New-Item -ItemType 'Directory' -Path $ContentPath }

# retrieve existing DFS replication groups
$DfsReplicationGroup = Get-DfsReplicationGroup @Dfsr

# create the DFS replication group and folder if necessary
If (!$DfsReplicationGroup) { New-DfsReplicationGroup @Dfsr; New-DfsReplicatedFolder @Dfsr -FolderName $GroupName }

# delegate permissions to the DFSR group if necessary
If ($AccountName) { Grant-DfsrDelegation @Dfsr -AccountName $AccountName -Force }

# retrieve DFS members and split into former and current members
$DfsrFormerMembers, $DfsrMembers = (Get-DfsrMember @Dfsr).Where({ [string]::IsNullOrEmpty($_.ComputerName) }, [System.Management.Automation.WhereOperatorSelectionMode]::Split)

# set primary member is group has no members or if current computer is only member
If ($DfsrMembers.Count -eq 0) { $PrimaryMember = $true } ElseIf ($DfsrMembers.Count -eq 1 -and $DfsrMembers.ComputerName -eq $ComputerName) { $PrimaryMember = $true } Else { $PrimaryMember = $false }

# remove former members
ForEach ($Guid in $DfsrFormerMembers.Identifier.Guid) { Start-Process -Wait -NoNewWindow -FilePath 'dfsradmin.exe' -ArgumentList 'mem', 'delete', "/RgName:$GroupName", "/MemGuid:$Guid" }

# join DFSR group is not a member
If ($ComputerName -notin $DfsrMembers.ComputerName) { Add-DfsrMember @Dfsr -ComputerName $ComputerName; Start-Sleep -Seconds 30 }

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

# refresh DFSR on computers with a new connection to current computer
If (!$PrimaryMember -and $NewDfsrConnections) { Stop-Service -Name 'DFSR'; Start-Sleep -Seconds 30; $DestinationComputerNames | Update-DfsrConfigurationFromAD -Verbose; Start-Sleep -Seconds 30; Start-Service -Name 'DFSR' }
