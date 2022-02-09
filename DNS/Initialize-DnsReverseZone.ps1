[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(  
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Zone')][ValidatePattern('.in-addr.arpa[.]{0,1}$')]
	[string]$Zone,
	[Parameter(Position = 1)]
	[string]$Prefix = "ip",
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
$zone_array = $Zone.Replace('.in-addr.arpa',$null).Split('.',[System.StringSplitOptions]::RemoveEmptyEntries)
[array]::Reverse($zone_array)

# get components from array
$address = [string]::Join('.',$zone_array).Split('-')[0]
$netmask = [string]::Join('.',$zone_array).Split('-')[1]
$counter = [Math]::Pow(2, (32-[uint32]$netmask))

# $address_array = @()
For ($i = 0; $i -lt $counter; $i++) { 
	# create the record array
	$record_array = $address.Split('.')
	# update the record array
	$record_array[-1] = [uint32]$record_array[-1] + $i
	$last_octet = $record_array[-1]
	# check the reserved hashtable
	switch ($true) {
		($null -ne $ReservedHosts -and $ReservedHosts.ContainsKey($last_octet) ) {
			$record = "$($ReservedHosts[$last_octet]).$Domain"
		}
		Default {
			$record = "$Prefix-$($record_array -join '-').reverse.$Domain"
		}
	}
	$record
}
