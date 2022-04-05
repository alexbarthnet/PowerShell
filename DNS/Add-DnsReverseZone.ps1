[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Zone')][ValidatePattern('.in-addr.arpa[.]{0,1}$')]
	[string]$Zone,
	[Parameter(Position = 1)]
	[string]$Prefix = 'ip',
	[Parameter(Position = 2)]
	[string]$Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name,
	[Parameter(Position = 3)]
	[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
	[Parameter(Position = 4)]
	[hashtable]$ReservedHosts,
	[Parameter(Position = 5)]
	[switch]$CopyNSFromDomain,
	[Parameter(Position = 6)]
	[switch]$Reset
)

# create array from zone and reverse
$zone_array = $Zone.Replace('.in-addr.arpa', $null).Split('.', [System.StringSplitOptions]::RemoveEmptyEntries)
[array]::Reverse($zone_array)

# get components from array
switch ($zone_array.Count) {
	# class A subnet
	1 {
		Write-Output 'Class A subnets not yet supported'
		Return
	}
	# class B
	2 {
		Write-Output 'Class B subnets not yet supported'
		Return
	}
	# class C subnet
	3 {
		$address = [string]::Join('.', $zone_array) + '.0'
		$counter = [Math]::Pow(2, 8)
	}
	# CIDR subnet
	4 {
		$address = [string]::Join('.', $zone_array).Split('-')[0]
		$netmask = [string]::Join('.', $zone_array).Split('-')[1]
		$counter = [Math]::Pow(2, (32 - [uint32]$netmask))
	}
	Default {
		Write-Output 'Too many octets in Zone parameter.'
		Return
	}
}

# check for zone
$zone_found = $null
$zone_found = Get-DnsServerZone -ComputerName $Server | Where-Object { $_.ZoneName -eq $Zone }
If ($null -eq $zone_found) {
	Try {
		Add-DnsServerPrimaryZone -Name $Zone -ComputerName $Server -DynamicUpdate 'Secure' -ReplicationScope 'Domain'
	}
	Catch {
		Write-Output 'Could not create zone'
		Return $_
	}
}
Else {
	Write-Output 'Zone found'
}

# check zone configuration
$domain_zone = $null
$domain_zone = Get-DnsServerZone -ComputerName $Server | Where-Object { $_.ZoneName -eq $Domain }
If ($null -ne $domain_zone) {
	If ($CopyNSFromDomain) {
		Write-Output "Copying NS records from '$Domain' zone..."
		Try {
			# create emtpy objects
			$forward_ns = $null
			$reverse_ns = $null

			# retrieve NS records
			$forward_ns = (Get-DnsServerResourceRecord -ComputerName $Server -ZoneName $Domain -Name '@' -RRType NS).RecordData.NameServer
			$reverse_ns = (Get-DnsServerResourceRecord -ComputerName $Server -ZoneName $Zone -Name '@' -RRType NS).RecordData.NameServer

			# create empty arrays
			If ($null -eq $forward_ns) { $forward_ns = @() }
			If ($null -eq $reverse_ns) { $reverse_ns = @() }

			# retrieve NS records that are missing
			$records_missing += [array][System.Linq.Enumerable]::Except([string[]]$forward_ns, [string[]]$reverse_ns)

			# retrieve NS records that are invalid
			$records_invalid += [array][System.Linq.Enumerable]::Except([string[]]$reverse_ns, [string[]]$forward_ns)

			# create any missing records
			ForEach ($record in $records_missing) {
				Try {
					Add-DnsServerResourceRecord -ZoneName $Zone -ComputerName $Server -NS -Name '@' -NameServer $record
					Write-Output "Created '$record' in '$Zone' on '$Server'"
				}
				Catch {
					Write-Output "ERROR: could not create record '$record'"
					Return
				}
			}

			# remove any invalid records
			ForEach ($record in $records_invalid) {
				Try {
					Remove-DnsServerResourceRecord -ZoneName $Zone -ComputerName $Server -RRType 'NS' -Name '@' -NameServer $record -Confirm:$false
					Write-Output "Removed '$record' from '$Zone' on '$Server'"
				}
				Catch {
					Write-Output "ERROR: could not remove record '$record'"
					Return
				}
			}
		}
		Catch {
			Write-Output "Could not locate forward zone for '$Domain'"
			Return $_
		}
	}
	Else {
		Write-Output 'Copy NS from Domain zone not requested'
	}
}
Else {
	Write-Output "Could not locate forward zone for '$Domain'"
}

# retrieve all PTR records from zone
$records_ptr = Get-DnsServerResourceRecord -ComputerName $Server -ZoneName $Zone -RRType PTR

# $address_array = @()
For ($i = 0; $i -lt $counter; $i++) {
	# create the record array
	$record_array = $address.Split('.')

	# update the record array
	$record_array[-1] = [uint32]$record_array[-1] + $i
	$record_value = $record_array -join '.'
	$record_label = $record_array -join '-'

	# check the reserved hashtable
	If ($ReservedHosts -and $ReservedHosts.ContainsKey($record_value)) {
		$record_data = "$($ReservedHosts[$record_value])"
	}
	Else {
		$record_data = "$Prefix-$record_label.reverse.$Domain"
	}
	# $record
	$record_ptr = $null
	$record_ptr = $records_ptr | Where-Object { $_.HostName -eq $record_array[-1] }
	If ($null -ne $record_ptr) {
		Write-Output "Found PTR record for '$($record_array[-1])': $($record_ptr.RecordData.PtrDomainName)"
	}
	Else {
		Try {
			Add-DnsServerResourceRecordPtr -ZoneName $Zone -ComputerName $Server -Name $record_array[-1] -PtrDomainName $record_data
			Write-Output "Created '$($record_array[-1])' in '$Zone' on '$Server': $record_data"
		}
		Catch {
			Write-Output "ERROR: could not create record '$record_data'"
			Return $_
		}
	}
}
