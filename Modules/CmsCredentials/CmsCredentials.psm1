Function Get-ComputersFromParams {
	<#
	.SYNOPSIS
	Creates a list of computers from inputs.

	.DESCRIPTION
	Creates a list of computers from inputs. Called by multiple functions in this module.

	.PARAMETER ComputerName
	Specifies one or more remote computers.

	.PARAMETER ClusterName
	Specifies one or more remote clusters.

	.PARAMETER Cluster
	Instructs the command to check if the local machine is a cluster and, if so, to execute on all members of the cluster.

	.INPUTS
	None.

	.OUTPUTS
	An array of computer hostnames.

	#>

	[CmdletBinding()]
	param (
		[Parameter(Position = 0)][AllowEmptyCollection()]
		[string[]]$ComputerName,
		[Parameter(Position = 1)][AllowEmptyCollection()]
		[string[]]$ClusterName,
		[Parameter(Position = 2)]
		[switch]$Cluster
	)

	# define empty array
	$ComputersFromParams = @()

	# retrieve local cluster name if requested
	If ($Cluster) {
		$ClusSvc = $null
		$ClusSvc = Get-Service | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -ne 'Disabled' }
		If ($null -ne $ClusSvc) {
			Try { $ClusterName += (Get-Cluster).Name }
			Catch { Write-Host 'ERROR: could not retrieve local cluster name' }
		}
		Else {
			Write-Host 'ERROR: cluster service is not running on local host'
		}
	}

	# add computers to array from ClusterName argument
	If ($ClusterName.Count) {
		ForEach ($cluster_name in $ClusterName) {
			Try {
				$cluster_nodes = $null
				$cluster_nodes = Invoke-Command -ComputerName $cluster_name -ScriptBlock { (Get-ClusterNode).Name }
				$cluster_nodes | ForEach-Object { $ComputersFromParams += $_ }
			}
			Catch {
				Write-Host "ERROR: could not retrieve list of cluster nodes from '$cluster_name'"
			}
		}
	}

	# add computers to array from ComputerName argument
	If ($ComputerName) {
		$ComputerName | ForEach-Object { $ComputersFromParams += $_ }
	}

	# remove duplicate computers
	$ComputersFromParams | Select-Object -Unique
}

Function New-CmsCredentialCertificate {
	<#
	.SYNOPSIS
	Creates a certificate for protecting credentials with CMS.

	.DESCRIPTION
	Creates a self-signed certificate for protecting one or more credentials with CMS.

	.PARAMETER Identity
	Specifies the identity for the CMS credential.

	.PARAMETER Exportable
	Switch parameter to allow the certificate to be exported.

	.PARAMETER FilePath
	Specifies the path for the exported PFX file.

	.PARAMETER Principals
	Specifies the principals to permit to access

	.INPUTS
	None.

	.OUTPUTS
	System.Security.Cryptography.X509Certificates.X509Certificate2

	#>

	[CmdletBinding()]
	Param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$Identity,
		[Parameter(Mandatory = $false)]
		[switch]$Exportable,
		[Parameter(DontShow)]
		[datetime]$NotBefore = [datetime]::Now,
		[Parameter(DontShow)]
		[datetime]$NotAfter = $NotBefore.AddYears(100),
		[Parameter(DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
		[Parameter(DontShow)]
		[string]$Subject = "cms-$Identity",
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# define datetime string
	$NotBeforeString = $NotBefore.ToUniversalTime().ToString('yyyyMMddTHHmmssffffZ')

	# update subject string
	$Subject = "CN=$Subject-$NotBeforeString"

	# define certificate values
	$SelfSignedCertificate = @{
		Subject           = $Subject
		Type              = 'DocumentEncryptionCert'
		HashAlgorithm     = 'SHA512'
		KeyLength         = 4096
		NotBefore         = $NotBefore
		NotAfter          = $NotAfter
		KeyExportPolicy   = $KeyExportPolicy
		CertStoreLocation = $CertStoreLocation
	}

	# if certificate should be exportable...
	If ($PSBoundParameters.ContainsKey('Exportable')) {
		$SelfSignedCertificate['KeyExportPolicy'] = 'ExportableEncrypted'
	}
	Else {
		$SelfSignedCertificate['KeyExportPolicy'] = 'NonExportable'
	}

	# check operating system
	switch ([System.Environment]::OSVersion.Platform) {
		'Win32NT' {
			# create self-signed certificate
			Try {
				$Certificate = New-SelfSignedCertificate @SelfSignedCertificate
			}
			Catch {
				Throw $_
			}
		}
		Default {
			# declare and return null
			Write-Warning 'CmsCredentials cannot create self-signed certificates on non-Windows platforms'
			Return $null
		}
	}

	# if certificate should be exported...
	If ($PSBoundParameters.ContainsKey('FilePath')) {
		# create hashtable for .pfx file
		$ExportPfxCertificate = @{
			Cert                  = $Certificate
			FilePath              = $FilePath
			ChainOption           = 'EndEntityCertOnly'
			CryptoAlgorithmOption = 'AES256_SHA256'
		}

		# add principals to hashtable
		If ($null -ne $Principals) {
			$ExportPfxCertificate['ProtectTo'] = $Principals
		}

		# export certificate as .pfx
		Try {
			$null = Export-PfxCertificate @ExportPfxCertificate
		}
		Catch {
			Throw $_
		}
	}

	# return certificate
	Return $Certificate
}

Function Protect-CmsCredential {
	<#
	.SYNOPSIS
	Protects a credential with CMS.

	.DESCRIPTION
	Protects a credential by encrypting it with a certificate using CMS. The calling user must have read access to the public key of the certificate that will protect the credential.

	.PARAMETER Identity
	Specifies the identity for the CMS credential.

	.PARAMETER Credential
	Specifies the PSCredential object to protect with CMS.

	.PARAMETER Thumbprint
	Specifies the thumbprint for an existing CMS certificate. Cannot be combined with the Reset or Cleanup parameters.

	.PARAMETER Reset
	Specifies that a new CMS certificate is required. Cannot be combined with the Thumbprint parameter.

	.PARAMETER Cleanup
	Specifies that old CMS certificates and credentials for the provided identity should be removed. Cannot be combined with the Thumbprint parameter.

	.PARAMETER Path
	Specifies the path to the folder where the store CMS credential file will be stored. The default value is 'C:\ProgramData\CmsCredentials' and the folder will be created if it does not exist.

	.PARAMETER OutFile
	Specifies the path for the CMS credential file. Providing this parameter will override the value created using Path and Identity parameters.

	.INPUTS
	None.

	.OUTPUTS
	None.

	#>

	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$Identity,
		[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
		[pscredential]$Credential,
		[Parameter(ParameterSetName = 'Thumbprint')]
		[string]$Thumbprint,
		[Parameter(ParameterSetName = 'Default')]
		[bool]$Reset,
		[Parameter(ParameterSetName = 'Default')]
		[bool]$Cleanup = $true,
		[Parameter(Mandatory = $false)]
		[string]$Path = (Join-Path -Path ([System.Environment]::GetFolderPath('CommonApplicationData')) -ChildPath 'CmsCredentials'),
		[Parameter(Mandatory = $false)]
		[string]$OutFile,
		[Parameter(DontShow)]
		[string]$Subject = "cms-$Identity",
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if thumbprint provided...
	If ($PSBoundParameters.ContainsKey('Thumbprint') -eq $true) {
		# retrieve certificate by thumbprint
		Try {
			$Certificate = Get-Item -Path "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning "could not locate certificate on '$Hostname' with thumbprint: $Thumbprint"
			Return
		}
	}
	# if thumbprint not provided and reset not requested...
	ElseIf ($PSBoundParameters.ContainsKey('Reset') -eq $false) {
		# retrieve latest certificate with matching subject
		Try {
			$Certificate = Get-ChildItem -Path 'Cert:\LocalMachine\My' -DocumentEncryptionCert -ErrorAction 'Stop' | Where-Object { $_.Subject -match "^CN=$Subject-" } | Sort-Object -Property 'NotBefore' | Select-Object -Last 1
		}
		Catch {
			Throw $_
		}
	}

	# if certificate not found...
	If ($null -eq $local:Certificate) {
		# create new certificate for identity
		Try {
			$Certificate = New-CmsCredentialCertificate -Identity $Identity
		}
		Catch {
			Write-Warning "could not create certificate on '$Hostname' with identity: $Identity"
			Return
		}
	}

	# if folder path not found...
	If ((Test-Path -Path $Path -PathType Container) -eq $false) {
		# create path
		Try {
			$null = New-Item -ItemType Directory -Path $Path -Verbose -ErrorAction 'Stop'
		}
		Catch {
			Throw $_
		}
	}

	# define datetime string
	$NotBeforeString = $Certificate.NotBefore.ToUniversalTime().ToString('yyyyMMddTHHmmssffffZ')

	# if OutFile not defined...
	If ($PSBoundParameters.ContainsKey('OutFile') -eq $false) {
		# define CMS file path
		$OutFile = Join-Path -Path $Path -ChildPath "$Subject-$NotBeforeString.txt"
	}

	# if CMS file not found...
	If ((Test-Path -Path $OutFile -PathType Leaf) -eq $false) {
		# create CMS file
		Try {
			$null = New-Item -ItemType File -Path $OutFile -Verbose -ErrorAction 'Stop'
		}
		Catch {
			Throw $_
		}
	}

	# create custom object for export
	$InputObject = [pscustomobject]@{
		Username = $Credential.Username
		Password = $Credential.GetNetworkCredential().Password
	}

	# convet custom object into JSON string
	Try {
		$Content = ConvertTo-Json -InputObject $InputObject -ErrorAction 'Stop'
	}
	Catch {
		Throw $_
	}

	# encrypt credentials to local certificate
	Try {
		Protect-CmsMessage -To $Certificate.Thumbprint -Content $Content -OutFile $OutFile -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning 'could not encrypt the CMS file'
		Throw $_
	}

	# if cleanup requested...
	If ($Cleanup) {
		# define parameters for Remove-CmsCredential
		$RemoveCmsCredential = @{
			Identity = $Identity
			Path     = $Path
			SkipLast = 1
		}

		# remove old CMS certificate and files
		Try {
			Remove-CmsCredential @RemoveCmsCredential
		}
		Catch {
			Write-Warning 'could not remove old CMS certificates and files'
			Return $_
		}
	}
}

Function Remove-CmsCredential {
	<#
	.SYNOPSIS
	Removes a credential protected by CMS.

	.DESCRIPTION
	Removes the certificate and encrypted file for a credential protected by CMS.

	.PARAMETER Identity
	Specifies the identity of a CMS credential.

	.PARAMETER Path
	Specifies the path to a folder containing CMS credential files. The default value is 'C:\ProgramData\CmsCredentials'

	.PARAMETER SkipLast
	Specifies the number of objects to skip when removing CMS credential certificates and files. Set to 0 by default.

	.INPUTS
	None.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Remove-CmsCredential -Identity "testcredential"

	.EXAMPLE
	PS> Remove-CmsCredential -Identity "testcredential" -Path "C:\Content\CmsCredentials"

	.EXAMPLE
	PS> Remove-CmsCredential -Identity "testcredential" -SkipLast 1

	.EXAMPLE
	PS> Remove-CmsCredential -Identity "testcredential" -Path "C:\Content\CmsCredentials" -SkipLast 1

	#>

	[CmdletBinding()]
	Param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$Identity,
		[Parameter(Mandatory = $false)]
		[string]$Path = (Join-Path -Path ([System.Environment]::GetFolderPath('CommonApplicationData')) -ChildPath 'CmsCredentials'),
		[Parameter(Mandatory = $false)]
		[uint16]$SkipLast = 0,
		[Parameter(DontShow)]
		[string]$Subject = "cms-$Identity",
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if credential files path found...
	If ((Test-Path -Path $Path -PathType Container) -eq $false) {
		Write-Warning "could not locate path to credential files: $Path"
		Return
	}

	# retrieve old credential files
	$OldFiles = Get-ChildItem -Path $Path -Filter '*.txt' -ErrorAction 'Stop' | Where-Object { $_.BaseName -match "^$Subject-" } | Sort-Object -Property 'LastWriteTime' | Select-Object -SkipLast $SkipLast

	# remove old credential files
	ForEach ($InputObject in $OldFiles) {
		Try {
			Remove-Item -InputObject $InputObject -Force -Verbose -ErrorAction 'Stop'
		}
		Catch {
			Throw $_
		}
	}

	# retrieve old certificates
	$OldCertificates = Get-ChildItem -Path 'Cert:\LocalMachine\My' -DocumentEncryptionCert -ErrorAction 'Stop' | Where-Object { $_.Subject -match "^CN=$Subject-" } | Sort-Object -Property 'NotBefore' | Select-Object -SkipLast $SkipLast

	# remove old certificates
	ForEach ($InputObject in $OldCertificates) {
		Try {
			Remove-Item -InputObject $InputObject -Force -Verbose -ErrorAction 'Stop'
		}
		Catch {
			Throw $_
		}
	}
}

Function Show-CmsCredential {
	<#
	.SYNOPSIS
	Display the identity of one or more credentials protected by CMS.

	.DESCRIPTION
	Display the certificate and encrypted file for one or more credentials protected by CMS.

	.PARAMETER Identity
	Specifies the identity of a specific CMS credential.

	.PARAMETER Path
	Specifies the path to a folder containing CMS credential files. The default value is 'C:\ProgramData\CmsCredentials'

	.INPUTS
	None.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Show-CmsCredential

	.EXAMPLE
	PS> Show-CmsCredential -Identity "testcredential"

	#>

	[CmdletBinding()]
	Param (
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$Identity,
		[Parameter(Mandatory = $false)]
		[string]$Path = (Join-Path -Path ([System.Environment]::GetFolderPath('CommonApplicationData')) -ChildPath 'CmsCredentials'),
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if path to credential files not found...
	If ((Test-Path -Path $Path -PathType Container) -eq $false) {
		Write-Warning "could not locate path to credential files: $Path"
		Return
	}

	# if identity not provided...
	If ($PSBoundParameters.ContainsKey('Identity') -eq $false) {
		# define identity as word character regex
		$Identity = '\w+'
	}

	# define subject using prefix and identity
	$Subject = "cms-$Identity"

	# retrieve credential files
	$CredentialFiles = Get-ChildItem -Path $Path -Filter '*.txt' -ErrorAction 'Stop' | Where-Object { $_.BaseName -match "^$Subject-" }

	# display credential files
	Write-Host "Found '$($CredentialFiles.Count)' credential files"
	$CredentialFiles | Sort-Object -Property 'BaseName' | Format-Table Name, LastWriteTime

	# retrieve credential certificates
	$CredentialCerts = Get-ChildItem -Path 'Cert:\LocalMachine\My' -DocumentEncryptionCert -ErrorAction 'Stop' | Where-Object { $_.Subject -match "^CN=$Subject-" }

	# display credential certificates
	Write-Host "Found '$($CredentialCerts.Count)' credential certificates"
	$CredentialCerts | Sort-Object -Property 'Subject' | Format-Table Subject, NotBefore
}

Function Unprotect-CmsCredential {
	<#
	.SYNOPSIS
	Retrieves a credential protected by CMS.

	.DESCRIPTION
	Retrieves a credential encrypted by a CMS certificate. The calling user must have read access to the private key of the certificate that protects the credential.

	.PARAMETER Identity
	Specifies the identity of the CMS credential.

	.PARAMETER AsPlainText
	Specifies the credential should be returned as a plain-text password. The credential will be returned a PSCustomObject with Username and Password properties.

	.PARAMETER Thumbprint
	Specifies the thumbprint of an existing CMS certificate.

	.PARAMETER Path
	Specifies the path to a folder containing CMS credential files or to a specific CMS credential file. The default value is the 'C:\ProgramData\CmsCredentials' folder.

	.INPUTS
	None.

	.OUTPUTS
	System.Management.Automation.PSCredential or System.Management.Automation.PSCustomObject.

	.EXAMPLE
	PS> Unprotect-CmsCredential -Identity "testcredential"

	.EXAMPLE
	PS> Unprotect-CmsCredential -Identity "testcredential" -AsPlainText

	#>

	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$Identity,
		[Parameter(Mandatory = $false)]
		[switch]$AsPlainText,
		[Parameter(Mandatory = $false)]
		[string]$Thumbprint,
		[Parameter(Mandatory = $false)]
		[string]$Path = (Join-Path -Path ([System.Environment]::GetFolderPath('CommonApplicationData')) -ChildPath 'CmsCredentials'),
		[Parameter(DontShow)]
		[string]$Subject = "cms-$Identity",
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if thumbprint provided...
	If ($PSBoundParameters.ContainsKey('Thumbprint') -eq $true) {
		# retrieve certificate by thumbprint
		Try {
			$Certificate = Get-Item -Path "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning "could not locate certificate on '$Hostname' with thumbprint: $Thumbprint"
			Return
		}
	}
	# if thumbprint not provided...
	Else {
		# retrieve latest certificate with matching subject
		Try {
			$Certificate = Get-ChildItem -Path 'Cert:\LocalMachine\My' -DocumentEncryptionCert -ErrorAction 'Stop' | Where-Object { $_.Subject -match "^CN=$Subject-" } | Sort-Object -Property 'NotBefore' | Select-Object -Last 1
		}
		Catch {
			Throw $_
		}
	}

	# if certificate not found...
	If ($null -eq $local:Certificate) {
		# declare and return
		Write-Warning "could not locate certificate on '$Hostname' with identity: $Identity"
		Throw [System.Management.Automation.ItemNotFoundException]
	}

	# if path is a folder...
	If (Test-Path -Path $Path -PathType 'Container') {
		# retrieve latest certificate file with matching subject
		Try {
			$FilePath = Get-ChildItem -Path $Path -Filter '*.txt' -ErrorAction 'Stop' | Where-Object { $_.BaseName -match "^$Subject-" } | Sort-Object -Property 'LastWriteTime' | Select-Object -Last 1 -ExpandProperty 'FullName'
		}
		Catch {
			Throw $_
		}
	}
	# if path is a file...
	Else {
		# retrieve credential file from path
		Try {
			$FilePath = Get-Item -Path $Path -ErrorAction 'Stop' | Select-Object -ExpandProperty 'FullName'
		}
		Catch {
			Throw $_
		}
	}

	# if file not found...
	If ($null -eq $local:FilePath) {
		# declare and return
		Write-Warning "could not locate file on '$Hostname' with identity: $Identity"
		Throw [System.Management.Automation.ItemNotFoundException]
	}

	# decrypt content of credential file
	Try {
		$InputObject = Unprotect-CmsMessage -Path $FilePath -To $Certificate -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning "could not decrypt content on '$Hostname' using '$($Certificate.Thumbprint)' certificate from file: '$FilePath'"
		Throw $_
	}

	# convert content from JSON string into custom object
	Try {
		$PSCustomObject = ConvertFrom-Json -InputObject $InputObject -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning "could not convert from JSON the decrypted content on '$Hostname' in file: '$FilePath'"
		Throw $_
	}

	# verify username property
	If ($null -eq $PSCustomObject.Username) {
		Write-Warning "could not locate 'Username' property on '$Hostname' in file: '$FilePath'"
		Throw [System.Management.Automation.ItemNotFoundException]
	}

	# verify password property
	If ($null -eq $PSCustomObject.Password) {
		Write-Warning "could not locate 'Password' property on '$Hostname' in file: '$FilePath'"
		Throw [System.Management.Automation.ItemNotFoundException]
	}

	# if plain text requested...
	If ($AsPlainText) {
		# return the PSCustomObject as-is
		Return $PSCustomObject
	}

	# convert password property into secure string
	Try {
		$SecureString = ConvertTo-SecureString -String $PSCustomObject.Password -AsPlainText -Force -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning "could not convert 'Password' property on '$Hostname' to a SecureString"
		Throw $_
	}

	# create PSCredential object
	Try {
		$PSCredential = [System.Management.Automation.PSCredential]::new($PSCustomObject.Username, $SecureString)
	}
	Catch {
		Write-Warning "could not create PSCredential object on '$Hostname' for identity: $Identity"
		Throw $_
	}

	# return PSCredential object
	Return $PSCredential
}

Function Update-CmsCredentialAccess {
	<#
	.SYNOPSIS
	Internal function for updating access to a CMS credential.

	.DESCRIPTION
	Internal function for updating access to a CMS credential. Utilized by Grant-CmsCredentialAccess, Revoke-CmsCredentialAccess, and Reset-CmsCredentialAccess.

	.PARAMETER Identity
	Specifies the identity of the CMS credential.

	.PARAMETER Mode
	Specifies the mode for the function. Must be one of: Grant, Revoke, Reset

	.PARAMETER Principals
	Specifies one or more security principals.

	.PARAMETER Thumbprint
	Specifies the thumbprint of an existing CMS certificate.

	.INPUTS
	None.

	.OUTPUTS
	None.

	#>

	[CmdletBinding(SupportsShouldProcess)]
	Param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$Identity,
		[Parameter(Mandatory = $true, Position = 1)][ValidateSet('Grant', 'Revoke', 'Reset')]
		[string]$Mode,
		[Parameter(Mandatory = $false)]
		[object[]]$Principals,
		[Parameter(Mandatory = $false)]
		[string]$Thumbprint,
		[Parameter(DontShow)]
		[string]$Subject = "cms-$Identity",
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# create list for SIDs
	$SecurityIdentifiers = [System.Collections.Generic.List[System.Security.Principal.SecurityIdentifier]]::new()

	# retrieve SIDs for principals
	If ($Mode -eq 'Reset') {
		# add NT AUTHORITY\SYSTEM
		$SecurityIdentifiers.Add([System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'))
		# add BUILTIN\Administrators
		$SecurityIdentifiers.Add([System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
	}
	Else {
		:NextPrincipal ForEach ($Principal in $Principals) {
			# if principal is SID object...
			If ($Principal -is [System.Security.Principal.SecurityIdentifier]) {
				$SecurityIdentifiers.Add($Principal)
				Continue NextPrincipal
			}

			# if principal is a well-known built-in principal that only translates on a domain controller...
			If ($Principal -eq 'Windows Authorization Access Group' -or $Principal -match '^w+\\Windows Authorization Access Group$') {
				# create SID for well-known built-in principal
				Try {
					$SecurityIdentifier = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-560')
				}
				Catch {
					Throw $_
				}

				# add SID to list and continue
				$SecurityIdentifiers.Add($SecurityIdentifier)
				Continue NextPrincipal
			}

			# if principal is a SID in string format...
			If ($Principal -match '^S-1-\d{1,2}-\d+') {
				# create SID from string
				Try {
					$SecurityIdentifier = [System.Security.Principal.SecurityIdentifier]::new($Principal)
				}
				Catch {
					Throw $_
				}

				# add SID to list and continue
				$SecurityIdentifiers.Add($SecurityIdentifier)
				Continue NextPrincipal
			}

			# if principal is in NT Domain or User Principal Name format...
			If ($Principal -match '^[\w\s\.-]+\\[\w\s\.-]+$' -or $Principal -match '^[\w\.-]+@[\w\.-]+$') {
				# create NT account from principal
				Try {
					$NTAccount = [System.Security.Principal.NTAccount]::new($Principal)
				}
				Catch {
					Throw $_
				}
			}
			# if principal is any other format...
			Else {
				# create NT account for principal with user domain prefixed
				Try {
					$NTAccount = [System.Security.Principal.NTAccount]::new("$([System.Environment]::UserDomainName)\$Principal")
				}
				Catch {
					Throw $_
				}
			}

			# translate NT account to SID
			Try {
				$SecurityIdentifier = $NTAccount.Translate([System.Security.Principal.SecurityIdentifier])
			}
			Catch {
				Throw $_
			}

			# add SID to list and continue
			$SecurityIdentifiers.Add($SecurityIdentifier)
		}
	}

	# if thumbprint provided...
	If ($PSBoundParameters.ContainsKey('Thumbprint') -eq $true) {
		# retrieve certificate by thumbprint
		Try {
			$Certificate = Get-Item -Path "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning "could not locate certificate on '$Hostname' with thumbprint: $Thumbprint"
			Return
		}
	}
	# if thumbprint not provided...
	Else {
		# retrieve latest certificate with matching subject
		Try {
			$Certificate = Get-ChildItem -Path 'Cert:\LocalMachine\My' -DocumentEncryptionCert -ErrorAction 'Stop' | Where-Object { $_.Subject -match "^CN=$Subject-" } | Sort-Object -Property 'NotBefore' | Select-Object -Last 1
		}
		Catch {
			Throw $_
		}
	}

	# if certificate not found...
	If ($null -eq $local:Certificate) {
		# declare and return
		Write-Warning "could not locate certificate on '$Hostname' with identity: $Identity"
		Throw [System.Management.Automation.ItemNotFoundException]
	}

	# if certificate is missing the private key...
	If ($Certificate.HasPrivateKey -eq $false) {
		Write-Warning -Message "could not locate certificate with private key on '$Hostname' with thumbprint: $($Certificate.Thumbprint)"
		Return $null
	}

	# if certificate private key property is populated...
	If ($Certificate.PrivateKey) {
		# define parent path for legacy private keys
		$ParentPath = Join-Path -Path ([System.Environment]::GetFolderPath('CommonApplicationData')) -ChildPath 'Microsoft\Crypto\RSA\MachineKeys'
	}
	Else {
		# define parent path for modern private keys
		$ParentPath = Join-Path -Path ([System.Environment]::GetFolderPath('CommonApplicationData')) -ChildPath 'Microsoft\Crypto\Keys'
	}

	# if certificate is missing algorithm friendly name...
	If ([string]::IsNullOrEmpty($Certificate.PublicKey.Oid.FriendlyName)) {
		Write-Warning -Message "could not retrieve algorithm for certificate on '$Hostname' with thumbprint: $($Certificate.Thumbprint)"
		Return $null
	}

	# retrieve private key child path using algorithm-specific method
	Try {
		switch ($Certificate.PublicKey.Oid.FriendlyName) {
			'DSA' {
				$ChildPath = [System.Security.Cryptography.X509Certificates.DSACertificateExtensions]::GetDSAPrivateKey($Certificate).Key.UniqueName
			}
			'ECDsa' {
				$ChildPath = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($Certificate).Key.UniqueName
			}
			'RSA' {
				$ChildPath = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate).Key.UniqueName
			}
		}
	}
	Catch {
		Write-Warning -Message "could not retrieve private key unique name for certificate on '$Hostname' with thumbprint: $($Certificate.Thumbprint)"
		Return $null
	}

	# if private key child path not found...
	If ([string]::IsNullOrEmpty($ChildPath)) {
		Write-Warning -Message "could not locate private key unique name for certificate on '$Hostname' with thumbprint: $($Certificate.Thumbprint)"
		Return $null
	}

	# retrieve private key path
	$PrivateKeyPath = Join-Path -Path $ParentPath -ChildPath $ChildPath

	# retrieve private key permissions
	Try {
		$PrivateKeyAcl = Get-Acl -Path $PrivateKeyPath -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not retrieve private key ACL for certificate on '$Hostname' with thumbprint: $($Certificate.Thumbprint)"
		Return $null
	}

	# process SIDs
	switch ($Mode) {
		'Grant' {
			ForEach ($SecurityIdentifier in $SecurityIdentifiers) {
				# create 'Read' rule for SID
				$AccessRule = [System.Security.AccessControl.FileSystemAccessRule]::new($SecurityIdentifier, 'Read', 'Allow')
				# add rule to ACL
				$PrivateKeyAcl.AddAccessRule($AccessRule)
			}
		}
		'Revoke' {
			ForEach ($SecurityIdentifier in $SecurityIdentifiers) {
				# remove rule for SID
				$PrivateKeyAcl.PurgeAccessRules($SecurityIdentifier)
			}
		}
		'Reset' {
			ForEach ($IdentityReference in $PrivateKeyAcl.Access.IdentityReference) {
				# remove rule for IdentityReference
				$PrivateKeyAcl.PurgeAccessRules($IdentityReference)
			}
			ForEach ($SecurityIdentifier in $SecurityIdentifiers) {
				# create 'FullControl' rule for SID
				$AccessRule = [System.Security.AccessControl.FileSystemAccessRule]::new($SecurityIdentifier, 'FullControl', 'Allow')
				# add rule to ACL
				$PrivateKeyAcl.AddAccessRule($AccessRule)
			}
		}
	}

	# update ACL on private key
	Try {
		Set-Acl -Path $PrivateKeyPath -AclObject $PrivateKeyAcl -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not update private key ACL for certificate on '$Hostname' with thumbprint: $($Certificate.Thumbprint)"
		Return $null
	}
}

Function Protect-CmsCredentials {
	<#
	.SYNOPSIS
	Protects a credential with CMS.

	.DESCRIPTION
	Creates a CMS certificate and encrypts the credential with the certificate using CMS. The calling user must have read access to the public key of the certificate that will protect the credential.

	.PARAMETER Credential
	Specifies the PSCredential object to be protected with CMS.

	.PARAMETER ComputerName
	Specifies one or more remote computers.

	.PARAMETER ClusterName
	Specifies the nodes of one or more remote clusters.

	.PARAMETER Cluster
	Specifies the nodes of the cluster which the local machine is a member of.

	.INPUTS
	None.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Protect-CmsCredentials -Identity "testcredential"

	.EXAMPLE
	PS> Protect-CmsCredentials -Identity "testcredential" -Prefix "private"

	.EXAMPLE
	PS> Protect-CmsCredentials -Identity "testcredential" -AsPlainText

	.EXAMPLE
	PS> Protect-CmsCredentials -Identity "testcredential" -Prefix "private" -AsPlainText

	#>

	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Mandatory = $True, Position = 0)]
		[string]$Identity,
		[Parameter(Mandatory = $True, ValueFromPipeline = $true)]
		[pscredential]$Credential,
		[Parameter(ParameterSetName = 'Path')]
		[string]$Path,
		[Parameter(ParameterSetName = 'Default')]
		[string[]]$ComputerName,
		[Parameter(ParameterSetName = 'Default')]
		[string[]]$ClusterName,
		[Parameter(ParameterSetName = 'Default')]
		[switch]$Cluster,
		[Parameter(ParameterSetName = 'Default')]
		[switch]$Reset,
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::Machinename).ToLowerInvariant()
	)

	# if parameters for computer name provided...
	If ($PSBoundParameters.ContainsKey('Cluster') -or $PSBoundParameters.ContainsKey('ClusterName') -or $PSBoundParameters.ContainsKey('ComputerName')) {
		# ...get computer names
		$CmsComputers = Get-ComputersFromParams -Cluster:$Cluster -ClusterName $ClusterName -ComputerName $ComputerName
	}
	# if parameters for computer name not provided...
	Else {
		# ...set computer names to localhost
		$CmsComputers = $HostName
	}

	# define parameter hashtable
	$ProtectParameters = @{
		Identity = $Identity
		Cred     = $Cred
		Reset    = $Reset
	}

	# if multiple computers defined or computer is remote...
	If ($CmsComputers.Count -gt 1 -or $CmsComputers -notcontains $Hostname) {
		# define modules for remote session
		$Modules = @('CmsCredentials')

		# retrieve module functions for remote session
		$ModuleFunctions = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleFunction in (Get-Module -Name $ModuleName).ExportedFunctions.Keys) {
				$ModuleFunctions[$ModuleFunction] = (Get-Item -Path function:$ModuleFunction).Definition
			}
		}

		# retrieve module aliases for remote session
		$ModuleAliases = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleAlias in (Get-Module -Name $ModuleName).ExportedAliases.Keys) {
				$ModuleAliases[$ModuleAlias] = (Get-Item -Path alias:$ModuleAlias).Definition
			}
		}
	}

	# protect credentials on each computer
	ForEach ($CmsComputer in $CmsComputers) {
		If ($CmsComputer -eq $Hostname -or $CmsComputer -like "$Hostname.*") {
			# protect credentials on local computer
			Try {
				Protect-CmsCredentialSecret @ProtectParameters
			}
			Catch {
				Write-Error "could not protect credentials on '$CmsComputer'"
			}
		}
		Else {
			# define functions for remote computer
			$NewCmsCredentialCertificate = "function New-CmsCredentialCertificate {${function:New-CmsCredentialCertificate}}"
			$ProtectCmsCredentialSecret = "function Protect-CmsCredentialSecret {${function:Protect-CmsCredentialSecret}}"
			$RemoveCmsCredentialSecret = "function Remove-CmsCredentialSecret {${function:Remove-CmsCredentialSecret}}"
			# protect credentials on remote computer
			Try {
				Invoke-Command -ComputerName $CmsComputer -ScriptBlock {
					# import functions on remote computer
					. ([ScriptBlock]::Create($using:NewCmsCredentialCertificate))
					. ([ScriptBlock]::Create($using:ProtectCmsCredentialSecret))
					. ([ScriptBlock]::Create($using:RemoveCmsCredentialSecret))

					# call functions on remote computer
					Protect-CmsCredentialSecret @using:ProtectParameters

					# # create objects in session
					# $ProtectParameters = $using:ProtectParameters
					# $ModuleFunctions = $using:ModuleFunctions
					# $ModuleAliases = $using:ModuleAliases
					# $CmsComputer = $using:CmsComputer

					# # load functions of local modules in remote session
					# ForEach ($ModuleFunction in $ModuleFunctions.Keys) {
					# 	Try {
					# 		. ([ScriptBlock]::Create("function $ModuleFunction {$ModuleFunctions[$ModuleFunction]}"))
					# 	}
					# 	Catch {
					# 		Write-Host "ERROR: could not define function '$ModuleFunction' on '$CmsComputer'"
					# 		Return
					# 	}
					# }

					# # load aliases of local modules in remote session
					# ForEach ($ModuleAlias in $ModuleAliases.Keys) {
					# 	Try {
					# 		New-Alias -Name $ModuleAlias -Value $ModuleAliases[$ModuleAlias]
					# 	}
					# 	Catch {
					# 		Write-Host "ERROR: could not define alias '$ModuleAlias' on '$CmsComputer'"
					# 		Return
					# 	}
					# }

					# # run commands in remote session
					# Try {
					# 	Protect-CmsCredentialSecret @using:ProtectParameters
					# }
					# Catch {
					# 	Write-Error "could not protect credentials on '$CmsComputer': $($_.ToString())"
					# }
				}
			}
			Catch {
				Write-Error "could not protect credentials on '$CmsComputer'"
			}
		}
	}
}

Function Remove-CmsCredentials {
	<#
	.SYNOPSIS
	Removes a credential protected by CMS.

	.DESCRIPTION
	Removes the certificate and encrypted file for a credential protected by CMS.

	.PARAMETER Identity
	Specifies the identity of a CMS credential.

	.PARAMETER Prefix
	Specifies the prefix for the CMS credential file. Set to 'cms' by default.

	.PARAMETER ComputerName
	Specifies one or more remote computers.

	.PARAMETER ClusterName
	Specifies the nodes of one or more remote clusters.

	.PARAMETER Cluster
	Specifies the nodes of the cluster which the local machine is a member of.

	.INPUTS
	None.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Remove-CmsCredentials -Identity "testcredential"

	.EXAMPLE
	PS> Remove-CmsCredentials -Identity "testcredential" -Prefix "private"

	.EXAMPLE
	PS> Remove-CmsCredentials -Identity "testcredential" -ComputerName "server1", "server2"

	.EXAMPLE
	PS> Remove-CmsCredentials -Identity "testcredential" -ClusterName "cluster1", "cluster2"

	.EXAMPLE
	PS> Remove-CmsCredentials -Identity "testcredential" -Cluster

	.EXAMPLE
	PS> Remove-CmsCredentials -Identity "testcredential" -Prefix "private" -ComputerName "server1", "server2" -ClusterName "cluster1", "cluster2" -Cluster

	#>

	[CmdletBinding()]
	Param(
		[Parameter(Position = 0, Mandatory = $True)]
		[string]$Identity,
		[Parameter(Position = 1)]
		[string]$Prefix = 'cms',
		[Parameter(Position = 2)]
		[string[]]$ComputerName,
		[Parameter(Position = 3)]
		[string[]]$ClusterName,
		[Parameter(Position = 4)]
		[switch]$Cluster,
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::Machinename).ToLowerInvariant()
	)

	# if parameters for computer name provided...
	If ($PSBoundParameters.ContainsKey('Cluster') -or $PSBoundParameters.ContainsKey('ClusterName') -or $PSBoundParameters.ContainsKey('ComputerName')) {
		# ...get computer names
		$CmsComputers = Get-ComputersFromParams -Cluster:$Cluster -ClusterName $ClusterName -ComputerName $ComputerName
	}
	# if parameters for computer name not provided...
	Else {
		# ...set computer names to localhost
		$CmsComputers = $HostName
	}

	# define parameter hashtable
	$RemoveParameters = @{
		Identity = $Identity
		Prefix   = $Prefix
	}

	# if multiple computers defined or computer is remote...
	If ($CmsComputers.Count -gt 1 -or $CmsComputers -notcontains $Hostname) {
		# define modules for remote session
		$Modules = @('CmsCredentials')

		# retrieve module functions for remote session
		$ModuleFunctions = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleFunction in (Get-Module -Name $ModuleName).ExportedFunctions.Keys) {
				$ModuleFunctions[$ModuleFunction] = (Get-Item -Path function:$ModuleFunction).Definition
			}
		}

		# retrieve module aliases for remote session
		$ModuleAliases = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleAlias in (Get-Module -Name $ModuleName).ExportedAliases.Keys) {
				$ModuleAliases[$ModuleAlias] = (Get-Item -Path alias:$ModuleAlias).Definition
			}
		}
	}

	# remove credentials on each computer
	ForEach ($CmsComputer in $CmsComputers) {
		If ($CmsComputer -eq $Hostname -or $CmsComputer -like "$Hostname.*") {
			# remove credentials on local computer
			Try {
				Remove-CmsCredentialSecret @RemoveParameters
			}
			Catch {
				Write-Error "could not remove credentials on '$CmsComputer''"
			}
		}
		Else {
			# define functions for remote computer
			$RemoveCmsCredentialSecret = "function Remove-CmsCredentialSecret {${function:Remove-CmsCredentialSecret}}"
			# remove credentials on remote computer
			Try {
				Invoke-Command -ComputerName $CmsComputer -ScriptBlock {
					# import functions on remote computer
					. ([ScriptBlock]::Create($using:RemoveCmsCredentialSecret))
					# call functions on remote computer
					Remove-CmsCredentialSecret @using:RemoveParameters
				}
			}
			Catch {
				Write-Error "could not remove credentials on '$CmsComputer'"
			}
		}
	}
}

Function Show-CmsCredentials {
	<#
	.SYNOPSIS
	Display a credential protected by CMS.

	.DESCRIPTION
	Display the certificate and encrypted file for a credential protected by CMS.

	.PARAMETER Identity
	Specifies the identity of a CMS credential.

	.PARAMETER Prefix
	Specifies the prefix for the CMS credential file. Set to 'cms' by default.

	.PARAMETER ComputerName
	Specifies one or more remote computers.

	.PARAMETER ClusterName
	Specifies the nodes of one or more remote clusters.

	.PARAMETER Cluster
	Specifies the nodes of the cluster which the local machine is a member of.

	.INPUTS
	None.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Show-CmsCredentials -Identity "testcredential"

	.EXAMPLE
	PS> Show-CmsCredentials -Identity "testcredential" -Prefix "private"

	.EXAMPLE
	PS> Show-CmsCredentials -Identity "testcredential" -ComputerName "server1", "server2"

	.EXAMPLE
	PS> Show-CmsCredentials -Identity "testcredential" -ClusterName "cluster1", "cluster2"

	.EXAMPLE
	PS> Show-CmsCredentials -Identity "testcredential" -Cluster

	.EXAMPLE
	PS> Show-CmsCredentials -Identity "testcredential" -Prefix "private" -ComputerName "server1", "server2" -ClusterName "cluster1", "cluster2" -Cluster

	#>

	[CmdletBinding()]
	Param(
		[Parameter(Position = 0)][AllowEmptyString()]
		[string]$Identity,
		[Parameter(Position = 1)]
		[string]$Prefix = 'cms',
		[Parameter(Position = 2)]
		[string[]]$ComputerName,
		[Parameter(Position = 3)]
		[string[]]$ClusterName,
		[Parameter(Position = 4)]
		[switch]$Cluster,
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::Machinename).ToLowerInvariant()
	)

	# if parameters for computer name provided...
	If ($PSBoundParameters.ContainsKey('Cluster') -or $PSBoundParameters.ContainsKey('ClusterName') -or $PSBoundParameters.ContainsKey('ComputerName')) {
		# ...get computer names
		$CmsComputers = Get-ComputersFromParams -Cluster:$Cluster -ClusterName $ClusterName -ComputerName $ComputerName
	}
	# if parameters for computer name not provided...
	Else {
		# ...set computer names to localhost
		$CmsComputers = $HostName
	}

	# define parameter hashtable
	$ShowParameters = @{
		Identity = $Identity
		Prefix   = $Prefix
	}

	# if multiple computers defined or computer is remote...
	If ($CmsComputers.Count -gt 1 -or $CmsComputers -notcontains $Hostname) {
		# define modules for remote session
		$Modules = @('CmsCredentials')

		# retrieve module functions for remote session
		$ModuleFunctions = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleFunction in (Get-Module -Name $ModuleName).ExportedFunctions.Keys) {
				$ModuleFunctions[$ModuleFunction] = (Get-Item -Path function:$ModuleFunction).Definition
			}
		}

		# retrieve module aliases for remote session
		$ModuleAliases = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleAlias in (Get-Module -Name $ModuleName).ExportedAliases.Keys) {
				$ModuleAliases[$ModuleAlias] = (Get-Item -Path alias:$ModuleAlias).Definition
			}
		}
	}

	# show credentials on each computer
	ForEach ($CmsComputer in $CmsComputers) {
		If ($CmsComputer -eq $Hostname -or $CmsComputer -like "$Hostname.*") {
			# show credentials on local computer
			Try {
				Show-CmsCredentialSecret @ShowParameters
			}
			Catch {
				Write-Error "could not display credentials on '$CmsComputer''"
			}
		}
		Else {
			# show credentials on remote computer
			$ShowFunction = "function Show-CmsCredentialSecret {${function:Show-CmsCredentialSecret}}"
			Try {
				Invoke-Command -ComputerName $CmsComputer -ScriptBlock {
					. ([ScriptBlock]::Create($using:ShowFunction))
					Show-CmsCredentialSecret @using:ShowParameters
				}
			}
			Catch {
				Write-Error "could not display credentials on '$CmsComputer'"
			}
		}
	}
}

Function Grant-CmsCredentialAccess {
	<#
	.SYNOPSIS
	Grants read access to the private key protecting a CMS credential

	.DESCRIPTION
	Grants read access to the private key protecting a CMS credential. This allows the permitted principal to decrypt the CMS credential.

	.PARAMETER Identity
	Specifies the identity of a CMS credential.

	.PARAMETER Principals
	Specifies one or more Active Directory principals.

	.PARAMETER ComputerName
	Specifies one or more remote computers.

	.PARAMETER ClusterName
	Specifies the nodes of one or more remote clusters.

	.PARAMETER Cluster
	Specifies the nodes of the cluster which the local machine is a member of.

	.INPUTS
	None.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Grant-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser"

	.EXAMPLE
	PS> Grant-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser" -ComputerName "server1", "server2"

	.EXAMPLE
	PS> Grant-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser" -ClusterName "cluster1", "cluster2"

	.EXAMPLE
	PS> Grant-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser" -Cluster

	.EXAMPLE
	PS> Grant-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser" -ComputerName "server1", "server2" -ClusterName "cluster1", "cluster2" -Cluster

	#>

	[CmdletBinding()]
	Param(
		[Parameter(Position = 0, Mandatory = $True)]
		[string]$Identity,
		[Parameter(Position = 1, Mandatory = $True)]
		[string[]]$Principals,
		[Parameter(Position = 2)]
		[string[]]$ComputerName,
		[Parameter(Position = 3)]
		[string[]]$ClusterName,
		[Parameter(Position = 4)]
		[switch]$Cluster,
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::Machinename).ToLowerInvariant()
	)

	# if parameters for computer name provided...
	If ($PSBoundParameters.ContainsKey('Cluster') -or $PSBoundParameters.ContainsKey('ClusterName') -or $PSBoundParameters.ContainsKey('ComputerName')) {
		# ...get computer names
		$CmsComputers = Get-ComputersFromParams -Cluster:$Cluster -ClusterName $ClusterName -ComputerName $ComputerName
	}
	# if parameters for computer name not provided...
	Else {
		# ...set computer names to localhost
		$CmsComputers = $HostName
	}

	# define parameter hashtable
	$UpdateParameters = @{
		Mode       = 'Grant'
		Identity   = $Identity
		Principals = $Principals
	}

	# if multiple computers defined or computer is remote...
	If ($CmsComputers.Count -gt 1 -or $CmsComputers -notcontains $Hostname) {
		# define modules for remote session
		$Modules = @('CmsCredentials')

		# retrieve module functions for remote session
		$ModuleFunctions = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleFunction in (Get-Module -Name $ModuleName).ExportedFunctions.Keys) {
				$ModuleFunctions[$ModuleFunction] = (Get-Item -Path function:$ModuleFunction).Definition
			}
		}

		# retrieve module aliases for remote session
		$ModuleAliases = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleAlias in (Get-Module -Name $ModuleName).ExportedAliases.Keys) {
				$ModuleAliases[$ModuleAlias] = (Get-Item -Path alias:$ModuleAlias).Definition
			}
		}
	}

	# grant credential access on each computer
	ForEach ($CmsComputer in $CmsComputers) {
		If ($CmsComputer -eq $Hostname -or $CmsComputer -like "$Hostname.*") {
			# grant credential access on local computer
			Try {
				Update-CmsCredentialAccess @UpdateParameters
			}
			Catch {
				Write-Error "could not grant credential access on '$CmsComputer''"
			}
		}
		Else {
			# grant credential access on remote computer
			Invoke-Command -ComputerName $CmsComputer -ScriptBlock {
				# create objects in session
				$ModuleFunctions = $using:ModuleFunctions
				$ModuleAliases = $using:ModuleAliases
				$CmsComputer = $using:CmsComputer

				# load functions of local modules in remote session
				ForEach ($ModuleFunction in $ModuleFunctions.Keys) {
					Try {
						. ([ScriptBlock]::Create("function $ModuleFunction {$ModuleFunctions[$ModuleFunction]}"))
					}
					Catch {
						Write-Host "could not load function '$ModuleFunction' on '$CmsComputer'"
						Return $_
					}
				}

				# load aliases of local modules in remote session
				ForEach ($ModuleAlias in $ModuleAliases.Keys) {
					Try {
						New-Alias -Name $ModuleAlias -Value $ModuleAliases[$ModuleAlias]
					}
					Catch {
						Write-Host "could not load alias '$ModuleAlias' on '$CmsComputer'"
						Return $_
					}
				}

				# run commands in remote session
				Try {
					Update-CmsCredentialAccess @using:UpdateParameters
				}
				Catch {
					Write-Error "could not grant credential access on '$CmsComputer'"
				}
			}
		}
	}
}

Function Reset-CmsCredentialAccess {
	<#
	.SYNOPSIS
	Resets read access to the private key protecting a CMS credential.

	.DESCRIPTION
	Resets read access to the private key protecting a CMS credential. Only the built-in Administrators and SYSTEM will have access to the private key after this command is run against a CMS credential.

	.PARAMETER Identity
	Specifies the identity of a CMS credential.

	.PARAMETER ComputerName
	Specifies one or more remote computers.

	.PARAMETER ClusterName
	Specifies the nodes of one or more remote clusters.

	.PARAMETER Cluster
	Specifies the nodes of the cluster which the local machine is a member of.

	.INPUTS
	None.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Reset-CmsCredentialAccess -Identity "testcredential"

	.EXAMPLE
	PS> Reset-CmsCredentialAccess -Identity "testcredential" -ComputerName "server1", "server2"

	.EXAMPLE
	PS> Reset-CmsCredentialAccess -Identity "testcredential" -ClusterName "cluster1", "cluster2"

	.EXAMPLE
	PS> Reset-CmsCredentialAccess -Identity "testcredential" -Cluster

	.EXAMPLE
	PS> Reset-CmsCredentialAccess -Identity "testcredential" -ComputerName "server1", "server2" -ClusterName "cluster1", "cluster2" -Cluster

	#>

	[CmdletBinding()]
	Param(
		[Parameter(Position = 0, Mandatory = $True)]
		[string]$Identity,
		[Parameter(Position = 1)]
		[string[]]$ComputerName,
		[Parameter(Position = 2)]
		[string[]]$ClusterName,
		[Parameter(Position = 3)]
		[switch]$Cluster,
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::Machinename).ToLowerInvariant()
	)

	# if parameters for computer name provided...
	If ($PSBoundParameters.ContainsKey('Cluster') -or $PSBoundParameters.ContainsKey('ClusterName') -or $PSBoundParameters.ContainsKey('ComputerName')) {
		# ...get computer names
		$CmsComputers = Get-ComputersFromParams -Cluster:$Cluster -ClusterName $ClusterName -ComputerName $ComputerName
	}
	# if parameters for computer name not provided...
	Else {
		# ...set computer names to localhost
		$CmsComputers = $HostName
	}

	# define parameter hashtable
	$UpdateParameters = @{
		Mode     = 'Reset'
		Identity = $Identity
	}

	# if multiple computers defined or computer is remote...
	If ($CmsComputers.Count -gt 1 -or $CmsComputers -notcontains $Hostname) {
		# define modules for remote session
		$Modules = @('CmsCredentials')

		# retrieve module functions for remote session
		$ModuleFunctions = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleFunction in (Get-Module -Name $ModuleName).ExportedFunctions.Keys) {
				$ModuleFunctions[$ModuleFunction] = (Get-Item -Path function:$ModuleFunction).Definition
			}
		}

		# retrieve module aliases for remote session
		$ModuleAliases = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleAlias in (Get-Module -Name $ModuleName).ExportedAliases.Keys) {
				$ModuleAliases[$ModuleAlias] = (Get-Item -Path alias:$ModuleAlias).Definition
			}
		}
	}

	# reset credential access on each computer
	ForEach ($CmsComputer in $CmsComputers) {
		If ($CmsComputer -eq $Hostname -or $CmsComputer -like "$Hostname.*") {
			# reset credential access on local computer
			Try {
				Update-CmsCredentialAccess @UpdateParameters
			}
			Catch {
				Write-Error "could not reset credential access on '$CmsComputer''"
			}
		}
		Else {
			# reset credential access on remote computer
			Invoke-Command -ComputerName $CmsComputer -ScriptBlock {
				# create objects in session
				$ModuleFunctions = $using:ModuleFunctions
				$ModuleAliases = $using:ModuleAliases
				$CmsComputer = $using:CmsComputer

				# load functions of local modules in remote session
				ForEach ($ModuleFunction in $ModuleFunctions.Keys) {
					Try {
						. ([ScriptBlock]::Create("function $ModuleFunction {$ModuleFunctions[$ModuleFunction]}"))
					}
					Catch {
						Write-Error "could not load function '$ModuleFunction' on '$CmsComputer'"
						Return
					}
				}

				# load aliases of local modules in remote session
				ForEach ($ModuleAlias in $ModuleAliases.Keys) {
					Try {
						New-Alias -Name $ModuleAlias -Value $ModuleAliases[$ModuleAlias]
					}
					Catch {
						Write-Error "could not load alias '$ModuleAlias' on '$CmsComputer'"
						Return
					}
				}

				# run commands in remote session
				Try {
					Update-CmsCredentialAccess @using:UpdateParameters
				}
				Catch {
					Write-Error "could not reset credential access on '$CmsComputer'"
				}
			}
		}
	}
}

Function Revoke-CmsCredentialAccess {
	<#
	.SYNOPSIS
	Revokes read access to the private key protecting a CMS credential

	.DESCRIPTION
	Revokes read access to the private key protecting a CMS credential. This function cannot revoke access to SYSTEM or the built-in Administrators.

	.PARAMETER Identity
	Specifies the identity of a CMS credential.

	.PARAMETER Principals
	Specifies one or more Active Directory principals.

	.PARAMETER ComputerName
	Specifies one or more remote computers.

	.PARAMETER ClusterName
	Specifies the nodes of one or more remote clusters.

	.PARAMETER Cluster
	Specifies the nodes of the cluster which the local machine is a member of.

	.INPUTS
	None.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Revoke-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser"

	.EXAMPLE
	PS> Revoke-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser" -ComputerName "server1", "server2"

	.EXAMPLE
	PS> Revoke-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser" -ClusterName "cluster1", "cluster2"

	.EXAMPLE
	PS> Revoke-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser" -Cluster

	.EXAMPLE
	PS> Revoke-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser" -ComputerName "server1", "server2" -ClusterName "cluster1", "cluster2" -Cluster

	#>

	[CmdletBinding()]
	Param(
		[Parameter(Position = 0, Mandatory = $True)]
		[string]$Identity,
		[Parameter(Position = 1, Mandatory = $True)]
		[string[]]$Principals,
		[Parameter(Position = 2)]
		[string[]]$ComputerName,
		[Parameter(Position = 3)]
		[string[]]$ClusterName,
		[Parameter(Position = 4)]
		[switch]$Cluster,
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::Machinename).ToLowerInvariant()
	)

	# if parameters for computer name provided...
	If ($PSBoundParameters.ContainsKey('Cluster') -or $PSBoundParameters.ContainsKey('ClusterName') -or $PSBoundParameters.ContainsKey('ComputerName')) {
		# ...get computer names
		$CmsComputers = Get-ComputersFromParams -Cluster:$Cluster -ClusterName $ClusterName -ComputerName $ComputerName
	}
	# if parameters for computer name not provided...
	Else {
		# ...set computer names to localhost
		$CmsComputers = $HostName
	}

	# define parameter hashtable
	$UpdateParameters = @{
		Mode       = 'Revoke'
		Identity   = $Identity
		Principals = $Principals
	}

	# if multiple computers defined or computer is remote...
	If ($CmsComputers.Count -gt 1 -or $CmsComputers -notcontains $Hostname) {
		# define modules for remote session
		$Modules = @('CmsCredentials')

		# retrieve module functions for remote session
		$ModuleFunctions = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleFunction in (Get-Module -Name $ModuleName).ExportedFunctions.Keys) {
				$ModuleFunctions[$ModuleFunction] = (Get-Item -Path function:$ModuleFunction).Definition
			}
		}

		# retrieve module aliases for remote session
		$ModuleAliases = @{}
		ForEach ($ModuleName in $Modules) {
			ForEach ($ModuleAlias in (Get-Module -Name $ModuleName).ExportedAliases.Keys) {
				$ModuleAliases[$ModuleAlias] = (Get-Item -Path alias:$ModuleAlias).Definition
			}
		}
	}

	# revoke credential access on each computer
	ForEach ($CmsComputer in $CmsComputers) {
		If ($CmsComputer -eq $Hostname -or $CmsComputer -like "$Hostname.*") {
			# revoke credential access on local computer
			Try {
				Update-CmsCredentialAccess @UpdateParameters
			}
			Catch {
				Write-Error "could not revoke credential access on '$CmsComputer''"
			}
		}
		Else {
			# revoke credential access on remote computer
			Invoke-Command -ComputerName $CmsComputer -ScriptBlock {
				# create objects in session
				$ModuleFunctions = $using:ModuleFunctions
				$ModuleAliases = $using:ModuleAliases
				$CmsComputer = $using:CmsComputer

				# load functions of local modules in remote session
				ForEach ($ModuleFunction in $ModuleFunctions.Keys) {
					Try {
						. ([ScriptBlock]::Create("function $ModuleFunction {$ModuleFunctions[$ModuleFunction]}"))
					}
					Catch {
						Write-Error "could not load function '$ModuleFunction' on '$CmsComputer'"
						Return
					}
				}

				# load aliases of local modules in remote session
				ForEach ($ModuleAlias in $ModuleAliases.Keys) {
					Try {
						New-Alias -Name $ModuleAlias -Value $ModuleAliases[$ModuleAlias]
					}
					Catch {
						Write-Error "could not load alias '$ModuleAlias' on '$CmsComputer'"
						Return
					}
				}

				# update credential access on remote computer
				Try {
					Update-CmsCredentialAccess @using:UpdateParameters
				}
				Catch {
					Write-Error "could not revoke credential access on '$CmsComputer'"
				}
			}
		}
	}
}

# define functions to export
$FunctionsToExport = @(
	'New-CmsCredentialCertificate'
	'Protect-CmsCredential'
	'Remove-CmsCredential'
	'Show-CmsCredential'
	'Unprotect-CmsCredential'
	'Protect-CmsCredentials'
	'Remove-CmsCredentials'
	'Show-CmsCredentials'
	'Unprotect-CmsCredentials'
	'Grant-CmsCredentialAccess'
	'Reset-CmsCredentialAccess'
	'Revoke-CmsCredentialAccess'
	'Update-CmsCredentialAccess'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport