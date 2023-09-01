[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# path for PFX files to import
	[Parameter(Position = 0, Mandatory = $True)][ValidateScript({ Test-Path -Path $_ -PathType 'Container' })]
	[string]$Path,
	# password for PFX files to import
	[Parameter(Position = 1)]
	[securestring]$Password,
	# import certificate even if found
	[Parameter(Position = 2)]
	[switch]$Force,
	# certificate store location
	[Parameter(DontShow)]
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

	# create CertStoreLocation if not found
	If (-not (Test-Path -Path $CertStoreLocation)) {
		Try {
			New-Item -ItemType Directory -Path 'Cert:\LocalMachine' -Name 'Shielded VM Local Certificates'
		}
		Catch {
			Throw $_
		}
	}

	Function Import-CertificatePair {
		Param(
			[Parameter(Position = 0, Mandatory = $true)][ValidateScript({ Test-Path -Path $_.FullName -PathType 'Leaf' })]
			[object]$PfxFile
		)

		# define expected .cer file
		$CerPath = $PfxFile.FullName.Replace($PfxFile.Extension, '.cer')
		Write-Verbose $CerPath


		# if .cer file exists and Force not set...
		If ((Test-Path -Path $CerPath) -and -not $Force) {
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
			# ...then retrieve any Shielded VM certificates with the same thumbprint as the X509 object
			$Certificate = Get-ChildItem -Path $CertStoreLocation | Where-Object { $_.Thumbprint -eq $X509Certificate2.Thumbprint }
			# ...then compare the thumbprints of the Certificate and the Cert object
			If ($X509Certificate2.Thumbprint -eq $Certificate.Thumbprint) {
				Write-Output 'Certificates in path and store match; skipping import of:'
				Write-Output "`tCerPath : '$($CerPath)'"
				Write-Output "`tPfxPath : '$($PfxFile.FullName)'"
				Write-Output "`tSubject : '$($X509Certificate2.Subject)'"
				Return
			}
		}

		# declare paths
		Write-Output 'Importing certificate to store:'
		Write-Output "`tPfxPath : '$($PfxFile.FullName)'"

		# create hashtable for .pfx file
		$ImportPfxCertificate = @{
			FilePath          = $PfxFile.FullName
			Exportable        = $true
			CertStoreLocation = $CertStoreLocation
		}

		# add password to hashtable
		If ($null -ne $Password) {
			$ImportPfxCertificate['Password'] = $Password
		}

		# export certificate as .pfx
		Try {
			$null = Import-PfxCertificate @ImportPfxCertificate
			Write-Output "...imported PFX file: '$($PfxFile.FullName)'"
		}
		Catch {
			Throw $_
		}
	}
}

Process {
	$PfxFiles = Get-ChildItem -Path $Path -Filter 'untrustedguardian*' | Where-Object { $_.Extension -eq '.pfx' -or $_.Extension -eq '.p12' }
	ForEach ($PfxFile in $PfxFiles) {
		Write-Verbose $PfxFile.FullName
		Import-CertificatePair -PfxFile $PfxFile
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
				Remove-Item -Path $OldFile.FullName -Force -ErrorAction Stop
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
