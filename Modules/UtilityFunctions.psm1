Function ConvertFrom-SecurityIdentifier {
	[CmdletBinding()]
	param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[object]$SID
	)

	# verify the input
	If ($SID -isnot [System.Security.Principal.SecurityIdentifier] -and $SID -is [System.String] -and $SID -match 'S-1-\d{1,2}-\d*') {
		Try {
			# convert string into SID
			$SID = [System.Security.Principal.SecurityIdentifier]($SID)
		}
		Catch {
			# throw error
			Throw $_
		}
	}

	# return the NTAccount
	Try {
		# return value for specific well-known SIDs or translate the SID
		switch ($SID.Value) {
			{ $_ -eq 'S-1-5-32-560' } {
				Return "$([System.Environment]::UserDomainName)\Windows Authorization Access Group"
			}
			Default {
				Return $SID.Translate([System.Security.Principal.NTAccount]).Value
			}
		}
	}
	Catch {
		# throw error
		Throw $_
	}
}

Function ConvertTo-SecurityIdentifier {
	[CmdletBinding()]
	param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[object]$Principal,
		[Parameter(Position = 1)]
		[switch]$Local
	)

	# verify input
	If ($Principal -is [System.Security.Principal.SecurityIdentifier]) {
		$Principal = $Principal.Value
	}
	Else {
		$Principal = [string]$Principal
	}

	# translate principal to SID
	Try {
		# check for specific well-known SIDs or translate the SID
		switch ($Principal) {
			{ ($_ -eq 'Windows Authorization Access Group') -or ($_ -eq "$([System.Environment]::UserDomainName)\Windows Authorization Access Group") } {
				Return [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-560')
			}
			{ $_ -match 'S-1-\d{1,2}-\d*' } {
				Return [System.Security.Principal.SecurityIdentifier]::new($Principal)
			}
			{ $_ -match '^[\w\.-]*\\[\w\.-]*$' } {
				Return ([System.Security.Principal.NTAccount]::new($Principal)).Translate([System.Security.Principal.SecurityIdentifier])
			}
			Default {
				If ($Local) {
					Return ([System.Security.Principal.NTAccount]::new([System.Environment]::MachineName, $Principal).Translate([System.Security.Principal.SecurityIdentifier]))
				}
				Else {
					Return ([System.Security.Principal.NTAccount]::new([System.Environment]::UserDomainName, $Principal).Translate([System.Security.Principal.SecurityIdentifier]))
				}
			}
		}
	}
	Catch {
		# return error
		Return $_
	}
}

Function Get-RandomAlpha {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Position = 0, Mandatory = $True)][ValidateRange(1, 65535)]
		[uint16]$Length,
		[switch]$LowerCase,
		[switch]$UpperCase,
		[switch]$Numbers,
		[switch]$Symbols,
		[switch]$All,
		[char[]]$ExcludeCharacters,
		[string[]]$ExcludeStrings
	)

	# check parameters
	If (-not $LowerCase -and -not $UpperCase -and -not $Numbers -and -not $Symbols) { $All = $true }

	# build list of characters
	$List = [System.Collections.Generic.List[byte]]::new()
	If ($All -or $Numbers) { 
		# 0123456789
		$List.AddRange([byte[]](48..57))
	}
	If ($All -or $UpperCase) {
		# ABCDEFGHIJKLMNOPQRSTUVWXYZ
		$List.AddRange([byte[]](65..90))
	}
	If ($All -or $LowerCase) {
		# abcdefghijklmnopqrstuvwxyz
		$List.AddRange([byte[]](97..122))
	}
	If ($All -or $Symbols) {
		# !"#$%&'()*+,-./
		$List.AddRange([byte[]](33..47))
		# :;<=>?@
		$List.AddRange([byte[]](58..64))
		# [\]^_`
		$List.AddRange([byte[]](91..96))
		# {|}~
		$List.AddRange([byte[]](123..127))
	}

	# remove excluded characters
	ForEach ($Character in $ExcludeCharacters) { $null = $List.Remove([byte]$Character) }

	# clear required objects
	$StringBuilder = [System.Text.StringBuilder]::new()

	# create random string
	While ($StringBuilder.Length -lt $Length) {
		# append random character to string from list
		$null = $StringBuilder.Append([char]($List[(Get-Random -Max $List.Count)]))
		# remove excluded strings
		ForEach ($String in $ExcludeStrings) { $null = $StringBuilder.Replace($String,$null) }
	}

	# return random string
	Return $StringBuilder.ToString()
}

Function Get-RandomHex {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Position = 0, Mandatory = $True)][ValidateRange(1, 65535)]
		[uint16]$Length,
		[Parameter(Position = 1)]
		[switch]$UpperCase
	)

	# clear required objects
	$string = [System.Text.StringBuilder]::new()

	# create random string
	Do { $null = $string.Append('{0:x}' -f (Get-Random -Max 15)) } Until ($string.Length -eq $Length -or $string.Length -eq 65535)

	# return random string
	If ($UpperCase) {
		Return $string.ToString().ToUpperInvariant()
	}
	Else {
		Return $string.ToString()
	}
}

Function Get-StringHash {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[string]$InputObject,
		[Parameter(Position = 1)][ValidateSet('SHA1', 'SHA256', 'SHA384', 'SHA512', 'MACTripleDES', 'MD5', 'RIPEMD160')]
		[string]$Algorithm = 'SHA256'
	)

	# clear required objects
	$hash = $null

	# create hash of string
	$hash = Get-FileHash -InputStream ([IO.MemoryStream]::new([byte[]][char[]]$InputObject)) -Algorithm $Algorithm

	# return hash of string
	Return $hash.Hash
}

# define functions to export
$functions_to_export = @()
$functions_to_export += 'ConvertFrom-SecurityIdentifier'
$functions_to_export += 'ConvertTo-SecurityIdentifier'
$functions_to_export += 'Get-RandomAlpha'
$functions_to_export += 'Get-RandomHex'
$functions_to_export += 'Get-StringHash'

# export module members
Export-ModuleMember -Function $functions_to_export