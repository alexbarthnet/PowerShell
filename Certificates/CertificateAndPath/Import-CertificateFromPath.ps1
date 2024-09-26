<#
.SYNOPSIS
Imports certificates to the local machine store based upon values in a JSON configuration file.

.DESCRIPTION
Imports certificates to the local machine store based upon values in a JSON configuration file. The JSON identifies the subject of certificate to be imported, the path to the certificate files, and the principals to grant access to the certificate after import.

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
The subject of a certificate file. Required when the Add or Remove parameters are specified.

.PARAMETER Path
The path to search for certificates. Required when the Add parameter is specified.

.PARAMETER Principals
The pricinipals that will be granted read access on any imported certificates. Required when the Add parameter is specified.

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Import-CertificateFromPath.ps1 -Json C:\Content\config.json

.EXAMPLE
.\Import-CertificateFromPath.ps1 -Json C:\Content\config.json -Show

.EXAMPLE
.\Import-CertificateFromPath.ps1 -Json C:\Content\config.json -Clear

.EXAMPLE
.\Import-CertificateFromPath.ps1 -Json C:\Content\config.json -Remove -Subject 'host.example.com'

.EXAMPLE
.\Import-CertificateFromPath.ps1 -Json C:\Content\config.json -Add -Subject 'host.example.com' -Path 'C:\path\' -Principals 'Domain Admins'
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Position = 0, ParameterSetName = 'Default')]
	[switch]$Import,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Show')]
	[switch]$Show,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Position = 0, Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Remove')]
	[Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Add')][ValidatePattern('^[^\*]+$')]
	[string]$Subject,
	[Parameter(Position = 2, Mandatory = $True, ParameterSetName = 'Add')][ValidatePattern('^[^\*]+$')][ValidateScript({ Test-Path -Path $_ })]
	[string]$Path,
	[Parameter(Position = 3, ParameterSetName = 'Add')]
	[string[]]$Principals,
	# path to JSON configuration file
	[Parameter(Mandatory = $True)]
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
	Function Set-CertificatePermissions {
		[CmdletBinding()]
		Param(
			[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ $_ -is [System.Security.Cryptography.X509Certificates.X509Certificate2] })]
			[object]$Certificate,
			[Parameter(Position = 1)][AllowEmptyCollection()]
			[string[]]$Principals,
			[Parameter(Position = 2)]
			[string[]]$RequiredPrincipals = @('BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM'),
			[Parameter(Position = 3)]
			[string[]]$AccessRights = @('Read', 'Synchronize')
		)

		# if certificate has private key...
		If ($Certificate.HasPrivateKey) {
			# if certificate is machine key...
			If ($Certificate.PrivateKey.CspKeyContainerInfo.MachineKeyStore) {
				# retrieve ACL for private key
				$cert_key = [System.Environment]::GetFolderPath('CommonApplicationData') + '\Microsoft\Crypto\RSA\MachineKeys\' + $Certificate.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
				$cert_acl = Get-Acl -Path $cert_key
				$cert_aces = @()

				# check ACL for required ACEs
				ForEach ($Principal in $RequiredPrincipals) {
					If ($null -eq ($cert_acl.Access | Where-Object { $_.IdentityReference -eq $Principal -and $_.FileSystemRights -eq $AccessRights })) {
						Try {
							$cert_aces += New-Object System.Security.AccessControl.FileSystemAccessRule @($Principal, 'FullControl', 'Allow')
							Write-Host "  - ACE Added  : $Principal"
						}
						Catch {
							Write-Host "ERROR: '$($Certificate.Subject)' - could not create ACE for required principal: $Principal"
							Return
						}
					}
					Else {
						Write-Host "  - ACE Found for required principal: $Principal"
					}
				}

				# check ACL for custom ACEs
				ForEach ($Principal in $Principals) {
					If ($null -eq ($cert_acl.Access | Where-Object { $_.IdentityReference -eq $Principal -and $_.FileSystemRights -eq $AccessRights })) {
						Try {
							$cert_aces += New-Object System.Security.AccessControl.FileSystemAccessRule @($Principal, $AccessRights, 'Allow')
							Write-Host "  - ACE Added  : $Principal"
						}
						Catch {
							Write-Host "ERROR: '$($Certificate.Subject)' - could not create ACE for requested principal: $Principal"
							Return
						}
					}
					Else {
						Write-Host "  - ACE Found for requested principal: $Principal"
					}
				}

				# update ACL if required
				If ($cert_aces.Count -gt 0) {
					ForEach ($cert_ace in $cert_aces) { $cert_acl.AddAccessRule($cert_ace) }
					Try {
						$cert_acl | Set-Acl -Path $cert_key
						Write-Host '  - ACE Updated...'
					}
					Catch {
						Write-Host "ERROR: '$($Certificate.Subject)' - could not update private key"
						Return
					}
				}
			}
			Else {
				Write-Host "WARNING: '$($Certificate.Subject)' - certificate is not in the machine store"
			}
		}
		Else {
			Write-Host "WARNING: '$($Certificate.Subject)' - certificate does not have a private key"
		}
	}

	Function Get-CertificateDetails {
		[CmdletBinding()]
		Param(
			[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][AllowNull()]
			[object]$Certificate
		)

		# report certificate details
		Write-Host "  - Subject    : $($Certificate.Subject)"
		Write-Host "  - Issuer     : $($Certificate.Issuer)"
		Write-Host "  - NotBefore  : $($Certificate.NotBefore)"
		Write-Host "  - NotAfter   : $($Certificate.NotAfter)"
		Write-Host "  - Thumbprint : $($Certificate.Thumbprint)"
		Write-Host "  - CertStore  : $($Certificate.PSParentPath.Replace('Microsoft.PowerShell.Security\Certificate::', 'Cert:\'))"
	}

	Function Get-CertificateStore {
		[CmdletBinding()]
		Param(
			[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][AllowNull()]
			[object]$Certificate
		)

		# determine certificate store using subject, issuer, and certificateauthority value from basic constraints extension
		If ($null -eq $Certificate) {
			$cert_store_location = 'Cert:\LocalMachine\My'
			$cert_store_psparent = 'Microsoft.PowerShell.Security\Certificate::LocalMachine\My'
		}
		ElseIf ($Certificate.Extensions.CertificateAuthority -and $Certificate.Subject -eq $Certificate.Issuer) {
			$cert_store_location = 'Cert:\LocalMachine\AuthRoot'
			$cert_store_psparent = 'Microsoft.PowerShell.Security\Certificate::LocalMachine\AuthRoot'
		}
		ElseIf ($Certificate.Extensions.CertificateAuthority -and $Certificate.Subject -ne $Certificate.Issuer) {
			$cert_store_location = 'Cert:\LocalMachine\CA'
			$cert_store_psparent = 'Microsoft.PowerShell.Security\Certificate::LocalMachine\CA'
		}
		Else {
			$cert_store_location = 'Cert:\LocalMachine\My'
			$cert_store_psparent = 'Microsoft.PowerShell.Security\Certificate::LocalMachine\My'
		}

		# return custom object with values
		[PSCustomObject]@{
			Location = $cert_store_location
			PSParent = $cert_store_psparent
		}
	}

	Function Find-CertificateFromFile {
		[CmdletBinding()]
		Param(
			[Parameter(Position = 0, Mandatory = $true)][ValidatePattern('^[^\*]+$')][ValidateScript({ Test-Path -Path $_ })]
			[string]$FilePath
		)

		# create certificate object from file
		Try {
			$cert_object = New-Object 'System.Security.Cryptography.X509Certificates.X509Certificate2' -ArgumentList $FilePath
		}
		Catch {
			Return [PSCustomObject]@{ Imported = $false; Certificate = $null; Store = $null }
		}

		# retrieve certificate store for certificate
		$cert_store = Get-CertificateStore -Certificate $cert_object

		# check incorrect stores for certificates with matching thumbprint then remove certificates
		$certs_with_same_hash = Get-ChildItem -Path 'Cert:\LocalMachine' -Recurse | Where-Object { $_.Thumbprint -eq $cert_object.Thumbprint }
		$certs_in_wrong_store = $certs_with_same_hash | Where-Object { $_.PSParentPath -ne $cert_store.PSParent -and $_.PSParentPath -ne 'Microsoft.PowerShell.Security\Certificate::LocalMachine\Root' }
		ForEach ($cert_in_wrong_store in $certs_in_wrong_store) {
			Write-Host " - removing '$($cert_in_wrong_store.Subject)' from '$($cert_in_wrong_store.Location)'"
			$cert_in_wrong_store | Remove-Item -Confirm:$false
		}

		# retrieve certificate from expected store with matching thumbprint
		$cert_found = Get-ChildItem -Path $cert_store.Location | Where-Object { $_.Thumbprint -eq $cert_object.Thumbprint } | Sort-Object NotBefore | Select-Object -Last 1

		# return certificate already imported if found
		If ($cert_found -is [System.Security.Cryptography.X509Certificates.X509Certificate2]) {
			Return [PSCustomObject]@{ Imported = $true; Certificate = $cert_found; Store = $cert_store }
		}
		Else {
			Return [PSCustomObject]@{ Imported = $false; Certificate = $cert_object; Store = $cert_store }
		}
	}

	Function Import-CertificateFromFile {
		[CmdletBinding()]
		Param(
			[Parameter(Position = 0, Mandatory = $true)][ValidatePattern('^[^\*]+$')][ValidateScript({ Test-Path -Path $_ })]
			[string]$FilePath
		)

		# locate certificate from file
		$cert_found = Find-CertificateFromFile -FilePath $FilePath
		Write-Host " - checking certificate: '$FilePath'"

		# check if certificate is imported
		If ($cert_found.Imported) {
			Write-Host ' - certificate already imported'
		}
		ElseIf ($cert_found.Certificate -is [System.Security.Cryptography.X509Certificates.X509Certificate2]) {
			Write-Host ' - certificate will be imported'
			Try {
				$cert_found.Certificate = Import-Certificate -FilePath $FilePath -CertStoreLocation $cert_found.Store.Location
			}
			Catch {
				Write-Host "ERROR: could not import certificate: $($FilePath.FullName)"
			}
		}
		Else {
			Write-Host "ERROR: could not import certificate: $($FilePath.FullName)"
		}

		# report certificate information
		If ($cert_found.Certificate -is [System.Security.Cryptography.X509Certificates.X509Certificate2]) {
			$cert_found.Certificate | Get-CertificateDetails
		}
	}

	Function Import-ChainCertificates {
		[CmdletBinding()]
		Param(
			[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ $_ -is [System.Security.Cryptography.X509Certificates.X509Certificate2] })]
			[object]$Certificate,
			[Parameter(Position = 1, Mandatory = $true)][ValidateScript({ Test-Path -Path $_ })]
			[string]$Path,
			[Parameter(Position = 2)][ValidatePattern('^[^\*]+$')]
			[string]$Prefix = [string]::Empty
		)

		# build prefix if not provided
		If ([string]::IsNullOrEmpty($Prefix)) {
			# retrieve CNs from subject
			$cert_subject_cn = @()
			$cert_subject_cn += $Certificate.Subject.Split(',') | Where-Object { $_ -match 'CN=' }

			# add a final CN if no CNs are in the subject
			$cert_subject_cn += '_default'

			# retrieve subject and NotBefore from input certificate
			$cert_file_head = $cert_subject_cn[0].Replace('CN=', $null).Trim()
			$cert_file_date = Get-Date -Date $Certificate.NotBefore -Format 'FileDateTimeUniversal'

			# define prefix for exported certificates from input certificate
			$Prefix = $cert_file_head, $cert_file_date -join '_'
		}

		# retrieve files matching cert name
		$cert_chain_files = Get-ChildItem -Path $Path | Where-Object { $_.BaseName -match "^$Prefix" -and ( $_.Extension -match '(\.cer|\.crt|\.pem)') }

		If ($cert_chain_files.Count -eq 0) {
			Write-Host 'WARNING: no chain certificates found'
		}
		Else {
			# process each object in chain_files
			ForEach ($cert_chain_file in $cert_chain_files) {
				Write-Host "`nFound certificate file: '$($cert_chain_file.FullName)'"
				Import-CertificateFromFile -FilePath $cert_chain_file.FullName
			}
		}
	}

	Function Import-PfxCertificateFromFile {
		[CmdletBinding()]
		Param(
			[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ Test-Path -Path $_ })]
			[string]$FilePath,
			[Parameter(Position = 1)]
			[switch]$Validate,
			[Parameter(Position = 2)]
			[string]$ValidationExtension = '.cer',
			[Parameter(Position = 3)][AllowEmptyCollection()]
			[string[]]$Principals
		)

		# retrieve object
		$cert_pfx_file = Get-Item -Path $FilePath
		Write-Host " - checking PFX: '$FilePath'"

		# declare PFX certificate not already imported
		$cert_imported = $false

		# validate PFX using associated public key
		If ($Validate) {
			# define validatation file path as fullname of PFX file where extension replaced with ValidationExtension
			$cert_validation_path = $cert_pfx_file.FullName.Replace($cert_pfx_file.Extension, $ValidationExtension)

			# locate certificate with validatation file
			$cert_found = Find-CertificateFromFile -FilePath $cert_validation_path

			# declare certificate already imported if found and has a private key
			If ($cert_found.Imported -and $cert_found.Certificate.HasPrivateKey) {
				# declare PFX certificate already installed
				Write-Host ' - PFX file already imported'

				# report certificate information
				$cert_imported = $true
			}
		}

		# import certificate if required
		If ($cert_imported -eq $false) {
			Write-Host ' - PFX file will be imported'

			# set certificate store
			If ($null -eq $cert_found) {
				$cert_found = [PSCustomObject]@{ Imported = $false; Certificate = $null; Store = (Get-CertificateStore -Certificate $null) }
			}

			# import PFX
			Try {
				$cert_found.Certificate = Import-PfxCertificate -FilePath $FilePath -CertStoreLocation $cert_found.Store.Location -Exportable
			}
			Catch {
				Write-Host "ERROR: '$FilePath' - could not import PFX file"
			}
		}

		# report certificate information, verify permissions, then import chain
		If ($cert_found.Certificate -is [System.Security.Cryptography.X509Certificates.X509Certificate2]) {
			$cert_found.Certificate | Get-CertificateDetails
			$cert_found.Certificate | Import-ChainCertificates -Path $cert_pfx_file.DirectoryName
			If ($Principals) {
				$cert_found.Certificate | Set-CertificatePermissions -Principals $Principals
			}

			If ($Replace) {
				# get certs matching subject and sort by descending issue date
				$cert_with_same_subject = @()
				$cert_with_same_subject += Get-ChildItem -Path 'Cert:\LocalMachine\My' | Where-Object { $_.Subject -eq $cert_found.Certificate.Subject } | Sort-Object -Property 'NotBefore' -Descending
				# if at least two certs with the same subject...
				If ($cert_with_same_subject.Count -ge 2) {
					# ...get second cert
					$cert_to_replace = $cert_with_same_subject[1]
					# replace old cert with new
					Switch-Certificate -OldCert $cert_to_replace -NewCert $cert_found.Certificate
				}
			}
		}
	}

	Function Import-PfxCertificateFromFolder {
		[CmdletBinding()]
		Param(
			[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ Test-Path -Path $_ -PathType Container })]
			[object]$Path,
			[Parameter(Position = 1, Mandatory = $true)][ValidatePattern('^[^\*]+$')]
			[string]$Subject,
			[Parameter(Position = 2)][AllowEmptyCollection()]
			[string[]]$Principals
		)

		# remove common name identifier if present
		If ($Subject.StartsWith('CN=', [System.StringComparison]::InvariantCultureIgnoreCase)) {
			$Subject = $Subject -replace '^CN='
		}

		# create empty objects
		$PFXFiles = Get-ChildItem -Path $Path | Where-Object { $_.Extension -match '(\.pfx|\.p12)' } | Sort-Object BaseName

		# retrieve PKCS12 files matching $Subject
		If ($Subject -ne '_default') {
			$PFXFiles = $PFXFiles | Where-Object { $_.BaseName.StartsWith($Subject, [System.StringComparison]::InvariantCultureIgnoreCase) } | Select-Object -Last 1
		}

		# if no PFX files found...
		If ($PFXFiles.Count -eq 0) {
			# declare and return
			Write-Host "`nERROR: no certificates found with subject: $Subject"
			Return
		}

		# process each PFX file
		ForEach ($PFXFile in $PFXFiles) {
			# declare state
			Write-Host "`nFound PFX file: '$($PFXFile.FullName)'"

			# define required parameters for Import-PfxCertificateFromFolder
			$ImportPfxCertificateFromFile = @{
				FilePath   = $PFXFile.FullName
				Principals = $Principals
				Validate   = $true
			}

			# import certificate from PFX file
			Try {
				Import-PfxCertificateFromFile @ImportPfxCertificateFromFile
			}
			Catch {
				Throw $_
			}
		}
	}
}

Process {
	# if JSON file found...
	If (Test-Path -Path $Json) {
		# ...create JSON data object as array of PSCustomObjects from JSON file content
		Try {
			$JsonData = [array](Get-Content -Path $Json -ErrorAction Stop | ConvertFrom-Json)
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
				# define required parameters for custom object
				$JsonParameters = [ordered]@{
					Subject    = [string]$Subject
					Path       = [string]$Path
				}

				# define optional parameters for custom object
				If ($PSBoundParameters.ContainsKey('Principals')) {
					$JsonParameters['Principals'] = [string[]]$Principals
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
		# process configuration file
		Default {
			# declare start
			Write-Host "`nImporting certificates per '$Json'"

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
					Default {
						# declare JSON entry contents
						Write-Host " - Subject    : '$($JsonDatum.Subject)'"
						Write-Host " - Path       : '$($JsonDatum.Path)'"

						# define required parameters for Import-PfxCertificateFromFolder
						$ImportPfxCertificateFromFolder = @{
							Subject    = [string]$JsonDatum.Subject
							Path       = [string]$JsonDatum.Path
						}

						# define optional parameters for Import-PfxCertificateFromFolder
						If ($null -ne $JsonDatum.Principals) {
							Write-Host " - Principals : '$($JsonDatum.Principals)'"
							$ImportPfxCertificateFromFolder['Principals'] = [string[]]$JsonDatum.Principals
						}

						# import PFX certificate from folder
						Try {
							Import-PfxCertificateFromFolder @ImportPfxCertificateFromFolder
						}
						Catch {
							Write-Host 'ERROR: could not import certificate:' $_.ToString()
							Continue :JsonDatum
						}
					}
				}
			}
		}
	}
}
