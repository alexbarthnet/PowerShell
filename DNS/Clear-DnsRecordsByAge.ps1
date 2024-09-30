#Requires -Modules DnsServer

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

.PARAMETER TimeSpan
The timespan to used to create the computed datetime. The default value is '60 days'

.INPUTS
System.String[]. One or more DNS lookup zones can be submitted via the pipeline.

.OUTPUTS
None. The script reports on actions taken and does not provide any actionable output.

.EXAMPLE
.\Clear-DnsRecordsByAge.ps1 -AllZones -TimeSpan (New-Timespan -Days 30)

#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Default')]
Param (
	# local host name
	[Parameter(DontShow)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# local domain name
	[Parameter(DontShow)]
	[string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
	# local DNS hostname
	[Parameter(DontShow)]
	[string]$DnsHostName = ($HostName, $DomainName -join '.').TrimEnd('.'),
	# primary domain controller for current domain
	[Parameter(DontShow)]
	[string]$PdcRoleOwner = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
	# names of zones for DNS record cleanup
	[Parameter(ParameterSetName = 'Default', Mandatory = $true, ValueFromPipeline = $true)]
	[string[]]$ZoneName,
	# names of zones for DNS record cleanup
	[Parameter(ParameterSetName = 'AllZones', Mandatory = $true)]
	[switch]$AllZones,
	# switch to exclude reverse lookup zones
	[Parameter(ParameterSetName = 'AllZones')]
	[switch]$ExcludeReverseLookupZones,
	# timespan of for DNS record cleanup
	[timespan]$TimeSpan = [timespan]::FromDays(60)
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

	Function Get-TimeSpanAsFormattedString {
		Param(
			[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
			[timespan]$TimeSpan
		)

		# create list
		$StringList = [System.Collections.Generic.List[System.String]]::new()

		# if Days is not zero...
		If ($TimeSpan.Days) {
			# if Days is one or negative one...
			If ($TimeSpan.Days -eq 1 -or $TimeSpan.Days -eq -1) {
				$StringList.Add('{0} day' -f $TimeSpan.Days)
			}
			# if Days is not one or negative one...
			Else {
				$StringList.Add('{0} days' -f $TimeSpan.Days)
			}
		}

		# if Hours is not zero...
		If ($TimeSpan.Hours) {
			# if Hours is one or negative one...
			If ($TimeSpan.Hours -eq 1 -or $TimeSpan.Hours -eq -1) {
				$StringList.Add('{0} hour' -f $TimeSpan.Hours)
			}
			# if Hours is not one or negative one...
			Else {
				$StringList.Add('{0} hours' -f $TimeSpan.Hours)
			}
		}

		# if Minutes is not zero...
		If ($TimeSpan.Minutes) {
			# if Minutes is one or negative one...
			If ($TimeSpan.Minutes -eq 1 -or $TimeSpan.Minutes -eq -1) {
				$StringList.Add('{0} minute' -f $TimeSpan.Minutes)
			}
			# if Minutes is not one or negative one...
			Else {
				$StringList.Add('{0} minutes' -f $TimeSpan.Minutes)
			}
		}

		# if Seconds is not zero...
		If ($TimeSpan.Seconds) {
			# if Seconds is one or negative one...
			If ($TimeSpan.Seconds -eq 1 -or $TimeSpan.Seconds -eq -1) {
				$StringList.Add('{0} second' -f $TimeSpan.Seconds)
			}
			# if Seconds is not one or negative one...
			Else {
				$StringList.Add('{0} seconds' -f $TimeSpan.Seconds)
			}
		}

		# if Milliseconds is not zero...
		If ($TimeSpan.Milliseconds) {
			# if Milliseconds is one or negative one...
			If ($TimeSpan.Milliseconds -eq 1 -or $TimeSpan.Milliseconds -eq -1) {
				$StringList.Add('{0} millisecond' -f $TimeSpan.Milliseconds)
			}
			# if Milliseconds is not one or negative one...
			Else {
				$StringList.Add('{0} milliseconds' -f $TimeSpan.Milliseconds)
			}
		}

		# join strings together
		$String = $StringList -join ', '

		# format string
		switch ($StringList.Count) {
			1 { 
				Return $String
			}
			2 { 
				Return $String.Replace(', ', ' and ')
			}
			Default {
				Return $String.Insert($String.LastIndexOf(',')+1, ' and')
			}
		}
	}
}

Process {
	# check for PDC role
	If (Assert-NonInteractiveSession -and $DnsHostName -ne $PdcRoleOwner) {
		Write-Information -MessageData 'Skipping DNS record cleanup: running non-interactively and the current system does not hold the Infrastructure Master role'
		Return
	}

	# creat empty objects
	$DnsZonesOnPdcRole = 0
	$DnsRecordsLocated = 0
	$DnsRecordsRemoved = 0
	$DnsRecordsErrored = 0
	$DnsRecordsInTotal = 0

	# ensure timespan is positive
	If ($TimeSpan -lt [timespan]::Zero) {
		$TimeSpan = $TimeSpan.Negate()
	}
	
	# get date from timespan
	$PreviousDate = [datetime]::Now.Subtract($TimeSpan)

	# declare date
	Write-Information -MessageData "Retrieve records last updated before $($PreviousDate.ToString()) ($(Get-TimeSpanAsFormattedString -TimeSpan $TimeSpan))"

	# get AD-integrated primary DNS zones with dynamic update enabled
	Try {
		$DnsServerZones = Get-DnsServerZone -ComputerName $PdcRoleOwner | Where-Object { $_.IsDsIntegrated -and $_.ZoneName -notlike '_msdcs.*' -and $_.ZoneType -eq 'Primary' -and $_.DynamicUpdate -in 'Secure', 'Unsecure' }
	}
	Catch {
		Write-Warning -Message "could not retrieve DNS zones: $($_.Exeception.Message)"
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
		Write-Information -MessageData "Checking for records in '$($DnsServerZone.ZoneName)'"

		# get DNS records
		Try {
			$DnsServerResourceRecords = Get-DnsServerResourceRecord -ComputerName $PdcRoleOwner -ZoneName $DnsServerZone.ZoneName | Where-Object { $_.TimeStamp -gt 0 -and $_.Timestamp -lt $PreviousDate } | Sort-Object -Property RecordType, HostName
		}
		Catch {
			Write-Warning -Message "could not retrieve DNS records: $($_.Exeception.Message)"
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
					Write-Information -MessageData "Located unexpected $($DnsServerResourceRecord.RecordType) record from $($DnsServerZone.ZoneName) created on $($DnsServerResourceRecord.TimeStamp): $($DnsServerResourceRecord.HostName)"
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
					Write-Warning -Message "could not remove record: $($_.ToString())"
					$DnsRecordsErrored++
					Continue NextDnsServerResourceRecord
				}

				# declare removed
				Write-Information -MessageData "Removed $($DnsServerResourceRecord.RecordType) record from $($DnsServerZone.ZoneName) created on $($DnsServerResourceRecord.TimeStamp): $($DnsServerResourceRecord.HostName); $RecordData"
				$DnsRecordsRemoved++
			}
			Else {
				# declare found
				Write-Information -MessageData "Located $($DnsServerResourceRecord.RecordType) record from $($DnsServerZone.ZoneName) created on $($DnsServerResourceRecord.TimeStamp): $($DnsServerResourceRecord.HostName); $RecordData"
				$DnsRecordsLocated++
			}
		}
	}

	# report DNS records removed
	Write-Information -MessageData "Found '$DnsRecordsInTotal' records(s) in '$DnsZonesOnPdcRole' zones"

	Write-Information -MessageData "Removed '$DnsRecordsRemoved' records(s)"
	If ($DnsRecordsLocated -gt 0) {
		Write-Information -MessageData "Located '$DnsRecordsLocated' records(s) to delete"
	}
	If ($DnsRecordsErrored -gt 0) {
		Write-Information -MessageData "Could not remove '$DnsRecordsErrored' records(s)"
	}
}
