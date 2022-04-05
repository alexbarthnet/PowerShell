# define logging
$log_root = (Get-CimInstance -Class Win32_OperatingSystem).WindowsDirectory
$log_file = (Split-Path -Path $PSCommandPath -Leaf).Replace((Get-Item -Path $PSCommandPath).Extension, '.txt')
$log_path = Join-Path -Path $log_root -Child $log_file
# retrieve thumbprints
$cert_in_cimv2 = Get-CimInstance -Class 'Win32_TSGeneralSetting' -Namespace 'root/cimv2/TerminalServices' | Select-Object -Last 1 -ExpandProperty 'SSLCertificateSHA1Hash'
$cert_in_store = Get-ChildItem -Path 'Cert:\LocalMachine\My' | Where-Object {$_.EnhancedKeyUsageList.FriendlyName -like 'Remote*'} | Sort-Object -Property 'NotBefore' | Select-Object -Last 1 -ExpandProperty 'Thumbprint'
# check thumbprints
If ($null -ne $cert_in_store -and $cert_in_cimv2 -ne $cert_in_store) {
	Start-Transcript -Path $log_path -Append
	Get-CimInstance -Class 'Win32_TSGeneralSetting' -Namespace 'root/cimv2/TerminalServices' | Set-CimInstance -Property @{ SSLCertificateSHA1Hash = $cert_in_store }
	Stop-Transcript
}
