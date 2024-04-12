Function Get-RandomAlpha {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Position = 0, Mandatory = $True)][ValidateRange(1, 65535)]
		[uint16]$Length,
		[Parameter(ParameterSetName = 'Defined')]
		[switch]$LowerCase,
		[Parameter(ParameterSetName = 'Defined')]
		[switch]$UpperCase,
		[Parameter(ParameterSetName = 'Defined')]
		[switch]$Numbers,
		[Parameter(ParameterSetName = 'Defined')]
		[switch]$Symbols,
		[Parameter(ParameterSetName = 'Default')]
		[switch]$All,
		[switch]$AsSecureString,
		[char[]]$ExcludeCharacters,
		[string[]]$ExcludeStrings
	)

	# check parameters
	If ($PSCmdlet.ParameterSetName -eq 'Default') { $All = $true }

	# build list of characters
	$List = [System.Collections.Generic.List[char]]::new()
	If ($All -or $Numbers) { 
		# 0123456789
		$List.AddRange([char[]](48..57))
	}
	If ($All -or $UpperCase) {
		# ABCDEFGHIJKLMNOPQRSTUVWXYZ
		$List.AddRange([char[]](65..90))
	}
	If ($All -or $LowerCase) {
		# abcdefghijklmnopqrstuvwxyz
		$List.AddRange([char[]](97..122))
	}
	If ($All -or $Symbols) {
		# !"#$%&'()*+,-./
		$List.AddRange([char[]](33..47))
		# :;<=>?@
		$List.AddRange([char[]](58..64))
		# [\]^_`
		$List.AddRange([char[]](91..96))
		# {|}~
		$List.AddRange([char[]](123..127))
	}

	# remove excluded characters
	ForEach ($Character in $ExcludeCharacters) { $null = $List.RemoveAll($Character) }

	# create string builder
	$StringBuilder = [System.Text.StringBuilder]::new()

	# create random string
	While ($StringBuilder.Length -lt $Length) {
		# append random character to string from list
		$null = $StringBuilder.Append($List[(Get-Random -Max $List.Count)])
		# remove excluded strings
		ForEach ($String in $ExcludeStrings) { $null = $StringBuilder.Replace($String,$null) }
	}

	# if secure string requested...
	If ($AsSecureString) {
		# return random string converted to secure string
		Return (ConvertTo-SecureString -String $StringBuilder.ToString() -AsPlainText -Force)
	}
	Else {
		# return random string
		Return $StringBuilder.ToString()
	}
}
