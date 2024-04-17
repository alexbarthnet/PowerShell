#Requires -Modules TranscriptWithHostAndDate

[CmdletBinding(SupportsShouldProcess)]
Param (
	[Parameter(Position = 0)]
	[string]$ZoneName = '*',
	[Parameter(Position = 1)][ValidateRange(1, 65535)]
	[uint16]$OlderThanUnits = 30,
	[Parameter(Position = 2)][ValidateSet('Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', 'Years')]
	[string]$OlderThanType = 'Days',
	# PDC emulator of domain
	[Parameter(DontShow)]
	[string]$PdcRoleOwner = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
	# check if current host is permitted to run scripts
	[Parameter(DontShow)]
	[switch]$HostCheck,
	# full path to host check files
	[Parameter(DontShow)]
	[string]$HostCheckPath = 'C:\Content\adfs\host',
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipTranscript,
	# local host name
	[Parameter(DontShow)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# local domain name
	[Parameter(DontShow)]
	[string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
	# local DNS hostname
	[Parameter(DontShow)]
	[string]$DnsHostName = ($HostName, $DomainName -join '.').TrimEnd('.')
)

Begin {
	Function Get-PreviousDate {
		Param (
			[Parameter(Mandatory = $true, Position = 0)][ValidateRange(1, 65535)]
			[uint16]$OlderThanUnits,
			[Parameter(Mandatory = $true, Position = 1)][ValidateSet('Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', 'Years')]
			[string]$OlderThanType
		)
		Switch ($OlderThanType) {
			'Seconds' { Return (Get-Date).AddSeconds(-1 * $OlderThanUnits) }
			'Minutes' { Return (Get-Date).AddMinutes(-1 * $OlderThanUnits) }
			'Hours' { Return (Get-Date).AddHours(-1 * $OlderThanUnits) }
			'Days' { Return (Get-Date).AddDays(-1 * $OlderThanUnits) }
			'Weeks' { Return (Get-Date).AddWeeks(-1 * $OlderThanUnits) }
			'Months' { Return (Get-Date).AddMonths(-1 * $OlderThanUnits) }
			'Years' { Return (Get-Date).AddYears(-1 * $OlderThanUnits) }
		}
	}
	
	# if skip transcript not requested...
	If ($SkipTranscript -ne $true) {
		# start transcript with parameters
		Try {
			Start-TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}

Process {
	# check active host
	If ($HostCheck) {
		# define url to check and declare start
		Write-Output "host-check-path: '$HostCheckPath'"

		# retrieving value from host check URI
		Try {
			$HostCheckText = Get-ChildItem -Path $HostCheckPath | Sort-Object -Property 'LastWriteTimeUtc' | Select-Object -Last 1 | Get-Content
		}
		Catch {
			Write-Output 'host-check-failed-connection'
			Return
		}

		# check value against hostname
		If ($HostCheckText -match $HostName) {
			Write-Output 'host-check-passed-hostname'
		}
		Else {
			Write-Output 'host-check-failed-hostname'
			Return
		}
	}

	# creat empty objects
	$DnsZonesOnPdcRole = 0
	$DnsRecordsRemoved = 0
	$DnsRecordsErrored = 0
	$DnsRecordsInTotal = 0

	# get date from inputs
	$PreviousDate = Get-PreviousDate -OlderThanUnits $OlderThanUnits -OlderThanType $OlderThanType
	Write-TranscriptWithHostAndDate "Checking for records older than $OlderThanUnits $OlderThanType ($($PreviousDate.ToString()))"

	# get DNS zones
	Try {
		$DnsServerZones = Get-DnsServerZone -ComputerName $PdcRoleOwner | Where-Object { $_.ZoneName -like $ZoneName -and $_.ZoneName -notlike '_msdcs.*' -and $_.ZoneType -eq 'Primary' -and $_.DynamicUpdate -eq 'Secure' -and $_.IsDsIntegrated }
	}
	Catch {
		Write-WarningToTranscriptWithHostAndDate "could not retrieve DNS zones: $($_.Exeception.Message)"
		Return $_
	}

	# process each DNS zone
	ForEach ($DnsServerZone in $DnsServerZones) {
		# increment total DNS records
		$DnsZonesOnPdcRole++

		# declare zone
		Write-TranscriptWithHostAndDate "Checking for records in '$($DnsServerZone.ZoneName)'"
	
		# get DNS records
		Try {
			$DnsServerResourceRecords = Get-DnsServerResourceRecord -ComputerName $PdcRoleOwner -ZoneName $DnsServerZone.ZoneName | Where-Object { $_.TimeStamp -gt 0 -and $_.Timestamp -lt $PreviousDate } | Sort-Object -Property RecordType,HostName
		}
		Catch {
			Write-WarningToTranscriptWithHostAndDate "could not retrieve DNS records: $($_.Exeception.Message)"
			Return $_
		}

		# process DNS records
		ForEach ($DnsServerResourceRecord in $DnsServerResourceRecords) {
			# increment total DNS records
			$DnsRecordsInTotal++

			# get DNS record data
			switch ($DnsServerResourceRecord.RecordType) {
				'A' { 
					$RecordData = $DnsServerResourceRecord.RecordData.IPv4Address.IPAddressToString
				}
				'AAAA' {
					$RecordData = $DnsServerResourceRecord.RecordData.IPv6Address.IPAddressToString
				}
				'PTR' {
					$RecordData = $DnsServerResourceRecord.RecordData.PtrDomainName
				}
				'SRV' {
					$RecordData = "[$($DnsServerResourceRecord.RecordData.Priority)][$($DnsServerResourceRecord.RecordData.Weight)][$($DnsServerResourceRecord.RecordData.Port)][$($DnsServerResourceRecord.RecordData.DomainName)]"
				}
			}

			# if remove attempt should be attempting
			If ($PSCmdlet.ShouldProcess("$($DnsServerResourceRecord.HostName).$($DnsServerResourceRecord.ZoneName)", 'Remove-DnsServerResourceRecord')) {
				Try {
					# Remove-DnsServerResourceRecord -ComputerName $PdcRoleOwner -ZoneName $DnsServerZone.ZoneName -Name $DnsServerResourceRecord.HostName -Confirm:$false
					# $DnsRecordsRemoved++
				}
				Catch {
					$DnsRecordsErrored++
					Write-WarningToTranscriptWithHostAndDate "could not remove record: $($_.Exeception.Message)"
				}
			}

			# declare removed
			Write-TranscriptWithHostAndDate "Removed $($DnsServerResourceRecord.RecordType) record from $($DnsServerZone.ZoneName) created on $($DnsServerResourceRecord.TimeStamp): $($DnsServerResourceRecord.HostName); $RecordData"
		}
	}

	# report DNS records removed
	Write-TranscriptWithHostAndDate "Found '$DnsRecordsInTotal' records(s) in '$DnsZonesOnPdcRole' zones"
	Write-TranscriptWithHostAndDate "Removed '$DnsRecordsRemoved' records(s)"
	If ($DnsRecordsErrored -gt 0) {
		Write-TranscriptWithHostAndDate "Could not remove '$DnsRecordsErrored' records(s)"
	}
}

End {
	# if skip transcript not requested...
	If ($SkipTranscript -ne $true) {
		# stop transcript with parameters
		Try {
			Stop-TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}
