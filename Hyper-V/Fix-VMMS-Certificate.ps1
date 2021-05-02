$host_name = (Get-WmiObject win32_computersystem).DNSHostName + "." + (Get-WmiObject win32_computersystem).Domain
$host_cert = Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object {$_.Subject -match $host_name -and $_.Issuer -notmatch $host_name -and $_.EnhancedKeyUsageList -match "Server Authentication"} | Sort-Object NotBefore | Select-Object -Last 1
$vmms_hash = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization" -Name "AuthCertificateHash" -ErrorAction SilentlyContinue
If ($host_cert) {
    If ($vmms_hash -eq $host_cert) {
        Write-Host "all is well!"
    } Else {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization" -Name "AuthCertificateHash" -Type String -Value $host_cert.Thumbprint
        Restart-Service VMMS
    }
}
