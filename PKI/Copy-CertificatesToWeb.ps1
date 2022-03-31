# define transcript file from script path and start transcript
Start-Transcript -Path $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.txt') -Force

# define paths
$dir_array = @()
$dir_array += $pki_certs = 'C:\Content\pki\certsrv'
$dir_array += $pki_pages = 'C:\Content\pki\wwwroot'
$dir_array += $iis_pages = 'C:\inetpub\wwwroot'
$dir_array += $iis_certs = 'C:\inetpub\wwwroot\pki'
 
# verify paths exist
$dir_array | ForEach-Object { If ((Test-Path $_) -eq $false) { New-Item -Type Directory -Path $_ } }
 
# copy DFS files to IIS
If (Test-Path -Path $pki_certs) { Get-ChildItem -Path $pki_certs | Copy-Item -Destination $iis_certs -Force -Verbose }
If (Test-Path -Path $pki_pages) { Get-ChildItem -Path $pki_pages | Copy-Item -Destination $iis_pages -Force -Verbose }
 
# define path for root certificates
$ad_fqdn = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name
$ad_path = ('\\' + $ad_fqdn + '\sysvol\' + $ad_fqdn + '\certificates\root')
 
# copy AD files to IIS
If (Test-Path -Path $ad_path) { Get-ChildItem -Path $ad_path | Copy-Item -Destination $iis_certs -Force -Verbose }

# stop transcript
Stop-Transcript
