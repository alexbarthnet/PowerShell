[CmdletBinding(DefaultParameterSetName = 'Password')]
Param(
	# path for exported PFX files 
	[Parameter(Position = 0, Mandatory = $True)][ValidateScript({ Test-Path -Path $_ -PathType 'Container' })]
	[string]$Path,
	# password for exported PFX files
	[Parameter(Position = 1)]
	[securestring]$Password,
	# prinicpals that can access exported PFX files
	[Parameter(Position = 2)]
	[string[]]$Principals,
	# local hostname
	[Parameter(DontShow)][ValidateScript({ Test-Path -Path $_ -PathType 'Container'})]
	[string]$CertStoreLocation = 'Cert:\LocalMachine\Shielded VM Local Certificates',
	# local hostname
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

Begin {
	# force close open transcript
	Try { Stop-Transcript } Catch [System.Management.Automation.PSInvalidOperationException] { $Error.Clear() }

	# define transcript file from script path and start transcript
	Start-Transcript -Path $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, "_$Hostname.txt") -Force

	# throw error "either or" parameter requirements not met
	If ($null -eq $Principals -and $null -eq $Password) {
		Throw [System.Management.Automation.ParameterBindingException]::New('The Password or Principals parameter must be provided.')
	}

	Function Export-CertificatePair {
		Param(
			[Parameter(Position = 0, Mandatory = $true)]
			[object]$Certificate,
			[Parameter(Position = 1, Mandatory = $true)]
			[string]$Prefix
		)
	
		# retrieve required certificate properties
		$NotBefore = Get-Date -Date $Certificate.NotBefore -Format 'FileDateTimeUniversal'
	
		# create file paths
		$FilePathPfx = Join-Path -Path $Path -ChildPath "$($Prefix, $NotBefore -join '_').pfx"
		$FilePathCer = Join-Path -Path $Path -ChildPath "$($Prefix, $NotBefore -join '_').cer"
	
		# if both files already exist and Force not set...
		If ((Test-Path -Path $FilePathCer) -and (Test-Path -Path $FilePathPfx) -and -not $Force) {
			# ...create Cert object from .cer file...
			Try {
				$X509Certificate2 = New-Object 'System.Security.Cryptography.X509Certificates.X509Certificate2' -ArgumentList $FilePathCer
			}
			Catch {
				Write-Error -Message "could not create X.509 certificate from '$FilePathCer'"
			}
			# ...then compare the thumbprints of the Certificate and the Cert object
			If ($X509Certificate2.Thumbprint -eq $Certificate.Thumbprint) {
				Write-Output "Certificates in path and store match; skipping export of:"
				Write-Output "`tCerPath : '$($FilePathCer.FullName)'"
				Write-Output "`tPfxPath : '$($FilePathPfx.FullName)'"
				Write-Output "`tSubject : '$($X509Certificate2.Subject)'"
				Return
			}
		}
	
		# create hashtable for .pfx file
		$ExportPfxCertificate = @{
			Cert                  = $Certificate 
			FilePath              = $FilePathPfx
			ChainOption           = 'EndEntityCertOnly'
			CryptoAlgorithmOption = 'AES256_SHA256'
		}
	
		# add principals to hashtable
		If ($null -ne $Principals) {
			$ExportPfxCertificate['ProtectTo'] = $Principals
		}
	
		# add password to hashtable
		If ($null -ne $Password) {
			$ExportPfxCertificate['Password'] = $Password
		}
	
		# export certificate as .pfx
		Try {
			$null = Export-PfxCertificate @ExportPfxCertificate
		}
		Catch {
			Throw $_
		}
	
		# export certificate as .cer
		Try {
			$null = Export-Certificate -Cert $Certificate -FilePath $FilePathCer
		}
		Catch {
			Throw $_
		}	
	}
}

Process {
	# retrieve all shielded VM certificates
	$ShieldedVMCerts = Get-ChildItem -Path $CertStoreLocation

	# retrieve and export each signing certificate
	$SigningCertificates = $ShieldedVMCerts | Where-Object { $_.Subject -match $HostName -and $_.Subject -match 'Signing' }
	foreach ($Certificate in $SigningCertificates) {
		$Prefix = $HostName, 'signing' -join '_'
		Export-CertificatePair -Certificate $Certificate -Prefix $Prefix
	}

	# retrieve and export each encryption certificate
	$EncryptionCertificates = $ShieldedVMCerts | Where-Object { $_.Subject -match $HostName -and $_.Subject -match 'Encryption' }
	foreach ($Certificate in $EncryptionCertificates) {
		$Prefix = $HostName, 'encrypt' -join '_'
		Export-CertificatePair -Certificate $Certificate -Prefix $Prefix
	}
}

End {
	# stop transcript
	Stop-Transcript
}
