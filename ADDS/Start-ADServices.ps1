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

	function Assert-ServiceStarted {
		param(
			[Parameter(Position = 0, Mandatory)]
			[string]$Name,
			[switch]$Force,
			[uint32]$TimeLimit = 60,
			[uint32]$TimeBetweenQueries = 5,
			[switch]$TimeBetweenQueriesIsMultiplied,
			[switch]$WaitForDependentToStartService
		)

		# retrieve service by name
		try {
			$Service = Get-Service -Name $Name -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not retrieve the '$Name' service: $($_.Exception.Message)"
			throw $_
		}

		# if service running...
		if ($Service.Status -eq 'Running') {
			# report state then return
			Write-Host "the '$Name' service was found already running"
			return
		}

		# if service start type is disabled...
		if ($Service.StartType -eq 'Disabled') {
			# warn before throwing exception
			Write-Warning -Message "the '$Name' service is disabled and cannot start"
			throw
		}

		# if service start type is manual or wait for dependent not requested...
		if ($Service.StartType -eq 'Manual' -and -not $WaitForDependentToStartService) {
			# start service by name and wait for service to start
			try {
				$Service = Start-Service -Name $Name -PassThru -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message "could not start the '$Name' service manually: $($_.Exception.Message)"
				throw $_
			}

			# report state then return
			Write-Host "the '$Name' service was started manually"
			return
		}

		# report state
		Write-Host "waiting for the '$Name' service to start..."

		# create and start stopwatch
		$StopWatch = [System.Diagnostics.Stopwatch]::StartNew()

		# while elapsed time is less than time limit and service not running...
		while ($StopWatch.Elapsed.TotalSeconds -lt $TimeLimit -and $Service.Status -ne 'Running') {
			# sleep between queries
			Start-Sleep -Seconds $TimeBetweenQueries

			# retrieve service by name
			try {
				$Service = Get-Service -Name $Name -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message "could not retrieve the '$Name' service: $($_.Exception.Message)"
				throw $_
			}

			# if service running...
			if ($Service.Status -eq 'Running') {
				# report state and wait time then return
				Write-Host "the '$Name' service was found running after '$([uint32]$StopWatch.Elapsed.TotalSeconds)' seconds"
				return
			}

			# report state
			Write-Host "...waiting an additional '$TimeBetweenQueries' seconds..."
		}

		# warn before starting service
		Write-Warning -Message "the '$Name' service was not found running after '$([uint32]$StopWatch.Elapsed.TotalSeconds)' seconds; starting service manually..."

		# start service by name and wait for service to start
		try {
			$Service = Start-Service -Name $Name -PassThru -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "could not start the '$Name' service manually: $($_.Exception.Message)"
			throw $_
		}

		# report state and wait time then return
		Write-Host "the '$Name' service was started manually after '$([uint32]$StopWatch.Elapsed.TotalSeconds)' seconds"
		return
	}
}

process {
	# if local system is a domain controller...
	if ($DomainRole -ge 4) {
		# start NTDS
		try {
			Assert-ServiceStarted -Name 'NTDS'
		}
		catch {
			return $_
		}

		# start Netlogon
		try {
			Assert-ServiceStarted -Name 'Netlogon'
		}
		catch {
			return $_
		}

		# start KDC
		try {
			Assert-ServiceStarted -Name 'KDC'
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
				Assert-ServiceStarted -Name $Name
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
		Assert-ServiceStarted -Name 'ADWS'
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
