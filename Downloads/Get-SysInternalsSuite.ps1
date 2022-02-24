[CmdletBinding()]
Param (
	[Parameter(Position = 0)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Destination = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path,
	[Parameter(Position = 1)]
	[string]$FileName = 'SysinternalsSuite.zip',
	[Parameter(Position = 2)]
	[string]$FilePath = (Join-Path -Path $Destination -ChildPath $FileName),
	[Parameter(Position = 3)]
	[string]$Uri = 'https://download.sysinternals.com/files/SysinternalsSuite.zip',
	[Parameter(Position = 4)]
	[switch]$Extract,
	[Parameter(Position = 5)]
	[switch]$SkipDownload,
	[Parameter(Position = 6)]
	[switch]$Force
)

# check file
If (Test-Path $FilePath -and -not $SkipDownload) {
	# get size of local file and remote URI
	$file_size = (Get-ItemProperty -Path $FilePath -ErrorAction 'SilentlyContinue').Length
	$uri_size = (Invoke-WebRequest -Uri $Uri -UseBasicParsing -Method 'Head').Headers.'Content-Length'
	# compare sizes
	If ($uri_size -eq $file_size) {
		Write-Output 'The local file and remote file have the same size, skipping download'
		$SkipDownload = $true
	}
}

# download file to destination
If ($Force -or -not $SkipDownload) {
	# download latest release to destination
	Try {
		Invoke-WebRequest -Uri $Uri -UseBasicParsing -OutFile $FilePath
	}
	Catch {
		Write-Error 'ERROR: could not download the file to the specified location'
		Return
	}
}

# extract files to destination
If ($Extract) {
	Try {
		Expand-Archive -Path $FilePath -DestinationPath $Destination -Force
	}
	Catch {
		Write-Error 'ERROR: could not extract files to the destination'
		Return
	}
}
