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
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipTranscript,
	# name in transcript files
	[Parameter(DontShow)]
	[string]$TranscriptName,
	# path to transcript files
	[Parameter(DontShow)]
	[string]$TranscriptPath,
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
				Write-Error -Message 'could not create X.509 certificate object'
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

	Function Start-TranscriptWithHostAndDate {
		Param(
			# name for transcript file
			[Parameter()]
			[string]$TranscriptName,
			# path for transcript file
			[Parameter()]
			[string]$TranscriptPath,
			# log start time
			[Parameter(DontShow)]
			[string]$TranscriptTime = ([datetime]::Now.ToString('yyyyMMddHHmmss')),
			# local hostname
			[Parameter(DontShow)]
			[string]$TranscriptHost = ([System.Environment]::MachineName)
		)

		# define default transcript name as basename of running script
		If (!$PSBoundParameters.ContainsKey('TranscriptName')) {
			$TranscriptName = (Get-PSCallStack)[1].Command -replace '\.ps1$'
		}

		# define default transcript path as named folder under transcripts folder in common application data folder
		If (!$PSBoundParameters.ContainsKey('TranscriptPath')) {
			$TranscriptPath = [System.Environment]::GetFolderPath('CommonApplicationData'), 'PowerShell_transcript', $TranscriptName -join '\'
		}

		# verify transcript path
		If (!(Test-Path -Path $TranscriptPath -PathType 'Container')) {
			# define parameters for New-Item
			$NewItem = @{
				Path        = $TranscriptPath
				ItemType    = 'Directory'
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# create transcript path
			Try {
				$null = New-Item @NewItem
			}
			Catch {
				Throw $_
			}
		}

		# build transcript file name with defined prefix, hostname, transcript name and current datetime
		$TranscriptFile = "PowerShell_transcript.$TranscriptHost.$TranscriptName.$TranscriptTime.txt"

		# define parameters for Start-Transcript
		$StartTranscript = @{
			Path        = Join-Path -Path $TranscriptPath -ChildPath $TranscriptFile
			Force       = $true
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# start transcript
		Try	{
			$null = Start-Transcript @StartTranscript
		}
		Catch {
			Throw $_
		}
	}

	Function Stop-TranscriptWithHostAndDate {
		Param(
			# name for transcript file
			[Parameter()]
			[string]$TranscriptName,
			# path of transcript files
			[Parameter()]
			[string]$TranscriptPath,
			# minimum number of transcript files for removal
			[Parameter(DontShow)]
			[uint16]$TranscriptCount = 7,
			# minimum age of transcript files for removal
			[Parameter(DontShow)]
			[double]$TranscriptDays = 7,
			# datetime for transcript files for removal
			[Parameter(DontShow)]
			[datetime]$TranscriptDate = ([datetime]::Now.AddDays(-$TranscriptDays)),
			# local hostname
			[Parameter(DontShow)]
			[string]$TranscriptHost = ([System.Environment]::MachineName)
		)

		# define default transcript name as basename of running script
		If (!$PSBoundParameters.ContainsKey('TranscriptName')) {
			$TranscriptName = (Get-PSCallStack)[1].Command -replace '\.ps1$'
		}

		# define default transcript path as named folder under transcripts folder in common application data folder
		If (!$PSBoundParameters.ContainsKey('TranscriptPath')) {
			$TranscriptPath = [System.Environment]::GetFolderPath('CommonApplicationData'), 'PowerShell_transcript', $TranscriptName -join '\'
			# LEGACY: re-define default transcript path as string array containing current path and original path in common application data folder
			[string[]]$TranscriptPath = @([System.Environment]::GetFolderPath('CommonApplicationData'), $TranscriptPath)
		}

		# define filter using default transcript prefix, hostname, and script name
		$TranscriptFilter = "PowerShell_transcript.$TranscriptHost.$TranscriptName*"

		# get transcript files matching filter
		$TranscriptFiles = Get-ChildItem -Path $TranscriptPath -Filter $TranscriptFilter -ErrorAction 'SilentlyContinue'

		# split transcript files on transcript date
		$NewFiles, $OldFiles = $TranscriptFiles.Where({ $_.LastWriteTime -ge $TranscriptDate }, [System.Management.Automation.WhereOperatorSelectionMode]::Split)
		
		# if count of files after transcript date is less than to cleanup threshold...
		If ($NewFiles.Count -lt $TranscriptCount) {
			# declare skip
			Write-Verbose -Message "Skipping transcript file cleanup; count of transcripts ($($NewFiles.Count)) would be below minimum transcript count ($TranscriptCount)" -Verbose
		}
		Else {
			# declare cleanup
			Write-Verbose -Message "Removing any transcript files matching '$TranscriptFilter' that are older than '$TranscriptDays' days from: $TranscriptPath" -Verbose
			# remove old logs
			ForEach ($OldFile in ($OldFiles | Sort-Object -Property FullName)) {
				Try {
					Remove-Item -Path $OldFile.FullName -Force -Verbose -ErrorAction Stop
				}
				Catch {
					$_
				}
			}
		}

		# stop transcript
		Try {
			$null = Stop-Transcript
		}
		Catch {
			Throw $_
		}
	}

	# if running...
	If ($PSCmdlet.ParameterSetName -eq 'Default') {
		# define hashtable for transcript functions
		$TranscriptWithHostAndDate = @{}
		# define parameters for transcript functions
		If ($PSBoundParameters.ContainsKey('TranscriptName')) { $TranscriptWithHostAndDate['TranscriptName'] = $PSBoundParameters['TranscriptName'] }
		If ($PSBoundParameters.ContainsKey('TranscriptPath')) { $TranscriptWithHostAndDate['TranscriptPath'] = $PSBoundParameters['TranscriptPath'] }
		# start transcript with parameters
		Try {
			Start-TranscriptWithHostAndDate @TranscriptWithHostAndDate
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
	# if running...
	If ($PSCmdlet.ParameterSetName -eq 'Default') {
		# stop transcript with parameters
		Try {
			Stop-TranscriptWithHostAndDate @TranscriptWithHostAndDate
		}
		Catch {
			Throw $_
		}
	}
}
