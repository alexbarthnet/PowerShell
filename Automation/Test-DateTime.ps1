<#
.SYNOPSIS
Test if a requested value is present in the current DateTime object.

.DESCRIPTION
Test if a requested value is present in the current DateTime object.

.PARAMETER Hour
The hour in 24 hour time.

.PARAMETER DayOfWeek
Timespan for specific modes. The default value is 1 hour. The timespan is utilized as follow:
- StartsWithin: check if a service window is configured to start between the current time and the current time plus the timespan.

.INPUTS
None.

.OUTPUTS
Boolean.

.EXAMPLE
.\Test-DateTime.ps1

.EXAMPLE
.\Test-DateTime.ps1 -Mode StartsWithin

.EXAMPLE
.\Test-DateTime.ps1 -DayOfWeek 'Friday'

#>

[CmdletBinding(DefaultParameterSetName = 'Hour')]
Param(
	# current time
	[Parameter(DontShow)]
	[datetime]$Now = [System.DateTime]::Now,
	# mode for script
	[Parameter(Position = 0, Mandatory, ParameterSetName = 'DayOfWeek')]
	[Parameter(Position = 1, Mandatory, ParameterSetName = 'HourAndDayOfWeek')]
	[string[]]$DayOfWeek,
	# timespan for parameters
	[Parameter(Position = 0, Mandatory, ParameterSetName = 'Hour')]
	[Parameter(Position = 0, Mandatory, ParameterSetName = 'HourAndDayOfWeek')]
	[uint16[]]$Hour,
	# switch to write response to a variable instead of to the pipeline
	[Parameter(Position = 1)]
	[switch]$AsVariable,
	# name of variable when AsVariable is true
	[Parameter(Position = 2)]
	[string]$VariableName = 'TestDateTime',
	# scope of variable when AsVariable is true
	[Parameter(Position = 3)]
	[string]$VariableScope = 'global'
)

Process {
	# switch on parameter set
	switch ($PSCmdlet.ParameterSetName) {
		'DayOfWeek' {
			$Value = $Now.DayOfWeek -in $DayOfWeek
		}
		'Hour' {
			$Value = $Now.Hour -in $Hour
		}
		'HourAndDayOfWeek' {
			$Value = $Now.Hour -in $Hour -and $Now.DayOfWeek -in $DayOfWeek
		}
		default {
			$Value = $false
		}
	}

	# if AsVariable requested...
	If ($AsVariable) {
		New-Variable -Name $VariableName -Scope $VariableScope -Value $Value -Force
	}
	Else {
		return $Value
	}
}