[CmdletBinding()]
Param (
	[Parameter(Position = 0)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Destination = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path,
	[Parameter(Position = 1)]
	[switch]$Extract,
	[Parameter(Position = 2)]
	[switch]$ExtractHere,	
	[Parameter(Position = 3)]
	[switch]$SkipDownload,
	[Parameter(Position = 4)]
	[switch]$Force,
	[Parameter(DontShow)]
	[string]$Uri = 'https://download.sysinternals.com/files/SysinternalsSuite.zip',
	[Parameter(DontShow)]
	[string]$FileName = 'SysinternalsSuite.zip',
	[Parameter(DontShow)]
	[string]$FilePath = (Join-Path -Path $Destination -ChildPath $FileName),
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

# check file
If ((Test-Path -Path $FilePath) -and -not $SkipDownload) {
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
If ((Test-Path -Path $FilePath) -and $Extract) {
	If ($ExtractHere) {
		# extract files to the path in the parameter
		$Folder = $Destination
	}
	Else {
		# get path from file
		$FolderPath = (Get-Item -Path $FilePath).DirectoryName
		# extract files to a subfolder of the default Downloads folder
		$Folder = Join-Path -Path $FolderPath -ChildPath (Get-Item -Path $FilePath).BaseName
	}
	# create folder
	If (-not (Test-Path -Path $Folder)) {
		Try {
			$null = New-Item -ItemType 'Directory' -Path $Folder -Force
		}
		Catch {
			Write-Error 'ERROR: could not create folder in destination'
			Return
		}
	}
	# extract files to folder
	Try {
		Expand-Archive -Path $FilePath -DestinationPath $Folder -Force
	}
	Catch {
		Write-Error 'ERROR: could not extract files to the destination'
		Return
	}
}
