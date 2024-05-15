#Requires -Modules DnsServer,TranscriptWithHostAndDate

<#
.SYNOPSIS
Removes dynamic DNS records that have not been updated since the datetime computed by the required parameters.

.DESCRIPTION
Removes dynamic DNS records that have not been updated since the datetime computed by the required parameters. This script supplants DNS scavenging with improved logging and flexibility.

.PARAMETER ZoneName
Specifies one or more DNS lookup zones to cleanup. Cannot be combined with the AllZones or ExcludeReverseLookupZones parameters

.PARAMETER AllZones
Swith parameter to cleanup all AD-integrated primary DNS lookup zones with Dynamic Update enabled. Cannot be combined with the ZoneName parameter.

.PARAMETER ExcludeReverseLookupZones
Swith parameter to exclude reverse lookup zones from cleanup. Cannot be combined with the ZoneName parameter.

.PARAMETER OlderThanUnits
The number of datetime units to create the computed datetime. The default value is '30'

.PARAMETER OlderThanType
The type of datetime units to create the computed datetime. The supported values are 'Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', and 'Years'. The default value is 'Days'

.INPUTS
System.String[]. One or more DNS lookup zones can be submitted via the pipeline.

.OUTPUTS
None. The script reports on actions taken and does not provide any actionable output.

.EXAMPLE
.\Clear-DnsRecordsByAge.ps1 -AllZones -OlderThanUnits 90 -OlderThanType 'Days'

#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Default')]
Param (
	# names of zones for DNS record cleanup
	[Parameter(ParameterSetName = 'Default', Mandatory = $true, ValueFromPipeline = $true)]
	[string[]]$ZoneName,
	# names of zones for DNS record cleanup
	[Parameter(ParameterSetName = 'AllZones', Mandatory = $true)]
	[switch]$AllZones,
	# switch to exclude reverse lookup zones
	[Parameter(ParameterSetName = 'AllZones')]
	[switch]$ExcludeReverseLookupZones,
	# first part of time for DNS record cleanup
	[Parameter(Position = 0)][ValidateRange(1, 65535)]
	[uint16]$OlderThanUnits = 30,
	# second part of time for DNS record cleanup
	[Parameter(Position = 1)][ValidateSet('Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', 'Years')]
	[string]$OlderThanType = 'Days',
	# infrastructure master for current domain
	[Parameter(DontShow)]
	[string]$InfrastructureRoleOwner = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().InfrastructureRoleOwner.Name,
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
	Function Assert-NonInteractiveSession {
		# if environment is not interactive
		If (![System.Environment]::UserInteractive) {
			Return $true
		}

		# retrieve command line args
		$CommandLineArgs = [System.Environment]::GetCommandLineArgs()

		# process command line args
		ForEach ($CommandLineArg in $CommandLineArgs) {
			If ($CommandLineArg.StartsWith('-NonI', [System.StringComparison]::InvariantCultureIgnoreCase)) {
				Return $true
			}
		}

		# if true has not been returned...
		Return $false
	}

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
	If (Assert-NonInteractiveSession -and $DnsHostName -ne $InfrastructureRoleOwner) {
		Write-TranscriptWithHostAndDate 'Skipping DNS record cleanup: running non-interactively and the current system does not hold the Infrastructure Master role'
		Return
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

	# get AD-integrated primary DNS zones with dynamic update enabled
	Try {
		$DnsServerZones = Get-DnsServerZone -ComputerName $InfrastructureRoleOwner | Where-Object { $_.IsDsIntegrated -and $_.ZoneName -notlike '_msdcs.*' -and $_.ZoneType -eq 'Primary' -and $_.DynamicUpdate -in 'Secure', 'Unsecure' }
	}
	Catch {
		Write-WarningToTranscriptWithHostAndDate "could not retrieve DNS zones: $($_.Exeception.Message)"
		Return $_
	}

	# if in default run mode...
	If ($PSBoundParameters.ContainsKey('ZoneName')) {
		# filter zones to zonename parameter
		If ($ZoneName.Count -gt 1) {
			$DnsServerZones = $DnsServerZones.Where({ $_.ZoneName -in $ZoneName })
		}
		Else {
			$DnsServerZones = $DnsServerZones.Where({ $_.ZoneName -like $ZoneName })
		}
	}

	# if in all zones run mode...
	If ($PSBoundParameters.ContainsKey('AllZones')) {
		If ($ExcludeReverseLookupZones) {
			$DnsServerZones = $DnsServerZones.Where({ $_.IsReverseLookupZone -eq $false })
		}
	}

	# process each DNS zone
	ForEach ($DnsServerZone in $DnsServerZones) {
		# increment total DNS records
		$DnsZonesOnPdcRole++

		# declare zone
		Write-TranscriptWithHostAndDate "Checking for records in '$($DnsServerZone.ZoneName)'"

		# get DNS records
		Try {
			$DnsServerResourceRecords = Get-DnsServerResourceRecord -ComputerName $InfrastructureRoleOwner -ZoneName $DnsServerZone.ZoneName | Where-Object { $_.TimeStamp -gt 0 -and $_.Timestamp -lt $PreviousDate } | Sort-Object -Property RecordType, HostName
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
					Remove-DnsServerResourceRecord -ComputerName $InfrastructureRoleOwner -ZoneName $DnsServerZone.ZoneName -InputObject $DnsServerResourceRecord -Force
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
