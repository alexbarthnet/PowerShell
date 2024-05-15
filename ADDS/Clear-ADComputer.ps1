#Requires -Modules ActiveDirectory,DnsServer

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Position = 0, Mandatory = $True)][ValidateScript({ $_ -is [Microsoft.ActiveDirectory.Management.ADComputer] -or $_ -is [System.String] })]
	[object]$Identity,
	[Parameter(Position = 1)]
	[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
)

# retrieve computer name from parameters
If ($Identity -is [Microsoft.ActiveDirectory.Management.ADComputer]) {
	$ComputerName = $Identity.Name
}
Else {
	$ComputerName = $Identity
}

# retrieve computer object from AD
Write-Host ("$Hostname,$ComputerName - locating computer object in AD")
Try {
	$ADComputer = Get-ADComputer -Server $Server -Identity $Identity -ErrorAction Stop
}
Catch {
	Write-Host ("$Hostname,$ComputerName - ...computer object not found")
}

# remove computer object
If ($null -ne $ADComputer) {
	Write-Host ("$Hostname,$ComputerName - ...found computer object")
	$Name = $ADComputer.DNSHostName
	Write-Host ("$Hostname,$ComputerName - removing computer object...")
	$ADObject | Remove-ADComputer -Server $Server -Confirm:$false
	Write-Host ("$Hostname,$ComputerName - ...removed computer object")
}

# resolve DNS A records
Write-Host ("$Hostname,$ComputerName - resolving DNS A records")
Try {
	$DnsRecords = Resolve-DnsName -Server $Server -Type A -Name $Name -DnsOnly -QuickTimeout -ErrorAction Stop
}
Catch {
	Write-Host ("$Hostname,$ComputerName - ...DNS A records not found")
}

# resolve DNS PTR records from DNS A records
If ($null -ne $DnsRecords) {
	Write-Host ("$Hostname,$ComputerName - resolving DNS PTR records")
	# create array for holding DNS pointer records
	$DnsPointerRecords = @()
	# process each DNS record
	ForEach ($DnsRecord in $DnsRecords) {
		Try {
			$DnsPointerRecords += Resolve-DnsName -Server $Server -Type PTR -Name $DnsRecord.IPAddress -DnsOnly -QuickTimeout -ErrorAction Stop
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName - ...DNS PTR record not found for: $($DnsRecord.IPAddress)")
		}
	}
}

# remove DNS A record
If ($null -ne $DnsRecords) {
	Write-Host ("$Hostname,$ComputerName - removing DNS A records from server: $Server")
	# process each DNS A record
	:DnsRecords ForEach ($DnsRecord in $DnsRecords) {
		# split DNS A record
		$Name, $ZoneName = $DnsRecord.Name.Split('.', 2)
		# retrieve DNS A record
		Try {
			$DnsServerResourceRecord = Get-DnsServerResourceRecord -ComputerName $Server -ZoneName $ZoneName -Name $Name -RRType A -ErrorAction Stop
			Write-Host ("$Hostname,$ComputerName - ...DNS A record found: $($DnsRecord.Name)")
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName - ...DNS A record not found on server: $($DnsRecord.Name)")
			Continue DnsRecords
		}
		Write-Host ("$Hostname,$ComputerName - removing DNS A record...")
		# remove DNS A record
		Try {
			$DnsServerResourceRecord | Remove-DnsServerResourceRecord -ComputerName $Server -ZoneName $ZoneName -Force -ErrorAction Stop
			Write-Host ("$Hostname,$ComputerName - ...removed DNS A record")
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName - ...DNS A record not removed")
		}
	}
}

# remove DNS A record
If ($null -ne $DnsPointerRecords) {
	Write-Host ("$Hostname,$ComputerName - removing DNS PTR records from server: $Server")
	# process each DNS A record
	:DnsPointerRecords ForEach ($DnsPointerRecord in $DnsPointerRecords) {
		# split DNS A record
		$Name, $ZoneName = $DnsPointerRecord.Name.Split('.', 2)
		# retrieve DNS A record
		Try {
			$DnsServerResourceRecord = Get-DnsServerResourceRecord -ComputerName $Server -ZoneName $ZoneName -Name $Name -RRType PTR -ErrorAction Stop
			Write-Host ("$Hostname,$ComputerName - ...DNS PTR record found: $($DnsPointerRecord.Name)")
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName - ...DNS PTR record not found on server: $($DnsPointerRecord.Name)")
			Continue DnsPointerRecords
		}
		Write-Host ("$Hostname,$ComputerName - removing DNS PTR record...")
		# remove DNS A record
		Try {
			$DnsServerResourceRecord | Remove-DnsServerResourceRecord -ComputerName $Server -ZoneName $ZoneName -Force -ErrorAction Stop
			Write-Host ("$Hostname,$ComputerName - ...removed DNS PTR record")
		}
		Catch {
			Write-Host ("$Hostname,$ComputerName - ...DNS PTR record not removed")
		}
	}
}
