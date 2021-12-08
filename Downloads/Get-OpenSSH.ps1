[CmdletBinding()]
Param (
    [Parameter(Position = 0)][ValidateScript({ Test-Path -Path $_ })]
    [string]$Destination = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path,
    [Parameter(Position = 1)]
    [switch]$Install,
    [Parameter(Position = 2)]
    [switch]$Force
)

# define local objects
$zip_down = $false
$zip_name = 'OpenSSH-Win64.zip'
$zip_file = Join-Path -Path $Destination -ChildPath $zip_name

# retrieve information on latest release
$uri_path = 'https://github.com/PowerShell/Win32-OpenSSH/releases/latest/'
$uri_file = (Invoke-WebRequest -Uri $uri_path -UseBasicParsing -MaximumRedirection 0 -ErrorAction SilentlyContinue).Headers.Location.Replace('/tag/', '/download/') + '/' + $zip_name
$uri_size = (Invoke-WebRequest -Uri $uri_file -UseBasicParsing -Method Head).Headers.'Content-Length'

# check file
If (Test-Path $zip_file) {
    If ($uri_size -eq (Get-ItemProperty $zip_file).Length -and -not $Force) {
        Write-Output 'Size of most recent download matches current download size, skipping!'
    }
    Else {
        $zip_down = $true
    }
}
Else {
    $zip_down = $true
}

# download file
If ($zip_down) {
    # download latest release to temp file
    Invoke-WebRequest -Uri $uri_file -OutFile $zip_file
}

# install file
If ($Install) {
    # extract files
    Expand-Archive -Path $zip_file -DestinationPath ([System.Environment]::GetFolderPath('ProgramFiles')) -Force
    # run install script
    . "$([System.Environment]::GetFolderPath('ProgramFiles'))\$($zip_file.BaseName)\install-sshd.ps1"
}
