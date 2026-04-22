<#
.SYNOPSIS
Test if the current time is between the datetimes parsed from provided strings.

.DESCRIPTION
Test if the current time matches the datetime parsed from a provided string.

.PARAMETER StartingDateTime
String value for the starting datetime that can be parsed into a [System.DateTime] object by the Parse() method.

.PARAMETER EndingDateTime
String value for the ending datetime that can be parsed into a [System.DateTime] object by the Parse() method.

.PARAMETER VariableName
SWitch parameter to store the result of the function as a variable rather than returning the result to the caller.

.PARAMETER VariableName
String value for the name of the variable when AsVariable switch provided. The default value is "TestCurrentTimeForDateTime".

.PARAMETER VariableScope
String value for the scope of the variable when AsVariable switch provided. The default value is "global".

.INPUTS
String.

.OUTPUTS
Boolean.

.EXAMPLE
.\Test-CurrentTimeForDateTime.ps1 -StartingDateTime '4AM' -EndingDateTime '5AM'

.NOTES
The StartingDateTime can be parsed as a specific day or hour.
#>

param(
	# current date time
	[Parameter(DontShow)]
	[datetime]$Now = [System.DateTime]::Now,
	# string to evaluate for starting datetime
	[Parameter(Position = 0, Mandatory = $True)]
	[string]$StartingDateTime,
	# string to evaluate for ending datetime
	[Parameter(Position = 1, Mandatory = $True)]
	[string]$EndingDateTime,
	# switch to write response to a variable instead of to the pipeline
	[Parameter(Position = 2)]
	[switch]$AsVariable,
	# name of variable when AsVariable is true
	[Parameter(Position = 3)]
	[string]$VariableName = 'TestCurrentTimeForDateTime',
	# scope of variable when AsVariable is true
	[Parameter(Position = 4)]
	[string]$VariableScope = 'global'
)

process {
	# parse starting date time
	try {
		$StartingDateTimeObject = [System.DateTime]::Parse($StartingDateTime)
	}
	catch {
		Write-Warning -Message "could not parse '$StartingDateTime' value of 'StartingDateTime' as DateTime object"
		return $_
	}

	# parse ending date time
	try {
		$EndingDateTimeObject = [System.DateTime]::Parse($EndingDateTime)
	}
	catch {
		Write-Warning -Message "could not parse '$EndingDateTime' value of 'EndingDateTime' as DateTime object"
		return $_
	}

	# if now is between starting and ending datetime objects...
	if ($StartingDateTimeObject -le $Now -and $EndingDateTimeObject -ge $Now) {
		$Value = $true
	}
	else {
		$Value = $false
	}

	# if AsVariable requested...
	if ($AsVariable) {
		New-Variable -Name $VariableName -Scope $VariableScope -Value $Value -Force
	}
	else {
		return $Value
	}
}
