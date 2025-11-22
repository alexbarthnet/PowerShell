<#
.SYNOPSIS
Inform configured load balancers that the local web server is ready to receive traffic.

.DESCRIPTION
Inform configured load balancers that the local web server is ready to receive traffic by creating a state file used by configured load balancers when a configured state file exists.

.PARAMETER PathForReadyState
The path to the ready state file. The default value is 'C:\inetpub\wwwroot\host\ready.htm'

.PARAMETER PathForConfiguredState
The path to the configured state file. The default value is 'C:\inetpub\wwwroot\host\configured.htm'

.NOTES
The 'configured' state file should be created as the last step of configuring a web server. This acts as the key to determine if the 'ready' state file should be present or removed.

#>

[CmdletBinding()]
param (
	# path to ready state file
	[Parameter(Position = 1)]
	[string]$PathForReadyState = 'C:\inetpub\wwwroot\host\ready.htm',
	# path to configured state file
	[Parameter(Position = 2)]
	[string]$PathForConfiguredState = 'C:\inetpub\wwwroot\host\configured.htm'
)

begin {
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
	# find ready state file
	$ReadyStateFileExists = Test-Path -Path $PathForReadyState -PathType Leaf

	# if ready state file found...
	if ($ReadyStateFileExists) {
		# warn and report state
		Write-Warning -Message "the '$PathForReadyState' ready state file was found unexpectedly; removing ready state file"

		# remove ready state file
		try {
			Remove-Item -Path $PathForReadyState -Force
		}
		catch {
			Write-Warning -Message "could not remove '$PathForReadyState' ready state file: $($_.Exception.Message)"
			return $_
		}

		# report state
		Write-Host "removed '$PathForReadyState' ready state file, checking configured state file"
	}
	else {
		# report state
		Write-Host "the '$PathForReadyState' ready state file was not found as expected, checking configured state file"
	}

	# find configured state file
	$ConfiguredStateFileExists = Test-Path -Path $PathForConfiguredState -PathType Leaf

	# if configured state file found...
	if ($ConfiguredStateFileExists) {
		# report state
		Write-Host "the '$PathForConfiguredState' configured state file was found; checking services"
	}
	# if configured state file not found...
	else {
		# warn and return
		Write-Warning -Message "the '$PathForConfiguredState' configured state file was NOT found; skipping service checks"
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

	# create ready state file
	try {
		$ItemForReadyState = New-Item -Force -Type File -Path $PathForReadyState
	}
	catch {
		Write-Warning -Message "could not create '$PathForReadyState' ready state file: $($_.Exception.Message)"
		return $_
	}

	# report state
	Write-Host "created '$PathForReadyState' ready state file, setting contents to current time"

	# define value for ready state file
	$Value = $ItemForReadyState.LastWriteTimeUtc.ToString('o')

	# update ready state file
	try {
		$ItemForReadyState | Set-Content -NoNewline -Value $Value
	}
	catch {
		Write-Warning -Message "could not update '$PathForReadyState' ready state file with '$Value' value: $($_.Exception.Message)"
		return $_
	}

	# report state
	Write-Host "updated '$PathForReadyState' ready state file with current time"
}
