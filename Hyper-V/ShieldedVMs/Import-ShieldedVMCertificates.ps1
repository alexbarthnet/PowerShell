#requires -Module TranscriptWithHostAndDate

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# path for PFX files to import
	[Parameter(Position = 0, Mandatory = $true)][ValidateScript({ Test-Path -Path $_ -PathType 'Container' })]
	[string]$Path,
	# overwrite existing certificates
	[Parameter(Position = 1)]
	[switch]$Force,
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipTranscript,
	# local host name
	[Parameter(DontShow)]
	[string]$HostName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().HostName.ToLowerInvariant(),
	# local domain name
	[Parameter(DontShow)]
	[string]$DomainName = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName.ToLowerInvariant(),
	# local DNS hostname
	[Parameter(DontShow)]
	[string]$DnsHostName = ($HostName, $DomainName -join '.').TrimEnd('.')
)

Begin {
	Function Import-PfxCertificateWithDpapi {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$FilePath,
			[Parameter(DontShow)]
			[string]$CertStoreLocation = 'Cert:\LocalMachine\My'
		)

		# if path not found...
		If (!(Test-Path -Path $FilePath -PathType 'Leaf')) {
			Write-Warning -Message "could not find file at path: $Path"
			Return
		}

		# get PFX data from certificate
		Try {
			$PfxData = Get-PfxData -FilePath $FilePath -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not retrieve PFX data from '$FilePath' file: $($_.Exception.Message)"
			Return $_
		}

		# get thumbprints from PFX 
		Try {
			$Thumbprints = $PfxData.EndEntityCertificates | Select-Object -ExpandProperty 'Thumbprint'
		}
		Catch {
			Write-Warning -Message "could not retrieve thumbprint from PFX data of '$FilePath' file: $($_.Exception.Message)"
			Return $_
		}

		# process thumbprints
		ForEach ($Thumbprint in $Thumbprints) {
			# declare thumbprint
			Write-Verbose -Verbose -Message "Found certificate with '$Thumbprint' thumbprint in PFX file at path: $FilePath"

			# define path to certificate
			$CertificatePath = Join-Path -Path $CertStoreLocation -ChildPath $Thumbprint

			# check for certificate by thumbprint
			If (Test-Path -Path $CertificatePath -PathType 'Leaf') {
				# get certificate by path
				Try {
					$Certificate = Get-Item -Path $CertificatePath -ErrorAction 'Stop'
				}
				Catch {
					Write-Warning -Message "could not retrieve certificate from '$FilePath' file: $($_.Exception.Message)"
					Continue
				}
				# if certificate has a private key...
				If ($Certificate.HasPrivateKey) {
					Write-Verbose -Verbose -Message "Verified certificate with '$Thumbprint' thumbprint imported from PFX file at path: $FilePath"
					Continue
				}
			}

			# define required parameters for Import-PfxCertificate
			$ImportPfxCertificate = @{
				FilePath          = $FilePath
				CertStoreLocation = $CertStoreLocation
				ErrorAction       = [System.Management.Automation.ActionPreference]::Stop
			}

			# import certificate
			Try {
				$null = Import-PfxCertificate @ImportPfxCertificate
			}
			Catch {
				Write-Warning -Message "could not import certificate from '$FilePath' file: $($_.Exception.Message)"
				Continue
			}

			# report imported and return
			Write-Verbose -Verbose -Message "Imported certificate from PFX file at path: $FilePath"
		}
	}

	# if parameter set is default and SkipTranscript not set...
	If ($PSCmdlet.ParameterSetName -eq 'Default' -and -not $SkipTranscript) {
		# start transcript with default parameters
		Try {
			Start-TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}

Process {
	# define certificate store
	$CertStoreLocation = 'Cert:\LocalMachine\Shielded VM Local Certificates'

	# create CertStoreLocation if not found
	If (-not (Test-Path -Path $CertStoreLocation)) {
		Try {
			$null = New-Item -Path $CertStoreLocation -ItemType 'Directory' -ErrorAction 'Stop'
		}
		Catch {
			Return $_
		}
	}

	# get PFX files from path
	Try {
		$PfxFiles = Get-ChildItem -Path $Path -Filter 'untrustedguardian*' | Where-Object { $_.Extension -in @('.pfx', '.p12') }
	}
	Catch {
		Write-Warning "could not search '$Path' for PFX files: $($_.Exception.Message)"
		Return $_
	}

	# process each PFX file found
	ForEach ($PfxFile in $PfxFiles) {
		# declare file found
		Write-Verbose "Found PFX file: $($PfxFile.FullName)"

		# define required paramters for Import-PfxCertificateFromPath
		$ImportPfxCertificateWithDpapi = @{
			FilePath          = $PfxFile.FullName
			CertStoreLocation = $CertStoreLocation
			ErrorAction       = [System.Management.Automation.ActionPreference]::Stop
		}

		# import certificate from PFX file to defined certificate store
		Try {
			Import-PfxCertificateWithDpapi @ImportPfxCertificateWithDpapi
		}
		Catch {
			Write-Warning "could not import '$($PfxFile.FullName)' file to '$CertStoreLocation' store: $($_.Exception.Message)"
		}
	}
}

End {
	# if parameter set is default and SkipTranscript not set...
	If ($PSCmdlet.ParameterSetName -eq 'Default' -and -not $SkipTranscript) {
		# stop transcript with default parameters
		Try {
			Stop-TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}
