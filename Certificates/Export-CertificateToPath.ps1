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
}

Process {
	# verify JSON file
	If (-not (Test-Path -Path $Json)) {
		If ($Add) {
			Try {
				$null = New-Item -ItemType 'File' -Path $Json
			}
			Catch {
				Write-Output "`nERROR: could not create configuration file:"
				Write-Output "$Json`n"
				Return
			}
		}
		Else {
			Write-Output "`nERROR: could not find configuration file:"
			Write-Output "$Json`n"
			Return
		}
	}

	# import JSON data
	$json_data = [array](Get-Content -Path $Json | ConvertFrom-Json)
	
	# evaluate parameters
	switch ($true) {
		$Clear {
			# remove configuration file
			If (Test-Path -Path $Json) {
				Try {
					Remove-Item -Path $Json -Force
					Write-Output "`nCleared configuration file: '$Json'"
				}
				Catch {
					Write-Output "`nERROR: could not clear configuration file: '$Json'"
				}
			}
		}
		$Remove {
			# remove matching entries from object
			Try {
				$json_data = $json_data | Where-Object {
					$_.Subject -ne $Subject
				}
				If ($null -eq $json_data) {
					[string]::Empty | Set-Content -Path $Json
					Write-Output "`nRemoved '$Subject' from configuration file: '$Json'"
				}
				Else {
					$json_data | ConvertTo-Json | Set-Content -Path $Json
					Write-Output "`nRemoved '$Subject' from configuration file: '$Json'"
				}
				$json_data | Select-Object Subject, Path, Principals, Updated
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file: '$Json'"
			}
		}
		$Add {
			# create custom object from parameters then add to object
			Try {
				$json_data += [pscustomobject]@{
					Subject    = [string]$Subject
					Path       = [string]$Path
					Principals = [string[]]$Principals
					Updated    = (Get-Date -Format FileDateTimeUniversal)
				}
				$json_data | ConvertTo-Json | Set-Content -Path $Json
				Write-Output "`nAdded '$Subject' to configuration file: '$Json'"
				$json_data | Select-Object Subject, Path, Principals, Updated
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file: '$Json'"
			}
		}
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
			If ($json_data.Count -eq 0) {
				# ...announce error and return
				Write-Output "ERROR: no entries found in input file: $Json"
				Return
			}
			# if configuration file is not empty...
			Else {
				# ...retrieve entry with matching subject if any
				$Defined = $json_data | Where-Object { $_.Subject -eq $cert_name -and -not [string]::IsNullOrEmpty($_.Path) -and -not [string]::IsNullOrEmpty($_.Principals) } | Select-Object -First 1
			}

			# if defined entry not found in configuration file...
			If ($null -eq $Defined) {
				# ...check for default entry in configuration file
				$Defined = $json_data | Where-Object { $_.Subject -eq '_default' -and -not [string]::IsNullOrEmpty($_.Path) -and -not [string]::IsNullOrEmpty($_.Principals) } | Select-Object -First 1
			}

			# if default entry not found in configuration file...
			If ($null -eq $Defined) {
				# ...announce error and return
				Write-Output "ERROR: unable to locate matching subject or '_default' entry with valid path and principals"
				Return
			}

			# announce $Result values
			Write-Host "`nFound matching configuration entry:"
			Write-Host " - subject    : $($Defined.Subject)"
			Write-Host " - path       : $($Defined.Path)"
			Write-Host " - principals : $($Defined.Principals)"

			# define params for Export-PfxCertificateToPrincipals
			$ExporPfxCertificateToPrincipalsParams = @{
				Name       = $cert_name
				Date       = $cert_date
				Hash       = $cert_hash
				Path       = $Defined.Path
				Principals = $Defined.Principals
			}

			# export pfx certificate to principals
			Try {
				Export-PfxCertificateToPrincipals @ExporPfxCertificateToPrincipalsParams
			}
			Catch {
				Write-Output 'ERROR: unable to export PFX certificate'
				Return $_
			}
		}
		Default {
			Write-Output "`nDisplaying '$Json'`n"
			$json_data | Select-Object Subject, Path, Principals, Updated
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
