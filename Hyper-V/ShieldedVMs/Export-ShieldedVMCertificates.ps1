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
	# certificate store location
	[Parameter(DontShow)][ValidateScript({ Test-Path -Path $_ -PathType 'Container' })]
	[string]$CertStoreLocation = 'Cert:\LocalMachine\Shielded VM Local Certificates',
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
	$PathWithHostName = $PSCommandPath.Replace('.ps1', "_$HostName.txt")
	# append datetime to transcript path
	$PathWithLogStart = $PathWithHostName.Replace('.txt', "_$LogStart.txt")
	# define parameters for Start-Transcript
	$StartTranscript = @{
		Path        = $PathWithLogStart
		Force       = $true
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}
	# start transcript in script directory
	Try {
		Start-Transcript @StartTranscript
	}
	Catch {
		# get script directory name
		$PSScriptDirectory = (Get-Item -Path $PSCommandPath).DirectoryName
		# get program data path
		$PathOfProgramData = [System.Environment]::GetFolderPath('CommonApplicationData')
		# redirect transcript from script directory to programdata path
		$PathInProgramData = $PathWithLogStart.Replace($PSScriptDirectory, $PathOfProgramData)
		# update parameters for Start-Transcript
		$StartTranscript['Path'] = $PathInProgramData
		# start transcript in programdata path
		Try {
			Start-Transcript @StartTranscript
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
				Write-Output 'Certificates in path and store match; skipping export of:'
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
	$TranscriptFiles = Get-ChildItem -Path $PathForTranscript | Where-Object { $_.BaseName.StartsWith($NameForTranscript) -and $_.LastWriteTime -lt (Get-Date).AddDays(-$LogDays) }
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

	# ...stop transcript
	Try {
		Stop-Transcript
	}
	Catch {
		Throw $_
	}
}
