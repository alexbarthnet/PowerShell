# get certificate
$hst = (Get-WmiObject win32_computersystem).DNSHostName + '.' + (Get-WmiObject win32_computersystem).Domain
$eku = "Server Authentication"
$crt = Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.Subject -match $hst -and $_.EnhancedKeyUsageList -match $eku } | Sort-Object NotBefore | Select-Object -Last 1

# get certificate permissions
$key = Join-Path -Path 'C:\ProgramData\Microsoft\Crypto\RSA\MachineKeys' -ChildPath $crt.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
$sid = New-Object System.Security.Principal.SecurityIdentifier @('S-1-5-83-0')
$acl = Get-Acl -Path $key

# update certificate permissions
$ace = New-Object System.Security.AccessControl.FileSystemAccessRule @($sid, 'Read', 'Allow')
$acl.AddAccessRule($ace)
Set-Acl -Path $key -AclObject $acl

# update registry
$reg = Get-Item -Path "HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Virtualization"
$reg | New-ItemProperty -Force -Name "DisableSelfSignedCertificateGeneration" -PropertyType Qword -Value 1
