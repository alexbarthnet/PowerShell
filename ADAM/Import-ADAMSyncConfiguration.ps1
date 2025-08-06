[CmdletBinding(SupportsShouldProcess)]
param(
    # working directory for ADAM sync
    [Parameter(DontShow)]
    [string]$WorkingDirectory = (Join-Path -Path $env:ProgramData -ChildPath 'ADAMSync\working'),
    # log file directory for ADAM sync
    [Parameter(DontShow)]
    [string]$LogFileDirectory = (Join-Path -Path $env:ProgramData -ChildPath 'ADAMSync\logs'),
    # log file date time
    [Parameter(DontShow)]
    [string]$LogFileDateTime = ([datetime]::Now.ToString('yyyyMMddTHHmmss')),
    # local host name
    [Parameter(DontShow)]
    [string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
    # domain path
    [Parameter(DontShow)]
    [string]$DomainPath = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().GetDirectoryEntry().DistinguishedName[0],
    # server to evaluate
    [Parameter(Position = 0)]
    [string]$ComputerName = $HostName,
    # server to evaluate
    [Parameter(Position = 1)]
    [uint16]$Port = 389,
    # local domain path
    [Parameter(Position = 2)]
    [string]$Partition = $DomainPath,
    # path for exported ADAM sync file
    [Parameter(Position = 3)][ValidateScript({ [System.IO.File]::Exists($_) })]
    [string]$Path,
    # switch to skip checking sync status
    [Parameter(Position = 4)]
    [switch]$SkipStatusCheck,
    # server for AD cmdlets
    [Parameter(DontShow)]
    [string]$Server = ($ComputerName, $Port -join ':')
)

# define action
$Action = 'install'

# connect to instance
try {
    $ADRootDSE = Get-ADRootDSE -Server $Server
}
catch {
    Write-Warning -Message "cannot $Action configuration: could not connect to root DSE on '$Server' server: $($_.Exception.Message)"
    throw $_
}

# validate AD LDS server name
if ($ADRootDSE.serverName -match '^CN=[\w-]+\$(?<InstanceName>\w+)') {
    $InstanceName = $Matches.InstanceName
}
else {
    Write-Warning -Message "cannot $Action configuration: could not extract InstanceName from '$($ADRootDSE.serverName)' serverName property on root DSE"
    return
}

# report state
Write-Host "found '$InstanceName' instance name from root DSE on '$Server' server"

# retrieve partition object
try {
    $ADObject = Get-ADObject -Server $Server -Identity $Partition -Properties 'configurationFile'
}
catch {
    Write-Warning -Message "cannot $Action configuration: could not retrieve '$Partition' object on '$Server' server: $($_.Exception.Message)"
    throw $_
}

# if configuration file is empty...
if ([string]::IsNullOrEmpty($ADObject.configurationFile)) {
    # skip status check
    $SkipStatusCheck = $true
}

# if SkipStatusCheck not provided...
if (!$SkipStatusCheck) {
    # create XML object
    try {
        $Xml = [System.Xml.XmlDocument]::new()
    }
    catch {
        Write-Warning -Message "cannot $Action configuration: could not create XML document object: $($_.Exception.Message)"
        throw $_
    }

    # populate XML object from configuration file
    try {
        $Xml.LoadXml($ADObject.configurationFile)
    }
    catch {
        Write-Warning -Message "cannot $Action configuration: could not load configuration file into XML document object: $($_.Exception.Message)"
        throw $_
    }

    # retrieve status of synchronizer state from XML object
    $SynchronizerStateStatus = $Xml.doc.'synchronizer-state'.'status'

    # if status is not empty...
    if (![string]::IsNullOrEmpty($SynchronizerStateStatus)) {
        Write-Warning -Message "cannot $Action configuration: found '$SynchronizerStateStatus' status in synchronizer state"
        return
    }
}

# create working directory
if (![System.IO.Directory]::Exists($WorkingDirectory)) {
    try {
        $null = New-Item -Force -ItemType 'Directory' -Path $WorkingDirectory
    }
    catch {
        Write-Warning -Message "cannot $Action configuration: could not create '$WorkingDirectory' working directory on '$Server' server: $($_.Exception.Message)"
        throw $_
    } 
}

# create log file path
if (![System.IO.Directory]::Exists($LogFileDirectory)) {
    try {
        $null = New-Item -Force -ItemType 'Directory' -Path $LogFileDirectory
    }
    catch {
        Write-Warning -Message "cannot $Action configuration: could not create '$LogFileDirectory' log file directory: $($_.Exception.Message)"
        throw $_
    } 
}

# define log file name
$LogFileName = '{0}_{1}_{2}_{3}_{4}_{5}.txt' -f $LogFileDateTime, $InstanceName, $Action, $ComputerName, $Port, $Partition

# define log file
$LogFile = Join-Path -Path $LogFileDirectory -ChildPath $LogFileName

# define argument list
$ArgumentList = @(
    '/{0}' -f $Action
    $Server
    '"{0}"' -f $Path
    '/log'
    '"{0}"' -f $LogFile
)

# report state
Write-Host "starting $Action of ADAM Sync configuration file for '$Partition' partition of '$InstanceName' instance name on '$Server' server"

# sync ADAM
try {
    Start-Process -NoNewWindow -Wait -WorkingDirectory $WorkingDirectory -FilePath 'C:\Windows\ADAM\adamsync.exe' -ArgumentList $ArgumentList
}
catch {
    Write-Warning -Message "cannot $Action ADAM Sync configuration file:  $($_.Exception.Message)"
    throw $_
}

# report state
Write-Host "complete $Action of ADAM Sync configuration from file: $Path"
