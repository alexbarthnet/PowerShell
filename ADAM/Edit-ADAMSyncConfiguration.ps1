[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Implicit')]
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
    # directory for exported ADAM sync file
    [Parameter(Position = 3, ParameterSetName = 'Implicit')]
    [string]$ExportsDirectory = (Join-Path -Path $env:ProgramData -ChildPath 'ADAMSync\exports'),
    # define attributes to add
    [string[]]$AddAttributes,
    # define attributes to remove
    [string[]]$RemoveAttributes,
    # define base DN to add
    [string[]]$AddContainers,
    # define base DN to remove
    [string[]]$RemoveContainers,
    # server for AD cmdlets
    [Parameter(DontShow)]
    [string]$Server = ($ComputerName, $Port -join ':')
)

################################################
# begin export
################################################

# define action
$Action = 'edit'

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
    Write-Warning -Message "cannot $Action configuration: found empty configurationFile property on '$Partition' object on '$Server' server"
    return
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

# create exports directory
if (![System.IO.Directory]::Exists($ExportsDirectory)) {
    try {
        $null = New-Item -Force -ItemType 'Directory' -Path $ExportsDirectory
    }
    catch {
        Write-Warning -Message "could not create '$ExportsDirectory' log file directory: $($_.Exception.Message)"
        throw $_
    }
}

# define state
$State = 'export-for-edit'

# define export file name
$ExportFileName = '{0}_{1}_{2}_{3}_{4}_{5}.xml' -f $LogFileDateTime, $InstanceName, $State, $ComputerName, $Port, $Partition

# combined directory and file name
$Path = Join-Path -Path $ExportsDirectory -ChildPath $ExportFileName

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

# create log files directory
if (![System.IO.Directory]::Exists($LogFileDirectory)) {
    try {
        $null = New-Item -Force -ItemType 'Directory' -Path $LogFileDirectory
    }
    catch {
        Write-Warning -Message "could not create '$LogFileDirectory' log file directory: $($_.Exception.Message)"
        throw $_
    }
}

# define log file name
$LogFileName = '{0}_{1}_{2}_{3}_{4}_{5}.txt' -f $LogFileDateTime, $InstanceName, $State, $ComputerName, $Port, $Partition

# define log file
$LogFile = Join-Path -Path $LogFileDirectory -ChildPath $LogFileName

# update action
$Action = 'export'

# define argument list
$ArgumentList = @(
    '/{0}' -f $Action
    $Server
    '"{0}"' -f $Partition
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
    Write-Warning -Message "cannot $Action ADAM Sync configuration file: $($_.Exception.Message)"
    throw $_
}

# report state
Write-Host "complete $Action of ADAM Sync configuration to file: $Path"

################################################
# define configuration data
################################################

# Run the following commands to create the XML object:
$Xml = [System.Xml.XmlDocument]::new()

# Run the following commands to load the template file:
$Xml.Load($Path)

# loop through attributes to add
foreach ($AttributeToAdd in $AddAttributes) {
    # define XML element
    $Element = $Xml.CreateElement('include')
    # define inner text as attribute name
    $Element.InnerText = $AttributeToAdd
    # append XML element to attributes section
    $null = $Xml.doc.configuration.query['attributes'].AppendChild($Element)
}

# loop through attributes to remove
foreach ($AttributeToRemove in $RemoveAttributes) {
    # retrieve XML element
    $Element = $Xml.SelectSingleNode("//doc//configuration//query//attributes//include[text()='$AttributeToRemove']")
    # remove XML element from attributes section
    $null = $Xml.doc.configuration.query['attributes'].RemoveChild($Element)
}

# loop through containers to add
foreach ($ContainerToAdd in $AddContainers) {
    # define XML element
    $Element = $Xml.CreateElement('base-dn')
    # define inner text as attribute name
    $Element.InnerText = $ContainerToAdd
    # append XML element to attributes section
    $null = $Xml.doc.configuration['query'].InsertBefore($Element, $Xml.doc.configuration.query['object-filter'])
}

# loop through containers to remove
foreach ($ContainerToRemove in $RemoveContainers) {
    # retrieve XML element
    $Element = $Xml.SelectSingleNode("//doc//configuration//query//base-dn[text()='$ContainerToRemove']")
    # remove XML element from attributes section
    $null = $Xml.doc.configuration['query'].RemoveChild($Element)
}

# create the XML writer settings
$XmlWriterSettings = [System.Xml.XmlWriterSettings]::new()

# define the XML writer settings
$XmlWriterSettings.Encoding = [System.Text.Encoding]::ASCII
$XmlWriterSettings.Indent = $true

# if WhatIf provided...
if ($WhatIfPreference) {
    # create the XML writer for console output
    $XmlWriter = [System.Xml.XmlWriter]::Create([console]::Out, $XmlWriterSettings)

    # review the configuration data after formatting
    $Xml.Save($XmlWriter)

    # return after reviewing
    return
}
else {
    # define state
    $State = 'import-for-edit'

    # define export file name
    $ImportFileName = '{0}_{1}_{2}_{3}_{4}_{5}.xml' -f $LogFileDateTime, $InstanceName, $State, $ComputerName, $Port, $Partition

    # combined directory and file name
    $Path = Join-Path -Path $ExportsDirectory -ChildPath $ImportFileName

    # update the XML writer settings
    $XmlWriterSettings.CloseOutput = $true

    # create the XML writer for the configuration file
    $XmlWriter = [System.Xml.XmlWriter]::Create($Path, $XmlWriterSettings)

    # save the configuration file
    $Xml.Save($XmlWriter)
}

################################################
# begin import
################################################

# define log file name
$LogFileName = '{0}_{1}_{2}_{3}_{4}_{5}.txt' -f $LogFileDateTime, $InstanceName, $State, $ComputerName, $Port, $Partition

# define log file
$LogFile = Join-Path -Path $LogFileDirectory -ChildPath $LogFileName

# update action
$Action = 'install'

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

################################################
# end import
################################################
