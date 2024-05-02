#Requires -Modules DnsServer,TranscriptWithHostAndDate

[CmdletBinding(SupportsShouldProcess)]
Param (
	# first part of time for DNS record cleanup
	[Parameter(Position = 0)][ValidateRange(1, 65535)]
	[uint16]$OlderThanUnits = 30,
	# second part of time for DNS record cleanup
	[Parameter(Position = 1)][ValidateSet('Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', 'Years')]
	[string]$OlderThanType = 'Days',
	# domains for DNS record cleanup
	[Parameter(Position = 2)]
	[string]$Domain = '*',
	# infrastructure master of domain
	[Parameter(DontShow)]
	[string]$PdcRoleOwner = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
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
	If (!$SkipTranscript) {
		# start transcript with default parameters
		Try {
			Start-TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}

Process {
	# check for PDC role
	If ($DnsHostName -ne $PdcRoleOwner) {
		Write-TranscriptWithHostAndDate 'Skipping DNS record cleanup: current server is not PDC role owner'
	}

	# creat empty objects
	$DnsZonesOnPdcRole = 0
	$DnsRecordsLocated = 0
	$DnsRecordsRemoved = 0
	$DnsRecordsErrored = 0
	$DnsRecordsInTotal = 0

	# get date from inputs
	$PreviousDate = Get-PreviousDate -OlderThanUnits $OlderThanUnits -OlderThanType $OlderThanType

	# declare date
	Write-TranscriptWithHostAndDate "Checking for records older than $OlderThanUnits $OlderThanType ($($PreviousDate.ToString()))"

	# get DNS zones
	Try {
		$DnsServerZones = Get-DnsServerZone -ComputerName $PdcRoleOwner | Where-Object { $_.ZoneName -like $Domain -and $_.ZoneName -notlike '_msdcs.*' -and $_.ZoneType -eq 'Primary' -and $_.DynamicUpdate -eq 'Secure' -and $_.IsDsIntegrated }
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
			$DnsServerResourceRecords = Get-DnsServerResourceRecord -ComputerName $PdcRoleOwner -ZoneName $DnsServerZone.ZoneName | Where-Object { $_.TimeStamp -gt 0 -and $_.Timestamp -lt $PreviousDate } | Sort-Object -Property RecordType, HostName
		}
		Catch {
			Write-WarningToTranscriptWithHostAndDate "could not retrieve DNS records: $($_.Exeception.Message)"
			Return $_
		}

		# process DNS records
		:NextDnsServerResourceRecord ForEach ($DnsServerResourceRecord in $DnsServerResourceRecords) {
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
				Default {
					Write-TranscriptWithHostAndDate "Located unexpected $($DnsServerResourceRecord.RecordType) record from $($DnsServerZone.ZoneName) created on $($DnsServerResourceRecord.TimeStamp): $($DnsServerResourceRecord.HostName)"
					Continue NextDnsServerResourceRecord
				}
			}

			# if remove attempt should be attempting
			If ($PSCmdlet.ShouldProcess("$($DnsServerResourceRecord.HostName).$($DnsServerResourceRecord.ZoneName)", 'Remove-DnsServerResourceRecord')) {
				# remove record
				Try {
					Remove-DnsServerResourceRecord -ComputerName $PdcRoleOwner -ZoneName $DnsServerZone.ZoneName -InputObject $DnsServerResourceRecord -Force
				}
				Catch {
					Write-WarningToTranscriptWithHostAndDate "could not remove record: $($_.ToString())"
					$DnsRecordsErrored++
					Continue NextDnsServerResourceRecord
				}

				# declare removed
				Write-TranscriptWithHostAndDate "Removed $($DnsServerResourceRecord.RecordType) record from $($DnsServerZone.ZoneName) created on $($DnsServerResourceRecord.TimeStamp): $($DnsServerResourceRecord.HostName); $RecordData"
				$DnsRecordsRemoved++
			}
			Else {
				# declare found
				Write-TranscriptWithHostAndDate "Located $($DnsServerResourceRecord.RecordType) record from $($DnsServerZone.ZoneName) created on $($DnsServerResourceRecord.TimeStamp): $($DnsServerResourceRecord.HostName); $RecordData"
				$DnsRecordsLocated++
			}
		}
	}

	# report DNS records removed
	Write-TranscriptWithHostAndDate "Found '$DnsRecordsInTotal' records(s) in '$DnsZonesOnPdcRole' zones"

	Write-TranscriptWithHostAndDate "Removed '$DnsRecordsRemoved' records(s)"
	If ($DnsRecordsLocated -gt 0) {
		Write-TranscriptWithHostAndDate "Located '$DnsRecordsLocated' records(s) to delete"
	}
	If ($DnsRecordsErrored -gt 0) {
		Write-TranscriptWithHostAndDate "Could not remove '$DnsRecordsErrored' records(s)"
	}
}

End {
	# if skip transcript not requested...
	If (!$SkipTranscript) {
		# stop transcript with default parameters
		Try {
			Stop-TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}
