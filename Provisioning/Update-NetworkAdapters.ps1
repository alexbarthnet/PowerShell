# define logging
$log_root = (Get-CimInstance -Class Win32_OperatingSystem).WindowsDirectory
$log_file = $PSCommandPath.Split('\')[-1].Replace('.ps1', '.txt')
$log_path = Join-Path -Path $log_root -Child $log_file
# retrieve Hyper-V adapter names and NetBIOS transport settings
$nics_to_rename = Get-NetAdapterAdvancedProperty -RegistryKeyword 'HyperVNetworkAdapterName' | Where-Object { $_.Name -ne $_.DisplayValue -and -not [string]::IsNullOrEmpty($_.DisplayValue) }
$nics_w_netbios = Get-ChildItem 'HKLM:SYSTEM\CurrentControlSet\services\NetBT\Parameters\Interfaces' | Get-ItemProperty | Where-Object { $_.NetbiosOptions -eq '0' }
$restart_needed = $false
# update network adapters
If ($nics_to_rename.Count -gt 0 -or $nics_w_netbios.Count -gt 0) {
	Start-Transcript -Path $log_path -Append
	ForEach ($nic_to_rename in $nics_to_rename) {
		# rename NICs with Hyper-V adapter name
		Try {
			Get-NetAdapter -Name $nic_to_rename.Name | Rename-NetAdapter -NewName $nic_to_rename.DisplayValue
			Write-Output "Renaming '$($nic_to_rename.Name)' to '$($nic_to_rename.DisplayValue)'"
		}
		Catch {
			Write-Error -Message "Could not rename '$($nic_to_rename.Name)' to '$($nic_to_rename.DisplayValue)'"
		}
	}
	ForEach ($nic_w_netbios in $nics_w_netbios) {
		# get NIC properties
		$nic_ifguid = $nic_w_netbios.PSChildName.Replace('Tcpip_', $null)
		$nic_object = Get-NetAdapter -Physical | Where-Object { $_.InterfaceGuid -eq $nic_ifguid }
		# disable NetBIOS transport
		Try {
			Set-ItemProperty -Path $nic_w_netbios.PSPath -Name 'NetbiosOptions' -Value 2
			Write-Output "Disabling NetBT on adapter '$($nic_object.Name)' with GUID '$nic_ifguid'"
			$restart_needed = $true
		}
		Catch {
			Write-Error -Message "Could not disable NetBT on adapter '$($nic_object.Name)' with GUID '$nic_ifguid'"
		}
	}
	# reload network adapter
	If ($restart_needed) {
		Restart-Computer -Force
	}
	Stop-Transcript
}
