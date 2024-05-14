[CmdletBinding()]
Param (
	[Parameter(Position = 0)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Path = (Get-Location),
	[Parameter(Position = 1)]
	[string]$FileName = 'ServiceTags_Public.json',
	[Parameter(DontShow)]
	[string]$Uri = 'https://www.microsoft.com/en-us/download/confirmation.aspx?id=56519',
	[Parameter(DontShow)]
	[string]$FilePath = (Join-Path -Path $Path -ChildPath $FileName),
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

# retrieve information on latest release
$UriForBits = (Invoke-WebRequest -Uri $Uri -UseBasicParsing -MaximumRedirection 0).Links.Where({ $_.href -match "\.json$" -and $_.target }) | Sort-Object 'href' -Unique | Select-Object -Last 1 -ExpandProperty 'href'

# check file
If ((Test-Path -Path $FilePath) -and -not $SkipDownload) {
	# get size of local file and remote URI
	$LengthFromFilePath = (Get-ItemProperty -Path $FilePath -ErrorAction 'SilentlyContinue').Length
	$LengthInUriHeaders = (Invoke-WebRequest -Uri $Uri -UseBasicParsing -Method 'Head').Headers.'Content-Length'
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
	Catch{
		Write-Warning -Message "could not download '$UriForBits' to '$FilePath"
		Return $_
	}
}
