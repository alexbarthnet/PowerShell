[CmdletBinding()]
Param (
	[Parameter(Position = 0)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Path = (Get-Location),
	[Parameter(Position = 1)]
	[switch]$Extract,
	[Parameter(Position = 2)]
	[switch]$SkipDownload,
	[Parameter(Position = 3)]
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

# extract files to destination
If ((Test-Path -Path $FilePath) -and $Extract) {
	# get basename of file
	$ChildPath = (Get-Item -Path $FilePath).BaseName

	# define folder using path and basename of file
	$Folder = Join-Path -Path $Path -ChildPath $ChildPath

	# create folder
	If (-not (Test-Path -Path $Folder)) {
		Try {
			$null = New-Item -ItemType 'Directory' -Path $Folder -Force
		}
		Catch {
			Write-Warning -Message "could not create folder: $Folder"
			Return $_
		}
	}
	# extract files to folder
	Try {
		Expand-Archive -Path $FilePath -DestinationPath $Folder -Force
	}
	Catch {
		Write-Warning -Message "could not extract files to the folder: $Folder"
		Return $_
	}
}
