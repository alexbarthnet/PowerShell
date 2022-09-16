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
	[string]$Storage,
	[Parameter(Position = 3, Mandatory = $True, ParameterSetName = 'Add')][ValidatePattern('^[^\*]+$')]
	[string[]]$Principals,
	[Parameter()]
	[string]$Json = $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, '.json'),
	# local hostname
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

Begin {
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

			# define format for certificate chain counter string
			$cert_counter_string_format = "d$($cert_chain.ChainElements.Certificate.Count.ToString().Length)"

			# export certificate chain to storage
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
			[string]$Storage,
			[Parameter(Position = 4, Mandatory = $true)]
			[string[]]$Principals
		)

		# declare start
		Write-Host "`nExporting private key and certificate chain"

		# retrieve certificate
		$cert_object = $null
		$cert_object = Get-ChildItem -Path 'Cert:\LocalMachine\My' | Where-Object { $_.Thumbprint -eq $Hash } | Sort-Object NotBefore | Select-Object -Last 1

		# export certificate and certificate chain to storage
		If ($cert_object) {
			# define full path to pfx
			$cert_file_head = $cert_object.Subject.Split(',', 2)[0].Split('=', 2)[-1]
			$cert_file_date = Get-Date -Date $cert_object.NotBefore -Format 'FileDateTimeUniversal'
			$cert_file_tail = 'cert.pfx'
			$cert_file_name = $cert_file_head, $cert_file_date, $cert_file_tail -join '_'
			$cert_file_path = Join-Path -Path $Storage -ChildPath $cert_file_name

			# export PFX to storage
			Write-Host " - exporting keypair to PFX   : $cert_file_path"
			$null = $cert_object | Export-PfxCertificate -FilePath $cert_file_path -ProtectTo $Principals -ChainOption EndEntityCertOnly -CryptoAlgorithmOption AES256_SHA256

			# export certificate chain to storage
			$cert_object | Export-CertificateChainFiles -Path $Storage
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
	$json_data = @()
	$json_data += Get-Content -Path $Json | ConvertFrom-Json

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
				$json_data | Select-Object Subject, Storage, Principals, Updated
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
					Storage    = [string]$Storage
					Principals = [string[]]$Principals
					Updated    = (Get-Date -Format FileDateTimeUniversal)
				}
				$json_data | ConvertTo-Json | Set-Content -Path $Json
				Write-Output "`nAdded '$Subject' to configuration file: '$Json'"
				$json_data | Select-Object Subject, Storage, Principals, Updated
			}
			Catch {
				Write-Output "`nERROR: could not update configuration file: '$Json'"
			}
		}
		{ $null -ne $Result } {
			# retrieve values from $Result
			$cert_name = $Result.ManagedItem.Name
			$cert_date = $Result.ManagedItem.DateStart
			$cert_hash = $Result.ManagedItem.CertificateThumbPrintHash

			# check for empty values in $Result
			If ([string]::IsNullOrEmpty($cert_name) -or [string]::IsNullOrEmpty($cert_date) -or [string]::IsNullOrEmpty($cert_hash)) {
				Write-Host "ERROR: one or more values from `$Result was null or empty"
				Exit
			}

			# declare values
			Write-Host "`nExporting certificate from `$Result object"
			Write-Host " - subject    : $cert_name"
			Write-Host " - datestart  : $cert_date"
			Write-Host " - thumbprint : $cert_hash"

			# check entry count in configuration file
			If ($json_data.Count -eq 0) {
				Write-Host "ERROR: no entries found in input file: $Json"
				Exit
			}

			# set use default
			$cert_found_match = $false
			$cert_use_default = $true

			# process each entry in configuration file
			ForEach ($json_datum in $json_data) {
				# check entry for matching subject and verify strings for storage and principals
				If ($json_datum.Subject -eq $cert_name -and -not [string]::IsNullOrEmpty($json_datum.Storage) -and -not [string]::IsNullOrEmpty($json_datum.Principals)) {
					$cert_found_match = $true
					$cert_use_default = $false
					$cert_subject = $json_datum.Subject
					$cert_storage = $json_datum.Storage
					$cert_prncpls = $json_datum.Principals
				}
			}

			# process default entry if required
			If ($cert_use_default) {
				# retrieve default entry
				$json_datum = $json_data | Where-Object { $_.Subject -eq '_default' } | Sort-Object -Property 'Updated' | Select-Object -Last 1
				# check for matching subject and verify strings for storage and principals
				If ($json_datum.Subject -eq '_default' -and -not [string]::IsNullOrEmpty($json_datum.Storage) -and -not [string]::IsNullOrEmpty($json_datum.Principals)) {
					$cert_found_match = $true
					$cert_subject = $json_datum.Subject
					$cert_storage = $json_datum.Storage
					$cert_prncpls = $json_datum.Principals
				}
			}

			# declare export details and start
			If ($cert_found_match) {
				Write-Host "`nRetrieving values from configuration file"
				Write-Host " - subject    : $cert_subject"
				Write-Host " - storage    : $cert_storage"
				Write-Host " - principals : $($cert_prncpls -join ',')"
				Export-PfxCertificateToPrincipals -Name $cert_name -Date $cert_date -Hash $cert_hash -Storage $cert_storage -Principals $cert_prncpls
			}
			Else {
				Write-Host "ERROR: unable to locate matching subject or '_default' entry with valid storage and principals"
			}
		}
		Default {
			Write-Output "`nDisplaying '$Json'`n"
			$json_data | Select-Object Subject, Storage, Principals, Updated
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
