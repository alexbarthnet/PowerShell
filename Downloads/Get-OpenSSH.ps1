[CmdletBinding()]
Param (
	[Parameter(Position = 0)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Path = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path,
	[Parameter(Position = 4)]
	[switch]$Install,
	[Parameter(Position = 5)]
	[switch]$InstallService,
	[Parameter(Position = 6)][ValidateSet('Automatic', 'Manual', 'Disabled')]
	[string]$ServiceStartType = 'Disabled',
	[Parameter(Position = 7)]
	[switch]$SkipDownload,
	[Parameter(Position = 8)]
	[switch]$Force,
	[Parameter(DontShow)]
	[string]$Uri = 'https://github.com/PowerShell/Win32-OpenSSH/releases/latest/',
	[Parameter(DontShow)]
	[string]$FileName = 'OpenSSH-Win64.zip',
	[Parameter(DontShow)]
	[string]$FilePath = (Join-Path -Path $Path -ChildPath $FileName),
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

# define parameters for Invoke-WebRequest
$InvokeWebRequest = @{
	Uri                = $Uri
	UseBasicParsing    = $true
	MaximumRedirection = 0
}

# retrieve response from URI
Try {
	$WebRequest = Invoke-WebRequest @InvokeWebRequest
}
Catch {
	Write-Error 'ERROR: could not retrieve response from URI'
	Return
}

# create URI for file from response
$UriForFile = $WebRequest.Headers.Location.Replace('/tag/', '/download/'), '/', $FileName -join $null

# check file
If ((Test-Path -Path $FilePath) -and -not $SkipDownload) {
	# get MD5 hash for local file and remote URI
	$HashFromFile = [System.Convert]::ToBase64String([System.Security.Cryptography.HashAlgorithm]::Create('md5').ComputeHash((Get-Content -Path $FilePath -Raw -Encoding Byte)))
	$HashFromLink = (Invoke-WebRequest -Uri $UriForFile -UseBasicParsing -Method 'Head').Headers.'Content-MD5'
	# compare hashs
	If ($HashFromLink -eq $HashFromFile) {
		Write-Output 'MD5 hash of most recent download matches MD5 hash in headers for URL, skipping!'
		$SkipDownload = $true
	}
}

# download file to destination
If ($Force -or -not $SkipDownload) {
	Try {
		Invoke-WebRequest -Uri $UriForFile -UseBasicParsing -OutFile $FilePath
	}
	Catch {
		Write-Error 'ERROR: could not download the file to the specified location'
		Return
	}
}

# install file
If ($Install -or $InstallService) {
	# check for admin rights
	If (-not ([Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
		Write-Error "ERROR: the 'Install' switch was set but the script cannot continue. The current PowerShell session does not have the Administrator role."
		Return
	}

	# check for existing SSH client sessions
	$processes = $null
	$processes = Get-Process | Where-Object { $_.ProcessName -eq 'ssh' }
	If ($processes) {
		Write-Warning "The 'Install' switch is set but 'ssh.exe' is still running. All 'ssh.exe' processes will be stopped." -WarningAction 'Inquire'
		Try {
			$processes | Stop-Process -Force
		}
		Catch {
			Write-Error "ERROR: could not stop 'ssh.exe' processes"
			Return
		}
	}

	# stop any running instances of OpenSSH
	$service = $null
	$service = Get-Service | Where-Object { $_.Name -eq 'sshd' }
	If ($service) {
		$service_starttype = $service.StartType
		$service_status = $service.Status
		Write-Warning "The 'Install' switch is set but the 'SSHD' service is still running. The 'SSHD' service will be stopped." -WarningAction 'Inquire'
		# stop and disable service
		Try {
			Stop-Service -Name 'sshd' -Force
			Set-Service -Name 'sshd' -StartupType 'Disabled'
		}
		Catch {
			Write-Error "ERROR: could not stop 'sshd' service"
			Return
		}
	}

	# remove any RTM instances of OpenSSH
	Try {
		Get-WindowsCapability -Online -Name 'OpenSSH*' | Remove-WindowsCapability -Online
	}
	Catch {
		Write-Error 'ERROR: could not remove default SSH files'
		Return
	}

	# extract files to Program Files
	Try {
		Expand-Archive -Path $FilePath -DestinationPath ([System.Environment]::GetFolderPath('ProgramFiles')) -Force
	}
	Catch {
		Write-Error 'ERROR: could not extract files to Program Files directory'
		Return
	}

	# run install script
	If ($InstallService -and ($null -eq $service)) {
		# run install script
		. "$([System.Environment]::GetFolderPath('ProgramFiles'))\$($FilePath.BaseName)\install-sshd.ps1"
	}

	# configure service starttype
	If ($service) {
		# restore service start type
		$service | Set-Service -StartupType $service_starttype
		# restart service if previously running
		If ($service_status -eq 'Running') {
			$service | Start-Service
		}
	}
	Else {
		# retrieve service and set service start type
		$service = Get-Service | Where-Object { $_.Name -eq 'sshd' }
		$service | Set-Service -StartupType $ServiceStartType
	}
}
