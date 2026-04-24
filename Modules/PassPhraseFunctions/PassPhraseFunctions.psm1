function Assert-ParameterValuesForPreset {
	param(
		[Parameter(Mandatory, Position = 0)]
		[hashtable]$ParameterValues
	)

	# retrieve bound parameters for parent scope
	try {
		$BoundParameters = Get-Variable -Scope 1 -Name 'PSBoundParameters' -ValueOnly
	}
	catch {
		Write-Warning -Message "could not retrieve 'PSBoundParameters' from parent scope for '$Preset' preset"
		throw $_
	}

	# loop through parameters for preset
	foreach ($Parameter in $ParameterValues.Keys) {
		# if parameter not explicitly provided...
		if (!$BoundParameters.ContainsKey($Parameter)) {
			# set value of parameter for preset
			try {
				$BoundParameters[$Parameter] = $ParameterValues[$Parameter]
			}
			catch {
				Write-Warning -Message "could not set value of '$Parameter' bound parameter from '$Preset' preset"
				throw $_
			}

			# set value of parameter for preset
			try {
				Set-Variable -Scope 1 -Name $Parameter -Value $ParameterValues[$Parameter]
			}
			catch {
				Write-Warning -Message "could not set value of '$Parameter' script variable from '$Preset' preset"
				throw $_
			}
		}
	}

	# update bound parameters for parent scope
	try {
		Set-Variable -Scope 1 -Name PSBoundParameters -Value $BoundParameters
	}
	catch {
		Write-Warning -Message "could not update 'PSBoundParameters' in parent scope for '$Preset' preset"
		throw $_
	}
}

function Get-RandomNumber {
	param(
		[uint64]$UpperBound = ([System.UInt64]::MaxValue)
	)

	# define an empty 64-bit byte array
	$Bytes = [byte[]]::new(8)

	# create a RandomNumberGenerator object
	$RandomNumberGenerator = [System.Security.Cryptography.RandomNumberGenerator]::Create()

	# populate byte array with random bytes
	$RandomNumberGenerator.GetBytes($Bytes)

	# convert byte array to 64-bit integer
	$RandomInteger = [BitConverter]::ToUInt64($Bytes, 0)

	# define random number as remainder of dividing 64-bit integer by upperbound
	$RandomNumber = $RandomInteger % $UpperBound

	# return random number
	return $RandomNumber
}

function New-PassPhrase {
	[CmdletBinding()]
	param(
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

	# if preset present...
	if ([string]::IsNullOrEmpty($script:Preset)) {
		# define parameter values for all presets
		$ParameterValuesForPreset = @{
			WithNumbers                     = @{
				IncludeNumbers = [System.Management.Automation.SwitchParameter]::new($true)
			}
			WithNumbersAndDelimiter         = @{
				IncludeNumbers    = [System.Management.Automation.SwitchParameter]::new($true)
				IncludeDelimiters = [System.Management.Automation.SwitchParameter]::new($true)
			}
			WithNumbersWithRandomDelimiters = @{
				IncludeNumbers      = [System.Management.Automation.SwitchParameter]::new($true)
				IncludeDelimiters   = [System.Management.Automation.SwitchParameter]::new($true)
				RandomizeDelimiters = [System.Management.Automation.SwitchParameter]::new($true)
			}
			WithRandomDelimiters            = @{
				IncludeDelimiters   = [System.Management.Automation.SwitchParameter]::new($true)
				RandomizeDelimiters = [System.Management.Automation.SwitchParameter]::new($true)
			}
		}

		# assert parameter values for specific preset
		try {
			Assert-ParameterValuesForPreset -ParameterValues $ParameterValuesForPreset[$Preset]
		}
		catch {
			throw $_
		}
	}

	# if path found...
	if ([System.IO.File]::Exists($Path) -and -not $script:Offline) {
		# retrive file length
		try {
			$FileInfo = [System.IO.FileInfo]::new($Path)
		}
		catch {
			Write-Warning "could not retrieve length of existing EFF wordlist : $($_.Exception.Message)"
			return $_
		}

		# retrieve headers from URI
		try {
			$WebRequest = Invoke-WebRequest -UseBasicParsing -Uri $Uri -Method Head -ErrorAction 'Stop'
		}
		catch {
			Write-Warning "could not download EFF wordlist: $($_.Exception.Message)"
			return $_
		}

		# if headers length does not match file length...
		if ($WebRequest.Headers.'Content-Length' -ne $FileInfo.Length) {
			# report length mismatch
			Write-Warning -Message 'found size of local EFF wordlist does not match size of online EFF wordlist; removing local file'

			# remove local file
			try {
				Remove-Item -Path $Path -Force
			}
			catch {
				Write-Warning "could not download EFF wordlist: $($_.Exception.Message)"
				return $_
			}
		}
	}

	# if path not found...
	if (![System.IO.File]::Exists($Path)) {
		# if offline...
		if ($script:Offline) {
			Write-Warning -Message "could not locate EFF wordlist at '$Path' path and running in Offline mode; exiting"
			return
		}

		# download word list file
		try {
			Start-BitsTransfer -Source $Uri -Destination $Path
		}
		catch {
			Write-Warning "could not download EFF wordlist: $($_.Exception.Message)"
			return $_
		}
	}

	# retrieve lines from word list file
	try {
		$WordList = Get-Content -Path $Path
	}
	catch {
		Write-Warning "could not read EFF wordlist file: $($_.Exception.Message)"
		return $_
	}

	# if delimiter list not provided and complex delimiters requested...
	if (!$PSBoundParameters.ContainsKey('DelimiterList') -and $UseComplexDelimiters) {
		# use complex delimiter list
		$DelimiterList = $ComplexDelimiterList
	}

	# define upper bounds for random numbers
	$NumberUpperBound = [System.Math]::Pow(10, $NumberLength)

	# if static delimiter not provided...
	if (!$PSBoundParameters.ContainsKey('Delimiter')) {
		# initialize random delimiter
		$Delimiter = $DelimiterList[(Get-RandomNumber -UpperBound $DelimiterList.Count)]
	}

	# initialize passphrase and word counter
	$Passphrase = [System.String]::Empty
	$WordCounter = 0

	# while word counter is less than requested word count or passphrase is less than requested length...
	while ($WordCounter -lt $WordCount -or $Passphrase.Length -lt $Length) {
		# if not the first word in the passphrase....
		if ($WordCounter -ne 0) {
			# if include delimiters requested...
			if ($IncludeDelimiters) {
				# if random delimiters requested...
				if ($RandomizeDelimiters) {
					# define empty delimiter string
					$Delimiter = [System.String]::Empty

					# while delimiter string is less than requested delimiter length...
					while ($Delimiter.Length -lt $DelimiterLength) {
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
			if ($IncludeNumbers) {
				# retrieve random number with upper bound
				$RandomNumber = Get-RandomNumber -UpperBound $NumberUpperBound

				# convert random number to string and pad to requested length
				$NumberString = $RandomNumber.ToString().PadLeft($NumberLength, '0')

				# append trimmed number to passphrase
				$Passphrase = '{0}{1}' -f $Passphrase, $NumberString

				# if include delimiters requested...
				if ($IncludeDelimiters) {
					# if random delimiters requested...
					if ($RandomizeDelimiters) {
						# define empty delimiter string
						$Delimiter = [System.String]::Empty

						# while delimiter string is less than requested delimiter length...
						while ($Delimiter.Length -lt $DelimiterLength) {
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
		if ($RandomizeCase) {
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

	return $Passphrase
}

# define functions to export
$FunctionsToExport = @(
	'New-PassPhrase'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport