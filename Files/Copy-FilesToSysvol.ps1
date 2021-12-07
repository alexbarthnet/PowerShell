[CmdletBinding()]
Param(
    [string]$Source = "$([System.Environment]::GetFolderPath('MyDocuments'))\Code\PowerShell",
    [string]$Destination = "\\$([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name)\sysvol\$([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name)\scripts",
    [string[]]$Folders = @('Certificates', 'Clusters', 'Credentials', 'Modules', 'PKI'),
    [string[]]$Extensions = @('.ps1','.psm1')
)

# get folder object
$folder = Get-Item -Path $Source

# get file objects
$files = $folder | Get-ChildItem -Directory | Where-Object { $_.Name -in $Folders } | Get-ChildItem | Where-Object { $_.Extension -in $Extensions }

# copy files
ForEach ($item in $files) { 
    # verify parent directory
    $parent = Join-Path -Path $Destination -ChildPath $item.DirectoryName.Substring($folder.FullName.Length)
    If ((Test-Path -Path $parent) -eq $false) { New-Item -ItemType Directory -Path $parent | Out-Null }
    
    # copy file
    $file = Join-Path -Path $Destination -ChildPath $item.FullName.Substring($folder.FullName.Length)
    $item | Copy-Item -Force -Verbose -Destination $file
}
