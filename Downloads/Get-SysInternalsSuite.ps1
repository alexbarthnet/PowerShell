[CmdletBinding()]
Param (
	[Parameter(Position = 0)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Path = (Get-Location),
	[Parameter(Position = 1)]
	[switch]$Extract,
	[Parameter(Position = 2)][ValidateScript({ Test-Path -Path $_ })]
	[string]$PathForExtractedFiles,
	[Parameter(Position = 3)]
	[switch]$SkipDownload,
	[Parameter(Position = 4)]
	[switch]$Force,
	[Parameter(DontShow)]
	[string]$Uri = 'https://download.sysinternals.com/files/SysinternalsSuite.zip',
	[Parameter(DontShow)]
	[string]$FileName = 'SysinternalsSuite.zip',
	[Parameter(DontShow)]
	[string]$FilePath = (Join-Path -Path $Path -ChildPath $FileName),
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

# retrieve information
$UriForBits = $Uri

# check file
If ((Test-Path -Path $FilePath) -and -not $SkipDownload) {
	# get size of local file and remote URI
	$LengthFromFilePath = (Get-ItemProperty -Path $FilePath -ErrorAction 'SilentlyContinue').Length
	$LengthInUriHeaders = (Invoke-WebRequest -Uri $UriForBits -UseBasicParsing -Method 'Head').Headers.'Content-Length'
	# compare sizes
	If ($LengthFromFilePath -eq $LengthInUriHeaders) {
		Write-Output 'The local file and remote file have the same size, skipping download'
		$SkipDownload = $true
	}
}

# download file to destination
If ($Force -or -not $SkipDownload) {
	Try {
		Start-BitsTransfer -Source $UriForBits -Destination $FilePath
	}
	Catch {
		Write-Warning -Message "could not download '$UriForBits' to '$FilePath"
		Return $_
	}
}

# expand archive to destination
If ((Test-Path -Path $FilePath) -and $Extract) {
	# if path for extracted files provided...
	If ($PSBoundParameters.ContainsKey('PathForExtractedFiles')) {
		# define destination path
		$DestinationPath = $PathForExtractedFiles
	}
	Else {
		# get basename of file
		$FileName = (Get-Item -Path $FilePath).BaseName

		# create destination path from path and basename of file
		$DestinationPath = Join-Path -Path $Path -ChildPath $FileName

		# if destination path not found...
		If (!(Test-Path -Path $DestinationPath)) {
			# create destination path
			Try {
				$null = New-Item -ItemType 'Directory' -Path $Path -Name $FileName -Force
			}
			Catch {
				Write-Warning -Message "could not create folder: $DestinationPath"
				Return $_
			}
		}
	}

	# extract files to folder
	Try {
		Expand-Archive -Path $FilePath -DestinationPath $DestinationPath -Force
	}
	Catch {
		Write-Warning -Message "could not extract files to folder: $DestinationPath"
		Return $_
	}
}
