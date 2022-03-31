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
	[string]$IPAddress,
	[Parameter(ParameterSetName = 'Add')]
	[string]$MacAddressPrefix,
	[Parameter(ParameterSetName = 'Add')]
	[string]$DhcpServer,
	[Parameter(ParameterSetName = 'Add')]
	[string]$DhcpScope,
	[Parameter(ParameterSetName = 'Add')][ValidateSet('ISO', 'SCCM', 'WDS')]
	[string]$OsdMethod,
	[Parameter(ParameterSetName = 'Add')]
	[string]$OsdPath,
	[Parameter(ParameterSetName = 'Add')]
	[string]$OsdServer,
	[Parameter(ParameterSetName = 'Add')]
	[string]$OsdDomain,
	[Parameter(ParameterSetName = 'Add')]
	[string]$DeploymentCollection,
	[Parameter(ParameterSetName = 'Add')]
	[string]$MaintenanceCollection,
	[Parameter(ParameterSetName = 'Add')]
	[string]$ClusterPriority = '2000',
	[Parameter()]
	[string]$Json = $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.json')
)

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
			$json_data = $json_data | Where-Object {
				$_.VMName -ne $VMName
			}
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
		# create custom object from parameters then add to object
		Try {
			$json_data += [pscustomobject]@{
				VMName                = $VMName
				VMHost                = $VMHost
				Path                  = $Path
				ProcessorCount        = $ProcessorCount
				MemoryStartupBytes    = $MemoryStartupBytes
				MemoryMinimumBytes    = $MemoryMinimumBytes
				MemoryMaximumBytes    = $MemoryMaximumBytes
				VHDSizeBytes          = $VHDSizeBytes
				DataVHDSizeBytes      = $DataVHDSizeBytes
				DataVHDCount          = $DataVHDCount
				ExcludedVHDSizeBytes  = $ExcludedVHDSizeBytes
				ExcludedVHDCount      = $ExcludedVHDCount
				SwitchName            = $SwitchName
				VLAN                  = $VLAN
				NetworkAdapterName    = $NetworkAdapterName
				IPAddress             = $IPAddress
				MacAddressPrefix      = $MacAddressPrefix
				DhcpServer            = $DhcpServer
				DhcpScope             = $DhcpScope
				OsdMethod             = $OsdMethod
				OsdPath               = $OsdPath
				OsdServer             = $OsdServer
				OsdDomain             = $OsdDomain
				DeploymentCollection  = $DeploymentCollection
				MaintenanceCollection = $MaintenanceCollection
				ClusterPriority       = $ClusterPriority
			}
			$json_data | ConvertTo-Json | Set-Content -Path $Json
			Write-Output "`nAdded '$VMName' to configuration file: '$Json'"
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
