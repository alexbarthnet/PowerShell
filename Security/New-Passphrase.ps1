Param(
	# folder path for word list file
	[Parameter(DontShow)]
	$FolderPath = [System.Environment]::GetFolderPath('CommonApplicationData'),
	# file path for word list file
	[Parameter(DontShow)]
	$FilePath = 'eff_large_wordlist.txt',
	# path for word list file
	[Parameter(DontShow)]
	$Path = (Join-Path -Path $FolderPath -ChildPath $FilePath),
	# URI for word list file
	[Parameter(DontShow)]
	$Uri = 'https://www.eff.org/files/2016/07/18/eff_large_wordlist.txt',
	# array of complex delimiters
	[Parameter(DontShow)]
	$ComplexDelimiterList = ('!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '-', '_', '=', '+', '[', '{', ']', '}', '\', ';', ':', '/', '?', ',', '.'),
	# array of simple delimiters
	[Parameter(DontShow)]
	$DelimiterList = ('-', '_', '=', '+', ';', ':', ',', '.'),
	# array of permitted cases
	[Parameter(DontShow)]
	$CaseList = ('Lower', 'Title', 'Upper'),
	# number of words required in passphrase
	[Parameter()][ValidateRange(2, 16)]
	[uint16]$WordCount = 4,
	# minimum length of generated passphrase
	[Parameter()][ValidateRange(16, 256)]
	[uint16]$Length = 25,
	# length of number strings added to passphrase
	[Parameter()][ValidateRange(1, 8)]
	[uint16]$NumberLength = 2,
	# length of delimiter strings added to passphrase
	[Parameter()][ValidateRange(1, 8)]
	[uint16]$DelimiterLength = 1,
	# string to define delimiter
	[string]$Delimiter,
	# switch to include numbers in the passphrase
	[switch]$IncludeNumbers,
	# switch to include delimiters in the passphrase
	[switch]$IncludeDelimiters,
	# switch to randomize delimiters
	[switch]$RandomizeDelimiters,
	# switch to use complex delimiters
	[switch]$UseComplexDelimiters,
	# switch to randomize case of words
	[switch]$RandomizeCase,
	# preset for Direction, SkipExisting, SkipDelete
	[ValidateSet('Words', 'WithNumbers', 'WithNumbersAndDelimiter', 'WithNumbersWithRandomDelimiters', 'WithRandomDelimiters')]
	[string]$Preset = 'WithNumbersAndDelimiter',
	# switch to skip checking size of local word list file against online word list
	[switch]$Offline
)

Function Get-RandomNumber {
	Param(
		$UpperBound = ([System.UInt64]::MaxValue)
	)

	# define an empty 64-bit byte array
	$Bytes = [byte[]]::new(8)

	# create a RandomNumberGenerator object
	$RandomNumberGenerator = [System.Security.Cryptography.RandomNumberGenerator]::Create()

	# populate byte array with random bytes
	$RandomNumberGenerator.GetBytes($Bytes)

	# convert byte array to 64-bit integer
	$RandomNumber = [BitConverter]::ToUInt64($Bytes, 0) % $UpperBound

	# Print the random number
	Return $RandomNumber
}

Function Resolve-PresetToParameters {
	# resolve IncludeNumbers
	If (!$script:PSBoundParameters.ContainsKey('IncludeNumbers')) {
		If ($script:Preset -in 'WithNumbers', 'WithNumbersAndDelimiter', 'WithNumbersWithRandomDelimiters') {
			$script:IncludeNumbers = $true
		}
		Else {
			$script:IncludeNumbers = $false
		}
	}

	# resolve IncludeDelimiters
	If (!$script:PSBoundParameters.ContainsKey('IncludeDelimiters')) {
		If ($script:Preset -in 'WithNumbersAndDelimiter', 'WithNumbersWithRandomDelimiters', 'WithRandomDelimiters') {
			$script:IncludeDelimiters = $true
		}
		Else {
			$script:IncludeDelimiters = $false
		}
	}

	# resolve RandomizeDelimiters
	If (!$script:PSBoundParameters.ContainsKey('RandomizeDelimiters')) {
		If ($script:Preset -in 'WithNumbersWithRandomDelimiters', 'WithRandomDelimiters') {
			$script:RandomizeDelimiters = $true
		}
		Else {
			$script:RandomizeDelimiters = $false
		}
	}
}

# resolve preset to parameters
Try {
	Resolve-PresetToParameters
}
Catch {
	Write-Warning -Message "could not resolve '$Preset' preset to parameters: $($_.Exception.Message)"
	Throw $_
}

# if path found...
If ([System.IO.File]::Exists($Path) -and -not $script:Offline) {
	# retrive file length
	Try {
		$FileInfo = [System.IO.FileInfo]::new($Path)
	}
	Catch {
		Write-Warning "could not retrieve length of existing EFF wordlist : $($_.Exception.Message)"
		Return $_
	}

	# retrieve headers from URI
	Try {
		$WebRequest = Invoke-WebRequest -Uri $Uri -Method Head -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning "could not download EFF wordlist: $($_.Exception.Message)"
		Return $_
	}

	# if headers length does not match file length...
	If ($WebRequest.Headers.'Content-Length' -ne $FileInfo.Length) {
		# report length mismatch
		Write-Warning -Message "found size of local EFF wordlist does not match size of online EFF wordlist; removing local file"

		# remove local file
		Try {
			Remove-Item -Path $Path -Force
		}
		Catch {
			Write-Warning "could not download EFF wordlist: $($_.Exception.Message)"
			Return $_
		}
	}
}

# if path not found...
If (![System.IO.File]::Exists($Path)) {
	# if offline...
	If ($script:Offline) {
		Write-Warning -Message "could not locate EFF wordlist at '$Path' path and running in Offline mode; exiting"
		Return
	}

	# download word list file
	Try {
		Start-BitsTransfer -Source $Uri -Destination $Path
	}
	Catch {
		Write-Warning "could not download EFF wordlist: $($_.Exception.Message)"
		Return $_
	}
}

# retrieve lines from word list file
Try {
	$WordList = Get-Content -Path $Path
}
Catch {
	Write-Warning "could not read EFF wordlist file: $($_.Exception.Message)"
	Return $_
}

# if delimiter list not provided and complex delimiters requested...
If (!$PSBoundParameters.ContainsKey('DelimiterList') -and $UseComplexDelimiters) {
	# use complex delimiter list
	$DelimiterList = $ComplexDelimiterList
}

# define upper bounds for random numbers
$NumberUpperBound = [System.Math]::Pow(10, $NumberLength)

# if static delimiter not provided...
If (!$PSBoundParameters.ContainsKey('Delimiter')) {
	# initialize random delimiter
	$Delimiter = $DelimiterList[(Get-RandomNumber -UpperBound $DelimiterList.Count)]
}

# initialize passphrase and word counter
$Passphrase = [System.String]::Empty
$WordCounter = 0

# while word counter is less than requested word count or passphrase is less than requested length...
While ($WordCounter -lt $WordCount -or $Passphrase.Length -lt $Length) {
	# if not the first word in the passphrase....
	If ($WordCounter -ne 0) {
		# if include delimiters requested...
		If ($IncludeDelimiters) {
			# if random delimiters requested...
			If ($RandomizeDelimiters) {
				# define empty delimiter string
				$Delimiter = [System.String]::Empty

				# while delimiter string is less than requested delimiter length...
				While ($Delimiter.Length -lt $DelimiterLength) {
					# retrieve random delimiter
					$RandomDelimiter = $DelimiterList[(Get-RandomNumber -UpperBound $DelimiterList.Count)]

					# append random delimiter to delimiter string
					$Delimiter = '{0}{1}' -f $Delimiter, $RandomDelimiter
				}
			}

			# append delimiter to passphrase
			$Passphrase = '{0}{1}' -f $Passphrase, $Delimiter
		}

		# if include numbers requested...
		If ($IncludeNumbers) {
			# retrieve random number with upper bound
			$RandomNumber = Get-RandomNumber -UpperBound $NumberUpperBound

			# convert random number to string and pad to requested length
			$NumberString = $RandomNumber.ToString().PadLeft($NumberLength, '0')

			# append trimmed number to passphrase
			$Passphrase = '{0}{1}' -f $Passphrase, $NumberString

			# if include delimiters requested...
			If ($IncludeDelimiters) {
				# if random delimiters requested...
				If ($RandomizeDelimiters) {
					# define empty delimiter string
					$Delimiter = [System.String]::Empty

					# while delimiter string is less than requested delimiter length...
					While ($Delimiter.Length -lt $DelimiterLength) {
						# retrieve random delimiter
						$RandomDelimiter = $DelimiterList[(Get-RandomNumber -UpperBound $DelimiterList.Count)]

						# append random delimiter to delimiter string
						$Delimiter = '{0}{1}' -f $Delimiter, $RandomDelimiter
					}
				}

				# append delimiter to passphrase
				$Passphrase = '{0}{1}' -f $Passphrase, $Delimiter
			}
		}
	}

	# retrieve random line from word list
	$RandomLine = $WordList[(Get-RandomNumber -UpperBound $WordList.Count)]

	# retrieve word after dice value and tab character then update to title case
	$RandomWord = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ToTitleCase($RandomLine.Substring(6))

	# if random case requested...
	If ($RandomizeCase) {
		# retrieve random case
		$RandomCase = $CaseList[(Get-RandomNumber -UpperBound $CaseList.Count)]

		# update word to random case
		switch ($RandomCase) {
			'Lower' {
				$RandomWord = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ToLower($RandomWord)
			}
			'Upper' {
				$RandomWord = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ToUpper($RandomWord)
			}
			Default {
				# no change required for TitleCase as word is already in title case
			}
		}
	}

	# append random word to passphrase
	$Passphrase = '{0}{1}' -f $Passphrase, $RandomWord

	# increment word counter
	$WordCounter++
}

Return $Passphrase
