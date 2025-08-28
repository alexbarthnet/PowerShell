[CmdletBinding()]
param (
    [Parameter(Position = 0)][ValidateScript({ Test-Path -Path $_ })]
    [string]$Path = $env:TEMP,
    [Parameter(DontShow)]
    [string]$Uri = 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest',
    [Parameter(DontShow)]
    [string]$Suffix = 'win-x64.msi',
    [Parameter(DontShow)]
    [hashtable]$Headers = @{ 'User-Agent' = 'PowerShellScript' }
)

# invoke REST method
try {
    $Response = Invoke-RestMethod -Uri $Uri -Headers $Headers
}
catch {
    return $_
}

# retrieve asset matching suffix
$Asset = $Response.Assets | Where-Object { $_.Name.EndsWith($Suffix) }

# if asset for matching suffix found...
if ($Asset) {
    # define source as download URL from asset
    $Source = $Asset.browser_download_url

    # define destination for asset
    $Destination = Join-Path -Path $Path -ChildPath $Asset.Name

    # download asset
    try {
        Start-BitsTransfer -Source $Source -Destination $Destination
    }
    catch {
        return $_
    }

    # report state
    Write-Host "Downloaded latest file with '$Suffix' suffix: $Destination"
}
# if asset not found...
else {
    Write-Warning -Message "could not locate latest file with '$Suffix' suffix"
    return
}

# define parameters
$StartProcess = @{
    NoNewWindow  = $true 
    Wait         = $true 
    FilePath     = 'msiexec.exe'
    ArgumentList = @(
        "/package $Destination"
        '/passive'
    )
}

# install MSI file
try {
    Start-Process @StartProcess
}
catch {
    return $_
}
