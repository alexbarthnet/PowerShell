#requires -Module TranscriptWithHostAndDate

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# path for exported PFX files
	[Parameter(Position = 0, Mandatory = $true)][ValidateScript({ Test-Path -Path $_ -PathType 'Container' })]
	[string]$Path,
	# prinicpals that can access exported PFX files
	[Parameter(Position = 1, Mandatory = $true)]
	[string[]]$Principals,
	# overwrite existing PFX file to reset security
	[Parameter(Position = 2)]
	[switch]$Force,
	# switch to create any missing parameters from JSON file
	[Parameter(DontShow)]
	[switch]$ParametersFromJson,
	# path to JSON file with parameters
	[Parameter(DontShow)]
	[string]$ParametersFromJsonPath,
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
	# load missing parameters from JSON file
	If ($ParametersFromJson) {
		# retrieve all parameters
		$Parameters = (Get-Command -Name $PSCommandPath).Parameters.Values

		# filter parameters to parameter set
		If ($PSCmdlet.ParameterSetName) {
			$Parameters = $Parameters | Where-Object { $_.ParameterSets[$PSCmdlet.ParameterSetName] -or $_.ParameterSets['__AllParameterSets'] }
		}

		# define unbound parameters
		$PSUnboundParameters = @{}
		ForEach ($ParameterName in $Parameters.Name) {
			If (-not $PSBoundParameters.ContainsKey($ParameterName)) {
				$PSUnboundParameters[$ParameterName] = $null
			}
		}

		# if ParametersFromJsonPath was not defined...
		If (-not $PSBoundParameters.ContainsKey('ParametersFromJsonPath')) {
			$ParametersFromJsonPath = $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.json')
		}

		# get data in JSON file
		Try {
			$Json = Get-Content -Path $ParametersFromJsonPath -ErrorAction Stop | ConvertFrom-Json
		}
		Catch {
			Throw $_
		}

		# create parameters from data in JSON file
		ForEach ($ParameterName in $PSUnboundParameters.Keys) {
			If ($ParameterName -in ($Json.PSObject.Properties.Name)) {
				Set-Variable -Name $ParameterName -Value $Json.$ParameterName -Scope 'Script'
			}
		}
	}

	Function Export-PfxCertificateWithDpapi {
		[CmdletBinding()]
		Param(
			[Parameter(Mandatory = $true)]
			[string]$FilePath,
			[Parameter(Mandatory = $true)]
			[string]$Certificate,
			[Parameter(Mandatory = $true)]
			[string]$ProtectTo
		)

		# if FilePath found...
		If (Test-Path -Path $FilePath -PathType 'Leaf') {
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
				Write-Warning -Message "could not retrieve thumbprint from PFX data of '$Path' file: $($_.Exception.Message)"
				Return $_
			}

			# process thumbprints
			ForEach ($Thumbprint in $Thumbprints) {
				# check for certificate by thumbprint
				If ($Certificate.Thumbprint -eq $Thumbprint) {
					Write-Verbose -Verbose -Message "Verified certificate with '$Thumbprint' thumbprint exported to PFX file at path: $Path"
					Continue
				}
			}
		}

		# define parameters for Export-PfxCertificate
		$ExportPfxCertificate = @{
			Cert                  = $Certificate
			FilePath              = $FilePath
			ProtectTo             = $ProtectTo
			ChainOption           = 'EndEntityCertOnly'
			CryptoAlgorithmOption = 'AES256_SHA256'
		}

		# export certificate as .pfx
		Try {
			$null = Export-PfxCertificate @ExportPfxCertificate
			Write-Verbose -Verbose -Message "Exported certificate with '$Thumbprint' thumbprint to PFX file at path: $Path"
		}
		Catch {
			Throw $_
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

	# retrieve all shielded VM certificates
	$ShieldedVMCertificates = Get-ChildItem -Path $CertStoreLocation | Where-Object { $_.Subject -match $Hostname }

	# retrieve signing certificates
	$SigningCertificates = $ShieldedVMCertificates | Where-Object { $_.Subject.StartsWith('CN=Shielded VM Signing Certificate (UntrustedGuardian)') }

	# retrieve encryption certificates
	$EncryptCertificates = $ShieldedVMCertificates | Where-Object { $_.Subject.StartsWith('CN=Shielded VM Encryption Certificate (UntrustedGuardian)') }

	# export signing certificates
	ForEach ($Certificate in $EncryptCertificates) {
		# define base name
		$BaseName = 'untrustedguardian', $HostName, 'encrypt', $Certificate.NotBefore.ToUniversalTime().ToString('yyyyMMddThhmmssZ') -join '_'

		# define file path
		$FilePath = Join-Path -Path $Path -ChildPath "$BaseName.pfx"

		# define required paramters for Export-PfxCertificateWithDpapi
		$ExportPfxCertificateWithDpapi = @{
			FilePath           = $FilePath
			ProtectTo          = $ProtectTo
			Certificate        = $Certificate
			ErrorAction        = [System.Management.Automation.ActionPreference]::Stop
		}

		# export certificate to PFX file
		Try {
			Export-PfxCertificateWithDpapi @ExportPfxCertificateWithDpapi
		}
		Catch {
			Write-Warning "could not export '$($Certificate.Subject)' certificate to '$FilePath' path: $($_.Exception.Message)"
		}
	}

	# export signing certificates
	ForEach ($Certificate in $SigningCertificates) {
		# define base name
		$BaseName = 'untrustedguardian', $HostName, 'signing', $Certificate.NotBefore.ToUniversalTime().ToString('yyyyMMddThhmmssZ') -join '_'

		# define file path
		$FilePath = Join-Path -Path $Path -ChildPath "$BaseName.pfx"

		# define required paramters for Export-PfxCertificateWithDpapi
		$ExportPfxCertificateWithDpapi = @{
			FilePath           = $FilePath
			ProtectTo          = $ProtectTo
			Certificate        = $Certificate
			ErrorAction        = [System.Management.Automation.ActionPreference]::Stop
		}

		# export certificate to PFX file
		Try {
			Export-PfxCertificateWithDpapi @ExportPfxCertificateWithDpapi
		}
		Catch {
			Write-Warning "could not export '$($Certificate.Subject)' certificate to '$FilePath' path: $($_.Exception.Message)"
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
