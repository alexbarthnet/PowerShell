# define strings
$uri_file = "https://download.sysinternals.com/files/SysinternalsSuite.zip"
$zip_name = "SysinternalsSuite.zip"

# build file paths
$zip_file = Join-Path -Path $PSScriptRoot -ChildPath $zip_name

# get file sizes
$uri_size = (Invoke-WebRequest -Uri $uri_file -UseBasicParsing -Method Head).Headers.'Content-Length'
$zip_size = (Get-ItemProperty -Path $zip_file -ErrorAction SilentlyContinue).Length

# check file sizes
If ($uri_size -eq $zip_size) {
    Write-Output "The local file and remote file have the same size, skipping download"
}
Else {
    # download file
    Invoke-WebRequest -Uri $uri_file -OutFile $zip_file

    # build file path using downloaded file
    $zip_path = Join-Path -Path $PSScriptRoot -ChildPath (Get-Item -Path $zip_file).BaseName

    # extract files
    Expand-Archive -Path $zip_file -DestinationPath $zip_path -Force    
}
