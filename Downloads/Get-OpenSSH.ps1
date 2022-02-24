[CmdletBinding()]
Param (
	[Parameter(Position = 0)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Destination = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path,
	[Parameter(Position = 1)]
	[string]$FileName = 'OpenSSH-Win64.zip',
	[Parameter(Position = 2)]
	[switch]$Install,
	[Parameter(Position = 3)]
	[switch]$InstallService,
	[Parameter(Position = 4)][ValidateSet('Automatic', 'Manual', 'Disabled')]
	[string]$StartType = 'Disabled',
	[Parameter(Position = 4)]
	[switch]$Force
)

# define local objects
$file_down = $true
$file_path = Join-Path -Path $Destination -ChildPath $file_name

# retrieve information on latest release
$uri_path = 'https://github.com/PowerShell/Win32-OpenSSH/releases/latest/'
$uri_link = (Invoke-WebRequest -Uri $uri_path -UseBasicParsing -MaximumRedirection 0 -ErrorAction SilentlyContinue).Headers.Location.Replace('/tag/', '/download/') + '/' + $file_name

# check file
If (Test-Path $file_path) {
	$uri_size = (Invoke-WebRequest -Uri $uri_file -UseBasicParsing -Method Head).Headers.'Content-Length'
	If ($uri_size -eq (Get-ItemProperty $file_path).Length -and -not $Force) {
		Write-Output 'Size of most recent download matches current download size, skipping!'
		$file_down = $false
	}
}

# download file
If ($file_down) {
	# download latest release to destination
	Invoke-WebRequest -Uri $uri_link -UseBasicParsing -OutFile $file_path
}

# install file
If ($Install) {
	# check for admin rights
	If (-not ([Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
		Write-Error "ERROR: the 'Install' switch was set but the script cannot continue. The current PowerShell session does not have the Administrator role." -ErrorAction SilentlyContinue
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
		Write-Error "ERROR: could not remove default SSH files"
		Return
	}

	# extract files
	Try {
		Expand-Archive -Path $file_path -DestinationPath ([System.Environment]::GetFolderPath('ProgramFiles')) -Force
	}
	Catch {
		Write-Error "ERROR: could not extract files to Program Files directory"
		Return
	}

	# run install script
	If ($InstallService) {
		# run install script
		. "$([System.Environment]::GetFolderPath('ProgramFiles'))\$($file_path.BaseName)\install-sshd.ps1"
		# configure the service
		$service = Get-Service | Where-Object { $_.Name -eq 'sshd' }
	}

	# restore service starttype
	If ($service) {
		$service | Set-Service -StartupType $service_starttype
		# restart service if previously running
		If ($service_status -eq 'Running') {
			$service | Start-Service
		}
	}
}
