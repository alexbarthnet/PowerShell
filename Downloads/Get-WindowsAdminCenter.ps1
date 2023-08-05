[CmdletBinding()]
Param (
	[Parameter(Position = 0)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Path = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path,
	[Parameter(Position = 1)]
	[switch]$Force,
	[Parameter(Position = 2)]
	[string]$Thumbprint,
	[Parameter(Position = 3)]
	[switch]$Install,
	[Parameter(DontShow)]
	[string]$Uri = 'https://aka.ms/WACDownload',
	[Parameter(DontShow)]
	[string]$FileName = 'MicrosoftEdgeEnterpriseX64.msi'
)

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

# expand uri
Try {
	$Uri = Expand-Uri -Uri $Uri
}
Catch {
	Throw $_
}

# get file from uri
Try {
	$Headers = Get-HeadersFromUri -Uri $Uri
}
Catch {
	Throw $_
}

# retrieve file name from headers
$ChildPath = Split-Path -Path $Uri -Leaf

# create local path
$FilePath = Join-Path -Path $Path -ChildPath $ChildPath

# if file exists...
If ((Test-Path -Path $FilePath -PathType Leaf) -and -not $Force) {
	# if remote hash is available...
	If (-not [string]::IsNullOrEmpty($Headers['Content-MD5'])) {
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
	ElseIf (-not [string]::IsNullOrEmpty($Headers['Content-Length'])) {
		# get local length
		Try {
			$SizeBytes = Get-Item -Path $FilePath | Select-Object -ExpandProperty SizeBytes
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

# if force or skipdownload was not set...
If ($Force -or -not $SkipDownload) {
	# ...download the file
	Try {
		Start-BitsTransfer -Source $Uri -Destination $FilePath
	}
	Catch {
		Write-Error 'ERROR: could not download file'
		Throw $_
	}
}

# if not install...
If (-not $Install) {
	Return
}

# get local certificate
If ($PSBoundParameters['Thumbprint']) {
	If (-not (Test-Path -Path "Cert:\LocalMachine\My\$Thumbprint" -PathType Leaf)) {
		Write-Host 'ERROR: provided thumbprint not found in local machine certificate store'
		Return
	}
}
Else {
	$Certificate = Get-ChildItem -Path 'Cert:\LocalMachine\My' | Where-Object { $_.Subject.StartsWith("CN=$env:computername.", [System.StringComparison]::InvariantCultureIgnoreCase) } | Sort-Object NotBefore | Select-Object -Last 1
	If ($null -eq $Certificate) {
		Write-Host 'ERROR: no certificate found with subject matching computer name'
		Return
	}
	Else {
		$Thumbprint = $Certificate.Thumbprint
	}
}

# get log path
$LogPath = $FilePath.Replace((Get-Item -Path $FilePath).Extension, '.txt')

$StartProcess = @{
	Wait         = $true
	FilePath     = 'msiexec.exe'
	ArgumentList = "/i $FilePath /qn /L*v $LogPath SME_PORT=443 SME_THUMBPRINT=$Thumbprint SSL_CERTIFICATE_OPTION=installed CHK_REDIRECT_PORT_80=1"
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
