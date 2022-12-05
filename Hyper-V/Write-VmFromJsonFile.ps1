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
	[string]$NetworkAdapterName,
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
	[string]$Json,
	[Parameter()]
	[string]$JsonSortProperty = 'VMname'
)

# if JSON file not provided...
If ([string]::IsNullOrEmpty($Json)) {
	# ...define default JSON file
	$Json = $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.json')
}

# verify JSON file
If ($Add -and -not (Test-Path -Path $Json)) {
	Try {
		$null = New-Item -ItemType 'File' -Path $Json -ErrorAction Stop
	}
	Catch {
		Write-Verbose "could not create configuration file: '$Json'"
		Return $_
	}
}

# import JSON data
Try {
	$json_data = [array](Get-Content -Path $Json | ConvertFrom-Json)
}
Catch {
	Write-Verbose "could not read configuration file: '$Json'"
	Return $_
}

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
			If ($VerbosePreference) {
				$json_data
			}
		}
		Catch {
			Write-Output "`nERROR: could not update configuration file: '$Json'"
		}
	}
	$Add {
		# define parameters in preferred order
		$json_params = @(
			'VMName'
			'VMHost'
			'Path'
			'ProcessorCount'
			'MemoryStartupBytes'
			'MemoryMinimumBytes'
			'MemoryMaximumBytes'
			'VHDSizeBytes'
			'DataVHDSizeBytes'
			'DataVHDCount'
			'ExcludedVHDSizeBytes'
			'ExcludedVHDCount'
			'SwitchName'
			'VLAN'
			'NetworkAdapterName'
			'MacAddressPrefix'
			'IPAddress'
			'DhcpServer'
			'DhcpScope'
			'DeploymentMethod'
			'DeploymentServer'
			'DeploymentPath'
			'DeploymentDomain'
			'DeploymentCollection'
			'MaintenanceCollection'
			'ClusterPriority'
		)
		# create ordered hashtable
		$json_hash = [ordered]@{}
		# update ordered hashtable with parameters
		ForEach ($param in $json_params) {
			If ($null -ne $PSBoundParameters[$param]) {
				$json_hash[$param] = $PSBoundParameters[$param]
			}
		}
		# create custom object from parameters then add to object
		Try {
			# remove any existing VM hashtable from array of hashtables
			If ($json_data | Where-Object { $_.VMName -eq $VMName } ) {
				$json_replace = $true
				$json_data = $json_data | Where-Object { $_.VMName -ne $VMName }
			}
			# add VM hashtable to array of hashtables
			$json_data += [pscustomobject]$json_hash
			# filter and sort array of hashtables
			$json_data = $json_data | Where-Object -Property $JsonSortProperty | Sort-Object -Property $JsonSortProperty
			# export array of hashtables to JSON
			$json_data | ConvertTo-Json | Set-Content -Path $Json
			If ($json_replace) {
				Write-Output "`nReplaced '$VMName' in configuration file: '$Json'"
				$json_hash
			}
			Else {
				Write-Output "`nAdded '$VMName' to configuration file: '$Json'"
				$json_hash
			}
			If ($VerbosePreference) {
				$json_data
			}
		}
		Catch {
			Write-Output "`nERROR: could not update configuration file: '$Json'"
		}
	}
	Default {
		Write-Output "`nDisplaying configuration file: '$Json'"
		$json_data
	}
}
