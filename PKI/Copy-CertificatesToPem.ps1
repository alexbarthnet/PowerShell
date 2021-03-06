Param(
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

# define transcript file from script path and start transcript
Start-Transcript -Path $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, "_$HostName.txt") -Force

# define paths
$ca_dir = "C:\Windows\system32\CertSrv\CertEnroll"
$ca_pki = "C:\Content\pki\certsrv"
 
# verify paths
If ((Test-Path -Path $ca_dir) -eq $false) { Write-Error -Message "Certification Authority directory not found"; Return }
If ((Test-Path -Path $ca_pki) -eq $false) { New-Item -Type Directory -Path $ca_pki}
 
# copy CRL file
$ca_crl = Get-ChildItem -Path $ca_dir | Where-Object {$_.Extension -eq ".crl"}
$ca_crl | Copy-Item -Destination $ca_pki -Verbose
 
# get CRT file object and byte encoding
$ca_file = Get-ChildItem -Path $ca_dir | Where-Object {$_.Extension -eq ".crt"} | Sort-Object LastWriteTime | Select-Object -Last 1
$ca_byte = Get-Content -Path $ca_file.FullName -Encoding Byte

# get CRT file without hostname
$ca_host = (Get-CimInstance -Class Win32_ComputerSystem).Name
$ca_part = $ca_host.Split("_").Count
$ca_name = $ca_file.BaseName.Split("_",$ca_part+1)[$ca_part]

# copy CRT file
$ca_path = Join-Path -Path $ca_pki -ChildPath ($ca_name + ".crt")
$ca_file | Copy-Item -Destination $ca_path -Verbose
 
# define the required strings for base64 files
$ca_base64 = [System.Convert]::ToBase64String($ca_byte)
$ca_header = "-----BEGIN CERTIFICATE-----"
$ca_footer = "-----END CERTIFICATE-----"

# define the environment specific line break strings
$ca_break_win = "`r`n"
$ca_break_pem = "`n"
 
# insert the environment specific line break after the 64th character on each line
$ca_base64_win = $ca_base64 -replace '.{64}',"`$&$ca_break_win"
$ca_base64_pem = $ca_base64 -replace '.{64}',"`$&$ca_break_pem"
 
# define the file names for each certificate type
$ca_file_win = Join-Path -Path $ca_pki -ChildPath ($ca_name + ".cer")
$ca_file_pem = Join-Path -Path $ca_pki -ChildPath ($ca_name + ".pem")
 
# set the header and footer around each base64-encoded certificate then export the content to the associated file
($ca_header, $ca_base64_win, $ca_footer) -join $ca_break_win | Out-File -FilePath $ca_file_win -Encoding ASCII -Force -NoNewline -Verbose
($ca_header, $ca_base64_pem, $ca_footer) -join $ca_break_pem | Out-File -FilePath $ca_file_pem -Encoding ASCII -Force -NoNewline -Verbose
 
# append an environment specific line break to the end of the file
Add-Content -Path $ca_file_win -Value $ca_break_win -NoNewline
Add-Content -Path $ca_file_pem -Value $ca_break_pem -NoNewline

# stop transcript
Stop-Transcript
