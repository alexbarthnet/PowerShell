[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Position = 0, ParameterSetName = 'Default')]
	[object]$Result,
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
	[Parameter()]
	[string]$Json,
	# local hostname
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

Begin {
	# if JSON file not provided...
	If ([string]::IsNullOrEmpty($Json)) {
		# ...define default JSON file
		$Json = $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.json')
	}

	# if result exists...
	If ($null -ne $Result) {
		# ...define transcript file from script path and start transcript
		Start-Transcript -Path $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, "_$Hostname.txt") -Force
	}

	Function Export-CertificateChainFiles {
		[CmdletBinding()]
		Param(
			[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
			[object]$Certificate,
			[Parameter(Position = 1, Mandatory = $true)][ValidateScript({ Test-Path -Path $_ })]
			[string]$Path,
			[Parameter(Position = 2)]
			[string]$Prefix = [string]::Empty
		)

		# build prefix if not provided
		If ([string]::IsNullOrEmpty($Prefix)) {
			# retrieve subject and NotBefore from input certificate
			$cert_file_head = $Certificate.Subject.Split(',', 2)[0].Split('=', 2)[-1]
			$cert_file_date = Get-Date -Date $Certificate.NotBefore -Format 'FileDateTimeUniversal'
			# define prefix for exported certificates from input certificate
			$Prefix = $cert_file_head, $cert_file_date -join '_'
		}

		# create certificate chain object
		$cert_chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
		$cert_chain.ChainPolicy.RevocationMode = 'NoCheck'

		# build certificate chain
		If ($cert_chain.Build($Certificate)) {
			# start certificate chain counter
			$cert_counter = 0

			# define *format* for certificate chain counter string
			$cert_counter_string_format = "d$($cert_chain.ChainElements.Certificate.Count.ToString().Length)"

			# export certificate chain to path
			ForEach ($cert_element in $cert_chain.ChainElements.Certificate) {
				switch ($cert_element.Subject) {
					$Certificate.Subject {
						# export input certificate
						$cert_chain_tail = 'cert.cer'
						$cert_chain_path = Join-Path -Path $Path -ChildPath ($Prefix, $cert_chain_tail -join '_')
						Write-Host " - exporting public key cert  : $cert_chain_path"
						$null = $cert_element | Export-Certificate -FilePath $cert_chain_path
					}
					$cert_element.Issuer {
						# export root certificate
						$cert_chain_tail = 'root.cer'
						$cert_chain_path = Join-Path -Path $Path -ChildPath ($Prefix, $cert_chain_tail -join '_')
						Write-Host " - exporting CA cert of root  : $cert_chain_path"
						$null = $cert_element | Export-Certificate -FilePath $cert_chain_path
					}
					Default {
						# increment counter for intermediate chain certificates
						$cert_counter++
						# export intermediate chain certificate
						$cert_chain_tail = 'chain' + $cert_counter.ToString($cert_counter_string_format) + '.cer'
						$cert_chain_path = Join-Path -Path $Path -ChildPath ($Prefix, $cert_chain_tail -join '_')
						Write-Host " - exporting CA cert in chain : $cert_chain_path"
						$null = $cert_element | Export-Certificate -FilePath $cert_chain_path
					}
				}
			}
		}
		Else {
			Write-Host "ERROR: building certificate chain for '$($Certificate.Subject)'"
		}
	}

	Function Export-PfxCertificateToPrincipals {
		[CmdletBinding()]
		Param(
			[Parameter(Position = 0, Mandatory = $true)]
			[datetime]$Date,
			[Parameter(Position = 1, Mandatory = $true)]
			[string]$Hash,
			[Parameter(Position = 2, Mandatory = $true)][ValidatePattern('^[^\*]+$')]
			[string]$Name,
			[Parameter(Position = 3, Mandatory = $true)][ValidateScript({ Test-Path -Path $_ })]
			[string]$Path,
			[Parameter(Position = 4, Mandatory = $true)]
			[string[]]$Principals,
			[Parameter(Position = 5)][ValidateScript({ Test-Path -Path $_ })]
			[string]$Store = 'Cert:\LocalMachine\My',
			[Parameter(Position = 5)][ValidateSet({ [Microsoft.CertificateServices.Commands.ExportChainOption].GetEnumValues() })]
			[string]$ChainOption = 'EndEntityCertOnly',
			[Parameter(Position = 5)][ValidateSet({ [Microsoft.CertificateServices.Commands.CryptoAlgorithmOptions].GetEnumValues() })]
			[string]$CryptoAlgorithmOption = 'AES256_SHA256'
		)

		# declare start
		Write-Host "`nExporting private key and certificate chain"

		# retrieve certificate
		$PFXData = $null
		$PFXData = Get-ChildItem -Path $Store | Where-Object { $_.Thumbprint -eq $Hash } | Sort-Object NotBefore | Select-Object -Last 1

		# export certificate and certificate chain to path
		If ($PFXData) {
			# define full path to pfx
			$FileHead = $PFXData.Subject.Split(',', 2)[0].Split('=', 2)[-1]
			$FileDate = Get-Date -Date $PFXData.NotBefore -Format 'FileDateTimeUniversal'
			$FileTail = 'cert.pfx'
			$FilePath = Join-Path -Path $Path -ChildPath ($FileHead, $FileDate, $FileTail -join '_')

			# define params for Export-PfxCertificateToPrincipals
			$ExportPfxCertificateParams = @{
				PFXData               = $PFXData
				FilePath              = $FilePath
				ProtectTo             = $Principals
				ChainOption           = $ChainOption
				CryptoAlgorithmOption = $CryptoAlgorithmOption
			}

			# export PFX file to path
			Write-Host " - exporting keypair to PFX   : $FilePath"
			$null = Export-PfxCertificate @ExportPfxCertificateParams

			# define params for Export-PfxCertificateToPrincipals
			$ExportCertificateChainFiles = @{
				Certificate = $PFXData
				Path        = $Path
			}

			# export certificate chain to path
			$null = Export-CertificateChainFiles @ExportCertificateChainFiles
		}
		Else {
			Write-Host "ERROR: certificate not found with hash: '$Hash'"
		}
	}

	Function Export-PfxCertificateWithSubject {
		[CmdletBinding()]
		Param(
			[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ Test-Path -Path $_ })]
			[object]$Path,
			[Parameter(Position = 1, Mandatory = $true)][ValidatePattern('^[^\*]+$')]
			[string]$Subject,
			[Parameter(Position = 2)][AllowEmptyCollection()]
			[string[]]$Principals
		)

		# create empty objects
		$cert_pfx_files = @()

		# retrieve PKCS12 files matching $Subject
		If ($Subject -eq '_default') {
			$cert_pfx_files += Get-ChildItem -Path $Path | Where-Object { $_.Extension -match '(\.pfx|\.p12)' } | Sort-Object BaseName
		}
		Else {
			$cert_pfx_files += Get-ChildItem -Path $Path | Where-Object { $_.Extension -match '(\.pfx|\.p12)' } | Sort-Object BaseName | Where-Object { $_.BaseName -match "^$Subject" } | Select-Object -Last 1
		}

		# check file count
		If ($cert_pfx_files.Count -eq 0) {
			Write-Host "`nERROR: no certificates found with subject: $Subject"
		}
		Else {
			ForEach ($cert_pfx_file in $cert_pfx_files) {
				Write-Host "`nFound PFX file: '$($cert_pfx_file.FullName)'"
				Import-PfxCertificateFromFile -FilePath $cert_pfx_file.FullName -Principals $Principals -Validate
			}
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

		}
		# clear configuration file
		$Clear {
			If (Test-Path -Path $Json) {
				Try {
					[string]::Empty | Set-Content -Path $Json
					Write-Output "`nCleared configuration file: '$Json'"
				}
				Catch {
					Write-Output "`nERROR: could not clear configuration file: '$Json'"
					Return $_
				}
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
			ForEach ($json_datum in $JsonData) {
				If ([string]::IsNullOrEmpty($json_datum.Subject) -or [string]::IsNullOrEmpty($json_datum.Storage)) {
					Write-Host "ERROR: invalid entry found in configuration file: $Json"
				}
				Else {
					Write-Host " - subject    : '$($json_datum.Subject)'"
					Write-Host " - storage    : '$($json_datum.Storage)'"
					Write-Host " - principals : '$($json_datum.Principals)'"
					Export-PfxCertificateWithSubject -Subject $json_datum.Subject -Path $json_datum.Storage -Principals $json_datum.Principals
				}
			}
		}
	}
}

End {
	# if result exists...
	If ($null -ne $Result) {
		# ...stop transcript
		Stop-Transcript
	}
}
