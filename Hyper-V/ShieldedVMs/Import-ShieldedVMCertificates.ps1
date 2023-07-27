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

		# if .cer file exists and Force not set...
		If ((Test-Path -Path $CerPath) -and -not $Force) {
			# ...create X509 object from .cer file...
			Try {
				$X509Certificate2 = New-Object 'System.Security.Cryptography.X509Certificates.X509Certificate2' -ArgumentList $CerFile
			}
			Catch {
				Write-Error -Message "could not create X.509 certificate from '$CerFile'"
			}
		}

		# if X509Certificate2 was created...
		If ($null -ne $X509Certificate2) {
			# ...then retrieve any Shielded VM certificates with the same thumbprint as the X509 object
			$ImportedCertificates = Get-ChildItem -Path $CertStoreLocation | Where-Object { $_.Thumbprint -eq $X509Certificate2.Thumbprint }
			# ...then compare the thumbprints of the Certificate and the Cert object
			If ($ImportedCertificates.Count -gt 0) {
				Write-Output 'Certificates in path and store match; skipping import of:'
				Write-Output "`tCerPath : '$($CerPath)'"
				Write-Output "`tPfxPath : '$($PfxFile.FullName)'"
				Write-Output "`tSubject : '$($X509Certificate2.Subject)'"
				Return
			}
		}

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
		}
		Catch {
			Throw $_
		}
	}
}

Process {
	$PfxFiles = Get-ChildItem -Path $Path -Filter 'untrustedguardian*' | Where-Object { $_.Extension -eq '.pfx' -or $_.Extension -eq '.p12' }
	foreach ($PfxFile in $PfxFiles) {
		Import-CertificatePair -PfxFile $PfxFile
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
