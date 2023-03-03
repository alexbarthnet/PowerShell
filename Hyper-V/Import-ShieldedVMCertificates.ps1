[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# path for PFX files to import
	[Parameter(Position = 0, Mandatory = $True)][ValidateScript({ Test-Path -Path $_ -PathType 'Container' })]
	[string]$Path,
	# password for PFX files to import
	[Parameter(Position = 1, Mandatory = $True)]
	[securestring]$Password,
	# local hostname
	[Parameter(DontShow)]
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

	# create CertStoreLocation if not found
	If (-not (Test-Path -Path $CertStoreLocation)) {
		Try {
			New-Item -ItemType Directory -Path 'Cert:\LocalMachine'  -Name 'Shielded VM Local Certificates'
		}
		Catch {
			Throw $_
		}
	}

	Function Import-CertificatePair {
		Param(
			[Parameter(Position = 0, Mandatory = $true)][ValidateScript({ Test-Path -Path $_ -PathType 'Leaf'})]
			[object]$PfxFile
		)

		# define expected .cer file
		$CerPath = $PfxFile.FullName.Replace($PfxFile.Extension, '.cer')

		# if .cer file exists and Force not set...
		If ((Test-Path -Path $CerPath) -and -not $Force) {
			# ...create X509 object from .cer file...
			Try {
				$X509Certificate2 = New-Object 'System.Security.Cryptography.X509Certificates.X509Certificate2' -ArgumentList $CerFile
			}
			Catch {
				Write-Error -Message "could not create X.509 certificate from '$CerFile'"
			}
			# ...then retrieve any Shielded VM certificates with the same thumbprint as the X509 object 
			$ImportedCertificates = Get-ChildItem -Path $CertStoreLocation | Where-Object { $_.Thumbprint -eq $X509Certificate2.Thumbprint }
			# ...then compare the thumbprints of the Certificate and the Cert object
			If ($ImportedCertificates.Count -gt 0) {
				Write-Output "Certificates in path and store match; skipping import of:"
				Write-Output "`tCerPath : '$($CerPath)'"
				Write-Output "`tPfxPath : '$($PfxFile.FullName)'"
				Write-Output "`tSubject : '$($X509Certificate2.Subject)'"
				Return
			}
		}

		# create hashtable for .pfx file
		$ImportPfxCertificate = @{
			FilePath              = $PfxFile.FullName
			Exportable            = $true
			CertStoreLocation     = $CertStoreLocation
		}

		# add password to hashtable
		If ($null -ne $Password) {
			$ImportPfxCertificate['Password'] = $Password
		}
	
		# export certificate as .pfx
		Try {
			$null = Import-PfxCertificate @ImportPfxCertificate
		}
		Catch {
			Throw $_
		}
	}
}

Process {
	$PfxFiles = Get-ChildItem -Path $Path | Where-Object { $_.Extension -eq '.pfx' -or $_.Extension -eq '.p12' }
	foreach ($PfxFile in $PfxFiles) {
		Import-CertificatePair -PfxFile $PfxFile
	}
}

End {
	# stop transcript
	Stop-Transcript
}
