[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[string]$VMName,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[string]$VMHost,
	[Parameter(ParameterSetName = 'Add')]
	[string]$Path,
	[Parameter(ParameterSetName = 'Add')][ValidateRange(1, 256)]
	[uint16]$ProcessorCount,
	[Parameter(ParameterSetName = 'Add')][ValidateScript({ ($_ -ge 32MB) -and ($_ -le 12TB) })]
	[uint64]$MemoryStartupBytes,
	[Parameter(ParameterSetName = 'Add')][ValidateScript({ ($_ -ge 32MB) -and ($_ -le 12TB) })]
	[uint64]$MemoryMinimumBytes,
	[Parameter(ParameterSetName = 'Add')][ValidateScript({ ($_ -ge 32MB) -and ($_ -le 12TB) })]
	[uint64]$MemoryMaximumBytes,
	[Parameter(ParameterSetName = 'Add')][ValidateScript({ ($_ -ge 3MB) -and ($_ -le 64TB) })]
	[uint64]$VHDSizeBytes,
	[Parameter(ParameterSetName = 'Add')][ValidateScript({ ($_ -ge 3MB) -and ($_ -le 64TB) })]
	[uint64]$DataVHDSizeBytes,
	[Parameter(ParameterSetName = 'Add')][ValidateRange(0, 63)]
	[uint16]$DataVHDCount,
	[Parameter(ParameterSetName = 'Add')][ValidateScript({ ($_ -ge 3MB) -and ($_ -le 64TB) })]
	[uint64]$ExcludedVHDSizeBytes,
	[Parameter(ParameterSetName = 'Add')][ValidateRange(0, 63)]
	[uint16]$ExcludedVHDCount,
	[Parameter(ParameterSetName = 'Add')]
	[string]$SwitchName,
	[Parameter(ParameterSetName = 'Add')][ValidateRange(0, 4094)]
	[uint16]$VLAN,
	[Parameter(ParameterSetName = 'Add')]
	[string]$NetworkAdapterName = 'Network Adapter',
	[Parameter(ParameterSetName = 'Add')]
	[string]$MacAddressPrefix,
	[Parameter(ParameterSetName = 'Add')]
	[string]$IPAddress,
	[Parameter(ParameterSetName = 'Add')]
	[string]$DhcpServer,
	[Parameter(ParameterSetName = 'Add')]
	[string]$DhcpScope,
	[Parameter(ParameterSetName = 'Add')][ValidateSet('ISO', 'SCCM', 'WDS')]
	[string]$DeploymentMethod,
	[Parameter(ParameterSetName = 'Add')]
	[string]$DeploymentPath,
	[Parameter(ParameterSetName = 'Add')]
	[string]$DeploymentServer,
	[Parameter(ParameterSetName = 'Add')]
	[string]$DeploymentDomain,
	[Parameter(ParameterSetName = 'Add')]
	[string]$DeploymentCollection,
	[Parameter(ParameterSetName = 'Add')]
	[string]$MaintenanceCollection,
	[Parameter(ParameterSetName = 'Add')]
	[uint32]$ClusterPriority,
	[Parameter()]
	[string]$Json
)

# if JSON file not provided...
If ([string]::IsNullOrEmpty($Json)) {
	# ...define default JSON file
	$Json = $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.json')
}

# verify JSON file
If (-not (Test-Path -Path $Json)) {
	If ($Add) {
		Try {
			$null = New-Item -ItemType 'File' -Path $Json
		}
		Catch {
			Write-Output "`nERROR: could not create configuration file:"
			Write-Output "$Json`n"
			Return
		}
	}
	Else {
		Write-Output "`nERROR: could not find configuration file:"
		Write-Output "$Json`n"
		Return
	}
}

# import JSON data
$json_data = @()
$json_data += Get-Content -Path $Json | ConvertFrom-Json

# evaluate parameters
switch ($true) {
	$Clear {
		# remove configuration file
		Write-Warning -Message "Continuing will remove the configuration file '$Json'"
		If (Test-Path -Path $Json) {
			Try {
				Remove-Item -Path $Json -Force
				Write-Output "`nCleared configuration file: '$Json'"
			}
			Catch {
				Write-Output "`nERROR: could not clear configuration file: '$Json'"
			}
		}
	}
	$Remove {
		# remove matching entries from object
		Try {
			$json_data = $json_data | Where-Object { $_.VMName -ne $VMName }
			If ($null -eq $json_data) {
				[string]::Empty | Set-Content -Path $Json
				Write-Output "`nRemoved '$VMName' from configuration file: '$Json'"
			}
			Else {
				$json_data | ConvertTo-Json | Set-Content -Path $Json
				Write-Output "`nRemoved '$VMName' from configuration file: '$Json'"
			}
			$json_data | Format-List
		}
		Catch {
			Write-Output "`nERROR: could not update configuration file: '$Json'"
		}
	}
	$Add {
		# define ordered hashtable with required parameters
		$json_hash = [ordered]@{
			VMName = $VMName
			VMHost = $VMHost
		}
		# update ordered hashtable with optional parameters
		If ($Path) { $json_hash['Path'] = $Path }
		If ($ProcessorCount) { $json_hash['ProcessorCount'] = $ProcessorCount }
		If ($MemoryStartupBytes) { $json_hash['MemoryStartupBytes'] = $MemoryStartupBytes }
		If ($MemoryMinimumBytes) { $json_hash['MemoryMinimumBytes'] = $MemoryMinimumBytes }
		If ($MemoryMaximumBytes) { $json_hash['MemoryMaximumBytes'] = $MemoryMaximumBytes }
		If ($VHDSizeBytes) { $json_hash['VHDSizeBytes'] = $VHDSizeBytes }
		If ($DataVHDSizeBytes) { $json_hash['DataVHDSizeBytes'] = $DataVHDSizeBytes }
		If ($DataVHDCount) { $json_hash['DataVHDCount'] = $DataVHDCount }
		If ($ExcludedVHDSizeBytes) { $json_hash['ExcludedVHDSizeBytes'] = $ExcludedVHDSizeBytes }
		If ($ExcludedVHDCount) { $json_hash['ExcludedVHDCount'] = $ExcludedVHDCount }
		If ($SwitchName) { $json_hash['SwitchName'] = $SwitchName }
		If ($VLAN) { $json_hash['VLAN'] = $VLAN }
		If ($NetworkAdapterName) { $json_hash['NetworkAdapterName'] = $NetworkAdapterName }
		If ($MacAddressPrefix) { $json_hash['MacAddressPrefix'] = $MacAddressPrefix }
		If ($IPAddress) { $json_hash['IPAddress'] = $IPAddress }
		If ($DhcpServer) { $json_hash['DhcpServer'] = $DhcpServer }
		If ($DhcpScope) { $json_hash['DhcpScope'] = $DhcpScope }
		If ($DeploymentMethod) { $json_hash['DeploymentMethod'] = $DeploymentMethod }
		If ($DeploymentServer) { $json_hash['DeploymentServer'] = $DeploymentServer }
		If ($DeploymentPath) { $json_hash['DeploymentPath'] = $DeploymentPath }
		If ($DeploymentDomain) { $json_hash['DeploymentDomain'] = $DeploymentDomain }
		If ($DeploymentCollection) { $json_hash['DeploymentCollection'] = $DeploymentCollection }
		If ($MaintenanceCollection) { $json_hash['MaintenanceCollection'] = $MaintenanceCollection }
		If ($ClusterPriority) { $json_hash['ClusterPriority'] = $ClusterPriority }
		# create custom object from parameters then add to object
		Try {
			# remove any existing VM hashtable from array of hashtables
			If ($json_data | Where-Object { $_.VMName -eq $VMName } ) {
				$json_replace = $true
				$json_data = $json_data | Where-Object { $_.VMName -ne $VMName }
			}
			# add VM hashtable to array of hashtables
			$json_data += $json_hash
			# export array of hashtables to JSON
			$json_data | ConvertTo-Json | Set-Content -Path $Json
			If ($json_replace) {
				Write-Output "`nReplaced '$VMName' in configuration file: '$Json'"
			}
			Else {
				Write-Output "`nAdded '$VMName' to configuration file: '$Json'"
			}
			$json_data | Format-List
		}
		Catch {
			Write-Output "`nERROR: could not update configuration file: '$Json'"
		}
	}
	Default {
		Write-Output "`nDisplaying configuration file: '$Json'"
		$json_data | Format-List
	}
}
