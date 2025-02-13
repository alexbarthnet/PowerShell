[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# path to JSON file with parameters
	[Parameter(ParameterSetName = 'Json', Mandatory = $true)][ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' })]
	[string]$ParametersFromJson,
	# optional parameter set to load from JSON file
	[Parameter(ParameterSetName = 'Json')]
	[string]$ParameterSetName,
	# path to folder with PFX files to import
	[Parameter(ParameterSetName = 'Default', Mandatory = $true, Position = 0)][ValidateScript({ Test-Path -Path $_ -PathType 'Container' })]
	[string]$Path,
	# switch to overwrite existing certificates
	[Parameter(Mandatory = $false)]
	[switch]$Force,
	# path to certificate store containing Shielded VM certificates
	[Parameter(DontShow)]
	[string]$CertStoreLocation = 'Cert:\LocalMachine\Shielded VM Local Certificates',
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
			[Parameter(Mandatory = $true)][ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' })]
			[string]$FilePath,
			[Parameter(Mandatory = $false)]
			[switch]$Force,
			[Parameter(DontShow)]
			[string]$CertStoreLocation = 'Cert:\LocalMachine\My'
		)

		# if force not set...
		If (!$local:Force) {
			# test PFX file matches certificate
			Try {
				$PfxCertificateAlreadyImported = Test-PfxFileAgainstStore -FilePath $FilePath -CertStoreLocation $CertStoreLocation
			}
			Catch {
				Return $_
			}

			# if PFX certificate already exported...
			If ($PfxCertificateAlreadyImported) {
				Return
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
			Write-Warning -Message "could not import certificate to '$CertStoreLocation' store from '$FilePath' file: $($_.Exception.Message)"
			Return $_
		}

		# report imported and return
		Write-Verbose -Verbose -Message "Imported certificates to '$CertStoreLocation' store from PFX file at path: $FilePath"
	}

	Function Test-PfxFileAgainstStore {
		Param(
			[Parameter(Mandatory = $true)]
			[string]$FilePath,
			[Parameter(Mandatory = $false)]
			[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
			[Parameter(DontShow)]
			[boolean]$CertificateFound = $false
		)

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
			$EndEntityCertificates = $PfxData.EndEntityCertificates
		}
		Catch {
			Write-Warning -Message "could not retrieve thumbprint from PFX data of '$FilePath' file: $($_.Exception.Message)"
			Return $_
		}

		# get certificates with private keys in store
		Try {
			$Certificates = Get-ChildItem -Path $CertStoreLocation -ErrorAction 'Stop' | Where-Object { $_.HasPrivateKey }
		}
		Catch {
			Write-Warning -Message "could not retrieve certificates from '$CertStoreLocation' path: $($_.Exception.Message)"
			Return $_
		}

		# process thumbprints
		ForEach ($EndEntityCertificate in $EndEntityCertificates) {
			# if thumbprint found in thumbprints of certificates with private keys in store...
			If ($EndEntityCertificate.Thumbprint -in $Certificates.Thumbprint) {
				# declare verified and record found
				Write-Verbose -Verbose -Message "Found '$CertStoreLocation' store contains certificate with '$($EndEntityCertificate.Thumbprint)' thumbprint and subject: $($EndEntityCertificate.Subject)"
				$CertificateFound = $true
			}
			# if thumbprint not found in thumbprints of certificates with private keys in store...
			Else {
				# immediately return false
				Write-Verbose -Verbose -Message "Found '$CertStoreLocation' store missing certificate with '$($EndEntityCertificate.Thumbprint)' thumbprint and subject: $($EndEntityCertificate.Subject)"
				Return $false
			}
		}

		# if certificate found...
		Return $CertificateFound
	}
}

Process {
	# if parameter from JSON file provided...
	If ($PSBoundParameters.ContainsKey('ParametersFromJson')) {
		# retrieve content of JSON file as PSCustomObject
		Try {
			$ParametersFromJsonObject = Get-Content -Path $ParametersFromJson -ErrorAction 'Stop' | ConvertFrom-Json -ErrorAction 'Stop'
		}
		Catch {
			Return $_
		}

		# retrieve parameter sets for command
		Try {
			$ParameterSets = (Get-Command -Name $PSCommandPath).ParameterSets
		}
		Catch {
			Return $_
		}

		# if named parameter set name defined...
		If ($PSBoundParameters.ContainsKey('ParameterSetNameForJson')) {
			# get parameters available in named parameter set
			$ParametersFromScript = $ParameterSets.Where({ $_.Name -eq $ParameterSetNameForJson }).Parameters
		}
		# if default parameter set name defined...
		ElseIf ($ParameterSets.IsDefault) {
			# get parameters in default parameter set
			$ParametersFromScript = $ParameterSets.Where({ $_.IsDefault }).Parameters
		}
		Else {
			# get parameters
			$ParametersFromScript = $ParameterSets.Parameters
		}

		# get parameter names from property names in PSCustomObject for parameters not defined at runtime
		$ParameterNames = $ParametersFromScript.Where({ $ParametersFromJsonObject.PSObject.Properties.Name.Contains($_.Name) -and -not $PSBoundParameters.ContainsKey($_.Name) }).Name

		# define parameters from JSON
		ForEach ($ParameterName in $ParameterNames) {
			# add parameter to bound parameters
			Try {
				$PSBoundParameters.Add($ParameterName, $ParametersFromJsonObject.$ParameterName)
			}
			Catch {
				Return $_
			}
			# create variable from parameter
			Try {
				Set-Variable -Name $ParameterName -Value $ParametersFromJsonObject.$ParameterName -Scope 'Script'
			}
			Catch {
				Return $_
			}
		}
	}

	# create CertStoreLocation if not found
	If (!(Test-Path -Path $CertStoreLocation)) {
		Try {
			$null = New-Item -Path $CertStoreLocation -ItemType 'Directory' -ErrorAction 'Stop'
		}
		Catch {
			Return $_
		}
	}

	# retrieve PFX files from path
	Try {
		$PfxFiles = Get-ChildItem -Path $Path -Filter 'untrustedguardian*' | Where-Object { $_.Extension -match '^\.p(fx|12)$' }
	}
	Catch {
		Write-Warning -Message "could not search '$Path' for PFX files: $($_.Exception.Message)"
		Return $_
	}

	# import PFX files to store
	ForEach ($PfxFile in $PfxFiles) {
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
			Write-Warning -Message "could not import '$($PfxFile.FullName)' file to '$CertStoreLocation' store: $($_.Exception.Message)"
		}
	}
}
