Function Get-PreviousDate {
	Param (
		[Parameter(Mandatory = $true, Position = 0)][ValidateRange(1, 65535)]
		[uint16]$OlderThanUnits,
		[Parameter(Mandatory = $true, Position = 1)][ValidateSet('Seconds', 'Minutes', 'Hours', 'Days', 'Weeks', 'Months', 'Years')]
		[string]$OlderThanType
	)
	Switch ($OlderThanType) {
		'Seconds' { Return (Get-Date).AddSeconds(-1 * $OlderThanUnits) }
		'Minutes' { Return (Get-Date).AddMinutes(-1 * $OlderThanUnits) }
		'Hours' { Return (Get-Date).AddHours(-1 * $OlderThanUnits) }
		'Days' { Return (Get-Date).AddDays(-1 * $OlderThanUnits) }
		'Weeks' { Return (Get-Date).AddWeeks(-1 * $OlderThanUnits) }
		'Months' { Return (Get-Date).AddMonths(-1 * $OlderThanUnits) }
		'Years' { Return (Get-Date).AddYears(-1 * $OlderThanUnits) }
	}
}
