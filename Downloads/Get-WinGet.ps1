[CmdletBinding()]
Param (
	[Parameter(Position = 0)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Path = (Get-Location),
	[Parameter(Position = 1)]
	[switch]$Install,
	[Parameter(Position = 2)]
	[switch]$SkipDownload,
	[Parameter(Position = 3)]
	[switch]$Force,
	[Parameter(DontShow)]
	[string]$Uri = 'https://github.com/microsoft/winget-cli/releases/latest/',
	[Parameter(DontShow)]
	[string]$FileName = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle',
	[Parameter(DontShow)]
	[string]$FilePath = (Join-Path -Path $Path -ChildPath $FileName),
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

# retrieve information on latest release
$UriForBits = (Invoke-WebRequest -Uri $Uri -UseBasicParsing -MaximumRedirection 0 -ErrorAction SilentlyContinue).Headers.Location.Replace('/tag/', '/download/') + '/' + $FileName

# check file
If ((Test-Path -Path $FilePath) -and -not $SkipDownload) {
	# get MD5 hash for local file and remote URI
	$HashFromFilePath = [System.Convert]::ToBase64String([System.Security.Cryptography.HashAlgorithm]::Create('md5').ComputeHash((Get-Content -Path $FilePath -Raw -Encoding Byte)))
	$HashInUriHeaders = (Invoke-WebRequest -Uri $UriForBits -UseBasicParsing -Method 'Head').Headers.'Content-MD5'
	# compare hashs
	If ($HashFromFilePath -eq $HashInUriHeaders) {
		Write-Output 'MD5 hash of most recent download matches MD5 hash in headers for URL, skipping!'
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

# install file
If ((Test-Path -Path $FilePath) -and $Install) {
	# check for admin rights
	If (!([Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
		Write-Warning -Message 'cannot install: the current PowerShell session does not have the Administrator role.'
		Return
	}

	# install msix
	Try {
		Add-AppxPackage -Path $FilePath
	}
	Catch {
		Write-Warning -Message 'could not install WinGet'
		Return $_
	}
}
