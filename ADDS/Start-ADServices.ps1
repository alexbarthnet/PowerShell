<#
.SYNOPSIS
Starts Active Directory and related services after boot up of an Active Directory directory server then verify Active Directory Web Services is servicing all Active Directory instances.

.DESCRIPTION
Starts Active Directory and related services after boot up of an Active Directory directory server then verify Active Directory Web Services is servicing all Active Directory instances.

.NOTES
This script first starts Active Directory instances (NTDS for domain controllers, named instances for AD LDS servers).
This script then starts any services dependent on NTDS on domain controllers.
This script then verifies that ADWS is servicing all known instances on the directory server.

.LINK
TBD

#>

[CmdletBinding()]
param (
	# domain role of current system
	[Parameter(DontShow)]
	[uint16]$DomainRole = (Get-CimInstance -ClassName 'Win32_ComputerSystem' -Property 'DomainRole').DomainRole
)

begin {
	function Assert-EventAfterLastBoot {
		[CmdletBinding()]
		param (
			# date time of last boot
			[Parameter(DontShow)]
			[datetime]$LastBootUpTime = (Get-CimInstance -ClassName 'Win32_OperatingSystem' -Property 'LastBootUpTime').LastBootUpTime,
			[Parameter(Mandatory, Position = 0)]
			[string]$LogName,
			[Parameter(Mandatory, Position = 1)]
			[uint32]$EventId,
			[uint32]$Number = 1,
			[uint32]$Limit = 8,
			[uint32]$Seconds = 5,
			[uint32]$WaitTime = 0,
			[uint32]$Multiplier = 0,
			[switch]$SkipWaitTimeMultiplier
		)

		# retrieve count of specific events after last boot up time
		try {
			$Count = Get-EventLog -LogName $LogName -After $LastBootUpTime -ErrorAction 'Stop' | Where-Object { $_.EventId -eq $EventId } | Measure-Object | Select-Object -ExpandProperty 'Count'
		}
		catch {
			Write-Warning -Message "$LogName; could not retrieve events before while loop"
			throw $_
		}

		# while limit not reached and count of events less than requested number of events...
		while ($Multiplier -lt $Limit -and $Count -lt $Number) {
			# increment multiplier
			$Multiplier++

			# if skip wait time multiplier requested...
			if ($SkipWaitTimeMultiplier.IsPresent) {
				$SecondsToSleep = $Seconds
			}
			# if skip wait time multiplier not requested...
			else {
				$SecondsToSleep = $Seconds * $Multiplier
			}

			# record total wait time
			$WaitTime += $SecondsToSleep

			# report state then wait
			Write-Host "...waiting an additional '$SecondsToSleep' seconds"
			Start-Sleep -Seconds $SecondsToSleep

			# retrieve count of specific events after last boot up time
			try {
				$Count = Get-EventLog -LogName $LogName -After $LastBootUpTime -ErrorAction 'Stop' | Where-Object { $_.EventId -eq $EventId } | Measure-Object | Select-Object -ExpandProperty 'Count'
			}
			catch {
				Write-Warning -Message "$LogName; could not retrieve events during while loop pass #$Multiplier"
				throw $_
			}
		}

		# if count of events less than requested number of events...
		if ($Count -lt $Number) {
			# ...declare wait time before throwing exception
			Write-Warning -Message "$LogName; could not find at least '$Number' events with '$EventId' event id after '$WaitTime' seconds"

			# throw exception
			throw
		}

		# if wait time incurred...
		if ($WaitTime -gt 0) {
			# ...declare complete and wait time
			Write-Host "$LogName, found '$Count' events with '$EventId' event id after '$WaitTime' seconds"
		}
		# if wait time not incurred...
		else {
			# ...declare complete
			Write-Host "$LogName, found '$Count' events with '$EventId' event id"
		}
	}

	function Start-ServiceAfterWait {
		param(
			[Parameter(Position = 0, Mandatory)]
			[string]$Name,
			[uint32]$Limit = [uint32]5,
			[uint32]$Seconds = [int32]5,
			[uint32]$WaitTime = [int32]0,
			[uint32]$Multiplier = [int32]0
		)

		# report state
		Write-Host "$Name; waiting for service to start automatically..."

		# get service by name
		try {
			$Service = Get-Service -Name $Name -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "$Name; could not retrieve service: $($_.Exception.Message)"
			return $_
		}

		# while limit not reached and service not running...
		while ($Multiplier -lt $Limit -and -not $Service.Status -eq 'Running') {
			# increment multiplier
			$Multiplier++

			# record total time
			$WaitTime += ($Seconds * $Multiplier)

			# wait for collection update to complete
			Write-Host "$Name; waiting an additional '$($Seconds * $Multiplier)' seconds"
			Start-Sleep -Seconds ($Seconds * $Multiplier)

			# get service by name
			try {
				$Service = Get-Service -Name $Name -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message "$Name; could not retrieve service: $($_.Exception.Message)"
				return $_
			}
		}

		# if service running...
		if ($Service.Status -eq 'Running') {
			# ...and wait time incurred...
			if ($WaitTime -gt 0) {
				# ...declare module loaded and wait time
				Write-Host "$Name; found service started after '$WaitTime' seconds"
			}
			# ...and wait time not incurred...
			else {
				# ...declare module loaded
				Write-Host "$Name; found service started"

			}
		}
		# if service not running...
		else {
			# warn before starting service
			Write-Warning -Message "$Name; service not started after '$WaitTime' seconds; starting service..."
			return $_

			# start the service
			try {
				Start-Service -Name $Name -Force
			}
			catch {
				Write-Warning -Message "$Name; could not start service: $($_.Exception.Message)"
				return $_
			}

			# report state
			Write-Host "$Name; service started after '$WaitTime' seconds"
			return $_
		}
	}
}

process {
	# if local system is a domain controller...
	if ($DomainRole -ge 4) {
		# start NTDS
		try {
			Start-ServiceAfterWait -Name 'NTDS'
		}
		catch {
			return $_
		}

		# start Netlogon
		try {
			Start-ServiceAfterWait -Name 'Netlogon'
		}
		catch {
			return $_
		}

		# start KDC
		try {
			Start-ServiceAfterWait -Name 'KDC'
		}
		catch {
			return $_
		}

		# define number of events
		$Number = 1
	}
	# if local system is not a domain controller (AD LDS)...
	else {
		# retrieve all services for AD LDS instance
		try {
			$Services = Get-CimInstance -ClassName 'Win32_Service' -Filter "PathName like '%dsamain.exe%'"
		}
		catch {
			Write-Warning -Message "could not retrieve services: $($_.Exception.Message)"
			return $_
		}

		# loop through services
		foreach ($Name in $Services.Name) {
			# start AD LDS instance
			try {
				Start-ServiceAfterWait -Name $Name
			}
			catch {
				return $_
			}
		}

		# set number of events to number of instances
		$Number = $Services | Measure-Object | Select-Object -ExpandProperty 'Count'
	}

	# start ADWS
	try {
		Start-ServiceAfterWait -Name 'ADWS'
	}
	catch {
		return $_
	}

	# assert ADWS servicing instances
	try {
		Assert-EventAfterLastBoot -LogName 'Active Directory Web Services' -EventId 1200 -Number $Number
	}
	catch {
		return $_
	}
}
