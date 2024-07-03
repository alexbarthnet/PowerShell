[CmdletBinding()]
Param (
	[Parameter(Position = 0)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Path = (Get-Location),
	[Parameter(Position = 4)]
	[switch]$Install,
	[Parameter(Position = 5)]
	[switch]$InstallService,
	[Parameter(Position = 6)][ValidateSet('Automatic', 'Manual', 'Disabled')]
	[string]$StartType,
	[Parameter(Position = 7)]
	[switch]$SkipDownload,
	[Parameter(Position = 8)]
	[switch]$Force,
	[Parameter(DontShow)]
	[string]$ProgramFiles = [System.Environment]::GetFolderPath('ProgramFiles'),
	[Parameter(DontShow)]
	[string]$Uri = 'https://github.com/PowerShell/Win32-OpenSSH/releases/latest/',
	[Parameter(DontShow)]
	[string]$FileName = 'OpenSSH-Win64.zip'
)

Begin {
	Function Expand-Uri {
		[CmdletBinding()]
		Param (
			[string]$Uri
		)

		# define parameters for Invoke-WebRequest
		$InvokeWebRequest = @{
			Uri                = $Uri
			Method             = 'Head'
			UseBasicParsing    = $true
			MaximumRedirection = 0
			ErrorAction        = [System.Management.Automation.ActionPreference]::SilentlyContinue
		}

		# get web request object
		$WebRequest = Invoke-WebRequest @InvokeWebRequest

		# check object
		If ($WebRequest -isnot [Microsoft.PowerShell.Commands.WebResponseObject]) {
			Throw $_
		}

		# if status is redirected and location found...
		If ($WebRequest.StatusCode -in '301', '302' -and -not [string]::IsNullOrEmpty($WebRequest.Headers.Location)) {
			# ...expand location
			Expand-Uri -Uri $WebRequest.Headers.Location
		}
		Else {
			Return $Uri
		}
	}

	Function Get-HeadersFromUri {
		[CmdletBinding()]
		Param (
			[string]$Uri
		)

		# define parameters for Invoke-WebRequest
		$InvokeWebRequest = @{
			Uri                = $Uri
			Method             = 'Head'
			UseBasicParsing    = $true
			MaximumRedirection = 0
			ErrorAction        = [System.Management.Automation.ActionPreference]::Stop
		}

		# retrieve response from URI
		Try {
			$WebRequest = Invoke-WebRequest @InvokeWebRequest
		}
		Catch {
			Throw $_
		}

		# return headers
		Return $WebRequest.Headers
	}

	Function Get-FileByteHash {
		Param (
			[Parameter(Mandatory = $true)]
			[string]$Path,
			[ValidateSet('MD5', 'SHA1', 'SHA256')]
			[string]$Algorithm = 'SHA256'
		)

		# get file content as bytes
		Try {
			$Bytes = Get-Content -Path $Path -Raw -Encoding Byte
		}
		Catch {
			Throw $_
		}

		# create hash object
		Try {
			switch ($Algorithm) {
				'MD5' {
					$HashAlgorithm = [System.Security.Cryptography.MD5]::Create()
				}
				'SHA1' {
					$HashAlgorithm = [System.Security.Cryptography.SHA1]::Create()
				}
				'SHA256' {
					$HashAlgorithm = [System.Security.Cryptography.SHA256]::Create()
				}
			}
		}
		Catch {
			Throw $_
		}

		# get hash of bytes
		Try {
			$Hash = $HashAlgorithm.ComputeHash($Bytes)
		}
		Catch {
			Throw $_
		}

		# convert hash to base64
		Try {
			$String = [System.Convert]::ToBase64String($Hash)
		}
		Catch {
			Throw $_
		}

		# return string
		Return $String
	}
}

Process {
	# retrieve URI with version number
	Try {
		$UriWithVersion = Expand-Uri -Uri $Uri
	}
	Catch {
		Throw $_
	}

	# update URI with file name
	$UriWithFileName = $UriWithVersion.Replace('/tag', '/download'), $FileName -join '/'

	# retrieve URI for actual file
	Try {
		$UriForBits = Expand-Uri -Uri $UriWithFileName
	}
	Catch {
		Throw $_
	}

	# retrieve headers of URI for actual file
	Try {
		$Headers = Get-HeadersFromUri -Uri $UriForBits
	}
	Catch {
		Throw $_
	}

	# create local path
	$FilePath = Join-Path -Path $Path -ChildPath $FileName

	# if file exists...
	If (Test-Path -Path $FilePath -PathType 'Leaf') {
		# if force set...
		If ($Force) {
			Write-Warning -Message 'Overwriting existing file: Force parameter was set and the '$FileName' file was found in '$Path' path'
		}
		# if remote hash is available...
		ElseIf ($Headers.ContainsKeys('Content-MD5')) {
			# get local hash
			Try {
				$FileByteHash = Get-FileByteHash -Path $FilePath -Algorithm 'MD5'
			}
			Catch {
				Throw $_
			}
			# if local hash matches remote hash...
			If ($FileByteHash -eq $Headers['Content-MD5']) {
				Write-Host 'Skipping file download: existing file hash matches value in Content-MD5 header'
				$SkipDownload = $true
			}
		}
		# if remote length is available...
		ElseIf ($Headers.ContainsKeys('Content-Length')) {
			# get local length
			Try {
				$SizeBytes = Get-Item -Path $FilePath | Select-Object -ExpandProperty 'SizeBytes'
			}
			Catch {
				Throw $_
			}
			# if local length matches remote length...
			If ($SizeBytes -eq $Headers['Content-Length']) {
				Write-Host 'Skipping file download: existing file size matches value in Content-Length header'
				$SkipDownload = $true
			}
		}
	}
	ElseIf ($SkipDownload) {
		Write-Warning -Message "Exiting with no changes: SkipDownload set to true and the '$FileName' file was not found in '$Path' path"
		Return
	}

	# if force or skipdownload was not set...
	If ($Force -or -not $SkipDownload) {
		# ...download the file
		Try {
			Start-BitsTransfer -Source $UriForBits -Destination $FilePath
		}
		Catch {
			Write-Warning -Message "could not download '$UriForBits' to '$FilePath"
			Return $_
		}
	}

	# if install and install service not set...
	If (!$Install -and !$InstallService) {
		Return
	}

	# check for admin rights
	If (!([Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
		Write-Warning -Message 'cannot install: the current PowerShell session does not have the Administrator role.'
		Return
	}

	# retrieve existing SSH client sessions
	$Processes = Get-Process | Where-Object { $_.ProcessName -eq 'ssh' }

	# if SSH client sessions found...
	If ($script:Processes) {
		Write-Warning "The 'Install' switch is set but 'ssh.exe' is running. All 'ssh.exe' processes will be stopped." -WarningAction 'Inquire'
		ForEach ($Process in $script:Processes) {
			Try {
				$Process | Stop-Process -Force
			}
			Catch {
				Write-Warning -Message "could not stop 'ssh.exe' process with process id: $($Process.ID)"
				Return $_
			}
		}
	}

	# check for existing SSHD service
	$Service = Get-Service | Where-Object { $_.Name -eq 'sshd' }

	# if SSHD service exists...
	If ($script:Service) {
		# retrieve SSHD service start type and status
		$StartType = $Service.StartType
		$Status = $Service.Status
		# if SSHD service is running...
		If ($Status -eq 'Running') {
			Write-Warning "The 'Install' switch is set but the 'SSHD' service is still running. The 'SSHD' service will be stopped." -WarningAction 'Inquire'
			# stop service
			Try {
				$Service | Stop-Service -Force
			}
			Catch {
				Write-Warning -Message "could not stop 'sshd' service"
				Return $_
			}
			# disable service
			Try {
				$Service | Set-Service -StartupType 'Disabled'
			}
			Catch {
				Write-Warning -Message "could not disable 'sshd' service"
				Return $_
			}
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
		Expand-Archive -Path $FilePath -DestinationPath $ProgramFiles -Force
	}
	Catch {
		Write-Error 'ERROR: could not extract files to Program Files directory'
		Return
	}

	# define path to extracted file
	$PathInProgramFiles = Join-Path -Path $ProgramFiles -ChildPath (Get-Item -Path $FilePath).BaseName

	# if install service set...
	If ($InstallService) {
		If ($script:Service) {
			Write-Warning -Message "The 'InstallService' switch is set but an existing instance of 'sshd' was found. Existing settings may be overwritten." -WarningAction 'Inquire'
		}
		# run install script
		Try {
			. "$PathInProgramFiles\install-sshd.ps1"
		}
		Catch {
			Write-Warning -Message 'could not run the SSHD install script'
		}
	}

	# check for existing SSHD service
	$Service = Get-Service | Where-Object { $_.Name -eq 'sshd' }

	# if SSHD service exists...
	If ($script:Service) {
		# set SSHD service start type
		Try {
			$Service | Set-Service -StartupType $StartType
		}
		Catch {
			Write-Warning -Message "could not set 'sshd' service start type: $StartType"
			Return $_
		}
		# if SSHD service was running or newly installed with an automatic start type...
		If ($Status -eq 'Running' -or ($null -eq $Status -and $StartupType -eq 'Automatic')) {
			Try {
				$Service | Start-Service
			}
			Catch {
				Write-Warning -Message "could not start 'sshd' service after install"
				Return $_
			}
		}
	}
}
