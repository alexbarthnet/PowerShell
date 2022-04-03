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
	[switch]$Reset
)

# create array from zone and reverse
$zone_array = $Zone.Replace('.in-addr.arpa', $null).Split('.', [System.StringSplitOptions]::RemoveEmptyEntries)
[array]::Reverse($zone_array)

# get components from array
switch ($zone_array.Count) {
	# class A
	1 {
		Write-Output 'Class A subnets not yet supported'
		Return
	}
	# class B
	2 {
		Write-Output 'Class B subnets not yet supported'
		Return
	}
	# class C
	3 {
		Write-Output 'Class C subnets not yet supported'
		$address = [string]::Join('.', $zone_array) + '.0'
		$counter = [Math]::Pow(2, 8)
		# Return
	}
	# CIDR
	4 {
		$address = [string]::Join('.', $zone_array).Split('-')[0]
		$netmask = [string]::Join('.', $zone_array).Split('-')[1]
		$counter = [Math]::Pow(2, (32 - [uint32]$netmask))
	}
	Default {
		Write-Output "Too many '.' in Zone parameter."
		Return
	}
}

# $address_array = @()
For ($i = 0; $i -lt $counter; $i++) { 
	# create the record array
	$record_array = $address.Split('.')
	# update the record array
	$record_array[-1] = [uint32]$record_array[-1] + $i
	$record_value = $record_array -join '.'
	$record_label = $record_array -join '-'
	# check the reserved hashtable
	If ($ReservedHosts.ContainsKey($record_value)) {
		$record = "$($ReservedHosts[$record_value])"
	}
	Else {
		$record = "$Prefix-$record_label.reverse.$Domain"
	}
	$record
}
