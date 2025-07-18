param(
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
    # working directory for ADAM sync
    [Parameter(Position = 3)]
    [string]$WorkingDirectory = (Join-Path -Path $env:ProgramData -ChildPath 'ADAMSync\working'),
    # log file directory for ADAM sync
    [Parameter(Position = 4)]
    [string]$LogFileDirectory = (Join-Path -Path $env:ProgramData -ChildPath 'ADAMSync\logs'),
    # switch to skip aging pass
    [Parameter(Position = 5)]
    [switch]$SkipAging,
    # switch to skip sync pass
    [Parameter(Position = 6)]
    [switch]$SkipSync,
    # switch to perform full sync
    [Parameter(Position = 7)]
    [switch]$FullSync,
    # server for AD cmdlets
    [Parameter(DontShow)]
    [string]$Server = ($ComputerName, $Port -join ':')
)

# connect to instance
try {
    $ADRootDSE = Get-ADRootDSE -Server $Server
}
catch {
    Write-Warning -Message "could not connect to root DSE on '$Server' server: $($_.Exception.Message)"
    throw $_
}

# validate AD LDS server name
if ($ADRootDSE.serverName -match '^CN=\w+\$(?<InstanceName>\w+)') {
    $InstanceName = $Matches.InstanceName
}
else {
    Write-Warning -Message "could not extract InstanceName from '$($ADRootDSE.serverName)' serverName property on root DSE"
    return
}

# report state
Write-Host "found '$InstanceName' instance name from root DSE on '$Server' server"

# create working directory
if (![System.IO.Directory]::Exists($WorkingDirectory)) {
    try {
        $null = New-Item -Force -ItemType 'Directory' -Path $WorkingDirectory
    }
    catch {
        Write-Warning -Message "could not create '$WorkingDirectory' working directory on '$Server' server: $($_.Exception.Message)"
        throw $_
    } 
}

# create log file path
if (![System.IO.Directory]::Exists($LogFileDirectory)) {
    try {
        $null = New-Item -Force -ItemType 'Directory' -Path $LogFileDirectory
    }
    catch {
        Write-Warning -Message "could not create '$LogFileDirectory' log file directory: $($_.Exception.Message)"
        throw $_
    } 
}

# if skip aging not requested...
if (!$SkipAging) {
    # define action
    $Action = 'ageall'

    # define log file name
    $LogFileName = '{0}_{1}_{2}_{3}_{4}_{5}.txt' -f [datetime]::Now.ToString('yyyyMMddTHHmmss'), $InstanceName, $Action, $ComputerName, $Port, $Partition

    # define log file
    $LogFile = Join-Path -Path $LogFileDirectory -ChildPath $LogFileName

    # define argument list
    $ArgumentList = @(
        '/{0}' -f $Action
        $Server
        '"{0}"' -f $Partition
        '/log'
        '"{0}"' -f $LogFile
    )

    # report state
    Write-Host "starting  '$InstanceName' instance name from root DSE on '$Server' server"

    # sync ADAM
    try {
        Start-Process -NoNewWindow -Wait -WorkingDirectory $WorkingDirectory -FilePath 'C:\Windows\ADAM\adamsync.exe' -ArgumentList $ArgumentList
    }
    catch {
        Write-Warning -Message "could not start ADAMSync ageall run for '$Partition' partition on '$Server' server: $($_.Exception.Message)"
        throw $_
    }
}

# if skip sync not requested...
if (!$SkipSync) {
    # if full sync requested...
    if ($FullSync) {
        $Action = 'fullsync'
    }
    else {
        $Action = 'sync'
    }

    # define log file name
    $LogFileName = '{0}_{1}_{2}_{3}_{4}_{5}.txt' -f [datetime]::Now.ToString('yyyyMMddTHHmmss'), $InstanceName, $Action, $ComputerName, $Port, $Partition

    # define log file
    $LogFile = Join-Path -Path $LogFileDirectory -ChildPath $LogFileName

    # define argument list
    $ArgumentList = @(
        '/{0}' -f $Action
        $Server
        '"{0}"' -f $Partition
        '/log'
        '"{0}"' -f $LogFile
    )

    # sync ADAM
    try {
        Start-Process -NoNewWindow -Wait -WorkingDirectory $WorkingDirectory -FilePath 'C:\Windows\ADAM\adamsync.exe' -ArgumentList $ArgumentList
    }
    catch {
        Write-Warning -Message "could not start ADAMSync sync run for '$Partition' partition on '$Server' server: $($_.Exception.Message)"
        throw $_
    }
}
