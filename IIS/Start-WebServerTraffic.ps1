<#
.SYNOPSIS
Inform configured load balancers that the local web server is ready to receive traffic.

.DESCRIPTION
Inform configured load balancers that the local web server is ready to receive traffic by creating a state file used by configured load balancers when a configured state file exists.

.PARAMETER PathForActiveState
The path to the active state file. The default value is 'C:\inetpub\wwwroot\host\active'

.PARAMETER PathForConfiguredState
The path to the configured state file. The default value is 'C:\inetpub\wwwroot\host\configured'

.NOTES
The 'configured' state file should be created as the last step of configuring a web server. This acts as the key to determine if the 'active' state file should be present or removed.

#>

[CmdletBinding()]
param (
	# path to active state file
	[Parameter(Position = 1)]
	[string]$PathForActiveState = 'C:\inetpub\wwwroot\host\active',
	# path to configured state file
	[Parameter(Position = 2)]
	[string]$PathForConfiguredState = 'C:\inetpub\wwwroot\host\configured'
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
			[uint32]$Limit = [uint32]5,
			[uint32]$Seconds = [int32]5,
			[uint32]$WaitTime = [int32]0,
			[uint32]$Multiplier = [int32]0,
			[switch]$SkipWaitTimeMultiplier
		)

		# retrieve service by name
		try {
			$Service = Get-Service -Name $Name -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "$Name; could not retrieve service: $($_.Exception.Message)"
			throw $_
		}

		# if service running...
		if ($Service.Status -eq 'Running') {
			# report state and return
			Write-Host "$Name; found service running"
			return
		}

		# if service start type is disabled...
		if ($Service.StartType -eq 'Disabled') {
			# warn before throwing exception
			Write-Warning -Message "$Name; cannot start disabled service"
			throw
		}

		# if service start type is manual...
		if ($Service.StartType -eq 'Manual') {
			# start service by name
			try {
				$Service = Start-Service -Name $Name -PassThru -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message "$Name; could not start service manually: $($_.Exception.Message)"
				throw $_
			}

			# if service running...
			if ($Service.Status -eq 'Running') {
				# report state and return
				Write-Host "$Name; started service manually"
				return
			}
			# if service is not running...
			else {
				# warn before throwing exception
				Write-Warning -Message "$Name; found service not running after starting service manually"
				throw
			}
		}

		# while limit not reached and service not running...
		while ($Multiplier -lt $Limit -and -not $Service.Status -eq 'Running') {
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

			# retrieve service by name
			try {
				$Service = Get-Service -Name $Name -ErrorAction 'Stop'
			}
			catch {
				Write-Warning -Message "$Name; could not retrieve service: $($_.Exception.Message)"
				throw $_
			}

			# if service running...
			if ($Service.Status -eq 'Running') {
				# report state and wait time then return
				Write-Host "$Name; found service running after '$WaitTime' seconds"
				return
			}
		}


		# warn before starting service
		Write-Warning -Message "$Name; found service not running after '$WaitTime' seconds; starting service..."

		# start the service
		try {
			$Service = Start-Service -Name $Name -PassThru -Force -ErrorAction 'Stop'
		}
		catch {
			Write-Warning -Message "$Name; could not start service: $($_.Exception.Message)"
			throw $_
		}

		# if service running...
		if ($Service.Status -eq 'Running') {
			# report state and return
			Write-Host "$Name; started service manually"
			return
		}
		# if service is not running...
		else {
			# warn before throwing exception
			Write-Warning -Message "$Name; found service not running after starting service manually"
			throw
		}
	}
}

process {
	# find active state file
	$ActiveStateFileExists = Test-Path -Path $PathForActiveState -PathType Leaf

	# find configured state file
	$ConfiguredStateFileExists = Test-Path -Path $PathForConfiguredState -PathType Leaf

	# if configured state file not found...
	if (!$ConfiguredStateFileExists) {
		# if active state file found...
		if ($ActiveStateFileExists) {
			# warn and report state
			Write-Warning -Message "found '$PathForActiveState' active state file without '$PathForConfiguredState' configured state file; removing active state file"

			# remove active state file
			try {
				Remove-Item -Path $PathForActiveState -Force
			}
			catch {
				Write-Warning -Message "could not remove '$PathForActiveState' active state file: $($_.Exception.Message)"
				return $_
			}

			# report state
			Write-Host "removed '$PathForActiveState' active state file"
		}
		else {
			# warn and report state
			Write-Warning -Message "could not locate either '$PathForActiveState' active state file or '$PathForConfiguredState' configured state file; skipping service checks"
		}

		# return after checking active state file
		return
	}

	# start HTTP Service
	try {
		Assert-ServiceStarted -Name 'http'
	}
	catch {
		return $_
	}

	# start Windows Process Activation Service
	try {
		Assert-ServiceStarted -Name 'was'
	}
	catch {
		return $_
	}

	# start World Wide Web Publishing Service
	try {
		Assert-ServiceStarted -Name 'w3svc'
	}
	catch {
		return $_
	}

	# create active state file
	try {
		$ItemForActiveState = New-Item -Force -Type File -Path $PathForActiveState
	}
	catch {
		Write-Warning -Message "could not create '$PathForActiveState' active state file: $($_.Exception.Message)"
		return $_
	}

	# define value for active state file
	$Value = $ItemForActiveState.LastWriteTimeUtc.ToString('o')

	# update active state file
	try {
		$ItemForActiveState | Set-Content -NoNewline -Value $Value
	}
	catch {
		Write-Warning -Message "could not update '$PathForActiveState' active state file with '$Value' value: $($_.Exception.Message)"
		return $_
	}
}
