[CmdletBinding()]
Param(
	[string[]]$InterfaceAlias,
	[switch]$DisableNetbios,
	[switch]$Rename
)

# retrieve network adapters with hardware interfaces to exclude virtual adapters
$NetAdapters = Get-NetAdapter | Where-Object { $_.HardwareInterface } | Sort-Object InterfaceAlias

# if interface aliases provided...
$NetAdapters = $NetAdapters.Where({ $_.InterfaceAlias -in $InterfaceAlias })

# loop through network adapters
:NextNetAdapter ForEach ($NetAdapter in $NetAdapters) {
	# retrieve current interface guid and alias
	$InterfaceGuid = $NetAdapter.InterfaceGuid
	$InterfaceIndex = $NetAdapter.InterfaceIndex
	$InterfaceAlias = $NetAdapter.Name
	

	# if disable netbios requested...
	If ($DisableNetbios) {
		# define path to NetBT interface from interface guid
		$Path = 'HKLM:SYSTEM\CurrentControlSet\services\NetBT\Parameters\Interfaces\Tcpip_{0}' -f $InterfaceGuid

		# retrieve current value
		Try {
			$Value = Get-ItemPropertyValue -Path $Path -Name 'NetbiosOptions' -ErrorAction 'Stop'
		}
		Catch {
			Write-Error -Message "$InterfaceGuid; $InterfaceAlias; Could not retrieve NetBT setting for adapter: $($_.Exception.Message)"
			Continue NextNetAdapter
		}

		# if NetBIOS transport already disabled...
		If ($Value -eq 2) {
			Write-Host "$InterfaceGuid; $InterfaceAlias; Found NetBT already disabled on adapter"
			Continue NextNetAdapter
		}

		# disable NetBIOS transport
		Try {
			Set-ItemProperty -Path $Path -Name 'NetbiosOptions' -Value 2 -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "$InterfaceGuid; $InterfaceAlias; Could not disable NetBT on adapter: $($_.Exception.Message)"
			Continue NextNetAdapter
		}

		# report state
		Write-Host "$InterfaceGuid; $InterfaceAlias; Disabled NetBT on adapter"
	}

	# if rename requested...
	If ($Rename) {
		# set base names
		$NewName = $null

		# retrieve hardware information
		$NetAdapterHardwareInfo = $NetAdapter | Get-NetAdapterHardwareInfo -ErrorAction SilentlyContinue

		# if port number found...
		If (![System.String]::IsNullOrEmpty($NetAdapterHardwareInfo.FunctionNumber)) {
			# build the new name from port information
			$NewName = 'Port {0}' -f ($NetAdapterHardwareInfo.FunctionNumber + 1)
			$RenameSource = 'port number'
		}

		# if slot number found...
		If (![System.String]::IsNullOrEmpty($NetAdapterHardwareInfo.SlotNumber)) {
			# build the new name from slot and port information
			$NewName = 'Slot {0} Port {0}' -f $NetAdapterHardwareInfo.SlotNumber, ($NetAdapterHardwareInfo.FunctionNumber + 1)
			$RenameSource = 'slot/port number'
		}
 
		# retrieve PCI device label
		$PciDeviceLabelString = $NetAdapter | Get-NetAdapterHardwareInfo -ErrorAction SilentlyContinue | Select-Object -ExpandPropty 'PciDeviceLabelString'

		# if PCI device label found
		If (![System.String]::IsNullOrEmpty($PciDeviceLabelString)) {
			# build the new name from PCI device label
			$NewName = $PciDeviceLabelString
			$RenameSource = 'PCI device label'
		}
 
		# retrieve Hyper-V network adapter name
		$HyperVNetworkAdapterName = $NetAdapter | Get-NetAdapterAdvancedProperty -ErrorAction SilentlyContinue | Where-Object { $_.RegistryKeyword -eq 'HyperVNetworkAdapterName' } | Select-Object -ExpandPropty 'DisplayValue'
		
		# if Hyper-V network adapter name found...
		If (![System.String]::IsNullOrEmpty($HyperVNetworkAdapterName)) {
			# build the name from Hyper-V network adapter name
			$NewName = $HyperVNetworkAdapterName
			$RenameSource = 'Hyper-V'
		} 

		# if new name not generated...
		If ([System.String]::IsNullOrEmpty($NewName)) {
			Write-Host "$InterfaceGuid; $InterfaceAlias; Skipped renaming adapter: could not generate name"
			Continue NextNetAdapter
		}

		# if new name matches current name...
		If ($NewName -eq $NetAdapter.Name) { 
			Write-Host "$InterfaceGuid; $InterfaceAlias; Skipped renaming adapter: generated name matches current name"
			Continue NextNetAdapter
		}

		# rename network adapter
		Try {
			Rename-NetAdapter -InterfaceIndex $InterfaceIndex -NewName $NewName
		}
		Catch {
			Write-Error -Message "$InterfaceGuid; $InterfaceAlias; Could not rename adapter: $($_.Exception.Message)"
			Continue NextNetAdapter
		}

		# report state
		Write-Host "$InterfaceGuid; $InterfaceAlias; Renamed adapter to '$NewName' from $RenameSource"
	}
}
