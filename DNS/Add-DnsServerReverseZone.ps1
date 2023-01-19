[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Zone')][ValidatePattern('.in-addr.arpa[.]{0,1}$')]
	[string]$Zone,
	[Parameter(Position = 1)]
	[string]$RecordPrefix = 'ip',
	[Parameter(Position = 2)]
	[string]$SubDomain = "reverse",
	[Parameter(Position = 3)]
	[string]$Domain = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name,
	[Parameter(Position = 4)]
	[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
	[Parameter(Position = 5)]
	[hashtable]$ReservedHosts,
	[Parameter(Position = 6)]
	[switch]$UseNameServersFromDomain,
	[Parameter(Position = 7)]
	[switch]$Reset
)

# create and reverse array from zone input
Try {
	# create array of octets in zone name
	$Array = $Zone.Replace('.in-addr.arpa', $null).Split('.', [System.StringSplitOptions]::RemoveEmptyEntries)
	# get count of octets
	$Count = $Array.Count
	# reverse array 
	[array]::Reverse($Array)
}
Catch {
	Throw $_
}

# get components from array
switch ($Count) {
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
		$Network = ($Array -join '.') + '.0'
		$Netmask = '24'
	}
	# CIDR subnet
	4 {
		$Network = ($Array -join '.' -split '-')[0]
		$Netmask = ($Array -join '.' -split '-')[1]
	}
	Default {
		Write-Error 'Too many octets in Zone parameter.'
		Return
	}
}

# check foward zone
Write-Output "Checking forward zone..."
Try {
	$ForwardZone = Get-DnsServerZone -ComputerName $Server -ZoneName "$SubDomain.$Domain" -ErrorAction 'Stop' | Select-Object -ExpandProperty 'ZoneName'
	Write-Output "...found forward zone for subdomain: '$ForwardZone'"
}
Catch {
	Try {
		$ForwardZone = Get-DnsServerZone -ComputerName $Server -ZoneName "$Domain" -ErrorAction 'Stop' | Select-Object -ExpandProperty 'ZoneName'
		Write-Output "...found forward zone for domain: '$ForwardZone'"
	}
	Catch {
		Write-Error "Could not locate forward zone: '$Domain'"
		Throw $_
	}
}

# check for reverse zone
Write-Output "Checking reverse zone..."
Try {
	$ReverseZone = Get-DnsServerZone -ComputerName $Server -Name $Zone -ErrorAction 'Stop' | Select-Object -ExpandProperty 'ZoneName'
	Write-Output "...found reverse zone: '$ReverseZone'"
}
Catch {
	Write-Output "...creating zone..."
	Try {
		$ReverseZone = Add-DnsServerPrimaryZone -ComputerName $Server -Name $Zone -DynamicUpdate 'Secure' -ReplicationScope 'Domain' -PassThru  | Select-Object -ExpandProperty 'ZoneName'
		Write-Output "...created reverse zone: '$ReverseZone'"
	}
	Catch {
		Write-Error "could not create reverse zone: '$Zone'"
		Throw $_
	}
}

# configure reverse zone
If ($UseNameServersFromDomain) {
	Write-Output "Updating NS records..."
	# retrieve forward zone NS records
	Try {
		$ForwardNSRecords = (Get-DnsServerResourceRecord -ComputerName $Server -ZoneName $ForwardZone -Name '@' -RRType NS).RecordData.NameServer
	}
	Catch {
		Write-Error "could not retrieve NS records from '$ForwardZone'"
		Throw $_
	}

	# retrieve reverse zone NS records
	Try {
		$ReverseNSRecords = (Get-DnsServerResourceRecord -ComputerName $Server -ZoneName $ReverseZone -Name '@' -RRType NS).RecordData.NameServer
	}
	Catch {
		Write-Error "could not retrieve NS records from '$ReverseZone'"
		Throw $_
	}

	# create emtpy lists
	$ForwardNameServers = [System.Collections.Generic.List[string]]::New()
	$ReverseNameServers = [System.Collections.Generic.List[string]]::New()

	# populate lists
	ForEach ($NameServer in $ForwardNSRecords) { $ForwardNameServers.Add($NameServer) }
	ForEach ($NameServer in $ReverseNSRecords) { $ReverseNameServers.Add($NameServer) }

	# retrieve NS records that are missing
	$MissingNameServers = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($ForwardNameServers, $ReverseNameServers))

	# retrieve NS records that are invalid
	$InvalidNameServers = [System.Linq.Enumerable]::ToList([System.Linq.Enumerable]::Except($ReverseNameServers, $ForwardNameServers))

	# create any missing NS records
	ForEach ($NameServer in $MissingNameServers) {
		Try {
			Add-DnsServerResourceRecord -ComputerName $Server -ZoneName $ReverseZone -NS -Name '@' -NameServer $NameServer
			Write-Output "...created NS record '$NameServer' in '$ReverseZone' on '$Server'"
		}
		Catch {
			Write-Output "could not create NS record '$NameServer'"
			Throw $_
		}
	}

	# remove any invalid NS records
	ForEach ($NameServer in $InvalidNameServers) {
		Try {
			Remove-DnsServerResourceRecord -ComputerName $Server -ZoneName $ReverseZone -RRType 'NS' -Name '@' -RecordData $NameServer -Confirm:$false
			Write-Output "...removed NS record '$NameServer' from '$ReverseZone' on '$Server'"
		}
		Catch {
			Write-Output "ERROR: could not remove NS record '$NameServer'"
			Throw $_
		}
	}
}

# define first IP and counter from address and netmask
$FirstIP = [uint32]($Network.Split('.')[-1])
$Counter = [uint32]$FirstIP + [Math]::Pow(2, (32 - [uint32]$Netmask))

# create PTR records
For ($Name = $FirstIP; $Name -lt $Counter; $Name++) {
	# create octet array from base address
	$Octets = $Network.Split('.')

	# update octet array with current octet
	$Octets[-1] = [string]$Name

	# create current IP address from octet array
	$IPAddress = $Octets -join '.'

	# check reserved hosts hashtable
	If ($ReservedHosts -and $ReservedHosts.ContainsKey($IPAddress)) {
		$PtrDomainName = "$($ReservedHosts[$IPAddress])"
	}
	Else {
		$IPAddressWithDashes = $Octets -join '-'
		$PtrDomainName = "$Prefix-$IPAddressWithDashes.$ForwardZone."
	}

	# create PTR record
	Try {
		$Record = Get-DnsServerResourceRecord -ComputerName $Server -ZoneName $Zone -Name $Name -ErrorAction 'Stop'
		If ($Record.RecordData.PtrDomainName -eq $PtrDomainName) {
			Write-Output "...found '$Name' in '$Zone' on '$Server' with value: $PtrDomainName"
		}
		Else {
			# copy PTR record object
			$NewRecord = $Record
			# update new PTR record object
			$NewRecord.RecordData.PtrDomainName = $PtrDomainName
			# update PTR record
			Try {
				Set-DnsServerResourceRecord -ComputerName $Server -ZoneName $Zone -OldInputObject $Record -NewInputObject $NewRecord -ErrorAction 'Stop'
				Write-Output "...updated '$Name' in '$Zone' on '$Server' with value: $PtrDomainName"
			}
			Catch {
				Throw $_
			}
		}
	}
	Catch {
		Try {
			Add-DnsServerResourceRecordPtr -ComputerName $Server -ZoneName $Zone -Name $Name -PtrDomainName $PtrDomainName
			Write-Output "...created '$Name' in '$Zone' on '$Server' with value: $PtrDomainName"
		}
		Catch {
			Throw $_
		}
	}
}

# create A records
For ($Name = $FirstIP; $Name -lt $Counter; $Name++) {
	# create octet array from base address
	$Octets = $Network.Split('.')

	# update octet array with current octet
	$Octets[-1] = [string]$Name

	# create current IP address from octet array
	$IPAddress = $Octets -join '.'

	# check reserved hosts hashtable
	If ($ReservedHosts -and $ReservedHosts.ContainsKey($IPAddress)) {
		$PtrDomainName = "$($ReservedHosts[$IPAddress])"
	}
	Else {
		$IPAddressWithDashes = $Octets -join '-'
		$PtrDomainName = "$Prefix-$IPAddressWithDashes.$ForwardZone."
	}

	# retrieve record name from PTR domain name
	$RecordName = $PtrDomainName.Split('.')[0]

	# create A record
	Try {
		$Record = Get-DnsServerResourceRecord -ComputerName $Server -ZoneName $ForwardZone -Name $RecordName -ErrorAction 'Stop'
		If ($Record.RecordData.IPv4Address.IPAddressToString -eq $IPAddress) {
			Write-Output "...found '$RecordName' in '$ForwardZone' on '$Server' with value: $IPAddress"
		}
		Else {
			# copy PTR record object
			$NewRecord = $Record
			# update new PTR record object
			$NewRecord.RecordData.IPv4Address = [System.Net.IPAddress]::Parse($IPAddress)
			# update PTR record
			Try {
				Set-DnsServerResourceRecord -ComputerName $Server -ZoneName $ForwardZone -OldInputObject $Record -NewInputObject $NewRecord -ErrorAction 'Stop'
				Write-Output "...updated '$RecordName' in '$ForwardZone' on '$Server' with value: $IPAddress"
			}
			Catch {
				Throw $_
			}
		}
	}
	Catch {
		Try {
			Add-DnsServerResourceRecordA -ComputerName $Server -ZoneName $Zone -Name $RecordName -IPv4Address $IPAddress -ErrorAction 'Stop'
			Write-Output "...created '$RecordName' in '$ForwardZone' on '$Server' with value: $IPAddress"
		}
		Catch {
			Throw $_
		}
	}
}
