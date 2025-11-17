<#
.SYNOPSIS
Inform configured load balancers to stop sending traffic to the local web server.

.DESCRIPTION
Inform configured load balancers to stop sending traffic to the local web server. by removing a state file used by configured load balancers.

.PARAMETER PathForActiveState
The path to the active state file. The default value is 'C:\inetpub\wwwroot\host\active'

.PARAMETER Wait
Switch parameter to sleep for 30 seconds

#>

[CmdletBinding()]
param (
	# path to state file
	[Parameter(Position = 1)]
	[string]$PathForActiveState = 'C:\inetpub\wwwroot\host\active',
	# switch parameter to wait for 30 seconds after removing file
	[Parameter(Position = 2)]
	[switch]$Wait,
	# time in seconds to sleep for
	[Parameter(Position = 3)]
	[unit16]$Seconds = 30
)

process {
	# test path
	$PathFound = Test-Path -Path $PathForActiveState -PathType Leaf

	# if path not found...
	if (!$PathFound) {
		Write-Warning -Message "could not locate '$PathForActiveState' active state file"
		return
	}

	# remove state file
	try {
		Remove-Item -Path $PathForActiveState -Force
	}
	catch {
		Write-Warning -Message "could not remove '$PathForActiveState' active state file: $($_.Exception.Message)"
		return $_
	}

	# if wait requested...
	if ($Wait.IsPresent) {
		# report state
		Write-Host "waiting '$Seconds' seconds to allow load balancers to detect absence of active state file"

		# sleep
		Start-Sleep -Seconds $Seconds
	}
}