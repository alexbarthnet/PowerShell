Function Get-CertificatePrivateKeyPath {
	<#
	.SYNOPSIS
	Returns the path to the private key of an X.509 certificate.

	.DESCRIPTION
	Returns the path to the private key of an X.509 certificate.

	.PARAMETER Certificate
	Specifies an X.509 certificate object. Cannot be combined with the Thumbprint parameter.

	.PARAMETER Thumbprint
	Specifies the thumbprint of an X.509 certificate. Cannot be combined with the Certificate parameter.

	.PARAMETER CertStoreLocation
	Specifices the path to the certificate store to search for a certificate by thumbprint when the Thumbprint parameter is specified.

	.INPUTS
	X509Certificate2. An object representing an X.509 certificate.

	.OUTPUTS
	System.String. A string representing the path to the private key for the input.

	.NOTES
	The path to a private key is defined by the cryptographic service provider (CSP).

	.LINK
	https://learn.microsoft.com/en-us/windows/win32/seccng/key-storage-and-retrieval#key-directories-and-files

	#>
	[CmdletBinding(DefaultParameterSetName = 'Certificate')]
	Param(
		[Parameter(ParameterSetName = 'Certificate', Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
		[Parameter(ParameterSetName = 'Thumbprint', Position = 0, Mandatory = $true)]
		[string]$Thumbprint,
		[Parameter(ParameterSetName = 'Thumbprint', Position = 1, Mandatory = $false)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if thumbprint provided...
	If ($PSCmdlet.ParameterSetName -eq 'Thumbprint') {
		Try {
			$Certificate = Get-Item -Path "$CertStoreLocation\$Thumbprint"
		}
		Catch {
			Write-Warning -Message "could not locate certificate in '$CertStoreLocation' on '$Hostname' for provided thumbprint: $Thumbprint"
			Return $null
		}
	}

	# if certificate does not have a private key...
	If ($Certificate.HasPrivateKey -eq $false) {
		Write-Warning -Message "could not locate private key on '$Hostname' for certificate with thumbprint: $($Certificate.Thumbprint)"
		Return $null
	}

	# retrieve algorithm for keypair
	$Algorithm = $Certificate.PublicKey.Oid.FriendlyName

	# retrieve private key using algorithm-specific method
	switch ($Algorithm) {
		'DSA' {
			$PrivateKey = [System.Security.Cryptography.X509Certificates.DSACertificateExtensions]::GetDSAPrivateKey($Certificate)
		}
		'ECDsa' {
			$PrivateKey = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($Certificate)
		}
		'RSA' {
			$PrivateKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
		}
		Default {
			Write-Warning -Message "found unsupported '$Algorithm' algorithm on '$Hostname' for certificate with thumbprint: $($Certificate.Thumbprint)"
			Return $null
		}
	}

	# if private key was not retrieved...
	If ($null -eq $PrivateKey) {
		Write-Verbose -Message "could not retrieve private key on '$Hostname' for certificate with thumbprint: $($Certificate.Thumbprint)"
		Return $null
	}

	# retrieve private key unique name
	$UniqueName = $PrivateKey.Key.UniqueName

	# if certificate is machine key...
	If ($PrivateKey.Key.IsMachineKey) {
		# define machine key container
		$Path = Join-Path -Path ([System.Environment]::GetFolderPath('CommonApplicationData')) -ChildPath 'Microsoft\Crypto'
	}
	# if certificate is not machine key...
	Else {
		# define user key container
		$Path = Join-Path -Path ([System.Environment]::GetFolderPath('ApplicationData')) -ChildPath 'Microsoft\Crypto'
	}

	# search key container for private key file
	Try {
		$PrivateKeyPath = Get-ChildItem -Path $Path -Recurse -Filter $UniqueName | Select-Object -First 1 -ExpandProperty FullName
	}
	Catch {
		Write-Warning -Message "could not search '$Path' path on '$Hostname' for object with unique name: $UniqueName"
		Throw $_
	}

	# if private key file found...
	If ($PrivateKeyPath) {
		Return $PrivateKeyPath
	}
	Else {
		Write-Warning -Message "could not find path to private key on '$Hostname' for certificate with thumbprint: $($Certificate.Thumbprint)"
		Return $null
	}
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

	# create GUID
	$GuidString = [Guid]::NewGuid().ToString()

	# update subject string
	$Subject = "CN=$Subject-$GuidString"

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

Function Get-CmsCredential {
	<#
	.SYNOPSIS
	Retrieves a credential protected by CMS.

	.DESCRIPTION
	Retrieves a credential encrypted by a CMS certificate. The calling user must have read access to the private key of the certificate that protects the credential.

	.PARAMETER Identity
	Specifies the identity of the CMS credential. Cannot be combined with the FilePath parameter.

	.PARAMETER Path
	Specifies the path to a folder containing CMS credential files. The default value is the 'C:\ProgramData\CmsCredentials' folder.

	.PARAMETER FilePath
	Specifies the path to a CMS credential file. Cannot be combined with the Identity parameter.

	.PARAMETER AsPlainText
	Specifies the credential should be returned as a plain-text password. The credential will be returned a PSCustomObject with Username and Password properties.

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
		[Parameter(ParameterSetName = 'FilePath', Position = 0, Mandatory)]
		[string]$FilePath,
		[Parameter(ParameterSetName = 'Default', Position = 0, Mandatory)]
		[string]$Identity,
		[Parameter(ParameterSetName = 'Default', Position = 1)]
		[string]$Path = (Join-Path -Path ([System.Environment]::GetFolderPath('CommonApplicationData')) -ChildPath 'CmsCredentials'),
		[Parameter(ParameterSetName = 'Default', DontShow)]
		[string]$Subject = "cms-$Identity",
		[Parameter(Mandatory = $false)]
		[switch]$AsPlainText,
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if file path provided and path is not a file...
	If ($PSCmdLet.ParameterSetName -eq 'FilePath' -and (Test-Path -Path $FilePath -PathType 'Leaf') -eq $false) {
		# declare and return
		Write-Warning "could not locate file with path: $FilePath"
		Throw [System.Management.Automation.ItemNotFoundException]
	}

	# if identity provided...
	If ($PSCmdLet.ParameterSetName -eq 'Default' -and (Test-Path -Path $Path -PathType 'Container') -eq $true) {
		# retrieve latest credential file with matching subject
		Try {
			$FilePath = Get-ChildItem -Path $Path -Filter '*.txt' -File -ErrorAction 'Stop' | Where-Object { $_.BaseName -match "^$Subject-" } | Sort-Object -Property 'LastWriteTime' | Select-Object -Last 1 -ExpandProperty 'FullName'
		}
		Catch {
			Throw $_
		}
	}

	# if file not found...
	If ([string]::IsNullOrEmpty($local:FilePath)) {
		# declare and return
		Write-Warning "could not locate file for '$Identity' identity in path: $Path"
		Throw [System.Management.Automation.ItemNotFoundException]
	}

	# define parameters for Unprotect-CmsMessage
	$UnprotectCmsMessage = @{
		Path        = $FilePath
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# define optional parameters for Unprotect-CmsMessage
	If ($null -ne $local:Certificate) {
		$UnprotectCmsMessage['To'] = $Certificate
	}

	# decrypt content of credential file
	Try {
		$InputObject = Unprotect-CmsMessage @UnprotectCmsMessage
	}
	Catch {
		Write-Warning "could not decrypt content in file: '$FilePath'"
		Throw $_
	}

	# convert content from JSON string into custom object
	Try {
		$PSCustomObject = ConvertFrom-Json -InputObject $InputObject -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning "could not convert decrypted content in file: '$FilePath'"
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

	.PARAMETER ComputerName
	Specifies the name of one or more remote computers.

	.INPUTS
	None.

	.OUTPUTS
	None.

	#>

	[CmdletBinding(DefaultParameterSetName = 'Identity')]
	Param (
		[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
		[pscredential]$Credential,
		[Parameter(ParameterSetName = 'Thumbprint', Mandatory = $true, Position = 0)]
		[string]$Thumbprint,
		[Parameter(ParameterSetName = 'Identity', Mandatory = $true, Position = 0)]
		[string]$Identity,
		[Parameter(ParameterSetName = 'Identity')]
		[switch]$Reset,
		[Parameter(ParameterSetName = 'Identity')]
		[switch]$SkipCleanup,
		[Parameter(Mandatory = $false)]
		[string]$Path = (Join-Path -Path ([System.Environment]::GetFolderPath('CommonApplicationData')) -ChildPath 'CmsCredentials'),
		[Parameter(Mandatory = $false)]
		[string]$OutFile,
		[Parameter(Mandatory = $false)]
		[string[]]$ComputerName,
		[Parameter(Mandatory = $false)]
		[switch]$Force,
		[Parameter(DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
		[Parameter(DontShow)]
		[string]$Subject = "cms-$Identity",
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if computername provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# remove ComputerName parameter from bound parameters
		$null = $PSBoundParameters.Remove('ComputerName')

		# define functions for remote computers
		$CertificateFunction = "function New-CmsCredentialCertificate {${function:New-CmsCredentialCertificate}}"
		$ProtectFunction = "function Protect-CmsCredential {${function:Protect-CmsCredential}}"
		$RemoveFunction = "function Remove-CmsCredential {${function:Remove-CmsCredential}}"

		# show credentials on remote computer
		ForEach ($RemoteComputerName in $ComputerName) {
			# if remote computer name is local computer name...
			If ($RemoteComputerName -match "^$Hostname$" -or $RemoteComputerName -match "^$Hostname\..+") {
				# set include local computer then continue
				$local:IncludeLocalComputer = $true
				Continue
			}
			# run function on remote computer
			Try {
				Invoke-Command -ComputerName $RemoteComputerName -ScriptBlock {
					. ([ScriptBlock]::Create($using:CertificateFunction))
					. ([ScriptBlock]::Create($using:ProtectFunction))
					. ([ScriptBlock]::Create($using:RemoveFunction))
					Protect-CmsCredential @using:PSBoundParameters
				}
			}
			Catch {
				Write-Warning "could not protect CMS credentials on '$RemoteComputerName' computer: $($_.Exception.Message)"
				Return
			}
		}

		# if include local computer not set...
		If ($null -eq $local:IncludeLocalComputer) {
			# return after running function on remote computers
			Return
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
			Throw $_
		}
	}
	# if thumbprint not provided and reset not requested...
	ElseIf ($PSBoundParameters.ContainsKey('Reset') -eq $false) {
		# retrieve latest certificate with matching subject
		Try {
			$Certificate = Get-ChildItem -Path 'Cert:\LocalMachine\My' -DocumentEncryptionCert -ErrorAction 'Stop' | Where-Object { $_.Subject -match "^CN=$Subject-" } | Sort-Object -Property 'NotBefore' | Select-Object -Last 1
		}
		Catch {
			Write-Warning "could not retrieve certificates on '$Hostname' for identity: $Identity"
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
			Throw $_
		}
	}

	# if folder path not found...
	If ((Test-Path -Path $Path -PathType Container) -eq $false) {
		# create path
		Try {
			$null = New-Item -ItemType Directory -Path $Path -Verbose -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning "could not create folder on '$Hostname' with path: $Path"
			Throw $_
		}
	}

	# create child path from subject
	Try {
		$ChildPath = ($Certificate.Subject -replace '^CN=') + '.txt'
	}
	Catch {
		Write-Warning "could not create child path on '$Hostname' from certificate with subject: $($Certificate.Subject)"
		Throw $_
	}
	
	# if OutFile not defined...
	If ($PSBoundParameters.ContainsKey('OutFile') -eq $false) {
		# define CMS file path
		$OutFile = Join-Path -Path $Path -ChildPath $ChildPath
	}

	# if CMS file found...
	If (Test-Path -Path $OutFile -PathType 'Leaf') {
		# if force not set...
		If (!$Force) {
			Write-Warning "existing credential file found; continue to overwrite file on '$Hostname' with path: $OutFile" -WarningAction Inquire
		}
	}
	# if CMS file not found...
	Else {
		# create CMS file
		Try {
			$null = New-Item -ItemType File -Path $OutFile -Verbose -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning "could not create file on '$Hostname' with path: $OutFile"
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
		Write-Warning "could not convert custom object on '$Hostname' for identity: $Identity"
		Throw $_
	}

	# encrypt credentials to local certificate
	Try {
		Protect-CmsMessage -To $Certificate.Thumbprint -Content $Content -OutFile $OutFile -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning "could not encrypt credential using '$($Certificate.Thumbprint)' thumbprint on '$Hostname' for identity: $Identity"
		Throw $_
	}

	# if skip cleanup not requested...
	If (!$SkipCleanup) {
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
			Write-Warning "could not remove old CMS certificates and files on '$Hostname' for identity: $Identity"
			Throw $_
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
	Specifies the path to a folder containing CMS credential files. The default value is 'C:\ProgramData\CmsCredentials'.

	.PARAMETER SkipLast
	Specifies the number of objects to skip when removing CMS credential certificates and files. Set to 0 by default.

	.PARAMETER ComputerName
	Specifies the name of one or more remote computers.

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
		[Parameter(Mandatory = $false)]
		[string[]]$ComputerName,
		[Parameter(DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
		[Parameter(DontShow)]
		[string]$Subject = "cms-$Identity",
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if computername provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# remove ComputerName parameter from bound parameters
		$null = $PSBoundParameters.Remove('ComputerName')

		# define functions for remote computers
		$RemoveFunction = "function Remove-CmsCredential {${function:Remove-CmsCredential}}"

		# show credentials on remote computer
		ForEach ($RemoteComputerName in $ComputerName) {
			# if remote computer name is local computer name...
			If ($RemoteComputerName -match "^$Hostname$" -or $RemoteComputerName -match "^$Hostname\..+") {
				# set include local computer then continue
				$local:IncludeLocalComputer = $true
				Continue
			}
			# run function on remote computer
			Try {
				Invoke-Command -ComputerName $RemoteComputerName -ScriptBlock {
					. ([ScriptBlock]::Create($using:RemoveFunction))
					Remove-CmsCredential @using:PSBoundParameters
				}
			}
			Catch {
				Write-Warning "could not remove CMS credential on '$RemoteComputerName' computer: $($_.Exception.Message)"
				Return
			}
		}

		# if include local computer not set...
		If ($null -eq $local:IncludeLocalComputer) {
			# return after running function on remote computers
			Return
		}
	}

	# if credential files path found...
	If ((Test-Path -Path $Path -PathType Container) -eq $false) {
		Write-Warning "could not locate path to credential files: $Path"
		Return
	}

	# retrieve old credential files
	Try {
		$Files = Get-ChildItem -Path $Path -Filter '*.txt' -File -ErrorAction 'Stop' | Where-Object { $_.BaseName -match "^$Subject-" } | Sort-Object -Property 'LastWriteTime' | Select-Object -SkipLast $SkipLast
	}
	Catch {
		Write-Warning "could not search for credential files on '$Hostname' in path: $Path"
		Throw $_
	}

	# remove old credential files
	ForEach ($Item in $Files) {
		Try {
			Remove-Item -Path $Item.PSPath -Force -Verbose -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not remove file on '$Hostname' with path: $($Item.PSPath)"
			Throw $_
		}
	}

	# retrieve old certificates
	Try {
		$Certificates = Get-ChildItem -Path $CertStoreLocation -DocumentEncryptionCert -ErrorAction 'Stop' | Where-Object { $_.Subject -match "^CN=$Subject-" } | Sort-Object -Property 'NotBefore' | Select-Object -SkipLast $SkipLast
	}
	Catch {
		Write-Warning "could not search for credential certificates on '$Hostname' in path: $CertStoreLocation"
		Throw $_
	}

	# remove old certificates
	ForEach ($Item in $Certificates) {
		Try {
			Remove-Item -Path $Item.PSPath -Force -Verbose -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not remove certificate on '$Hostname' with path: $($Item.PSPath)"
			Throw $_
		}
	}
}

Function Show-CmsCredential {
	<#
	.SYNOPSIS
	Displays information about one or more credentials protected by CMS.

	.DESCRIPTION
	Displays the identity, GUID, certificate and encrypted file for one or more credentials protected by CMS.

	.PARAMETER Identity
	Specifies the identity of a specific CMS credential.

	.PARAMETER Path
	Specifies the path to a folder containing CMS credential files. The default value is 'C:\ProgramData\CmsCredentials'.

	.PARAMETER ComputerName
	Specifies the name of one or more remote computers.

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
		[Parameter(Mandatory = $false)]
		[string[]]$ComputerName,
		[Parameter(DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if computername provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# remove ComputerName parameter from bound parameters
		$null = $PSBoundParameters.Remove('ComputerName')

		# define functions for remote computers
		$ShowFunction = "function Show-CmsCredential {${function:Show-CmsCredential}}"

		# show credentials on remote computer
		ForEach ($RemoteComputerName in $ComputerName) {
			# if remote computer name is local computer name...
			If ($RemoteComputerName -match "^$Hostname$" -or $RemoteComputerName -match "^$Hostname\..+") {
				# set include local computer then continue
				$local:IncludeLocalComputer = $true
				Continue
			}
			# run function on remote computer
			Try {
				Invoke-Command -ComputerName $RemoteComputerName -ScriptBlock {
					. ([ScriptBlock]::Create($using:ShowFunction))
					Show-CmsCredential @using:PSBoundParameters
				}
			}
			Catch {
				Write-Warning "could not display CMS credentials on '$RemoteComputerName' computer: $($_.Exception.Message)"
				Return
			}
		}

		# if include local computer not set...
		If ($null -eq $local:IncludeLocalComputer) {
			# return after running function on remote computers
			Return
		}
	}

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
	Try {
		$CredentialFiles = Get-ChildItem -Path $Path -Filter '*.txt' -File -ErrorAction 'Stop' | Where-Object { $_.BaseName -match "^$Subject-" }
	}
	Catch {
		Write-Warning "could not retrieve credential files on '$Hostname' from path: $Path"
		Return
	}

	# retrieve credential certificates
	Try {
		$CredentialCerts = Get-ChildItem -Path $CertStoreLocation -DocumentEncryptionCert -ErrorAction 'Stop' | Where-Object { $_.Subject -match "^CN=$Subject-" }
	}
	Catch {
		Write-Warning "could not retrieve credential certificates on '$Hostname'"
		Return
	}

	# create list for credential details
	$List = [System.Collections.Generic.List[System.Object]]::new()

	# add credential files to list
	ForEach ($CredentialFile in $CredentialFiles) {
		# retrieve identity and datetime from credential file
		$Identity, $Guid = $CredentialFile.BaseName -replace '^cms-' -split '-', 2
		# check list for existing entries
		$Entry = $List | Where-Object { $_.Identity -eq $Identity -and $_.DateTime -eq $DateTime }
		# if entry found...
		If ($null -ne $Entry) {
			# update credential entry
			$Entry.Path = $CredentialFile.FullName
		}
		# if entry not found...
		Else {
			# create credential entry
			$ListEntry = [PSCustomObject]@{
				Identity      = $Identity
				Guid          = $Guid
				Thumbprint    = [string]::Empty
				Path          = $CredentialFile.FullName
				LastWriteTime = $CredentialFile.LastWriteTime
			}
			# add new credential entry to list
			$List.Add($ListEntry)
		}
	}

	# add credential files to list
	ForEach ($CredentialCert in $CredentialCerts) {
		# retrieve identity and datetime from credential file
		$Identity, $Guid = $CredentialCert.Subject -replace '^CN=cms-' -split '-', 2
		# check list for existing entries
		$Entry = $List | Where-Object { $_.Identity -eq $Identity -and $_.DateTime -eq $DateTime }
		# if entry found...
		If ($null -ne $Entry) {
			# update credential entry
			$Entry.Thumbprint = $CredentialCert.Thumbprint
		}
		# if entry not found...
		Else {
			# create credential entry
			$ListEntry = [PSCustomObject]@{
				Identity      = $Identity
				Guid          = $Guid
				Thumbprint    = $CredentialCert.Thumbprint
				Path          = [string]::Empty
				LastWriteTime = $CredentialCert.NotBefore
			}
			# add new credential entry to list
			$List.Add($ListEntry)
		}
	}

	# display list entries
	Write-Host "Found '$($List.Count)' credentials"
	$List | Sort-Object -Property 'Identity', 'LastWriteTime' | Format-Table Identity, Guid, Thumbprint, Path
}

Function Update-CmsCredentialAccess {
	<#
	.SYNOPSIS
	Internal function for updating access to the private key protecting a CMS credential

	.DESCRIPTION
	Internal function for updating access to the private key protecting a CMS credential. Utilized by Grant-CmsCredentialAccess, Revoke-CmsCredentialAccess, and Reset-CmsCredentialAccess.

	.PARAMETER Identity
	Specifies the identity of a CMS credential. Cannot be combined with the Thumbprint parameter.

	.PARAMETER Thumbprint
	Specifies the thumbprint of a certificate protecting a CMS credential. Cannot be combined with the Identity parameter.

	.PARAMETER Mode
	Specifies the mode for the function. Must be one of: Grant, Revoke, Reset

	.PARAMETER Principals
	Specifies one or more security principals.

	.INPUTS
	None.

	.OUTPUTS
	None.

	#>

	[CmdletBinding(SupportsShouldProcess)]
	Param (
		[Parameter(ParameterSetName = 'Thumbprint', Mandatory = $true, Position = 0)]
		[string]$Thumbprint,
		[Parameter(ParameterSetName = 'Identity', Mandatory = $true, Position = 0)]
		[string]$Identity,
		[Parameter(Mandatory = $true, Position = 1)][ValidateSet('Grant', 'Revoke', 'Reset')]
		[string]$Mode,
		[Parameter(Mandatory = $false)]
		[object[]]$Principals,
		[Parameter(DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
		[Parameter(DontShow)]
		[string]$Subject = "cms-$Identity",
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if thumbprint provided...
	If ($PSBoundParameters.ContainsKey('Thumbprint') -eq $true) {
		# retrieve certificate by thumbprint
		Try {
			$Certificate = Get-Item -Path "$CertStoreLocation\$Thumbprint" -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not locate certificate in '$CertStoreLocation' on '$Hostname' for provided thumbprint: $Thumbprint"
			Return
		}
	}
	# if thumbprint not provided...
	Else {
		# retrieve latest certificate with matching subject
		Try {
			$Certificate = Get-ChildItem -Path $CertStoreLocation -DocumentEncryptionCert -ErrorAction 'Stop' | Where-Object { $_.Subject -match "^CN=$Subject-" } | Sort-Object -Property 'NotBefore' | Select-Object -Last 1
		}
		Catch {
			Throw $_
		}
	}

	# if certificate not found...
	If ($null -eq $local:Certificate) {
		# declare and return
		Write-Warning -Message "could not locate certificate on '$Hostname' with identity: $Identity"
		Throw [System.Management.Automation.ItemNotFoundException]
	}

	# retrieve private key path
	Try {
		$Path = Get-CertificatePrivateKeyPath -Certificate $Certificate
	}
	Catch {
		Write-Warning -Message "could not retrieve path to private key for certificate on '$Hostname' with thumbprint: $($Certificate.Thumbprint)"
		Throw $_
	}

	# if private key path not found...
	If ($null -eq $local:Path) {
		# declare and return
		Write-Warning -Message "could not locate private key for certificate on '$Hostname' with thumbprint: $($Certificate.Thumbprint)"
		Throw [System.Management.Automation.ItemNotFoundException]
	}

	# retrieve private key permissions
	Try {
		$AclObject = Get-Acl -Path $Path -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not retrieve ACL for private key of certificate on '$Hostname' with thumbprint: $($Certificate.Thumbprint)"
		Throw $_
	}

	# create list for SIDs
	$SecurityIdentifiers = [System.Collections.Generic.List[System.Security.Principal.SecurityIdentifier]]::new()

	# get SIDs
	switch ($Mode) {
		'Reset' {
			# add NT AUTHORITY\SYSTEM
			$SecurityIdentifiers.Add([System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'))
			# add BUILTIN\Administrators
			$SecurityIdentifiers.Add([System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
		}
		Default {
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
	}

	# process SIDs
	switch ($Mode) {
		'Reset' {
			ForEach ($IdentityReference in $AclObject.Access.IdentityReference) {
				# remove rule for IdentityReference
				$AclObject.PurgeAccessRules($IdentityReference)
			}
			ForEach ($SecurityIdentifier in $SecurityIdentifiers) {
				# create 'FullControl' rule for SID
				$AccessRule = [System.Security.AccessControl.FileSystemAccessRule]::new($SecurityIdentifier, 'FullControl', 'Allow')
				# add rule to ACL
				$AclObject.AddAccessRule($AccessRule)
			}
		}
		'Grant' {
			ForEach ($SecurityIdentifier in $SecurityIdentifiers) {
				# create 'Read' rule for SID
				$AccessRule = [System.Security.AccessControl.FileSystemAccessRule]::new($SecurityIdentifier, 'Read', 'Allow')
				# add rule to ACL
				$AclObject.AddAccessRule($AccessRule)
			}
		}
		'Revoke' {
			ForEach ($SecurityIdentifier in $SecurityIdentifiers) {
				# remove rule for SID
				$AclObject.PurgeAccessRules($SecurityIdentifier)
			}
		}
	}

	# update ACL on private key
	Try {
		Set-Acl -Path $Path -AclObject $AclObject -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not update ACL for private key of certificate on '$Hostname' with thumbprint: $($Certificate.Thumbprint)"
		Throw $_
	}
}

Function Grant-CmsCredentialAccess {
	<#
	.SYNOPSIS
	Grants read access to the private key protecting a CMS credential

	.DESCRIPTION
	Grants read access to the private key protecting a CMS credential. Read access to the associated private key is required to decrypt a CMS credential.

	.PARAMETER Identity
	Specifies the identity of a CMS credential. Cannot be combined with the Thumbprint parameter.

	.PARAMETER Thumbprint
	Specifies the thumbprint of a certificate protecting a CMS credential. Cannot be combined with the Identity parameter.

	.PARAMETER Principals
	Specifies one or more security principals.

	.PARAMETER ComputerName
	Specifies the name of one or more remote computers.

	.INPUTS
	None.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Grant-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser"

	.EXAMPLE
	PS> Grant-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser" -ComputerName "server1", "server2"

	#>

	[CmdletBinding(DefaultParameterSetName = 'Identity')]
	Param(
		[Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Identity')]
		[string]$Identity,
		[Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Thumbprint')]
		[string]$Thumbprint,
		[Parameter(Mandatory = $true, Position = 1)]
		[string[]]$Principals,
		[Parameter(Mandatory = $false)]
		[string[]]$ComputerName,
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::Machinename).ToLowerInvariant()
	)

	# add mode to bound parameters
	$PSBoundParameters.Add('Mode', 'Grant')

	# if computer names provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# remove ComputerName parameter from bound parameters
		$null = $PSBoundParameters.Remove('ComputerName')

		# define functions for remote computers
		$UpdateFunction = "function Update-CmsCredentialAccess {${function:Update-CmsCredentialAccess}}"

		# show credentials on remote computer
		ForEach ($RemoteComputerName in $ComputerName) {
			# if remote computer name is local computer name...
			If ($RemoteComputerName -match "^$Hostname$" -or $RemoteComputerName -match "^$Hostname\..+") {
				# set include local computer then continue
				$local:IncludeLocalComputer = $true
				Continue
			}
			# run function on remote computer
			Try {
				Invoke-Command -ComputerName $RemoteComputerName -ScriptBlock {
					. ([ScriptBlock]::Create($using:UpdateFunction))
					Update-CmsCredentialAccess @using:PSBoundParameters
				}
			}
			Catch {
				Write-Warning "could not grant access to CMS credentials on '$RemoteComputerName' computer: $($_.Exception.Message)"
				Return $_
			}
		}

		# if include local computer not set...
		If ($null -eq $local:IncludeLocalComputer) {
			# return after running function on remote computers
			Return
		}
	}

	# grant access to credential on local computer
	Try {
		Update-CmsCredentialAccess @PSBoundParameters
	}
	Catch {
		Write-Warning "could not grant access to CMS credential on '$Hostname' computer: $($_.Exception.Message)"
		Return $_
	}
}

Function Reset-CmsCredentialAccess {
	<#
	.SYNOPSIS
	Resets read access to the private key protecting a CMS credential.

	.DESCRIPTION
	Resets read access to the private key protecting a CMS credential. Only the built-in Administrators and SYSTEM will have access to the private key after this command is run against a CMS credential.

	.PARAMETER Identity
	Specifies the identity of a CMS credential. Cannot be combined with the Thumbprint parameter.

	.PARAMETER Thumbprint
	Specifies the thumbprint of a certificate protecting a CMS credential. Cannot be combined with the Identity parameter.

	.PARAMETER ComputerName
	Specifies the name of one or more remote computers.

	.INPUTS
	None.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Reset-CmsCredentialAccess -Identity "testcredential"

	.EXAMPLE
	PS> Reset-CmsCredentialAccess -Identity "testcredential" -ComputerName "server1", "server2"

	#>

	[CmdletBinding(DefaultParameterSetName = 'Identity')]
	Param(
		[Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Identity')]
		[string]$Identity,
		[Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Thumbprint')]
		[string]$Thumbprint,
		[Parameter(Mandatory = $false)]
		[string[]]$ComputerName,
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::Machinename).ToLowerInvariant()
	)

	# add mode to bound parameters
	$PSBoundParameters.Add('Mode', 'Reset')

	# if computer names provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# remove ComputerName parameter from bound parameters
		$null = $PSBoundParameters.Remove('ComputerName')

		# define functions for remote computers
		$UpdateFunction = "function Update-CmsCredentialAccess {${function:Update-CmsCredentialAccess}}"

		# show credentials on remote computer
		ForEach ($RemoteComputerName in $ComputerName) {
			# if remote computer name is local computer name...
			If ($RemoteComputerName -match "^$Hostname$" -or $RemoteComputerName -match "^$Hostname\..+") {
				# set include local computer then continue
				$local:IncludeLocalComputer = $true
				Continue
			}
			# run function on remote computer
			Try {
				Invoke-Command -ComputerName $RemoteComputerName -ScriptBlock {
					. ([ScriptBlock]::Create($using:UpdateFunction))
					Update-CmsCredentialAccess @using:PSBoundParameters
				}
			}
			Catch {
				Write-Warning "could not reset access to CMS credentials on '$RemoteComputerName' computer: $($_.Exception.Message)"
				Return $_
			}
		}

		# if include local computer not set...
		If ($null -eq $local:IncludeLocalComputer) {
			# return after running function on remote computers
			Return
		}
	}

	# reset access to credential on local computer
	Try {
		Update-CmsCredentialAccess @PSBoundParameters
	}
	Catch {
		Write-Warning "could not reset access to CMS credential on '$Hostname' computer: $($_.Exception.Message)"
		Return $_
	}
}

Function Revoke-CmsCredentialAccess {
	<#
	.SYNOPSIS
	Revokes read access to the private key protecting a CMS credential

	.DESCRIPTION
	Revokes read access to the private key protecting a CMS credential. Read access to the associated private key is required to decrypt a CMS credential. Read access for SYSTEM or the built-in Administrators group cannot be revoked.

	.PARAMETER Identity
	Specifies the identity of a CMS credential. Cannot be combined with the Thumbprint parameter.

	.PARAMETER Thumbprint
	Specifies the thumbprint of a certificate protecting a CMS credential. Cannot be combined with the Identity parameter.

	.PARAMETER Principals
	Specifies one or more security principals.

	.PARAMETER ComputerName
	Specifies the name of one or more remote computers.

	.INPUTS
	None.

	.OUTPUTS
	None.

	.EXAMPLE
	PS> Revoke-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser"

	.EXAMPLE
	PS> Revoke-CmsCredentialAccess -Identity "testcredential" -Principals "DOMAIN\TestUser" -ComputerName "server1", "server2"

	#>

	[CmdletBinding(DefaultParameterSetName = 'Identity')]
	Param(
		[Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Identity')]
		[string]$Identity,
		[Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Thumbprint')]
		[string]$Thumbprint,
		[Parameter(Mandatory = $true, Position = 1)]
		[string[]]$Principals,
		[Parameter(Mandatory = $false)]
		[string[]]$ComputerName,
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::Machinename).ToLowerInvariant()
	)

	# add mode to bound parameters
	$PSBoundParameters.Add('Mode', 'Revoke')

	# if computer names provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# remove ComputerName parameter from bound parameters
		$null = $PSBoundParameters.Remove('ComputerName')

		# define functions for remote computers
		$UpdateFunction = "function Update-CmsCredentialAccess {${function:Update-CmsCredentialAccess}}"

		# show credentials on remote computer
		ForEach ($RemoteComputerName in $ComputerName) {
			# if remote computer name is local computer name...
			If ($RemoteComputerName -match "^$Hostname$" -or $RemoteComputerName -match "^$Hostname\..+") {
				# set include local computer then continue
				$local:IncludeLocalComputer = $true
				Continue
			}
			# run function on remote computer
			Try {
				Invoke-Command -ComputerName $RemoteComputerName -ScriptBlock {
					. ([ScriptBlock]::Create($using:UpdateFunction))
					Update-CmsCredentialAccess @using:PSBoundParameters
				}
			}
			Catch {
				Write-Warning "could not revoke access to CMS credentials on '$RemoteComputerName' computer: $($_.Exception.Message)"
				Return $_
			}
		}

		# if include local computer not set...
		If ($null -eq $local:IncludeLocalComputer) {
			# return after running function on remote computers
			Return
		}
	}

	# revoke access to credential on local computer
	Try {
		Update-CmsCredentialAccess @PSBoundParameters
	}
	Catch {
		Write-Warning "could not revoke access to CMS credential on '$Hostname' computer: $($_.Exception.Message)"
		Return $_
	}
}

# define functions to export
$FunctionsToExport = @(
	'New-CmsCredentialCertificate'
	'Get-CmsCredential'
	'Protect-CmsCredential'
	'Remove-CmsCredential'
	'Show-CmsCredential'
	'Grant-CmsCredentialAccess'
	'Reset-CmsCredentialAccess'
	'Revoke-CmsCredentialAccess'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport