[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Default')]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Path,
    [Parameter(Mandatory, Position = 1, ParameterSetName = 'Password')]
    [securestring]$Password,
    [Parameter(Mandatory, Position = 1, ParameterSetName = 'Credential')]
    [pscredential]$Credential,
    [string]$DateString = [System.DateTime]::Now.ToString('yyyyMMdd'),
    [string]$ConfigurationPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'
)

# if configuration path not found in registry
if (!(Test-Path -Path $ConfigurationPath -PathType 'Container')) {
    # warn and return
    Write-Warning -Message "could not locate CertSvc configuration registry key, exiting!"
    return
}

# retrieve CA name from active configuration in registry
try {
    $CAName = Get-ItemPropertyValue -Path $ConfigurationPath -Name Active
}
catch {
    Write-Warning -Message "could not retrieve CA name from Active property on CertSvc configuration registry key, exiting!"
    throw $_
}

# if CA name not found...
if ([System.String]::IsNullOrEmpty($CAName)) {
    # warn and return
    Write-Warning -Message "found empty string for CA name in Active property on CertSvc configuration registry key, exiting!"
    return
}

# define path for local CA
$BackupPathForCA = Join-Path -Path $Path -ChildPath $CAName

# define path for individual backup
$BackupPathForCAWithDate = Join-Path -Path $BackupPathForCA -ChildPath $DateString

# create path for individual backup
try {
    $null = New-Item -ItemType Directory -Path $BackupPathForCAWithDate
}
catch {
    throw $_
}

# define parameters for Backup-CARoleService
$BackupCARoleService = @{
    Path = $BackupPathForCAWithDate
}

# switch on parameter set name
switch ($PSCmdlet.ParameterSetName) {
    'Password' {
        $BackupCARoleService['Password'] = $Password
    }
    'Credential' {
        $BackupCARoleService['Password'] = $Credential.Password
    }
    Default {
        Write-Warning -Message "No password or crendential provided; the CA private key will NOT be protected." -WarningAction Inquire
    }
}

# report state
Write-Host "creating '$DateString' backup for '$CAName' CA..."

# backup CA
try {
    Backup-CARoleService @BackupCARoleService
}
catch {
    throw $_
}

# report state
Write-Host "...backup created"

# get backups from local CA
try {
    $ChildItems = Get-ChildItem -Path $BackupPathForCA -Directory
}
catch {
    throw $_
}

# select all but last seven backups
$BackupsToRemove = $ChildItems | Select-Object -SkipLast 7

# loop through backups to remove
foreach ($BackupToRemove in $BackupsToRemove) {
    # report state
    Write-Host "removing old backup: $($BackupToRemove.FullName)"

    # remove backup
    try {
        $BackupToRemove | Remove-Item -Force -Recurse
    }
    catch {
        throw $_
    }

    # report state
    Write-Host "...removed old backup"
}
