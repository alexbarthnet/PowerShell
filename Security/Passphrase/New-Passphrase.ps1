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
	# number of words required in passphrase
	[Parameter()][ValidateRange(2, 16)]
	[uint16]$WordCount = 2,
	# minimum length of generated passphrase
	[Parameter()][ValidateRange(16, 256)]
	[uint16]$Length = 15,
	# mode for how delimiters are added to the passphrase
	[Parameter()][ValidateSet('None', 'Simple', 'Numbers', 'NumbersWithDelimiter', 'Random', 'RandomWithNumbers')]
	[string]$DelimiterMode = 'None',
	# type of delimiters to use when random delimiters requested
	[ValidateSet('Simple', 'Complete')]
	[string]$DelimiterType = 'Simple',
	[string]$Delimiter,

	# switch to include numbers in the passphrase
	[switch]$IncludeNumbers,
	# switch to include delimiters in the passphrase
	[switch]$IncludeDelimiters,
	# switch to randomize any delimiters
	[switch]$RandomizeDelimiters,
	# switch to use complex delimiters
	[switch]$UseComplexDelimiters,
	# preset for Direction, SkipExisting, SkipDelete
	[ValidateSet('Default', 'Contribute', 'Mirror', 'Merge')]
	[string]$Preset = 'Default'
)

Function Get-RandomNumber { 
	Param(
		$UpperBound = ([System.int32]::MaxValue)
	)

	# define an empty 32-bit byte array to store the 32-bit number
	$Bytes = [byte[]]::new(4)

	# create a RandomNumberGenerator object
	$RandomNumberGenerator = [System.Security.Cryptography.RandomNumberGenerator]::Create()

	# generate a random integer between 0 and 100
	$RandomNumberGenerator.GetBytes($Bytes)

	# define upper bound for the random number
	$RandomNumber = [BitConverter]::ToUInt32($Bytes, 0) % $UpperBound

	# Print the random number
	Return $RandomNumber
}

Function Resolve-PresetToParameters {
	# resolve Direction
	If (!$script:PSBoundParameters.ContainsKey('Direction')) {
		If ($script:Preset -eq 'Sync' -or $script:Preset -eq 'Merge') {
			$script:Direction = 'Both'
		}
		If ($script:Preset -eq 'Mirror' -or $script:Preset -eq 'Contribute' -or $script:Preset -eq 'Missing') {
			$script:Direction = 'Forward'
		}
	}

	# resolve SkipDelete
	If (!$script:PSBoundParameters.ContainsKey('SkipDelete')) {
		If ($script:Preset -eq 'Merge' -or $script:Preset -eq 'Contribute' -or $script:Preset -eq 'Missing') {
			$script:SkipDelete = $true
		}
		If ($script:Preset -eq 'Sync' -or $script:Preset -eq 'Mirror') {
			$script:SkipDelete = $false
		}
	}

	# resolve SkipExisting
	If (!$script:PSBoundParameters.ContainsKey('SkipExisting')) {
		If ($script:Preset -eq 'Missing') {
			$script:SkipExisting = $true
		}
		If ($script:Preset -eq 'Sync' -or $script:Preset -eq 'Merge' -or $script:Preset -eq 'Mirror' -or $script:Preset -eq 'Contribute') {
			$script:SkipExisting = $false
		}
	}
}

# if path not found...
If (![System.IO.File]::Exists($Path)) {
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

# if delimiter list not provides and complex delimiters requested...
If (!$PSBoundParameters.ContainsKey('DelimiterList') -and $UseComplexDelimiters) {
	# use complex delimiter list
	$DelimiterList = $ComplexDelimiterList
}

# retrieve upper bounds for delimiter and word lists
$DelimiterUpperBound = $DelimiterList.Count - 1
$WordListUpperBound = $WordList.Count - 1

# if static delimiter not provided...
If (!$PSBoundParameters.ContainsKey('Delimiter')) {
	# initialize delimiter randomly
	$Delimiter = $DelimiterList[(Get-RandomNumber -UpperBound $DelimiterUpperBound)]
}

# initialize passphrase and word counter
$Passphrase = [System.String]::Empty
$WordCounter = 0

# while word counter is less than requested word count or passphrase is less than requested length...
While ($WordCounter -lt $WordCount -or $Passphrase.Length -lt $Length) {
	# if not the first word in the passphrase and delimiter mode is not none...
	If ($WordCounter -ne 0 -and $DelimiterMode -ne 'None') {
		# if delimiter mode is random or random with numbers...
		If ($DelimiterMode -in 'RandomWithNumbers', 'Random') {
			# retrieve random delimiter
			$Delimiter = $DelimiterList[(Get-RandomNumber -UpperBound $DelimiterUpperBound)]
		}

		# if delimiter mode is random or random with numbers...
		If ($DelimiterMode -in 'NumbersWithDelimiter', 'RandomWithNumbers', 'Random') {
			# append delimiter to passphrase
			$Passphrase = '{0}{1}' -f $Passphrase, $Delimiter
		}

		# if delimiter mode is random or random with numbers...
		If ($DelimiterMode -in 'RandomWithNumbers', 'NumbersWithDelimiter', 'Numbers') {
			# retrieve random number
			$RandomNumber = Get-RandomNumber -UpperBound 99

			# append random delimiter to passphrase
			$Passphrase = '{0}{1}' -f $Passphrase, $RandomNumber
		}

		# if delimiter mode is random or random with numbers...
		If ($DelimiterMode -in 'RandomWithNumbers') {
			# retrieve random delimiter
			$Delimiter = $DelimiterList[(Get-RandomNumber -UpperBound $DelimiterUpperBound)]
		}

		# if delimiter mode is random or random with numbers...
		If ($DelimiterMode -in 'RandomWithNumbers', 'NumbersWithDelimiter') {
			# append delimiter to passphrase
			$Passphrase = '{0}{1}' -f $Passphrase, $Delimiter
		}
	}

	# retrieve random line from word list
	$RandomLine = $WordList[(Get-RandomNumber -UpperBound $WordListUpperBound)]

	# retrieve word after dice value and tab character then update the case
	$RandomWord = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ToTitleCase($RandomLine.Substring(6))

	# append random word to passphrase
	$Passphrase = '{0}{1}' -f $Passphrase, $RandomWord

	# increment word counter
	$WordCounter++
}

Return $Passphrase
