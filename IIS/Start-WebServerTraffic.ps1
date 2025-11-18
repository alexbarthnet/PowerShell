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
		Write-Host "found '$PathForConfiguredState' configured state file; checking services"
	}
	# if configured state file not found...
	else {
		# warn and return
		Write-Warning -Message "the '$PathForConfiguredState' configured state file was not found; skipping service checks"
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
