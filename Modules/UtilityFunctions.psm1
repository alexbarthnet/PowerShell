Function ConvertFrom-SecurityIdentifier {
	[CmdletBinding()]
	param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[object]$SID
	)

	# verify the input
	If ($SID -isnot [System.Security.Principal.SecurityIdentifier] -and $SID -is [System.String] -and $SID -match 'S-1-\d{1,2}-\d*') {
		$SID = [System.Security.Principal.SecurityIdentifier]($SID)
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
		# return error
		Return $_
	}
}

Function ConvertTo-SecurityIdentifier {
	[CmdletBinding()]
	param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[object]$Principal
	)

	# verify the input
	If ($Principal -isnot [System.String] -and $Principal -is [System.Security.Principal.SecurityIdentifier]) {
		$Principal = $Principal.Value
	}

	# translate principal to SID
	Try {
		# check for specific well-known SIDs or translate the SID
		switch ($Principal) {
			{ ($_ -eq 'Windows Authorization Access Group') -or ($_ -eq "$([System.Environment]::UserDomainName)\Windows Authorization Access Group") } {
				Return [System.Security.Principal.SecurityIdentifier]('S-1-5-32-560')
			}
			{ ($_ -match 'S-1-\d{1,2}-\d*') } {
				Return [System.Security.Principal.SecurityIdentifier]($Principal)
			}
			{ $_ -match '^[\w\.-]*\\[\w\.-]*$' } {
				Return ([System.Security.Principal.NTAccount]($Principal)).Translate([System.Security.Principal.SecurityIdentifier])
			}
			Default {
				Return ([System.Security.Principal.NTAccount]([System.Environment]::UserDomainName, $cms_principal)).Translate([System.Security.Principal.SecurityIdentifier])
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
		[switch]$All
	)

	# check parameters
	If (-not $LowerCase -and -not $UpperCase -and -not $Numbers) { $All = $true }

	# build array
	$array = @()
	If ($All -or $Numbers) { $array += 48..57 }
	If ($All -or $UpperCase) { $array += 65..90 }
	If ($All -or $LowerCase) { $array += 97..122 }

	# clear required objects
	$string = [System.Text.StringBuilder]::new()

	# create random string
	Do { $null = $string.Append([char]($array[(Get-Random -Max $array.Count)])) } Until ($string.Length -eq $Length -or $string.Length -eq 65535)

	# return random string
	Return $string.ToString()
}

Function Get-RandomHex {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Position = 0, Mandatory = $True)][ValidateRange(1, 65535)]
		[uint16]$Length
	)

	# clear required objects
	$string = [System.Text.StringBuilder]::new()

	# create random string
	Do { $null = $string.Append('{0:x}' -f (Get-Random -Max 16)) } Until ($string.Length -eq $Length -or $string.Length -eq 65535)

	# return random string
	Return $string.ToString()
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