# see UtilityFunctions.psm1 for the latest version
Function Get-RandomHex {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Position = 0, Mandatory = $True)][ValidateRange(1, 65535)]
		[uint16]$Length,
		[Parameter(Position = 1)]
		[switch]$UpperCase
	)

	# create string builder
	$string = [System.Text.StringBuilder]::new()

	# create random string
	While ($StringBuilder.Length -lt $Length) {
		$null = $string.Append('{0:x}' -f (Get-Random -Max 15))
	}

	# return random string
	If ($UpperCase) {
		Return $string.ToString().ToUpperInvariant()
	}
	Else {
		Return $string.ToString()
	}
}
