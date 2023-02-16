[CmdletBinding()]
Param (
	[Parameter(Position = 0)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Destination = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path,
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
	[string]$FilePath = (Join-Path -Path $Destination -ChildPath $FileName),
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

# retrieve information on latest release
$uri_link = (Invoke-WebRequest -Uri $Uri -UseBasicParsing -MaximumRedirection 0 -ErrorAction SilentlyContinue).Headers.Location.Replace('/tag/', '/download/') + '/' + $FileName

# check file
If ((Test-Path -Path $FilePath) -and -not $SkipDownload) {
	# get MD5 hash for local file and remote URI
	$file_hash = [System.Convert]::ToBase64String([System.Security.Cryptography.HashAlgorithm]::Create('md5').ComputeHash((Get-Content -Path $FilePath -Raw -Encoding Byte)))
	$uri_hash = (Invoke-WebRequest -Uri $uri_link -UseBasicParsing -Method Head).Headers.'Content-MD5'
	# compare hashs
	If ($uri_hash -eq $file_hash) {
		Write-Output 'MD5 hash of most recent download matches MD5 hash in headers for URL, skipping!'
		$SkipDownload = $true
	}
}

# download file to destination
If ($Force -or -not $SkipDownload) {
	Try {
		Invoke-WebRequest -Uri $uri_link -UseBasicParsing -OutFile $FilePath
	}
	Catch{
		Write-Error "ERROR: could not download the file to the specified location"
		Return
	}
}

# install file
If ($Install) {
	# check for admin rights
	If (-not ([Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
		Write-Error "ERROR: the 'Install' switch was set but the script cannot continue. The current PowerShell session does not have the Administrator role."
		Return
	}

	# extract files to temp
	Try {
		# Expand-Archive -Path $FilePath -DestinationPath ([System.Environment]::GetFolderPath('ProgramFiles')) -Force
	}
	Catch {
		Write-Error "ERROR: could not extract files to Program Files directory"
		Return
	}

	# install msix
	Add-AppxPackage -Path $FilePath
}
