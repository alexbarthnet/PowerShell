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

Function Get-StringHash {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[string]$InputObject,
		[Parameter(Position = 1)][ValidateSet( {(Get-Command -Name 'Get-FileHash').Parameters['Algorithm'].Attributes.ValidValues} )]
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
$FunctionsToExport = @(
	'ConvertFrom-SecurityIdentifier'
	'ConvertTo-SecurityIdentifier'
	'Get-RandomAlpha'
	'Get-RandomHex'
	'Get-StringHash'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport