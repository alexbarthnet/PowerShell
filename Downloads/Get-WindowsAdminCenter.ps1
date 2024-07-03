[CmdletBinding()]
Param (
	[Parameter(Position = 0)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Path = (Get-Location),
	[Parameter(Position = 1)]
	[switch]$Force,
	[Parameter(Position = 2)]
	[string]$Thumbprint,
	[Parameter(Position = 3)]
	[switch]$Install,
	[Parameter(DontShow)]
	[string]$Uri = 'https://aka.ms/WACDownload'
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
	# expand uri
	Try {
		$UriForBits = Expand-Uri -Uri $Uri
	}
	Catch {
		Throw $_
	}

	# get file from uri
	Try {
		$Headers = Get-HeadersFromUri -Uri $UriForBits
	}
	Catch {
		Throw $_
	}

	# retrieve file name from headers
	$ChildPath = Split-Path -Path $UriForBits -Leaf

	# create local path
	$FilePath = Join-Path -Path $Path -ChildPath $ChildPath

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

	# if not install...
	If (-not $Install) {
		Return
	}

	# get local certificate
	If ($PSBoundParameters['Thumbprint']) {
		If (Test-Path -Path "Cert:\LocalMachine\My\$Thumbprint" -PathType 'Leaf') {
			Try {
				$Certificate = Get-Item -Path "Cert:\LocalMachine\My\$Thumbprint"
			}
			Catch {
				Write-Warning "could not retrieve certificate in local machine store with thumbprint: $Thumbprint"
				Return $_
			}
		}
		Else {
			Write-Warning "could not locate certificate in local machine store with thumbprint: $Thumbprint"
			Return
		}
	}
	Else {
		Try {
			$Certificate = Get-ChildItem -Path 'Cert:\LocalMachine\My' | Where-Object { $_.Subject.StartsWith("CN=$env:computername.", [System.StringComparison]::InvariantCultureIgnoreCase) } | Sort-Object NotBefore | Select-Object -Last 1
		}
		Catch {
			Write-Warning "could not retrieve certificates from local machine store"
			Return $_
		}
	}

	# get log path
	$LogPath = $FilePath.Replace((Get-Item -Path $FilePath).Extension, '.txt')

	# define arguments for Start-Process
	$ArgumentList = "/i $FilePath /qn /L*v $LogPath SME_PORT=443 CHK_REDIRECT_PORT_80=1"

	# if thumbprint found...
	If ($null -eq $Certificate) {
		$ArgumentList = "$ArgumentList SSL_CERTIFICATE_OPTION=generate"
	}
	Else {
		$ArgumentList = "$ArgumentList SSL_CERTIFICATE_OPTION=installed SME_THUMBPRINT=$($Certificate.Thumbprint)"
	}

	# define parameters for Start-Process
	$StartProcess = @{
		Wait         = $true
		FilePath     = 'msiexec.exe'
		ArgumentList = $ArgumentList
	}

	# install / update WAC
	Try {
		Start-Process @StartProcess
	}
	Catch {
		Throw $_
	}

	# start service
	Try {
		Start-Service -Name 'ServerManagementGateway'
	}
	Catch {
		Throw $_
	}
}
