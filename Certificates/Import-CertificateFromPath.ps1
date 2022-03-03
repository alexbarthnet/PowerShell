[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Mandatory = $True, ParameterSetName = 'Import')]
	[switch]$Import,
	[Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
	[switch]$Clear,
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[switch]$Remove,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[switch]$Add,
	[Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')][ValidatePattern('^[^\*]+$')]
	[string]$Subject,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')][ValidatePattern('^[^\*]+$')][ValidateScript({ Test-Path -Path $_ })]
	[string]$Storage,
	[Parameter(Mandatory = $True, ParameterSetName = 'Add')]
	[string[]]$Principals,
	[Parameter()][ValidateScript({ Test-Path -Path $_ })]
	[string]$Json
)

Function Set-CertificatePermissions {
	[CmdletBinding()]
	Param(
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ $_ -is [System.Security.Cryptography.X509Certificates.X509Certificate2] })]
		[object]$Certificate,
		[Parameter(Position = 1)][AllowEmptyCollection()]
		[string[]]$Principals,
		[Parameter(Position = 2)]
		[string[]]$RequiredPrincipals = @('BUILTIN\Administrators', 'NT AUTHORITY\SYSTEM')
	)

	# verify certificate has private key
	If ($Certificate.HasPrivateKey) {
		# retrieve ACL for private key
		$cert_key = [System.Environment]::GetFolderPath('CommonApplicationData') + '\Microsoft\Crypto\RSA\MachineKeys\' + $Certificate.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
		$cert_acl = Get-Acl -Path $cert_key
		$cert_aces = @()

		# check ACL for required ACEs
		$AccessRights = 'FullControl'
		ForEach ($Principal in $RequiredPrincipals) {
			If ($null -eq ($cert_acl.Access | Where-Object { $_.IdentityReference -eq $Principal -and $_.FileSystemRights -eq $AccessRights })) {
				Try {
					$cert_aces += New-Object System.Security.AccessControl.FileSystemAccessRule @($Principal, $AccessRights, 'Allow')
					Write-Host "  - ACE Added  : $Principal"
				}
				Catch {
					Write-Host "ERROR: '$($Certificate.Subject)' - could not create ACE for: $Principal"
				}
			}
			Else {
				Write-Host "  - ACE Found  : $Principal"
			}
		}

		# check ACL for custom ACEs
		$AccessRights = @('Read', 'Synchronize')
		ForEach ($Principal in $Principals) {
			If ($null -eq ($cert_acl.Access | Where-Object { $_.IdentityReference -eq $Principal -and $_.FileSystemRights -eq $AccessRights })) {
				Try {
					$cert_aces += New-Object System.Security.AccessControl.FileSystemAccessRule @($Principal, $AccessRights, 'Allow')
					Write-Host "  - ACE Added  : $Principal"
				}
				Catch {
					Write-Host "ERROR: '$($Certificate.Subject)' - could not create ACE for: $Principal"
				}
			}
			Else {
				Write-Host "  - ACE Found  : $Principal"
			}
		}

		# update ACL if required
		If ($cert_aces.Count -gt 0) {
			ForEach ($cert_ace in $cert_aces) { $cert_acl.AddAccessRule($cert_ace) }
			Try {
				$cert_acl | Set-Acl -Path $cert_key
				Write-Host "  - ACE Updated..."
			}
			Catch {
				Write-Host "ERROR: '$($Certificate.Subject)' - could not update private key"
			}
		}
	}
	Else {
		Write-Host "WARNING: '$($Certificate.Subject)' - cannot set key permissions on certificates without a private key"
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
		$cert_subject_cn += "_default"

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
		[Parameter(Position = 3)]
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
		$cert_found.Certificate | Set-CertificatePermissions -Principals $Principals
		$cert_found.Certificate | Import-ChainCertificates -Path $cert_pfx_file.DirectoryName
	}
}

Function Import-PfxCertificateFromFolder {
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

# define configuration file from script path then verify path
If ([string]::IsNullOrEmpty($Json)) {
	$json_path = $PSCommandPath.Replace('.ps1', '.json')
}
Else {
	$json_path = $Json
}
$json_test = Test-Path -Path $json_path

# clear required objects then check file
$json_data = @()
If ($json_test) {
	# retrieve JSON file name
	$json_name = (Get-Item -Path $json_path).Name
	# create object from JSON file
	$json_data += Get-Content -Path $json_path | ConvertFrom-Json
}
Else {
	# define expected JSON file name
	$json_name = Split-Path -Path $json_path -Leaf
}

switch ($true) {
	$Clear {
		Write-Output "Clearing '$json_name'"
		If ($json_test) { Remove-Item -Path $json_path -Force }
	}
	$Remove {
		# remove matching entries from object
		$json_data = $json_data | Where-Object { $_.Subject -ne $Subject }
		$json_data | ConvertTo-Json | Set-Content -Path $json_path
		# declare changes then show current state
		Write-Output "Updating '$json_name' to remove '$Subject'"
		$json_data | Select-Object Subject, Storage, Principals, Updated | Format-Table
	}
	$Add {
		# create custom object from parameters then add to object
		$json_data += [pscustomobject]@{
			Subject    = [string]$Subject
			Storage    = [string]$Storage
			Principals = [string[]]$Principals
			Updated    = (Get-Date -Format FileDateTimeUniversal)
		}
		$json_data | ConvertTo-Json | Set-Content -Path $json_path
		# declare changes then show current state
		Write-Output "Updating '$json_name' to add '$Subject'"
		$json_data | Select-Object Subject, Storage, Principals, Updated | Format-Table
	}
	$Import {
		Try {
			# define transcript file from script path and start transcript
			Start-Transcript -Path $PSCommandPath.Replace('.ps1', '.txt') -Force

			# declare start
			Write-Host "`nImporting certificates from '$json_name'"

			# check entry count in configuration file
			If ($json_data.Count -eq 0) {
				Write-Host "ERROR: no entries found in configuration file: $json_name"
				Return
			}

			# process configuration file
			ForEach ($json_datum in $json_data) {
				If ([string]::IsNullOrEmpty($json_datum.Subject) -or [string]::IsNullOrEmpty($json_datum.Storage)) {
					Write-Host "ERROR: invalid entry found in configuration file: $json_name"
				}
				Else {
					Write-Host " - subject    : '$($json_datum.Subject)'"
					Write-Host " - storage    : '$($json_datum.Storage)'"
					Write-Host " - principals : '$($json_datum.Principals)'"
					Import-PfxCertificateFromFolder -Subject $json_datum.Subject -Path $json_datum.Storage -Principals $json_datum.Principals
				}
			}
		}
		Finally {
			# stop transscript
			Write-Host ([string]::Empty)
			Stop-Transcript
		}
	}
	Default {
		Write-Output "Displaying '$json_name'"
		$json_data | Select-Object Subject, Storage, Principals, Updated | Format-Table
	}
}
