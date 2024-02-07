<#
.SYNOPSIS
Exports certificates from the local machine store based upon values in a JSON configuration file.

.DESCRIPTION
Exports certificates from the local machine store based upon values in a JSON configuration file. The JSON identifies the subject of certificate to be exported, the path of the exported certificate files, and the principals to grant access to the PFX certificate files.

.PARAMETER Json
The path to a JSON file containing the configuration for this script.

.PARAMETER Show
Switch parameter to show all entries from the JSON configuration file. Cannot be combined with the Clear, Remove, or Add parameters.

.PARAMETER Clear
Switch parameter to clear all entries from the JSON configuration file. Cannot be combined with the Show, Remove, or Add parameters.

.PARAMETER Remove
Switch parameter to remove an entry from the JSON configuration file. Cannot be combined with the Show, Clear, or Add parameters.

.PARAMETER Add
Switch parameter to add an entry from the JSON configuration file. Cannot be combined with the Show, Clear, or Remove parameters.

.PARAMETER Subject
The subject of the certificate to export. Required when the Add or Remove parameters are specified.

.PARAMETER Path
The path to export certificate files. Required when the Add parameter is specified.

.PARAMETER Principals
The pricinipals that will be granted access to any exported PFX certificates. Required when the Add parameter is specified.

.PARAMETER SkipChain
Switch parameter to skip exporting the certificates in the chain. Optional when the Add parameter is specified.

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Export-CertificateToPath.ps1 -Json C:\Content\config.json

.EXAMPLE
.\Export-CertificateToPath.ps1 -Json C:\Content\config.json -Show

.EXAMPLE
.\Export-CertificateToPath.ps1 -Json C:\Content\config.json -Clear

.EXAMPLE
.\Export-CertificateToPath.ps1 -Json C:\Content\config.json -Remove -Subject 'host.example.com'

.EXAMPLE
.\Export-CertificateToPath.ps1 -Json C:\Content\config.json -Add -Subject 'host.example.com' -Path 'C:\path\' -Principals 'Domain Admins'
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Position = 0, ParameterSetName = 'Default')]
	[object]$Result,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Show')]
	[switch]$Show,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Remove')][ValidatePattern('^[^\*]+$')]
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Add')][ValidatePattern('^[^\*]+$')]
	[string]$Subject,
	[Parameter(Position = 2, Mandatory = $True, ParameterSetName = 'Add')][ValidatePattern('^[^\*]+$')][ValidateScript({ Test-Path -Path $_ })]
	[string]$Path,
	[Parameter(Position = 3, Mandatory = $True, ParameterSetName = 'Add')][ValidatePattern('^[^\*]+$')]
	[string[]]$Principals,
	[Parameter(Position = 4, ParameterSetName = 'Add')]
	[switch]$SkipChain,
	[Parameter()]
	[string]$Json,
	# switch to skip transcript logging
	[Parameter(DontShow)]
	[switch]$SkipTranscript,
	# name in transcript files
	[Parameter(DontShow)]
	[string]$TranscriptName,
	# path to transcript files
	[Parameter(DontShow)]
	[string]$TranscriptPath,
	# local hostname
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

Begin {
	Function Compare-CertificateWithPath {
		[CmdletBinding()]
		Param(
			[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ $_ -is [System.Security.Cryptography.X509Certificates.X509Certificate2] })]
			[object]$Certificate,
			[Parameter(Position = 1, Mandatory = $true)]
			[string]$Path
		)

		# if validation file found...
		If (Test-Path -Path $Path -PathType Leaf) {
			# create certificate object from validation file
			Try {
				$ValidationCertificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($Path)
			}
			Catch {
				Write-Verbose "error creating certificate object from file: $($_.ToString())"
				Return $false
			}

			# if thumbprints match...
			If ($Certificate.Thumbprint -eq $ValidationCertificate.Thumbprint) {
				Write-Verbose 'certificate and file thumbprints match'
				Return $true
			}
			# if thumbprints do not match...
			Else {
				Write-Verbose 'certificate and file thumbprints do not match'
				Return $false
			}
		}
		# if validation file not found...
		Else {
			Write-Verbose 'file not found'
			Return $false
		}
	}

	Function Export-CertificateChainFiles {
		[CmdletBinding()]
		Param(
			[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ $_ -is [System.Security.Cryptography.X509Certificates.X509Certificate2] })]
			[object]$Certificate,
			[Parameter(Position = 1, Mandatory = $true)][ValidateScript({ Test-Path -Path $_ -PathType Container })]
			[string]$Path,
			[Parameter(Position = 2)]
			[string]$Prefix = [string]::Empty
		)

		# build prefix if not provided
		If ([string]::IsNullOrEmpty($Prefix)) {
			# retrieve subject and NotBefore from input certificate
			$FileHead = $Certificate.Subject.Split(',', 2)[0].Split('=', 2)[-1]
			$FileDate = Get-Date -Date $Certificate.NotBefore -Format 'FileDateTimeUniversal'

			# define prefix for exported certificates from input certificate
			$Prefix = $FileHead, $FileDate -join '_'
		}

		# create certificate chain object
		$X509Chain = [System.Security.Cryptography.X509Certificates.X509Chain]::new()
		$X509Chain.ChainPolicy.RevocationMode = 'NoCheck'

		# build chain from certificate
		Try {
			$Built = $X509Chain.Build($Certificate)
		}
		Catch {
			Write-Host "ERROR: building certificate chain for '$($Certificate.Subject)'"
			Throw $_
		}

		# if chain was not built...
		If ($Built -eq $false) {
			Write-Host "ERROR: unable to build certificate chain for '$($Certificate.Subject)'"
			Return
		}

		# start certificate chain counter
		$ChainCounter = 0

		# define *format* for certificate chain counter string based upon chain element count
		$ChainCounterStringFormat = "d$($X509Chain.ChainElements.Certificate.Count.ToString().Length)"

		# export certificate chain to path
		:ChainElement ForEach ($ChainElement in $X509Chain.ChainElements.Certificate) {
			# declare certificate
			# Write-Host " - found certificate in chain : $($ChainElement.Subject)"

			# define strings for chain element
			switch ($ChainElement.Subject) {
				# define end entity certificate
				$Certificate.Subject { $Suffix = 'cert.cer' }
				# define root certificate
				$ChainElement.Issuer { $Suffix = 'root.cer' }
				# define intermediate chain certificate
				Default { $ChainCounter++; $Suffix = 'chain' + $ChainCounter.ToString($ChainCounterStringFormat) + '.cer' }
			}

			# build certificate file path
			$FilePath = Join-Path -Path $Path -ChildPath ($Prefix, $Suffix -join '_')

			# check if chain element already exported
			Try {
				$Matched = Compare-CertificateWithPath -Certificate $ChainElement -Path $FilePath
			}
			Catch {
				Write-Warning "could not compare certificate with file: $FilePath"
			}
			
			# if chain element already exported...
			If ($Matched) {
				# ...declare and continue
				Write-Host " - verified certificate file at : $FilePath"
				Continue ChainElement
			}

			# export chain element as certificate
			Try {
				$null = $ChainElement | Export-Certificate -FilePath $FilePath
				Write-Host " - exported certificate file to : $FilePath"
			}
			Catch {
				Write-Host "ERROR: exporting certificate for: '$($ChainElement.Subject)'"
				Continue ChainElement
			}
		}
	}

	Function Export-PfxCertificateToFile {
		[CmdletBinding()]
		Param(
			[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ $_ -is [System.Security.Cryptography.X509Certificates.X509Certificate2] })]
			[object]$Certificate,
			[Parameter(Position = 1, Mandatory = $true)][ValidateScript({ Test-Path -Path $_ -PathType Container })]
			[object]$Path,
			[Parameter(Position = 2)][AllowEmptyCollection()]
			[string[]]$Principals,
			[Parameter(Position = 3)]
			[switch]$Validate,
			[Parameter(Position = 4)][ValidateSet({ [Microsoft.CertificateServices.Commands.ExportChainOption].GetEnumValues() })]
			[string]$ChainOption = 'EndEntityCertOnly',
			[Parameter(Position = 5)][ValidateSet({ [Microsoft.CertificateServices.Commands.CryptoAlgorithmOptions].GetEnumValues() })]
			[string]$CryptoAlgorithmOption = 'AES256_SHA256'
		)

		# define full path to pfx
		$FileHead = $Certificate.Subject.Split(',', 2)[0].Split('=', 2)[-1]
		$FileDate = Get-Date -Date $Certificate.NotBefore -Format 'FileDateTimeUniversal'
		$FileTail = 'cert.pfx'
		$FilePath = Join-Path -Path $Path -ChildPath ($FileHead, $FileDate, $FileTail -join '_')

		# if PFX file found...
		If (Test-Path -Path $FilePath -PathType Leaf) {
			# if validation not requested...
			If (!$Validate) {
				# ...declare and return
				Write-Host " - found existing PFX file at   : $FilePath"
				Return
			}

			# define validation file path from pfx file path
			$ValidationFilePath = $FilePath -replace '\.pfx$', '\.cer$'

			# test certificate against validation file in path
			Try {
				$Validated = Compare-CertificateWithPath -Certificate $Certificate -Path $ValidationFilePath
			}
			Catch {
				Write-Warning "error comparing certificate with path: $($_.ToString())"
			}

			# if certificate was validated...
			If ($Validated) {
				# ...declare and return
				Write-Host " - validated PFX file           : $FilePath"
				Return
			}
		}

		# define parameters for Export-PfxCertificate
		$ExportPfxCertificateParams = @{
			Cert                  = $Certificate
			FilePath              = $FilePath
			ProtectTo             = $Principals
			ChainOption           = $ChainOption
			CryptoAlgorithmOption = $CryptoAlgorithmOption
		}

		# export PFX file to path
		Try {
			$null = Export-PfxCertificate @ExportPfxCertificateParams
			Write-Host " - exported PFX file to         : $FilePath"
		}
		Catch {
			Write-Host "ERROR: exporting PFX file for: '$($Certificate.Subject)'"
			Throw $_
		}
	}

	Function Export-PfxCertificateToFolder {
		[CmdletBinding()]
		Param(
			[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ Test-Path -Path $_ -PathType Container })]
			[object]$Path,
			[Parameter(Position = 1, Mandatory = $true)][ValidatePattern('^[^\*]+$')]
			[string]$Subject,
			[Parameter(Position = 2)][AllowEmptyCollection()]
			[string[]]$Principals,
			[Parameter(Position = 3)]
			[switch]$SkipChain,
			[Parameter(Position = 4)][ValidateScript({ Test-Path -Path $_ })]
			[string]$Store = 'Cert:\LocalMachine\My'
		)

		# retrieve exportable certificates
		$Certificates = Get-ChildItem -Path $Store | Where-Object { $_.PrivateKey.CspKeyContainerInfo.Exportable } | Sort-Object Subject, NotBefore

		# filter exportable certificates
		If ($Subject -ne '_default') {
			$Certificates = $Certificates | Where-Object { $_.Subject -eq $Subject -or $_.Subject -eq "CN=$Subject" } | Select-Object -Last 1
		}

		# if no exportable certificates found...
		If ($Certificates.Count -eq 0) {
			# declare and return
			Write-Host "`nERROR: no certificates found with subject: $Subject"
			Return
		}

		# process each exportable certificate
		:Certificate ForEach ($Certificate in $Certificates) {
			# declare start
			Write-Host "`nFound certificate: '$($Certificate.Subject)'"

			# define required parameters for Export-PfxCertificateToFile
			$ExportPfxCertificateToFile = @{
				Certificate = $Certificate
				Path        = $Path
				Principals  = $Principals
			}
			
			# export certificate to PFX file
			Try {
				Export-PfxCertificateToFile @ExportPfxCertificateToFile
			}
			Catch {
				Throw $_
			}

			# if SkipChain set...
			If ($SkipChain) {
				Write-Host " - skipping chain file export : $Path"
				Continue Certificate
			}

			# define parameters for Export-CertificateChainFiles
			$ExportCertificateChainFiles = @{
				Certificate = $Certificate
				Path        = $Path
			}

			# export certificate chain to path
			Try {
				Export-CertificateChainFiles @ExportCertificateChainFiles
			}
			Catch {
				Throw $_
			}
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
			# remove old transcript files
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
	# if JSON file found...
	If (Test-Path -Path $Json) {
		# ...create JSON data object as array of PSCustomObjects from JSON file content
		Try {
			$JsonData = [array](Get-Content -Path $Json | ConvertFrom-Json)
		}
		Catch {
			Write-Output "`nERROR: could not read configuration file: '$Json'"
			Return $_
		}
	}
	# if JSON file was not found...
	Else {
		# ...and Add set...
		If ($Add) {
			# ...try to create the JSON file
			Try {
				$null = New-Item -ItemType 'File' -Path $Json -ErrorAction Stop
			}
			Catch {
				Write-Output "`nERROR: could not create configuration file: '$Json'"
				Return $_
			}
			# ...create JSON data object as empty array
			$JsonData = @()
		}
		# ...and Add not set...
		Else {
			# ...report and return
			Write-Output "`nERROR: could not find configuration file: '$Json'"
			Return
		}
	}

	# evaluate parameters
	switch ($true) {
		# show configuration file
		$Show {
			Write-Output "`nDisplaying '$Json'"
			$JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
		}
		# clear configuration file
		$Clear {
			Try {
				[string]::Empty | Set-Content -Path $Json
				Write-Output "`nCleared configuration file: '$Json'"
			}
			Catch {
				Write-Output "`nERROR: could not clear configuration file: '$Json'"
				Return $_
			}
		}
		# remove entry from configuration file
		$Remove {
			Try {
				$JsonData = $JsonData | Where-Object { $_.Subject -ne $Subject }
				If ($null -eq $JsonData) {
					[string]::Empty | Set-Content -Path $Json
					Write-Output "`nRemoved '$Subject' from configuration file: '$Json'"
				}
				Else {
					$JsonData | ConvertTo-Json | Set-Content -Path $Json
					Write-Output "`nRemoved '$Subject' from configuration file: '$Json'"
				}
				$JsonData | Format-List
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file: '$Json'"
				Return $_
			}
		}
		# add entry to configuration file
		$Add {
			Try {
				# create hashtable for custom object
				$JsonParameters = [ordered]@{
					Subject    = [string]$Subject
					Path       = [string]$Path
					Principals = [string[]]$Principals
				}

				# add current time as FileDateTimeUniversal
				$JsonParameters['Updated'] = Get-Date -Format FileDateTimeUniversal

				# create custom object from hashtable
				$JsonDatum = [pscustomobject]$JsonParameters

				# remove existing entry with same name
				If ($JsonData.Subject -contains $Subject) {
					Write-Warning -Message "Will overwrite existing entry for '$Subject' configuration file: '$Json' `nAny previous configuration for this entry will **NOT** be preserved" -WarningAction Inquire
					$JsonData = $JsonData | Where-Object { $_.Subject -ne $Subject }
				}

				# add datum to data
				$JsonData += $JsonDatum
				$JsonData | ConvertTo-Json -Depth 100 | Set-Content -Path $Json
				Write-Output "`nAdded '$Subject' to configuration file: '$Json'"
				$JsonData | ConvertTo-Json -Depth 100 | ConvertFrom-Json | Format-List
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file: '$Json'"
				Return $_
			}
		}
		# process input against configuration file
		{ $null -ne $Result } {
			# retrieve $Result values
			$cert_name = $Result.ManagedItem.Name
			$cert_date = $Result.ManagedItem.DateStart
			$cert_hash = $Result.ManagedItem.CertificateThumbPrintHash

			# validate $Result values
			If ([string]::IsNullOrEmpty($cert_name) -or [string]::IsNullOrEmpty($cert_date) -or [string]::IsNullOrEmpty($cert_hash)) {
				Write-Host "ERROR: one or more values from `$Result was null or empty"
				Return
			}

			# announce $Result values
			Write-Host "`nExporting certificate from `$Result object"
			Write-Host " - subject    : $cert_name"
			Write-Host " - datestart  : $cert_date"
			Write-Host " - thumbprint : $cert_hash"

			# if configuration file is empty...
			If ($JsonData.Count -eq 0) {
				# ...announce error and return
				Write-Output "ERROR: no entries found in input file: $Json"
				Return
			}
			# if configuration file is not empty...
			Else {
				# ...retrieve entry with matching subject if any
				$Defined = $JsonData | Where-Object { $_.Subject -eq $cert_name -and -not [string]::IsNullOrEmpty($_.Path) -and -not [string]::IsNullOrEmpty($_.Principals) } | Select-Object -First 1
			}

			# if defined entry not found in configuration file...
			If ($null -eq $Defined) {
				# ...check for default entry in configuration file
				$Defined = $JsonData | Where-Object { $_.Subject -eq '_default' -and -not [string]::IsNullOrEmpty($_.Path) -and -not [string]::IsNullOrEmpty($_.Principals) } | Select-Object -First 1
			}

			# if default entry not found in configuration file...
			If ($null -eq $Defined) {
				# ...announce error and return
				Write-Output "ERROR: unable to locate matching subject or '_default' entry with valid path and principals"
				Return
			}

			# announce $Defined values
			Write-Host "`nFound matching configuration entry:"
			Write-Host " - subject    : $($Defined.Subject)"
			Write-Host " - path       : $($Defined.Path)"
			Write-Host " - principals : $($Defined.Principals)"

			# if cert_date is datetimeoffset...
			If ($cert_date -is [System.DateTimeOffset]) {
				# ...convert to datetime
				Try {
					$cert_date = $cert_date.DateTime
				}
				Catch {
					Throw $_
				}
			}

			# define params for Export-PfxCertificateToPrincipals
			$ExportPfxCertificateToPrincipals = @{
				Name       = $cert_name
				Date       = $cert_date
				Hash       = $cert_hash
				Path       = $Defined.Path
				Principals = $Defined.Principals
			}

			# export pfx certificate to principals
			Try {
				Export-PfxCertificateToPrincipals @ExportPfxCertificateToPrincipals
			}
			Catch {
				Write-Output 'ERROR: unable to export PFX certificate'
				Return $_
			}
		}
		Default {
			# declare start
			Write-Host "`nExporting certificates per '$Json'"

			# check entry count in configuration file
			If ($JsonData.Count -eq 0) {
				Write-Host "ERROR: no entries found in configuration file: $Json"
				Return
			}

			# process configuration file
			:JsonDatum ForEach ($JsonDatum in $JsonData) {
				switch ($true) {
					([string]::IsNullOrEmpty($JsonDatum.Subject)) {
						Write-Host "ERROR: required entry (Subject) not found in configuration file: $Json"; Continue :JsonDatum
					}
					([string]::IsNullOrEmpty($JsonDatum.Path)) {
						Write-Host "ERROR: required entry (Path) not found in configuration file: $Json"; Continue :JsonDatum
					}
					([string]::IsNullOrEmpty($JsonDatum.Principals)) {
						Write-Host "ERROR: required entry (Principals) not found in configuration file: $Json"; Continue :JsonDatum
					}
					Default {
						# declare JSON entry contents
						Write-Host " - Subject    : '$($JsonDatum.Subject)'"
						Write-Host " - Path       : '$($JsonDatum.Path)'"
						Write-Host " - Principals : '$($JsonDatum.Principals -join ',')'"

						# define required parameters for Export-PfxCertificateToFolder
						$ExportPfxCertificateToFolder = @{
							Subject    = [string]$JsonDatum.Subject
							Path       = [string]$JsonDatum.Path
							Principals = [string[]]$JsonDatum.Principals
						}

						# export PFX certificate to folder
						Try {
							Export-PfxCertificateToFolder @ExportPfxCertificateToFolder
						}
						Catch {
							Write-Host 'ERROR: could not export certificate:' $_.ToString()
							Continue :JsonDatum
						}
					}
				}
			}
		}
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
