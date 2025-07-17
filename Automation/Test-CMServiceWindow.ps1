<#
.SYNOPSIS
Test if a Configuration Manager service window is scheduled.

.DESCRIPTION
Test if a Configuration Manager service window is scheduled.

.PARAMETER Mode
The mode of the script. The default value is "DayOfWeek" and the following values are supported:
- DayOfWeek: check if a service window is configured for the current day of the week
- StartsWithin: check if a service window is configured to start within a provided timespan.

.PARAMETER TimeSpan
Timespan for specific modes. The default value is 1 hour. The timespan is utilized as follow:
- StartsWithin: check if a service window is configured to start between the current time and the current time plus the timespan.

.INPUTS
None.

.OUTPUTS
Boolean.

.EXAMPLE
.\Test-CMServiceWindow.ps1

.EXAMPLE
.\Test-CMServiceWindow.ps1 -Mode StartsWithin

.EXAMPLE
.\Test-CMServiceWindow.ps1 -Mode StartsWithin -Timespan (New-TimeSpan -Hours 4)

.LINK
https://learn.microsoft.com/en-us/mem/configmgr/develop/reference/core/clients/sdk/ccm_servicewindow-client-wmi-class
#>

[CmdletBinding()]
Param(
	# current time
	[Parameter(DontShow)]
	[datetime]$Now = [System.DateTime]::Now,
	# mode for script
	[Parameter(Position = 0)][ValidateSet('DayOfWeek', 'StartsWithin')]
	[string]$Mode = 'DayOfWeek',
	# timespan for parameters
	[Parameter(Position = 1)]
	[timespan]$TimeSpan = [System.TimeSpan]::FromHours(1),
	# switch to write response to a variable instead of to the pipeline
	[Parameter(Position = 2)]
	[switch]$AsVariable,
	# name of variable when AsVariable is true
	[Parameter(Position = 3)]
	[name]$VariableName = 'TestCMServiceWindow',
	# scope of variable when AsVariable is true
	[Parameter(Position = 4)]
	[name]$VariableScope = 'global'
)


# retrieve the CIM instance
Try {
	$ServiceWindows = Get-CimInstance -Namespace "root\ccm\clientsdk" -Class "CCM_ServiceWindow"
}
Catch {
	Write-Warning -Message "could not filter the service window objects: $($_.Exception.Message)"
	Return $_
}
	
# filter the CIM instance to the ALLPROGRAM_SERVICEWINDOW type
Try {
	$FilteredServiceWindows = $ServiceWindows.Where({ $_.Type -eq 1 })
}
Catch {
	Write-Warning -Message "could not filter the service window objects: $($_.Exception.Message)"
	Return $_
}

# retrieve adjusted datetime
switch ($Mode) {
	'StartsWithin' {
		Try {
			$DateTime = $Now.Add($TimeSpan)
		}
		Catch {
			Write-Warning -Message "could not create datetime from timespan: $($_.Exception.Message)"
			Return $_
		}
	}
}

# loop through maintenance windows
ForEach ($ServiceWindow in $FilteredServiceWindows) {
	# retrieve service window start time and end time converted to universal time
	# the datetime values are reported as UTC values but with a "local" type
	# the datetime values are converted "to" universal time to retrieve the actual local times
	$StartTime = $ServiceWindow.StartTime.ToUniversalTime()
	$EndTime = $ServiceWindow.EndTime.ToUniversalTime().AddSeconds(-1)

	# switch on mode
	switch ($Mode) {
		'DayOfWeek' {
			# if service window starts today...
			If ($StartTime.DayOfWeek -eq $Now.DayOfWeek) {
				Write-Verbose -Message "Service Window found that starts today: $($Now.ToString('o'))"
				Return $true
			}
			# if service window ends today...
			If ($EndTime.DayOfWeek -eq $Now.DayOfWeek) {
				Write-Verbose -Message "Service Window found that ends today: $($Now.ToString('o'))"
				Return $true
			}
		}
		'StartsWithin' {
			# if adjusted date time is within start and end time...
			If ($DateTime -gt $StartTime -and $DateTime -lt $EndTime) {
				Write-Verbose -Message "Service Window found that starts within '$($TimeSpan.ToString())' timespan from now: $($Now.ToString('o'))"
				Return $true
			}
		}
	}
}

# return false if not conditions met
switch ($Mode) {
	'DayOfWeek' {
		Write-Verbose -Message "No Service Window found that starts or ends today: $($Now.ToString('o'))"
		Return $false
	}
	'StartsWithin' {
		Write-Verbose -Message "No Service Window found that starts within '$($TimeSpan.ToString())' timespan from now: $($Now.ToString('o'))"
		Return $true
	}
}
