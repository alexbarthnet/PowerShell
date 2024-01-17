# retrieve enumerated devices in CurrentControlSet
$EnumeratedDevices = Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Hardware Profiles\Current\System\CurrentControlSet\Enum' -Recurse
# identify devices where the CSConfigFlags has been set to 1 ('Not Present' in Get-NetAdapter)
$NotPresentDevices = $EnumeratedDevices | Where-Object { $_.Property -eq 'CSConfigFlags' } | Where-Object { (Get-ItemPropertyValue -Path $_.PSPath -Name 'CSConfigFlags') -eq '1' }
# reset CSConfigFlags back to 0
$NotPresentDevices | ForEach-Object { Set-ItemProperty -Path $_.PSPath -Name CSConfigFlags -Value 0 }