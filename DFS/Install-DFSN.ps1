[CmdletBinding(DefaultParameterSetName = 'Relative')]
param(
    [Parameter(DontShow)]
    [string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
    [Parameter(DontShow)]
    [string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
    [Parameter(DontShow)]
    [string]$DnsHostName = ($HostName, $DomainName -join '.').TrimEnd('.'),
    [Parameter(Position = 0, Mandatory, ParameterSetName = 'Relative')]
    [string]$RelativePath,
    [Parameter(Position = 0, Mandatory, ParameterSetName = 'Explicit')]
    [string]$Path,
    [Parameter(Position = 1, Mandatory, ParameterSetName = 'Explicit')]
    [string]$TargetPath,
    [Parameter()]
    [string]$AdminAccounts
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

# install DFS-N feature
try {
    $WindowsFeature = Install-WindowsFeature -Name 'FS-DFS-Namespace' -IncludeManagementTools
}
catch {
    Write-Warning -Message "could not install 'FS-DFS-Namespace' feature: $($_.Exception.Message)"
    return $_
}

# if DFS-N feature installed...
if ($WindowsFeature.ExitCode -eq 'Success') {
    # restart DFS-N service to address WMI issues
    Restart-Service -Name 'DFS'
}

# if relative path provided...
If ($PSBoundParameters.ContainsKey('RelativePath')) {
    # define path from domain name and relative path
    $Path = '\\{0}\{1}' -f $DomainName, $RelativePath

    # define target path from DNS host name and relative path
    $TargetPath = '\\{0}\{1}' -f $DnsHostName, $RelativePath
}

# check for existing DFS-N root 
try {
    $DfsnRoot = Get-DfsnRoot -Path $Path -ErrorAction 'Stop' 
}
catch {
    # define required parameters for New-DfsnRoot
    $NewDfsnRoot = @{
        Path                         = $Path
        TargetPath                   = $TargetPath
        Type                         = 'DomainV2'
        EnableAccessBasedEnumeration = $true
        ErrorAction                  = 'Stop'
    }

    # define required parameters for New-DfsnRoot
    If ($PSBoundParameters.ContainsKey('AdminAccounts')) {
        $NewDfsnRoot.GrantAdminAccounts = $AdminAccounts
    }

    # create new DFS-N root
    try {
        $null = New-DfsnRoot @NewDfsnRoot
    }
    catch {
        Write-Warning -Message "could not create '$Path' DFS-N root: $($_.Exception.Message)"
        return $_
    }
}

# if existing DFS-N root retrieved...
If ($DfsnRoot) {
    # report state
    Write-Host "Located '$Path' DFS-N root"
}
else {
    # report state
    Write-Host "Created '$Path' DFS-N root"
}

# check for existing DFS-N root target
try {
    $DfsnRootTarget = Get-DfsnRootTarget -Path $Path -TargetPath $TargetPath -ErrorAction 'Stop'
}
catch {
    # define parameters for New-DfsnRootTarget
    $NewDfsnRoot = @{
        Path                         = $Path
        TargetPath                   = $TargetPath
        ErrorAction                  = 'Stop'
    }

    # create new DFS-N root target
    try {
        $null = New-DfsnRootTarget -Path $Path -TargetPath $TargetPath -ErrorAction 'Stop'
    }
    catch {
        Write-Warning -Message "could not create '$TargetPath' DFS-N root target: $($_.Exception.Message)"
        return $_
    }
}

# if existing DFS-N root target retrieved...
If ($DfsnRootTarget) {
    # report state
    Write-Host "Located '$TargetPath' DFS-N root target"
}
else {
    # report state
    Write-Host "Created '$TargetPath' DFS-N root target"
}
