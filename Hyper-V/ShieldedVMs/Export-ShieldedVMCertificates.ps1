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
	# overwrite existing PFX and CER file to reset security
	[Parameter(Position = 3)]
	[switch]$Force,
	# certificate store location
	[Parameter(DontShow)]
	[string]$CertStoreLocation = 'Cert:\LocalMachine\Shielded VM Local Certificates',
	# switch to create any missing parameters from JSON file
	[Parameter(DontShow)]
	[switch]$ParametersFromJson,
	# path to JSON file with parameters
	[Parameter(DontShow)]
	[string]$ParametersFromJsonPath,
	# log file max age
	[Parameter(DontShow)]
	[double]$LogDays = 7,
	# log file min count
	[Parameter(DontShow)]
	[uint16]$LogCount = 7,
	# log start time
	[Parameter(DontShow)]
	[string]$LogStart = (Get-Date -Format FileDateTimeUniversal),
	# local hostname
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

Begin {
	# append hostname to script path to define transcript path
	$PathScriptLog = $PSCommandPath.Replace('.ps1', "_$HostName.txt")
	# append datetime to transcript path
	$PathScriptLog = $PathScriptLog.Replace('.txt', "_$LogStart.txt")
	# define ideal log path
	$PathFolderLog = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'Logs'
	# if ideal log path found...
	If (Test-Path -Path $PathFolderLog -PathType Container) {
		# use modified script path
		$PathScriptLog = $PathScriptLog.Replace($PSScriptRoot, $PathFolderLog)
	}
	# if ideal log path not found...
	Else {
		# use original script path and folder
		$PathScriptLog = $PSCommandPath
		$PathFolderLog = $PSScriptRoot
	}
	# define parameters for Start-Transcript
	$StartTranscript = @{
		Path        = $PathScriptLog
		Force       = $true
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}
	# start transcript in script directory
	Try {
		Start-Transcript @StartTranscript
	}
	Catch {
		# get program data path
		$PathOfAppData = [System.Environment]::GetFolderPath('CommonApplicationData')
		# redirect transcript from script directory to programdata path
		$PathInAppData = $PathScriptLog.Replace($PathFolderLog, $PathOfAppData)
		# update parameters for Start-Transcript
		$StartTranscript['Path'] = $PathInAppData
		# start transcript in programdata path
		Try {
			Start-Transcript @StartTranscript
		}
		Catch {
			Throw $_
		}
	}

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

	# create CertStoreLocation if not found
	If (-not (Test-Path -Path $CertStoreLocation)) {
		Try {
			New-Item -ItemType Directory -Path 'Cert:\LocalMachine' -Name 'Shielded VM Local Certificates'
		}
		Catch {
			Throw $_
		}
	}

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
		$PfxPath = Join-Path -Path $Path -ChildPath "$($Prefix, $NotBefore -join '_').pfx"
		$CerPath = Join-Path -Path $Path -ChildPath "$($Prefix, $NotBefore -join '_').cer"

		# if both files already exist and Force not set...
		If ((Test-Path -Path $CerPath) -and (Test-Path -Path $PfxPath) -and -not $Force) {
			# ...create empty certificate object then...
			Try {
				$X509Certificate2 = New-Object -TypeName 'System.Security.Cryptography.X509Certificates.X509Certificate2'
			}
			Catch {
				Write-Error -Message "could not create X.509 certificate object"
			}

			# ...import .cer file into object
			Try {
				$X509Certificate2.Import($CerPath)
			}
			Catch {
				Write-Error -Message "could not import X.509 certificate from '$CerPath'"
			}
		}

		# if X509Certificate2 was created...
		If ($null -ne $X509Certificate2.Thumbprint) {
			# ...then compare the thumbprints of the Certificate and the Cert object
			If ($X509Certificate2.Thumbprint -eq $Certificate.Thumbprint) {
				Write-Output 'Certificates in path and store match; skipping export of:'
				Write-Output "`tCerPath : '$($CerPath)'"
				Write-Output "`tPfxPath : '$($PfxPath)'"
				Write-Output "`tSubject : '$($X509Certificate2.Subject)'"
				Return
			}
		}

		# declare paths
		Write-Output 'Exporting certificate to path:'
		Write-Output "`tCerPath : '$($CerPath)'"
		Write-Output "`tPfxPath : '$($PfxPath)'"
		Write-Output "`tSubject : '$($Certificate.Subject)'"
		Write-Output "`tPrincipals : $($Principals -join ', ')"

		# create hashtable for .pfx file
		$ExportPfxCertificate = @{
			Cert                  = $Certificate
			FilePath              = $PfxPath
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
			Write-Output "...exported PFX file: '$PfxPath'"
		}
		Catch {
			Throw $_
		}

		# export certificate as .cer
		Try {
			$null = Export-Certificate -Cert $Certificate -FilePath $CerPath
			Write-Output "...exported CER file: '$CerPath'"
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
		$Prefix = 'untrustedguardian', $HostName, 'signing' -join '_'
		Export-CertificatePair -Certificate $Certificate -Prefix $Prefix
	}

	# retrieve and export each encryption certificate
	$EncryptionCertificates = $ShieldedVMCerts | Where-Object { $_.Subject -match $HostName -and $_.Subject -match 'Encryption' }
	foreach ($Certificate in $EncryptionCertificates) {
		$Prefix = 'untrustedguardian', $HostName, 'encrypt' -join '_'
		Export-CertificatePair -Certificate $Certificate -Prefix $Prefix
	}
}

End {
	# get transcript path
	$PathForTranscript = Split-Path -Path $StartTranscript['Path'] -Parent
	# get transcript name
	$NameForTranscript = (Split-Path -Path $StartTranscript['Path'] -Leaf).Replace("_$LogStart.txt", $null)
	# get transcript files
	$TranscriptFiles = Get-ChildItem -Path $PathForTranscript | Where-Object { $_.BaseName.StartsWith($NameForTranscript, [System.StringComparison]::InvariantCultureIgnoreCase) -and $_.LastWriteTime -lt (Get-Date).AddDays(-$LogDays) }
	# get transcript files newer than cleanup date
	$NewFiles = $TranscriptFiles | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-$LogDays) }
	# if count of transcript files count is less than cleanup threshold...
	If ($LogCount -lt $NewFiles.Count ) {
		# declare and continue
		Write-Output "Skipping transcript file cleanup; count of transcript files ($($NewFiles.Count)) is below cleanup threshold ($LogCount)"
	}
	# if count of transcript files is not less than cleanup threshold...
	Else {
		# get log files older than cleanup date
		$OldFiles = $TranscriptFiles | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$LogDays) } | Sort-Object -Property FullName
		# remove old logs
		ForEach ($OldFile in $OldFiles) {
			Write-Output "Removing old transcript file: $($OldFile.FullName)"
			Try {
				Remove-Item -InputObject $OldFile -Force -ErrorAction Stop
			}
			Catch {
				$_
			}
		}
	}

	# stop transcript
	Try {
		Stop-Transcript
	}
	Catch {
		Throw $_
	}
}
