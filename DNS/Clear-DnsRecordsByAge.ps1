#Requires -Modules LogToMultiple

[CmdletBinding(SupportsShouldProcess)]
Param (
	[Parameter(Position = 0)][ValidateRange(1, 65535)]
	[uint16]$OlderThanUnits = 30,
	[Parameter(Position = 1)][ValidateSet('Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', 'Years')]
	[string]$OlderThanType = 'Days',
	[Parameter(Position = 3)]
	[string]$Domain = '*',
	[Parameter(Position = 4)]
	[string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
	[Parameter(Position = 5)]
	[switch]$HostCheck,
	[Parameter(Position = 6)]
	[string]$HostCheckUri = "https://login.$DomainFqdn/host",
	[Parameter(DontShow)]
	[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
)

Function Get-PreviousDate {
	Param (
		[Parameter(Mandatory = $true, Position = 0)][ValidateRange(1, 65535)]
		[uint16]$OlderThanUnits,
		[Parameter(Mandatory = $true, Position = 1)][ValidateSet('Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', 'Years')]
		[string]$OlderThanType
	)
	Switch ($OlderThanType) {
		'Minutes' { Return (Get-Date).AddMinutes(-1 * $OlderThanUnits) }
		'Hours' { Return (Get-Date).AddHours(-1 * $OlderThanUnits) }
		'Days' { Return (Get-Date).AddDays(-1 * $OlderThanUnits) }
		'Weeks' { Return (Get-Date).AddWeeks(-1 * $OlderThanUnits) }
		'Months' { Return (Get-Date).AddMonths(-1 * $OlderThanUnits) }
		'Years' { Return (Get-Date).AddYears(-1 * $OlderThanUnits) }
	}
}


# start log file
Try {
	Start-LogToMultiple -ScriptPath $PSCommandPath
}
Catch {
	Write-Host 'ERROR: could not start logging'
	Return $_
}

# check active host
If ($HostCheck) {
	# define url to check and declare start
	Write-Output "host-check-uri: $HostCheckUri"
	# retrieving value from host check URI
	Try {
		$host_check_txt = (Invoke-WebRequest -Uri $HostCheckUri -UseBasicParsing -ErrorAction 'SilentlyContinue').Content
	}
	Catch {
		Write-Output 'host-check-failed-connection'
		Return
	}
	# check value against hostname
	If ($host_check_txt -match $Hostname) {
		Write-Output 'host-check-passed-hostname'
	}
	Else {
		Write-Output 'host-check-failed-hostname'
		Return
	}
}

# get date from inputs
$dns_time = Get-PreviousDate -OlderThanUnits $OlderThanUnits -OlderThanType $OlderThanType
Write-LogToMultiple -LogText "Checking for records older than $OlderThanUnits $OlderThanType ($($dns_time.ToString()))"

# get DNS zones
Try {
	$dns_zones = Get-DnsServerZone -ComputerName $Server | Where-Object { $_.ZoneName -like $Domain -and $_.ZoneType -eq 'Primary' -and $_.DynamicUpdate -eq 'Secure' -and $_.IsDsIntegrated -and -not $_.IsReverseLookupZone }
}
Catch {
	Write-Host 'ERROR: could not retrieve DNS zones'
	Return $_
}

# process each DNS zone
ForEach ($dns_zone in $dns_zones) {
	Try {
		$dns_records = Get-DnsServerResourceRecord -ComputerName $Server -ZoneName $dns_zone.ZoneName | Where-Object { $_.TimeStamp -gt 0 -and $_.Timestamp -lt $dns_time }
	}
	Catch {

	}
	# process each DNS record
	ForEach ($dns_record in $dns_records) {
		Try {
			switch ($dns_record.RecordType) {
				'A' { $dns_record_data = $dns_record.RecordData.IPv4Address.IPAddressToString }
				'AAAA' { $dns_record_data = $dns_record.RecordData.IPv6Address.IPAddressToString }
				'SRV' { $dns_record_data = "[$($dns_record.RecordData.Priority)][$($dns_record.RecordData.Weight)][$($dns_record.RecordData.Port)][$($dns_record.RecordData.DomainName)]" }
			}
			if ($PSCmdlet.ShouldProcess("$($dns_record.HostName).$($dns_zone.ZoneName)", 'Remove-DnsServerResourceRecord')) {
				# $dns_record | Remove-DnsServerResourceRecord -ComputerName $Server -ZoneName $dns_zone.ZoneName -Confirm:$false
				Write-LogToMultiple -LogSubject $dns_zone.ZoneName -LogText "Removed record created on $($dns_record.Timestamp): $($dns_record.RecordType); $($dns_record.HostName).$($dns_zone.ZoneName); $dns_record_data"
			}
		}
		Catch {

		}
	}
}


# start log file
Try {
	Remove-LogToMultiple -ScriptPath $PSCommandPath
}
Catch {
	Write-Host 'ERROR: could not cleanup logs'
	Return $_
}
