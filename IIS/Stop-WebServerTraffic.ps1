<#
.SYNOPSIS
Inform configured load balancers to stop sending traffic to the local web server.

.DESCRIPTION
Inform configured load balancers to stop sending traffic to the local web server by removing a state file used by configured load balancers.

.PARAMETER PathForReadyState
The path to the state file. The default value is 'C:\inetpub\wwwroot\host\ready.htm'

.PARAMETER Seconds
The time in seconds to wait after removing tthe state file.

#>

[CmdletBinding()]
param (
	# path to ready state file
	[Parameter(Position = 0)]
	[string]$PathForReadyState = 'C:\inetpub\wwwroot\host\ready.htm',
	# time in seconds to sleep for
	[Parameter(Position = 1)]
	[unit16]$Seconds = 30
)

process {
	# find ready state file
	$ReadyStateFileExists = Test-Path -Path $PathForReadyState -PathType Leaf

	# if ready state file found...
	if ($ReadyStateFileExists) {
		# warn and report state
		Write-Warning -Message "the '$PathForReadyState' ready state file was found; removing ready state file"

		# remove ready state file
		try {
			Remove-Item -Path $PathForReadyState -Force
		}
		catch {
			Write-Warning -Message "could not remove '$PathForReadyState' ready state file: $($_.Exception.Message)"
			return $_
		}

		# report state
		Write-Host "removed '$PathForReadyState' ready state file"
	}
	# if ready state file not found...
	else {
		Write-Warning -Message "the '$PathForReadyState' ready state file was not found"
		return
	}

	# report state
	Write-Host "waiting '$Seconds' seconds to allow load balancers to detect absence of ready state file"

	# sleep
	Start-Sleep -Seconds $Seconds
}