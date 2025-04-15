[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Default')]
Param(
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

Begin {
	Function Convert-NetAdapterFromDhcpToStatic {
		Param(
			[Microsoft.Management.Infrastructure.CimInstance]$NetAdapter
		)

		# retrieve current interface guid and alias
		$InterfaceName = $NetAdapter.Name
		$InterfaceGuid = $NetAdapter.InterfaceGuid

		# filter adapter bindings to adapter and IPv4
		$NetAdapterBinding = $NetAdapterBindings | Where-Object { $_.InterfaceDescription -eq $NetAdapter.InterfaceDescription } | Where-Object { $_.ComponentID -eq 'ms_tcpip' }

		# if IPv4 not bound to adapter...
		If (!$NetAdapterBinding.Enabled) {
			Write-Host "$InterfaceGuid; $InterfaceName; Could not locate enabled TCP/IP binding on adapter"
			Return
		}

		# retrieve IP interface
		Try {
			$NetIPInterface = $NetAdapter | Get-NetIPInterface -AddressFamily IPv4
		}
		Catch {
			Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not retrieve IP interface for adapter: $($_.Exception.Message)"
			Return $_
		}

		# if DHCP not enabled...
		If ($NetIPInterface.Dhcp -ne 'Enabled') {
			Write-Host "$InterfaceGuid; $InterfaceName; Skipping adapter: DHCP not enabled"
			Return
		}

		# retrieve IP addresses
		Try {
			$NetIPAddresses = $NetAdapter | Get-NetIPAddress -AddressFamily IPv4
		}
		Catch {
			Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not retrieve IP addresses for adapter: $($_.Exception.Message)"
			Return $_
		}

		# if no IP addresses assigned by DHCP...
		if (($NetIPAddresses | Where-Object { $_.PrefixOrigin -eq 'DHCP' -and $_.SuffixOrigin -eq 'DHCP' } | Measure-Object).Count -eq 0) {
			Write-Host "$InterfaceGuid; $InterfaceName; Could not locate any IP addresses assigned by DHCP on adapter"
			Return
		}

		# retrieve default IPv4 route on adapter assigned by DHCP
		Try {
			$NetRoute = $NetAdapter | Get-NetRoute -AddressFamily IPv4 | Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.PreferredLifetime -lt [System.TimeSpan]::MaxValue }
		}
		Catch {
			Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not retrieve network routes for adapter: $($_.Exception.Message)"
			Return $_
		}

		# retrieve DNS client server addresses
		Try {
			$DnsClientServerAddress = $NetAdapter | Get-DnsClientServerAddress -AddressFamily IPv4
		}
		Catch {
			Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not retrieve DNS servers for adapter: $($_.Exception.Message)"
			Return $_
		}

		# disable DHCP on adapter
		Try {
			$NetAdapter | Set-NetIPInterface -Dhcp Disabled
		}
		Catch {
			Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not disable DHCP on adapter: $($_.Exception.Message)"
			Return $_
		}

		# loop through IP addresses
		:NextNetIPAddress ForEach ($NetIPAddress in $NetIPAddresses) {
			# if either origin is not DHCP...
			If ($NetIPAddress.PrefixOrigin -ne 'DHCP' -or $NetIPAddress.SuffixOrigin -ne 'DHCP') {
				# continue to next IP address
				Continue NextNetIPAddress
			}

			# report state
			Write-Verbose -Message "$InterfaceGuid; $InterfaceName; Will assign '$($NetIPAddress.IPv4Address)/$($NetIPAddress.PrefixLength)' as address for adapter"

			# assign IP address
			Try {
				$null = $NetAdapter | New-NetIPAddress -IPAddress $NetIPAddress.IPv4Address -PrefixLength $NetIPAddress.PrefixLength
			}
			Catch {
				Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not assign IP address to adapter: $($_.Exception.Message)"
				Return $_
			}

			# report state
			Write-Verbose -Message "$InterfaceGuid; $InterfaceName; Assign IP address"
		}

		# if default IPv4 route was on adapter and assigned by DHCP
		If ($NetRoute) {
			# report state
			Write-Verbose -Message "$InterfaceGuid; $InterfaceName; Will assign '$($NetRoute.NextHop)' as gateway for adapter"

			# assign default route to adapter statically 
			Try {
				$null = $NetAdapter | New-NetRoute -DestinationPrefix '0.0.0.0/0' -NextHop $NetRoute.NextHop
			}
			Catch {
				Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not remove default route for adapter: $($_.Exception.Message)"
				Return $_
			}

			# report state
			Write-Verbose -Message "$InterfaceGuid; $InterfaceName; Added default route"
		}

		# assign DNS client server addresses
		Try {
			$NetAdapter | Set-DnsClientServerAddress -ServerAddresses $DnsClientServerAddress.ServerAddresses
		}
		Catch {
			Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not assign DNS servers to adapter: $($_.Exception.Message)"
			Return $_
		}
	}

	Function Disable-NetAdapterNetbios {
		Param(
			[Microsoft.Management.Infrastructure.CimInstance]$NetAdapter
		)

		# retrieve current interface guid and alias
		$InterfaceName = $NetAdapter.Name
		$InterfaceGuid = $NetAdapter.InterfaceGuid

		# define path and name for NetBT settings on interface
		$Path = 'HKLM:SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces\Tcpip_{0}' -f $InterfaceGuid
		$Name = 'NetbiosOptions'

		# retrieve current value
		Try {
			$Value = Get-ItemPropertyValue -Path $Path -Name $Name -ErrorAction 'Stop'
		}
		Catch {
			Write-Error -Message "$InterfaceGuid; $InterfaceName; Could not retrieve NetBT setting for adapter: $($_.Exception.Message)"
			Return $_
		}

		# if NetBIOS transport already disabled...
		If ($Value -eq 2) {
			Write-Host "$InterfaceGuid; $InterfaceName; Found NetBT already disabled on adapter"
			Return
		}

		# disable NetBIOS transport
		Try {
			Set-ItemProperty -Path $Path -Name $Name -Value 2 -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not disable NetBT on adapter: $($_.Exception.Message)"
			Return $_
		}

		# report state
		Write-Host "$InterfaceGuid; $InterfaceName; Disabled NetBT on adapter"
	}

	Function Rename-NetAdapterViaProperties {
		Param(
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
		If (![System.String]::IsNullOrEmpty($NetAdapterHardwareInfo.FunctionNumber)) {
			# build the new name from port information
			$NewName = '{0} {1}' -f $FunctionLabel, ($NetAdapterHardwareInfo.FunctionNumber + 1)
			$RenameSource = 'function number'
		}

		# if slot number found...
		If (![System.String]::IsNullOrEmpty($NetAdapterHardwareInfo.SlotNumber)) {
			# build the new name from slot and port information
			$NewName = '{0} {1} {2} {3}' -f $SlotLabel, $NetAdapterHardwareInfo.SlotNumber, $FunctionLabel, ($NetAdapterHardwareInfo.FunctionNumber + 1)
			$RenameSource = 'slot and function numbers'
		}

		# if PCI device label found
		If (![System.String]::IsNullOrEmpty($NetAdapterHardwareInfo.PciDeviceLabelString)) {
			# build the new name from PCI device label
			$NewName = $NetAdapterHardwareInfo.PciDeviceLabelString
			$RenameSource = 'PCI device label'
		}

		# if Hyper-V network adapter name found...
		If (![System.String]::IsNullOrEmpty($HyperVNetworkAdapterName)) {
			# build the name from Hyper-V network adapter name
			$NewName = $HyperVNetworkAdapterName
			$RenameSource = 'Hyper-V'
		}

		# if new name not generated...
		If ([System.String]::IsNullOrEmpty($NewName)) {
			Write-Host "$InterfaceGuid; $InterfaceName; Skipped renaming adapter: could not generate name"
			Return
		}

		# if new name matches current name...
		If ($NewName -eq $NetAdapter.Name) {
			Write-Host "$InterfaceGuid; $InterfaceName; Skipped renaming adapter: generated name matches current name"
			Return
		}

		# rename network adapter
		Try {
			Rename-NetAdapter -InputObject $NetAdapter -NewName $NewName
		}
		Catch {
			Write-Error -Message "$InterfaceGuid; $InterfaceName; Could not rename adapter: $($_.Exception.Message)"
			Return $_
		}

		# report state
		Write-Host "$InterfaceGuid; $InterfaceName; Renamed adapter to '$NewName' from $RenameSource"
	}

	# retrieve advanced properties
	Try {
		$NetAdapterAdvancedProperties = Get-NetAdapterAdvancedProperty
	}
	Catch {
		Throw $_
	}

	# retrieve bindings
	Try {
		$NetAdapterBindings = Get-NetAdapterBinding
	}
	Catch {
		Throw $_
	}

	# retrieve advanced properties
	Try {
		$NetAdapterHardwareInfos = Get-NetAdapterHardwareInfo
	}
	Catch {
		Throw $_
	}

	# switch on parameter set name
	switch ($PSCmdlet.ParameterSetName) {
		'InputObject' {
			$NetAdapters = $script:InputObject
		}
		'InterfaceAlias' {
			# retrieve network adapter by index
			Try {
				$NetAdapters = Get-NetAdapter -InterfaceAlias $script:InterfaceAlias
			}
			Catch {
				Throw $_
			}
		}
		'InterfaceIndex' {
			# retrieve network adapter by index
			Try {
				$NetAdapters = Get-NetAdapter -InterfaceIndex $script:InterfaceIndex
			}
			Catch {
				Throw $_
			}
		}
		'Physical' {
			# retrieve physical network adapters
			Try {
				$NetAdapters = Get-NetAdapter -Physical
			}
			Catch {
				Throw $_
			}
		}
		Default {
			# retrieve all network adapters
			Try {
				$NetAdapters = Get-NetAdapter
			}
			Catch {
				Throw $_
			}
		}
	}
}

Process {
	# if disable LMHOSTS requested...
	If ($PSBoundParameters.ContainsKey('DisableLMHosts')) {
		# define path and name for LMHOSTS lookup setting
		$Path = 'HKLM:SYSTEM\CurrentControlSet\Services\NetBT\Parameters'
		$Name = 'EnableLMHOSTS'

		# retrieve current value
		Try {
			$Value = Get-ItemPropertyValue -Path $Path -Name $Name -ErrorAction 'Stop'
		}
		Catch {
			Write-Error -Message "Could not retrieve LMHOSTS lookup setting on system: $($_.Exception.Message)"
			Continue NextParameter
		}

		# if LMHOSTS lookup already disabled...
		If ($Value -eq 0) {
			Write-Host "$InterfaceGuid; $InterfaceName; Found LMHOSTS lookup already disabled on system"
			Continue NextParameter
		}

		# disable LMHOSTS lookup
		Try {
			Set-ItemProperty -Path $Path -Name $Name -Value 0 -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "$InterfaceGuid; $InterfaceName; Could not disable LMHOSTS lookup on system: $($_.Exception.Message)"
			Continue NextParameter
		}

		# report state
		Write-Host 'Disabled LMHOSTS lookup on system'
	}

	# if disable Netbios requested...
	If ($PSBoundParameters.ContainsKey('DisableNetbios')) {
		# loop through network adapters
		ForEach ($NetAdapter in $NetAdapters ) {
			Disable-NetAdapterNetbios -NetAdapter $NetAdapter
		}
	}

	# if static requested...
	If ($PSBoundParameters.ContainsKey('ConvertFromDhcpToStatic')) {
		# loop through network adapters
		ForEach ($NetAdapter in $NetAdapters) {
			Convert-NetAdapterFromDhcpToStatic -NetAdapter $NetAdapter
		}
	}

	# if rename requested...
	If ($PSBoundParameters.ContainsKey('Rename')) {
		# loop through network adapters
		ForEach ($NetAdapter in $NetAdapters ) {
			Rename-NetAdapterViaProperties -NetAdapter $NetAdapter
		}
	}
}
