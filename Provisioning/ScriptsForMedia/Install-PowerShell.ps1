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
    $FilePath = Join-Path -Path $Path -ChildPath $Asset.Name

    # download asset
    try {
        Start-BitsTransfer -Source $Source -Destination $FilePath
    }
    catch {
        return $_
    }

    # report state
    Write-Host "Downloaded MSI for latest release of PowerShell for 64-bit Windows: $FilePath"
}
# if asset not found...
else {
    Write-Warning -Message "could not locate MSI for latest release of PowerShell for 64-bit Windows"
    return
}

# report state
Write-Host "Installing latest release of PowerShell for 64-bit Windows: $($Asset.Name)"

# define parameters
$StartProcess = @{
    NoNewWindow  = $true 
    Wait         = $true 
    FilePath     = 'msiexec.exe'
    ArgumentList = @(
        "/package $FilePath"
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

# report state
Write-Host "Installed latest release of PowerShell for 64-bit Windows"

# rmeove MSI file
try {
    Remove-Item -Path $FilePath -Force
}
catch {
    return $_
}

# report state
Write-Host "Removed MSI for latest release of PowerShell for 64-bit Windows: $FilePath"
