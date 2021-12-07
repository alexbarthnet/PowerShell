[CmdletBinding()]
Param (
    [Parameter()]
    [switch]$Install,
    [switch]$Force
)

# define configuration file from script path then test path
$json_path = $PSCommandPath.Replace('.ps1', '.json')

# clear required objects then check file
If (Test-Path -Path $json_path) {
    # create object from JSON file
    $json_data = Get-Content -Path $json_path | ConvertFrom-Json
    
    # retrieve values from JSON
    If ([string]::IsNullOrEmpty($json_data.Length)) {
        $zip_size = 0
    }
    Else {
        $zip_size = [int32]($json_data.Length)
    }
} 
Else {
    # define expected JSON file name
    $zip_size = 0
}

# define strings
$zip_name = 'OpenSSH-Win64.zip'

# retrieve information on latest release
$uri_path = 'https://github.com/PowerShell/Win32-OpenSSH/releases/latest/'
$uri_file = (Invoke-WebRequest -Uri $uri_path -UseBasicParsing -MaximumRedirection 0 -ErrorAction SilentlyContinue).Headers.Location.Replace('/tag/', '/download/') + '/' + $zip_name
$uri_size = (Invoke-WebRequest -Uri $uri_file -UseBasicParsing -Method Head).Headers.'Content-Length'

# check file sizes
If ($Force -or $Install -or $uri_size -ne $zip_size) {
    # create temp file
    $tmp_file = New-TemporaryFile

    # remove any previous downloads
    Get-ChildItem -Path $tmp_file.PSParentPath -Filter $zip_name | Remove-Item -Force
    
    # download latest release to temp file
    Invoke-WebRequest -Uri $uri_file -OutFile $tmp_file

    # rename temp file
    $zip_file = Rename-Item -Path $tmp_file -NewName $zip_name -PassThru

    # save file information to JSON
    $zip_file | Select-Object FullName, Length | ConvertTo-Json | Set-Content -Path $json_path

    # extract files
    Expand-Archive -Path $zip_file -DestinationPath ([System.Environment]::GetFolderPath('ProgramFiles')) -Force

    # remove temp file
    $zip_file | Remove-Item -Force

    # install app
    If ($Install) {
        . "$([System.Environment]::GetFolderPath('ProgramFiles'))\$($zip_file.BaseName)\install-sshd.ps1"
    }
}
Else {
    Write-Output 'Size of most recent download matches current download size, skipping!'
}
