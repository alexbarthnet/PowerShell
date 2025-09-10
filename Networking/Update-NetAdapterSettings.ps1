[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Default')]
param(
	[Parameter(ParameterSetName = 'InputObject', ValueFromPipeline)][ValidateScript({ $_.CimClass.CimClassName -eq 'MSFT_NetAdapter' })]
	[Microsoft.Management.Infrastructure.CimInstance[]]$InputObject,
	[Parameter(ParameterSetName = 'InterfaceAlias')][Alias('ifAlias', 'Name')]
	[string]$InterfaceAlias,
	[Parameter(ParameterSetName = 'InterfaceIndex')][Alias('ifIndex')]
	[uint16]$InterfaceIndex,
	[Parameter(ParameterSetName = 'Physical')]
	[switch]$Physical,
	[switch]$DisableLMHosts,
	[switch]$DisableNetbios,
	[switch]$Rename,
	[switch]$ConvertFromDhcpToStatic
)

begin {
	function Disable-LMHosts {
		# define path and name for LMHOSTS lookup setting
		$Path = 'HKLM:SYSTEM\CurrentControlSet\Services\NetBT\Parameters'
		$Name = 'EnableLMHOSTS'

		# retrieve current value
		try {
			$Value = Get-ItemPropertyValue -Path $Path -Name $Name -ErrorAction 'Stop'
		}
		catch {
			Write-Error -Message "Could not retrieve LMHOSTS lookup setting on system: $($_.Exception.Message)"
			return
		}

		# if LMHOSTS lookup already disabled...
		if ($Value -eq 0) {
			Write-Host 'Found LMHOSTS lookup already disabled on system'
			return
		}

		# disable LMHOSTS lookup
		try {
			Set-ItemProperty -Path $Path -Name $Name -Value 0 -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not disable LMHOSTS lookup on system: $($_.Exception.Message)"
			return
		}

		# report state
		Write-Host 'Disabled LMHOSTS lookup on system'
	}

	function Convert-NetAdapterFromDhcpToStatic {
		param(
			[Microsoft.Management.Infrastructure.CimInstance]$NetAdapter
		)

		# retrieve current interface guid and alias
		$InterfaceName = $NetAdapter.Name
		$InterfaceGuid = $NetAdapter.InterfaceGuid

		# filter adapter bindings to adapter and IPv4
		$NetAdapterBinding = $NetAdapterBindings | Where-Object { $_.InterfaceDescription -eq $NetAdapter.InterfaceDescription } | Where-Object { $_.ComponentID -eq 'ms_tcpip' }

		# if IPv4 not bound to adapter...
		if (!$NetAdapterBinding.Enabled) {
			Write-Host "$InterfaceGuid; $InterfaceName; Could not locate enabled TCP/IP binding on adapter"
			return
		}

		# retrieve IP interface
		try {
			$NetIPInterface = $NetAdapter | Get-NetIPInterface -AddressFamily IPv4
		}
		catch {
			Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not retrieve IP interface for adapter: $($_.Exception.Message)"
			return $_
		}

		# if DHCP not enabled...
		if ($NetIPInterface.Dhcp -ne 'Enabled') {
			Write-Host "$InterfaceGuid; $InterfaceName; Skipping adapter: DHCP not enabled"
			return
		}

		# retrieve IP addresses
		try {
			$NetIPAddresses = $NetAdapter | Get-NetIPAddress -AddressFamily IPv4
		}
		catch {
			Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not retrieve IP addresses for adapter: $($_.Exception.Message)"
			return $_
		}

		# if no IP addresses assigned by DHCP...
		if (($NetIPAddresses | Where-Object { $_.PrefixOrigin -eq 'DHCP' -and $_.SuffixOrigin -eq 'DHCP' } | Measure-Object).Count -eq 0) {
			Write-Host "$InterfaceGuid; $InterfaceName; Could not locate any IP addresses assigned by DHCP on adapter"
			return
		}

		# retrieve default IPv4 route on adapter assigned by DHCP
		try {
			$NetRoute = $NetAdapter | Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.PreferredLifetime -lt [System.TimeSpan]::MaxValue }
		}
		catch {
			Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not retrieve network routes for adapter: $($_.Exception.Message)"
			return $_
		}

		# retrieve DNS client server addresses
		try {
			$DnsClientServerAddress = $NetAdapter | Get-DnsClientServerAddress -AddressFamily IPv4
		}
		catch {
			Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not retrieve DNS servers for adapter: $($_.Exception.Message)"
			return $_
		}

		# disable DHCP on adapter
		try {
			$NetAdapter | Set-NetIPInterface -Dhcp Disabled
		}
		catch {
			Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not disable DHCP on adapter: $($_.Exception.Message)"
			return $_
		}

		# loop through IP addresses
		:NextNetIPAddress foreach ($NetIPAddress in $NetIPAddresses) {
			# if either origin is not DHCP...
			if ($NetIPAddress.PrefixOrigin -ne 'DHCP' -or $NetIPAddress.SuffixOrigin -ne 'DHCP') {
				# continue to next IP address
				continue NextNetIPAddress
			}

			# report state
			Write-Host "$InterfaceGuid; $InterfaceName; Will assign '$($NetIPAddress.IPv4Address)/$($NetIPAddress.PrefixLength)' as address for adapter"

			# assign IP address
			try {
				$null = $NetAdapter | New-NetIPAddress -IPAddress $NetIPAddress.IPv4Address -PrefixLength $NetIPAddress.PrefixLength
			}
			catch {
				Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not assign IP address to adapter: $($_.Exception.Message)"
				return $_
			}

			# report state
			Write-Host "$InterfaceGuid; $InterfaceName; Assigned IP address"
		}

		# if default IPv4 route was on adapter and assigned by DHCP
		if ($NetRoute) {
			# report state
			Write-Host "$InterfaceGuid; $InterfaceName; Will add '$($NetRoute.NextHop)' as default gateway for adapter"

			# assign default route to adapter statically 
			try {
				$null = $NetAdapter | New-NetRoute -DestinationPrefix '0.0.0.0/0' -NextHop $NetRoute.NextHop
			}
			catch {
				Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not add default gateway for adapter: $($_.Exception.Message)"
				return $_
			}

			# report state
			Write-Host "$InterfaceGuid; $InterfaceName; Added default gateway"
		}

		# if DNS client server addresses were assigned by DHCP...
		if ($DnsClientServerAddress) {
			# report state
			Write-Host "$InterfaceGuid; $InterfaceName; Will assign '$($DnsClientServerAddress.ServerAddresses)' as DNS servers for adapter"

			# assign DNS client server addresses
			try {
				$NetAdapter | Set-DnsClientServerAddress -ServerAddresses $DnsClientServerAddress.ServerAddresses
			}
			catch {
				Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not assign DNS servers to adapter: $($_.Exception.Message)"
				return $_
			}

			# report state
			Write-Host "$InterfaceGuid; $InterfaceName; Assigned DNS servers"
		}
	}

	function Disable-NetAdapterNetbios {
		param(
			[Microsoft.Management.Infrastructure.CimInstance]$NetAdapter
		)

		# retrieve current interface guid and alias
		$InterfaceName = $NetAdapter.Name
		$InterfaceGuid = $NetAdapter.InterfaceGuid

		# define path and name for NetBT settings on interface
		$Path = 'HKLM:SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces\Tcpip_{0}' -f $InterfaceGuid
		$Name = 'NetbiosOptions'

		# retrieve current value
		try {
			$Value = Get-ItemPropertyValue -Path $Path -Name $Name -ErrorAction 'Stop'
		}
		catch {
			Write-Error -Message "$InterfaceGuid; $InterfaceName; Could not retrieve NetBT setting for adapter: $($_.Exception.Message)"
			return $_
		}

		# if NetBIOS transport already disabled...
		if ($Value -eq 2) {
			Write-Host "$InterfaceGuid; $InterfaceName; Found NetBT already disabled on adapter"
			return
		}

		# disable NetBIOS transport
		try {
			Set-ItemProperty -Path $Path -Name $Name -Value 2 -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not disable NetBT on adapter: $($_.Exception.Message)"
			return $_
		}

		# report state
		Write-Host "$InterfaceGuid; $InterfaceName; Disabled NetBT on adapter"
	}

	function Rename-NetAdapterViaProperties {
		param(
			[Microsoft.Management.Infrastructure.CimInstance]$NetAdapter,
			[System.String]$NewName = [System.String]::Empty,
			[System.String]$SlotLabel = 'Slot',
			[System.String]$FunctionLabel = 'Port'
		)

		# retrieve adapter properties
		$InterfaceName = $NetAdapter.Name
		$InterfaceGuid = $NetAdapter.InterfaceGuid

		# filter hardware information to network adapter
		$NetAdapterHardwareInfo = $NetAdapterHardwareInfos | Where-Object { $_.InterfaceDescription -eq $NetAdapter.InterfaceDescription }

		# filter advanced properties to network adapter
		$NetAdapterAdvancedProperty = $NetAdapterAdvancedProperties | Where-Object { $_.InterfaceDescription -eq $NetAdapter.InterfaceDescription }

		# retrieve Hyper-V network adapter name from advanced properties
		$HyperVNetworkAdapterName = $NetAdapterAdvancedProperty | Where-Object { $_.RegistryKeyword -eq 'HyperVNetworkAdapterName' } | Select-Object -ExpandProperty 'RegistryValue'

		# if port number found...
		if (![System.String]::IsNullOrEmpty($NetAdapterHardwareInfo.FunctionNumber)) {
			# build the new name from port information
			$NewName = '{0} {1}' -f $FunctionLabel, ($NetAdapterHardwareInfo.FunctionNumber + 1)
			$RenameSource = 'function number'
		}

		# if slot number found...
		if (![System.String]::IsNullOrEmpty($NetAdapterHardwareInfo.SlotNumber)) {
			# build the new name from slot and port information
			$NewName = '{0} {1} {2} {3}' -f $SlotLabel, $NetAdapterHardwareInfo.SlotNumber, $FunctionLabel, ($NetAdapterHardwareInfo.FunctionNumber + 1)
			$RenameSource = 'slot and function numbers'
		}

		# if PCI device label found
		if (![System.String]::IsNullOrEmpty($NetAdapterHardwareInfo.PciDeviceLabelString)) {
			# build the new name from PCI device label
			$NewName = $NetAdapterHardwareInfo.PciDeviceLabelString
			$RenameSource = 'PCI device label'
		}

		# if Hyper-V network adapter name found...
		if (![System.String]::IsNullOrEmpty($HyperVNetworkAdapterName)) {
			# build the name from Hyper-V network adapter name
			$NewName = $HyperVNetworkAdapterName
			$RenameSource = 'Hyper-V'
		}

		# if new name not generated...
		if ([System.String]::IsNullOrEmpty($NewName)) {
			Write-Host "$InterfaceGuid; $InterfaceName; Skipped renaming adapter: could not generate name"
			return
		}

		# if new name matches current name...
		if ($NewName -eq $NetAdapter.Name) {
			Write-Host "$InterfaceGuid; $InterfaceName; Skipped renaming adapter: generated name matches current name"
			return
		}

		# rename network adapter
		try {
			Rename-NetAdapter -InputObject $NetAdapter -NewName $NewName
		}
		catch {
			Write-Error -Message "$InterfaceGuid; $InterfaceName; Could not rename adapter: $($_.Exception.Message)"
			return $_
		}

		# report state
		Write-Host "$InterfaceGuid; $InterfaceName; Renamed adapter to '$NewName' from $RenameSource"
	}

	# retrieve advanced properties
	try {
		$NetAdapterAdvancedProperties = Get-NetAdapterAdvancedProperty
	}
	catch {
		throw $_
	}

	# retrieve bindings
	try {
		$NetAdapterBindings = Get-NetAdapterBinding
	}
	catch {
		throw $_
	}

	# retrieve advanced properties
	try {
		$NetAdapterHardwareInfos = Get-NetAdapterHardwareInfo
	}
	catch {
		throw $_
	}

	# switch on parameter set name
	switch ($PSCmdlet.ParameterSetName) {
		'InputObject' {
			$NetAdapters = $script:InputObject
		}
		'InterfaceAlias' {
			# retrieve network adapter by index
			try {
				$NetAdapters = Get-NetAdapter -InterfaceAlias $script:InterfaceAlias
			}
			catch {
				throw $_
			}
		}
		'InterfaceIndex' {
			# retrieve network adapter by index
			try {
				$NetAdapters = Get-NetAdapter -InterfaceIndex $script:InterfaceIndex
			}
			catch {
				throw $_
			}
		}
		'Physical' {
			# retrieve physical network adapters
			try {
				$NetAdapters = Get-NetAdapter -Physical
			}
			catch {
				throw $_
			}
		}
		Default {
			# retrieve all network adapters
			try {
				$NetAdapters = Get-NetAdapter
			}
			catch {
				throw $_
			}
		}
	}
}

process {
	# if disable LMHOSTS requested...
	if ($PSBoundParameters.ContainsKey('DisableLMHosts')) {
		try {
			Disable-LMHosts
		}
		catch {
			return $_
		}
	}

	# retrieve count of netadapters
	$NetAdaptersCount = $NetAdapters | Measure-Object | Select-Object -ExpandProperty 'Count'

	# if disable Netbios requested...
	if ($PSBoundParameters.ContainsKey('DisableNetbios')) {
		# report state
		Write-Host "Disabling Netbios on '$NetAdaptersCount' adapters"

		# loop through network adapters
		foreach ($NetAdapter in $NetAdapters ) {
			try {
				Disable-NetAdapterNetbios -NetAdapter $NetAdapter
			}
			catch {
				return $_
			}
		}
	}

	# if static requested...
	if ($PSBoundParameters.ContainsKey('ConvertFromDhcpToStatic')) {
		# report state
		Write-Host "Converting IP addresses from DHCP to static on '$NetAdaptersCount' adapters"

		# loop through network adapters
		foreach ($NetAdapter in $NetAdapters) {
			try {
				Convert-NetAdapterFromDhcpToStatic -NetAdapter $NetAdapter
			}
			catch {
				return $_
			}
		}
	}

	# if rename requested...
	if ($PSBoundParameters.ContainsKey('Rename')) {
		# report state
		Write-Host "Renaming '$NetAdaptersCount' adapters"

		# loop through network adapters
		foreach ($NetAdapter in $NetAdapters ) {
			try {
				Rename-NetAdapterViaProperties -NetAdapter $NetAdapter
			}
			catch {
				return $_
			}
		}
	}
}
