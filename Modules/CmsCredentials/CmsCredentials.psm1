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
	If ($PSBoundParameters.ContainsKey('Thumbprint')) {
		# create path for certificate by thumbprint
		$CertificatePath = Join-Path -Path $CertStoreLocation -ChildPath $Thumbprint
		# retrieve certificate by thumbprint
		Try {
			$Certificate = Get-Item -Path $CertificatePath -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not locate certificate in '$CertStoreLocation' on '$Hostname' with thumbprint: $Thumbprint"
			Throw $_
		}
	}

	# if certificate does not have a private key...
	If (!$Certificate.HasPrivateKey) {
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
	If ($null -eq $local:PrivateKey) {
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
		$PrivateKeyPath = Get-ChildItem -Path $Path -Recurse -Filter $UniqueName | Select-Object -First 1 -ExpandProperty 'FullName'
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

Function Test-CmsInvalidIdentity {
	<#
	.SYNOPSIS
	Tests a string for characters not permited in the Identity of a CMS credential.

	.DESCRIPTION
	Tests a string for characters not permited in the Identity of a CMS credential.

	.PARAMETER Identity
	Specifies the identity of a CMS credential.

	.INPUTS
	System.String.

	.OUTPUTS
	System.Boolean.

	#>
	[CmdletBinding()]
	Param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$Identity,
		[Parameter(Mandatory = $false)]
		[string]$Pattern = '[\\,="]' # '[^\w\s\.\-]'
	)

	# test pattern against identity
	If (Select-String -InputObject $Identity -Pattern $Pattern -Quiet) {
		Return $true
	}
	Else {
		Return $false
	}
}

Function Test-CmsInvalidSubject {
	<#
	.SYNOPSIS
	Tests a string for characters not permited in the subject of a CMS credential certificate.

	.DESCRIPTION
	Tests a string for characters not permited in the subject of a CMS credential certificate.

	.PARAMETER Subject
	Specifies the subject of a CMS credential certificate.

	.INPUTS
	System.String.

	.OUTPUTS
	System.Boolean.

	#>
	[CmdletBinding()]
	Param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$Subject,
		[Parameter(Mandatory = $false)]
		[string]$Pattern = '[\\"]'
	)

	# test pattern against identity
	If (Select-String -InputObject $Subject -Pattern $Pattern -Quiet) {
		Return $true
	}
	Else {
		Return $false
	}
}

Function Export-CmsCredentialCertificate {
	<#
	.SYNOPSIS
	Exports a certificate for protecting credentials with CMS.

	.DESCRIPTION
	Exports a certificate for protecting credentials with CMS. The exported certificate is protected using DPAPI.

	.PARAMETER Thumbprint
	Specifies the thumbprint of a certificate protecting a CMS credential. Cannot be combined with the Identity parameter.

	.PARAMETER Identity
	Specifies the identity of a CMS credential. Cannot be combined with the Thumbprint parameter.

	.PARAMETER FilePath
	Specifies the path for the exported PFX file.

	.PARAMETER Principals
	Specifies one or more security principals.

	.INPUTS
	None.

	.OUTPUTS
	None.

	.NOTES
	The -ProtectTo parameter of the Export-PfxCertificate cannot be used in a remote session due to second-hop limitations.

	#>

	[CmdletBinding(DefaultParameterSetName = 'Identity')]
	Param (
		[Parameter(ParameterSetName = 'Thumbprint', Mandatory = $true, Position = 0)]
		[string]$Thumbprint,
		[Parameter(ParameterSetName = 'Identity', Mandatory = $true, Position = 0)]
		[string]$Identity,
		[Parameter(Mandatory = $true)]
		[string]$FilePath,
		[Parameter(Mandatory = $true)]
		[object[]]$Principals,
		[Parameter(DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if identity contains invalid characters...
	If ($PSBoundParameters.ContainsKey('Identity') -and (Test-CmsInvalidIdentity -Identity $Identity)) {
		# warn and return
		Write-Warning -Message "the value provided for the Identity parameter contains one or more of the following invalid characters: '\' (backslash), '=' (equal sign)"
		Return
	}

	# if thumbprint provided...
	If ($PSBoundParameters.ContainsKey('Thumbprint')) {
		# create path for certificate by thumbprint
		$CertificatePath = Join-Path -Path $CertStoreLocation -ChildPath $Thumbprint
		# retrieve certificate by thumbprint
		Try {
			$Certificate = Get-Item -Path $CertificatePath -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not locate certificate in '$CertStoreLocation' on '$Hostname' with thumbprint: $Thumbprint"
			Throw $_
		}
	}
	# if thumbprint not provided...
	Else {
		# define pattern as organizational unit of Identity followed by organization of CmsCredentials
		$Pattern = "OU=$Identity, O=CmsCredentials$"
		# retrieve latest certificate with matching subject
		Try {
			$Certificate = Get-ChildItem -Path $CertStoreLocation -DocumentEncryptionCert -ErrorAction 'Stop' | Where-Object { Select-String -InputObject $_.Subject -Pattern $Pattern -Quiet } | Sort-Object -Property 'NotBefore' | Select-Object -Last 1
		}
		Catch {
			Write-Warning -Message "could not search for certificate in '$CertStoreLocation' on '$Hostname' with identity: $Identity"
			Throw $_
		}

		# if certificate not found...
		If ($null -eq $local:Certificate) {
			# declare and return
			Write-Warning -Message "could not locate certificate in '$CertStoreLocation' on '$Hostname' with identity: $Identity"
			Throw [System.Management.Automation.ItemNotFoundException]
		}
	}

	# define parameters for Export-PfxCertificate
	$ExportPfxCertificate = @{
		Cert                  = $Certificate
		FilePath              = $FilePath
		ProtectTo             = $Principals
		ChainOption           = 'EndEntityCertOnly'
		CryptoAlgorithmOption = 'AES256_SHA256'
	}

	# export certificate as .pfx
	Try {
		$null = Export-PfxCertificate @ExportPfxCertificate
	}
	Catch {
		Write-Warning -Message "could not export PFX file for certificate on '$Hostname' with thumbprint: $($Certificate.Thumbprint)"
		Throw $_
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

	.PARAMETER ComputerName
	Specifies the name of one or more remote computers.

	.INPUTS
	None.

	.OUTPUTS
	System.Security.Cryptography.X509Certificates.X509Certificate2

	#>

	[CmdletBinding()]
	Param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$Identity,
		[Parameter(Mandatory = $false)][ValidateSet('NonExportable', 'ExportableEncrypted', 'Exportable')]
		[string]$KeyExportPolicy = 'NonExportable',
		[Parameter(Mandatory = $false)]
		[string[]]$ComputerName,
		[Parameter(DontShow)]
		[guid]$Guid = [guid]::NewGuid(),
		[Parameter(DontShow)]
		[datetime]$NotBefore = [datetime]::Now,
		[Parameter(DontShow)]
		[datetime]$NotAfter = $NotBefore.AddYears(100),
		[Parameter(DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if identity contains invalid characters...
	If (Test-CmsInvalidIdentity -Identity $Identity) {
		# warn and return
		Write-Warning -Message "the value provided for the Identity parameter contains one or more of the following invalid characters: '\' (backslash), '=' (equal sign)"
		Return
	}

	# if computername provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# remove ComputerName parameter from bound parameters
		$null = $PSBoundParameters.Remove('ComputerName')

		# define required functions
		$FunctionNames = 'Test-CmsInvalidIdentity', 'New-CmsCredentialCertificate'

		# define list for function script blocks
		$FunctionScriptBlocks = [System.Collections.Generic.List[System.String]]::new()

		# add script block for required functions to list
		ForEach ($FunctionName in $FunctionNames) {
			# get function definition
			Try {
				$FunctionDefinition = (Get-Command -Name $FunctionName -ErrorAction 'Stop').Definition
			}
			Catch {
				Write-Warning -Message "could not retrieve definition on '$Hostname' for function: $FunctionName"
				Throw $_
			}
			# create function script block and add to list
			$FunctionScriptBlocks.Add("function $FunctionName {$FunctionDefinition}")
		}

		# create certificate for credential on remote computer
		ForEach ($RemoteComputerName in $ComputerName) {
			# if remote computer name is local computer name...
			If ($RemoteComputerName -match "^$Hostname($|\..*)") {
				# set include local computer then continue
				$local:IncludeLocalComputer = $true
				Continue
			}
			# run function on remote computer
			Try {
				Invoke-Command -ComputerName $RemoteComputerName -ScriptBlock {
					# import functions
					ForEach ($FunctionScriptBlock in $using:FunctionScriptBlocks) {
						. ([ScriptBlock]::Create($FunctionScriptBlock))
					}
					# run functions
					New-CmsCredentialCertificate @using:PSBoundParameters
				}
			}
			Catch {
				Write-Warning -Message "could not invoke function(s) on '$RemoteComputerName' computer: $($_.Exception.Message)"
				Throw $_
			}
		}

		# if include local computer not set...
		If ($null -eq $local:IncludeLocalComputer) {
			# return after running function on remote computers
			Return
		}
	}

	# define certificate values
	$SelfSignedCertificate = @{
		Subject           = "CN=$Guid, OU=$Identity, O=CmsCredentials"
		Type              = 'DocumentEncryptionCert'
		HashAlgorithm     = 'SHA512'
		KeyLength         = 4096
		KeyExportPolicy   = $KeyExportPolicy
		NotBefore         = $NotBefore
		NotAfter          = $NotAfter
		CertStoreLocation = $CertStoreLocation
	}

	# if certificate should be exportable as plain text...
	If ($KeyExportPolicy -eq 'Exportable') {
		# update certificate type to use legacy CSP
		$SelfSignedCertificate['Type'] = 'DocumentEncryptionCertLegacyCsp'
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

	# return certificate
	Return $Certificate
}

Function Get-CmsCredential {
	<#
	.SYNOPSIS
	Retrieves a credential protected by CMS.

	.DESCRIPTION
	Retrieves a credential encrypted by a CMS certificate. The calling user must have read access to the private key that protects the credential.

	.PARAMETER FilePath
	Specifies the path to a CMS credential file. Cannot be combined with the Identity parameter.

	.PARAMETER To
	Specifies the CMS message recipient in one of the following formats:
		* An actual certificate (as retrieved from the certificate provider).
		* Path to the a file containing the certificate.
		* Path to a directory containing the certificate.
		* Thumbprint of the certificate (used to look in the certificate store).
		* Subject name of the certificate (used to look in the certificate store).
	Requires the FilePath parameter.

	.PARAMETER Identity
	Specifies the identity of the CMS credential. Cannot be combined with the FilePath parameter.

	.PARAMETER Path
	Specifies the path to a folder containing CMS credential files. The default value is the 'C:\ProgramData\CmsCredentials' folder. Requires the Identity parameter.

	.PARAMETER AsPlainText
	Specifies the credential should be returned as a plain-text password. The credential will be returned a PSCustomObject with Username and Password properties.

	.PARAMETER ComputerName
	Specifies the name of one or more remote computers.

	.INPUTS
	None.

	.OUTPUTS
	System.Management.Automation.PSCredential or System.Management.Automation.PSCustomObject.

	.EXAMPLE
	PS> Get-CmsCredential -Identity "testcredential"

	.EXAMPLE
	PS> Get-CmsCredential -Identity "testcredential" -AsPlainText

	#>

	[CmdletBinding(DefaultParameterSetName = 'Identity')]
	Param(
		[Parameter(ParameterSetName = 'FilePath', Position = 0, Mandatory)]
		[string]$FilePath,
		[Parameter(ParameterSetName = 'FilePath', Position = 1)][ValidateScript({ $_ -is [System.Security.Cryptography.X509Certificates.X509Certificate2] -or $_ -is [System.String] })]
		[object]$To,
		[Parameter(ParameterSetName = 'Identity', Position = 0, Mandatory)]
		[string]$Identity,
		[Parameter(ParameterSetName = 'Identity', Position = 1)]
		[string]$Path = (Join-Path -Path ([System.Environment]::GetFolderPath('CommonApplicationData')) -ChildPath 'CmsCredentials'),
		[Parameter(Mandatory = $false)]
		[switch]$AsPlainText,
		[Parameter(Mandatory = $false)]
		[string[]]$ComputerName,
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if identity contains invalid characters...
	If ($PSBoundParameters.ContainsKey('Identity') -and (Test-CmsInvalidIdentity -Identity $Identity)) {
		# warn and return
		Write-Warning -Message "the value provided for the Identity parameter contains one or more of the following invalid characters: '\' (backslash), '=' (equal sign)"
		Return $null
	}

	# if computername provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# remove ComputerName parameter from bound parameters
		$null = $PSBoundParameters.Remove('ComputerName')

		# define required functions
		$FunctionNames = 'Test-CmsInvalidIdentity', 'Get-CmsCredential'

		# define list for function script blocks
		$FunctionScriptBlocks = [System.Collections.Generic.List[System.String]]::new()

		# add script block for required functions to list
		ForEach ($FunctionName in $FunctionNames) {
			# get function definition
			Try {
				$FunctionDefinition = (Get-Command -Name $FunctionName -ErrorAction 'Stop').Definition
			}
			Catch {
				Write-Warning -Message "could not retrieve definition on '$Hostname' for function: $FunctionName"
				Throw $_
			}
			# create function script block and add to list
			$FunctionScriptBlocks.Add("function $FunctionName {$FunctionDefinition}")
		}

		# get credential on remote computer
		ForEach ($RemoteComputerName in $ComputerName) {
			# if remote computer name is local computer name...
			If ($RemoteComputerName -match "^$Hostname($|\..*)") {
				# set include local computer then continue
				$local:IncludeLocalComputer = $true
				Continue
			}
			# run function on remote computer
			Try {
				Invoke-Command -ComputerName $RemoteComputerName -ScriptBlock {
					# import functions
					ForEach ($FunctionScriptBlock in $using:FunctionScriptBlocks) {
						. ([ScriptBlock]::Create($FunctionScriptBlock))
					}
					# run functions
					Get-CmsCredential @using:PSBoundParameters
				}
			}
			Catch {
				Write-Warning -Message "could not invoke function(s) on '$RemoteComputerName' computer: $($_.Exception.Message)"
				Throw $_
			}
		}

		# if include local computer not set...
		If ($null -eq $local:IncludeLocalComputer) {
			# return after running function on remote computers
			Return
		}
	}

	# if file path provided and path is not a file...
	If ($PSBoundParameters.ContainsKey('FilePath') -and -not (Test-Path -Path $FilePath -PathType 'Leaf')) {
		# declare and return
		Write-Warning -Message "could not locate credential file with path: $FilePath"
		Return $null
	}

	# if identity provided...
	If ($PSBoundParameters.ContainsKey('Identity') -and (Test-Path -Path $Path -PathType 'Container')) {
		# define pattern as organizational unit of Identity followed by organization of CmsCredentials
		$Pattern = "OU=$Identity, O=CmsCredentials$"
		# retrieve latest credential file with matching subject
		Try {
			$FilePath = Get-ChildItem -Path $Path -Filter '*.txt' -File -ErrorAction 'Stop' | Where-Object { Select-String -InputObject $_ -Pattern $Pattern -Quiet } | Sort-Object -Property 'LastWriteTime' | Select-Object -Last 1 -ExpandProperty 'FullName'
		}
		Catch {
			Write-Warning -Message "could not search for files for '$Identity' identity in path: $Path"
			Throw $_
		}
		# if file not found...
		If ([string]::IsNullOrEmpty($local:FilePath)) {
			# declare and return
			Write-Warning -Message "could not locate credential file for '$Identity' identity in path: $Path"
			Return $null
		}
	}

	# define required parameters for Unprotect-CmsMessage
	$UnprotectCmsMessage = @{
		Path        = $FilePath
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# define optional parameters for Unprotect-CmsMessage
	If ($PSBoundParameters.ContainsKey('To')) {
		$UnprotectCmsMessage['To'] = $local:To
	}

	# decrypt content of credential file
	Try {
		$InputObject = Unprotect-CmsMessage @UnprotectCmsMessage
	}
	Catch {
		Write-Warning -Message "could not decrypt content in file: '$FilePath'"
		Throw $_
	}

	# convert content from JSON string into custom object
	Try {
		$PSCustomObject = ConvertFrom-Json -InputObject $InputObject -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not convert decrypted content in file: '$FilePath'"
		Throw $_
	}

	# verify username property
	If ($null -eq $PSCustomObject.Username) {
		Write-Warning -Message "could not locate 'Username' property on '$Hostname' in file: '$FilePath'"
		Throw [System.Management.Automation.ItemNotFoundException]
	}

	# verify password property
	If ($null -eq $PSCustomObject.Password) {
		Write-Warning -Message "could not locate 'Password' property on '$Hostname' in file: '$FilePath'"
		Throw [System.Management.Automation.ItemNotFoundException]
	}

	# if plain text requested...
	If ($local:AsPlainText) {
		# return the PSCustomObject as-is
		Return $PSCustomObject
	}

	# if domain not included in credential...
	If ([string]::IsNullOrEmpty($PSCustomObject.Domain)) {
		# retrieve username from object as-is
		$Username = $PSCustomObject.Username
	}
	Else {
		# combine domain and username from object
		$Username = $PSCustomObject.Domain, $PSCustomObject.Username -join '\'
	}

	# convert password property into secure string
	Try {
		$SecureString = ConvertTo-SecureString -String $PSCustomObject.Password -AsPlainText -Force -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not convert 'Password' property on '$Hostname' to a SecureString"
		Throw $_
	}

	# create PSCredential object
	Try {
		$PSCredential = [System.Management.Automation.PSCredential]::new($Username, $SecureString)
	}
	Catch {
		Write-Warning -Message "could not create PSCredential object on '$Hostname' for identity: $Identity"
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
	Protects a credential by encrypting it with a certificate using CMS. The calling user must have read access to the public key that will protect the credential.

	.PARAMETER Credential
	Specifies the PSCredential object to protect with CMS.

	.PARAMETER To
	Specifies one or more CMS message recipients, identified in any of the following formats:
		* An actual certificate (as retrieved from the certificate provider).
		* Path to the file containing the certificate.
		* Path to a directory containing the certificate.
		* Thumbprint of the certificate (used to look in the certificate store).
		* Subject name of the certificate (used to look in the certificate store).
	Cannot be combined with the Identity parameter.

	.PARAMETER Identity
	Specifies the identity for the CMS credential. Cannot be combined with the To parameter. A new CMS certificate will be created if an existing CMS certificate for the provided identify is not found.

	.PARAMETER OutFile
	Specifies the path for the CMS credential file.

	.PARAMETER Path
	Specifies the path for the folder where the CMS credential file will be created when the OutFile parameter is not provided. The default value is 'C:\ProgramData\CmsCredentials'. The folder is created when it does not exist and the OutFile parameter is not provided.

	.PARAMETER Reset
	Switch to create a new CMS certificate and credential file for the provided identity. Requires the Identity parameter.

	.PARAMETER SkipCleanup
	Switch to skip removal of old CMS certificates and credential files for the provided identity. Requires the Identity parameter.

	.PARAMETER ComputerName
	Specifies the name of one or more remote computers.

	.INPUTS
	None.

	.OUTPUTS
	None.

	#>

	[CmdletBinding(DefaultParameterSetName = 'Identity')]
	Param (
		[Parameter(ValueFromPipeline = $true, Mandatory = $true)]
		[pscredential]$Credential,
		[Parameter(ParameterSetName = 'Explicit', Position = 0, Mandatory = $true)][ValidateScript({ $_ -is [System.Security.Cryptography.X509Certificates.X509Certificate2] -or $_ -is [System.String] })]
		[object]$To,
		[Parameter(ParameterSetName = 'Identity', Position = 0, Mandatory = $true)]
		[string]$Identity,
		[Parameter(ParameterSetName = 'Explicit', Position = 1, Mandatory = $true)]
		[Parameter(ParameterSetName = 'Identity', Position = 1)]
		[string]$OutFile,
		[Parameter(ParameterSetName = 'Identity')]
		[string]$Path = (Join-Path -Path ([System.Environment]::GetFolderPath('CommonApplicationData')) -ChildPath 'CmsCredentials'),
		[Parameter(ParameterSetName = 'Identity')]
		[switch]$Reset,
		[Parameter(ParameterSetName = 'Identity')]
		[switch]$SkipCleanup,
		[Parameter(Mandatory = $false)]
		[string[]]$ComputerName,
		[Parameter(Mandatory = $false)]
		[switch]$Force,
		[Parameter(DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if identity contains invalid characters...
	If ($PSBoundParameters.ContainsKey('Identity') -and (Test-CmsInvalidIdentity -Identity $Identity)) {
		# warn and return
		Write-Warning -Message "the value provided for the Identity parameter contains one or more of the following invalid characters: '\' (backslash), '=' (equal sign)"
		Return
	}

	# if computername provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# remove ComputerName parameter from bound parameters
		$null = $PSBoundParameters.Remove('ComputerName')

		# define required functions
		$FunctionNames = 'Test-CmsInvalidIdentity', 'Test-CmsInvalidSubject', 'New-CmsCredentialCertificate', 'Protect-CmsCredential', 'Remove-CmsCredential'

		# define list for function script blocks
		$FunctionScriptBlocks = [System.Collections.Generic.List[System.String]]::new()

		# add script block for required functions to list
		ForEach ($FunctionName in $FunctionNames) {
			# get function definition
			Try {
				$FunctionDefinition = (Get-Command -Name $FunctionName -ErrorAction 'Stop').Definition
			}
			Catch {
				Write-Warning -Message "could not retrieve definition on '$Hostname' for function: $FunctionName"
				Throw $_
			}
			# create function script block and add to list
			$FunctionScriptBlocks.Add("function $FunctionName {$FunctionDefinition}")
		}

		# protect credential on remote computer
		ForEach ($RemoteComputerName in $ComputerName) {
			# if remote computer name is local computer name...
			If ($RemoteComputerName -match "^$Hostname($|\..*)") {
				# set include local computer then continue
				$local:IncludeLocalComputer = $true
				Continue
			}
			# run function on remote computer
			Try {
				Invoke-Command -ComputerName $RemoteComputerName -ScriptBlock {
					# import functions
					ForEach ($FunctionScriptBlock in $using:FunctionScriptBlocks) {
						. ([ScriptBlock]::Create($FunctionScriptBlock))
					}
					# run functions
					Protect-CmsCredential @using:PSBoundParameters
				}
			}
			Catch {
				Write-Warning -Message "could not invoke function(s) on '$RemoteComputerName' computer: $($_.Exception.Message)"
				Throw $_
			}
		}

		# if include local computer not set...
		If ($null -eq $local:IncludeLocalComputer) {
			# return after running function on remote computers
			Return
		}
	}

	# if identity provided...
	If ($PSBoundParameters.ContainsKey('Identity')) {
		# if reset not requested...
		If (!$local:Reset) {
			# define pattern that:
			# - starts with common name of a GUID
			# - includes organizational unit of Identity
			# - concludes with organization of CmsCredentials
			$Pattern = "^CN=[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}, OU=$Identity, O=CmsCredentials$"

			# retrieve latest certificate where subject matches pattern
			Try {
				$To = Get-ChildItem -Path $CertStoreLocation -DocumentEncryptionCert -ErrorAction 'Stop' | Where-Object { Select-String -InputObject $_.Subject -Pattern $Pattern -Quiet } | Sort-Object -Property 'NotBefore' | Select-Object -Last 1
			}
			Catch {
				Write-Warning -Message "could not search for certificate in '$CertStoreLocation' on '$Hostname' with identity: $Identity"
				Throw $_
			}
		}

		# if certificate not found...
		If (!$local:To) {
			# create new certificate for identity
			Try {
				$To = New-CmsCredentialCertificate -Identity $Identity
			}
			Catch {
				Write-Warning -Message "could not create certificate on '$Hostname' with identity: $Identity"
				Throw $_
			}
		}

		# if outfile parameter not provided...
		If (!$local:OutFile) {
			# if folder path not found...
			If (!(Test-Path -Path $Path -PathType 'Container')) {
				# create path
				Try {
					$null = New-Item -ItemType Directory -Path $Path -Verbose -ErrorAction 'Stop'
				}
				Catch {
					Write-Warning -Message "could not create folder on '$Hostname' with path: $Path"
					Throw $_
				}
			}

			# create file name from certificate
			Try {
				$FileName = $To.GetNameInfo('SimpleName', $false)
			}
			Catch {
				Write-Warning -Message "could not create filename on '$Hostname' from certificate subject: $($To.Subject)"
				Throw $_
			}

			# define CMS file path
			$OutFile = Join-Path -Path $Path -ChildPath "$FileName.txt"
		}
	}

	# if recipient is a certificate...
	If ($To -is [System.Security.Cryptography.X509Certificates.X509Certificate2]) {
		# define recipient string as subject of certificate
		$RecipientString = $To.Subject
	}
	# if recipient is not a certificate...
	Else {
		# define recipient string as value of recipient
		$RecipientString = $To
	}

	# if CMS credential file found...
	If (Test-Path -Path $OutFile -PathType 'Leaf') {
		# if force and reset not set...
		If (!$local:Force -and !$local:Reset) {
			Write-Warning -Message "existing credential file found; continue to overwrite file on '$Hostname' with path: $OutFile" -WarningAction 'Inquire'
		}
	}

	# convert network credential to JSON string
	Try {
		$Content = $Credential.GetNetworkCredential() | Select-Object -Property 'UserName', 'Password', 'Domain' | ConvertTo-Json -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not convert custom object on '$Hostname' for identity: $Identity"
		Throw $_
	}

	# encrypt credentials to recipient
	Try {
		Protect-CmsMessage -To $To -Content $Content -OutFile $OutFile -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not encrypt credential on '$Hostname' for recipient(s): $RecipientString"
		Throw $_
	}

	# if identity provided...
	If ($PSBoundParameters.ContainsKey('Identity')) {
		# retrieve content of credential file
		Try {
			$Content = Get-Content -Path $OutFile -Raw -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not read credential file on '$Hostname' with path: $OutFile"
			Throw $_
		}

		# insert subject line into content of credential file
		Try {
			$Value = $Content.Insert(0, "Subject: $($To.Subject)`r`n")
		}
		Catch {
			Write-Warning -Message "could not insert certificate subject into credential file on '$Hostname' with path: $OutFile"
			Throw $_
		}

		# save updated content to credential file
		Try {
			Set-Content -Path $OutFile -Value $Value -Encoding 'UTF8' -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not update credential file on '$Hostname' with path: $OutFile"
			Throw $_
		}

		# if skip cleanup not requested...
		If (!$local:SkipCleanup) {
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
				Write-Warning -Message "could not remove old CMS certificates and files on '$Hostname' for identity: $Identity"
				Throw $_
			}
		}
	}
}

Function Remove-CmsCredential {
	<#
	.SYNOPSIS
	Removes a credential protected by CMS.

	.DESCRIPTION
	Removes the certificate and encrypted file for a credential protected by CMS.

	.PARAMETER Thumbprint
	Specifies the thumbprint for an existing CMS certificate. Cannot be combined with the Identity parameter.

	.PARAMETER Identity
	Specifies the identity of an existing CMS credential. Cannot be combined with the Thumbprint parameter.

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
	PS> Remove-CmsCredential -Identity "testcredential" -SkipLast 1

	.EXAMPLE
	PS> Remove-CmsCredential -Identity "testcredential" -Path "C:\Content\CmsCredentialFiles"

	.EXAMPLE
	PS> Remove-CmsCredential -Identity "testcredential" -Path "C:\Content\CmsCredentialFiles" -SkipLast 1

	#>

	[CmdletBinding(DefaultParameterSetName = 'Identity')]
	Param (
		[Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Thumbprint')]
		[string]$Thumbprint,
		[Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Identity')]
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
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if identity contains invalid characters...
	If ($PSBoundParameters.ContainsKey('Identity') -and (Test-CmsInvalidIdentity -Identity $Identity)) {
		# warn and return
		Write-Warning -Message "the value provided for the Identity parameter contains one or more of the following invalid characters: '\' (backslash), '=' (equal sign)"
		Return
	}

	# if computername provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# remove ComputerName parameter from bound parameters
		$null = $PSBoundParameters.Remove('ComputerName')

		# define required functions
		$FunctionNames = 'Test-CmsInvalidIdentity', 'Remove-CmsCredential'

		# define list for function script blocks
		$FunctionScriptBlocks = [System.Collections.Generic.List[System.String]]::new()

		# add script block for required functions to list
		ForEach ($FunctionName in $FunctionNames) {
			# get function definition
			Try {
				$FunctionDefinition = (Get-Command -Name $FunctionName -ErrorAction 'Stop').Definition
			}
			Catch {
				Write-Warning -Message "could not retrieve definition on '$Hostname' for function: $FunctionName"
				Throw $_
			}
			# create function script block and add to list
			$FunctionScriptBlocks.Add("function $FunctionName {$FunctionDefinition}")
		}

		# remove credential on remote computer
		ForEach ($RemoteComputerName in $ComputerName) {
			# if remote computer name is local computer name...
			If ($RemoteComputerName -match "^$Hostname($|\..*)") {
				# set include local computer then continue
				$local:IncludeLocalComputer = $true
				Continue
			}
			# run function on remote computer
			Try {
				Invoke-Command -ComputerName $RemoteComputerName -ScriptBlock {
					# import functions
					ForEach ($FunctionScriptBlock in $using:FunctionScriptBlocks) {
						. ([ScriptBlock]::Create($FunctionScriptBlock))
					}
					# run functions
					Remove-CmsCredential @using:PSBoundParameters
				}
			}
			Catch {
				Write-Warning -Message "could not invoke function(s) on '$RemoteComputerName' computer: $($_.Exception.Message)"
				Throw $_
			}
		}

		# if include local computer not set...
		If ($null -eq $local:IncludeLocalComputer) {
			# return after running function on remote computers
			Return
		}
	}

	# if thumbprint provided...
	If ($PSBoundParameters.ContainsKey('Thumbprint')) {
		# create path for certificate by thumbprint
		$CertificatePath = Join-Path -Path $CertStoreLocation -ChildPath $Thumbprint
		# retrieve certificate by thumbprint
		Try {
			$Certificate = Get-Item -Path $CertificatePath -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not locate certificate in '$CertStoreLocation' on '$Hostname' with thumbprint: $Thumbprint"
			Throw $_
		}

		# if certificate subject is an empty string...
		If ([string]::IsNullOrEmpty($Certificate.Subject)) {
			# warn and return
			Write-Warning -Message "the subject of the certificate on '$Hostname' with '$Thumbprint' thumbprint is null or an empty string"
			Return
		}

		# if certificate subject contains invalid characters...
		If (Test-CmsInvalidSubject -Subject $Certificate.Subject) {
			# warn and return
			Write-Warning -Message "the subject of the certificate on '$Hostname' with '$Thumbprint' thumbprint contains one or more of the following invalid characters: '\' (backslash)"
			Return
		}

		# retrieve pattern as subject of certificate
		$Pattern = $Certificate.Subject
		$SimpleMatch = $true
	}
	Else {
		# define pattern as organizational unit of Identity followed by organization of CmsCredentials
		$Pattern = "OU=$Identity, O=CmsCredentials$"
		$SimpleMatch = $false
	}

	# if path to credential certificates found...
	If (Test-Path -Path $CertStoreLocation -PathType 'Container') {
		# define script block for where-object
		$ScriptBlock = { Select-String -InputObject $_.Subject -Pattern $Pattern -SimpleMatch:$SimpleMatch -Quiet }
		# retrieve credential certificates with matching subject
		Try {
			$CredentialCerts = Get-ChildItem -Path $CertStoreLocation -DocumentEncryptionCert -ErrorAction 'Stop' | Where-Object -FilterScript $ScriptBlock | Sort-Object -Property 'NotBefore' | Select-Object -SkipLast $SkipLast
		}
		Catch {
			Write-Warning -Message "could not retrieve credential certificates on '$Hostname'"
			Return
		}
	}
	Else {
		Write-Warning -Message "could not locate store for credential certificates on '$Hostname' with path: $CertStoreLocation"
	}

	# if path to credential files found...
	If (Test-Path -Path $Path -PathType 'Container') {
		# define script block for where-object
		$ScriptBlock = { Select-String -InputObject $_ -Pattern $Pattern -SimpleMatch:$SimpleMatch -Quiet }
		# retrieve credential files where content contains matching subject
		Try {
			$CredentialFiles = Get-ChildItem -Path $Path -Filter '*.txt' -File -ErrorAction 'Stop' | Where-Object -FilterScript $ScriptBlock | Sort-Object -Property 'LastWriteTime' | Select-Object -SkipLast $SkipLast
		}
		Catch {
			Write-Warning -Message "could not search for credential files on '$Hostname' in path: $Path"
			Throw $_
		}
	}
	Else {
		Write-Warning -Message "could not locate folder for credential files on '$Hostname' with path: $Path"
	}

	# remove old credential certificates
	ForEach ($Item in $local:CredentialCerts) {
		Try {
			Remove-Item -Path $Item.PSPath -Force -Verbose -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not remove certificate on '$Hostname' with path: $($Item.PSPath)"
			Throw $_
		}
	}

	# remove old credential files
	ForEach ($Item in $local:CredentialFiles) {
		Try {
			Remove-Item -Path $Item.PSPath -Force -Verbose -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not remove file on '$Hostname' with path: $($Item.PSPath)"
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

	.PARAMETER Thumbprint
	Specifies the thumbprint for an existing CMS certificate. Cannot be combined with the Identity parameter.

	.PARAMETER Identity
	Specifies the identity of existing CMS credential files and certificates. Cannot be combined with the Thumbprint parameters

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

	.EXAMPLE
	PS> Show-CmsCredential -Identity "testcredential" -ComputerName "server1", "server2"

	.EXAMPLE
	PS> Show-CmsCredential -Identity "testcredential" -Path "C:\Content\CmsCredentialFiles"

	.EXAMPLE
	PS> Show-CmsCredential -Identity "testcredential" -Path "C:\Content\CmsCredentialFiles" -ComputerName "server1", "server2"

	#>

	[CmdletBinding(DefaultParameterSetName = 'Identity')]
	Param (
		[Parameter(Mandatory = $false, Position = 0, ParameterSetName = 'Thumbprint')]
		[string]$Thumbprint,
		[Parameter(Mandatory = $false, Position = 0, ParameterSetName = 'Identity')]
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

	# if identity contains invalid characters...
	If ($PSBoundParameters.ContainsKey('Identity') -and (Test-CmsInvalidIdentity -Identity $Identity)) {
		# warn and return
		Write-Warning -Message "the value provided for the Identity parameter contains one or more of the following invalid characters: '\' (backslash), '=' (equal sign)"
		Return
	}

	# if computername provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# remove ComputerName parameter from bound parameters
		$null = $PSBoundParameters.Remove('ComputerName')

		# define required functions
		$FunctionNames = 'Test-CmsInvalidIdentity', 'Test-CmsInvalidSubject', 'Show-CmsCredential'

		# define list for function script blocks
		$FunctionScriptBlocks = [System.Collections.Generic.List[System.String]]::new()

		# add script block for required functions to list
		ForEach ($FunctionName in $FunctionNames) {
			# get function definition
			Try {
				$FunctionDefinition = (Get-Command -Name $FunctionName -ErrorAction 'Stop').Definition
			}
			Catch {
				Write-Warning -Message "could not retrieve definition on '$Hostname' for function: $FunctionName"
				Throw $_
			}
			# create function script block and add to list
			$FunctionScriptBlocks.Add("function $FunctionName {$FunctionDefinition}")
		}

		# show credential on remote computer
		ForEach ($RemoteComputerName in $ComputerName) {
			# if remote computer name is local computer name...
			If ($RemoteComputerName -match "^$Hostname($|\..*)") {
				# set include local computer then continue
				$local:IncludeLocalComputer = $true
				Continue
			}
			# run function on remote computer
			Try {
				Invoke-Command -ComputerName $RemoteComputerName -ScriptBlock {
					# import functions
					ForEach ($FunctionScriptBlock in $using:FunctionScriptBlocks) {
						. ([ScriptBlock]::Create($FunctionScriptBlock))
					}
					# run functions
					Show-CmsCredential @using:PSBoundParameters
				}
			}
			Catch {
				Write-Warning -Message "could not invoke function(s) on '$RemoteComputerName' computer: $($_.Exception.Message)"
				Throw $_
			}
		}

		# if include local computer not set...
		If ($null -eq $local:IncludeLocalComputer) {
			# return after running function on remote computers
			Return
		}
	}

	# if thumbprint provided...
	If ($PSBoundParameters.ContainsKey('Thumbprint')) {
		# create path for certificate by thumbprint
		$CertificatePath = Join-Path -Path $CertStoreLocation -ChildPath $Thumbprint

		# retrieve certificate by thumbprint
		Try {
			$Certificate = Get-Item -Path $CertificatePath -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not locate certificate in '$CertStoreLocation' on '$Hostname' with thumbprint: $Thumbprint"
			Throw $_
		}

		# if certificate subject is an empty string...
		If ([string]::IsNullOrEmpty($Certificate.Subject)) {
			# warn and return
			Write-Warning -Message "the subject of the certificate on '$Hostname' with '$($Certificate.Thumbprint)' thumbprint is null or an empty string"
			Return
		}

		# if certificate subject contains invalid characters...
		If (Test-CmsInvalidSubject -Subject $Certificate.Subject) {
			# warn and return
			Write-Warning -Message "the subject of the certificate on '$Hostname' with '$($Certificate.Thumbprint)' thumbprint contains one or more of the following invalid characters: '\' (backslash)"
			Return
		}

		# define pattern as subject label followed by subject of certificate
		$Pattern = "Subject: $($Certificate.Subject)"
		$SimpleMatch = $true
	}
	# if identity provided...
	ElseIf ($PSBoundParameters.ContainsKey('Identity')) {
		# define pattern as organizational unit of Identity followed by organization of CmsCredentials
		$Pattern = "OU=$Identity, O=CmsCredentials$"
		$SimpleMatch = $false
	}
	Else {
		# define pattern as organization of CmsCredentials
		$Pattern = 'O=CmsCredentials$'
		$SimpleMatch = $false
	}

	# if path to credential certificates found...
	If (Test-Path -Path $CertStoreLocation -PathType 'Container') {
		# retrieve credential certificates with matching subject
		Try {
			$CredentialCerts = Get-ChildItem -Path $CertStoreLocation -DocumentEncryptionCert -ErrorAction 'Stop' | Where-Object { Select-String -InputObject $_.Subject -Pattern $Pattern -SimpleMatch:$SimpleMatch -Quiet }
		}
		Catch {
			Write-Warning -Message "could not retrieve credential certificates on '$Hostname'"
			Return
		}
	}
	Else {
		Write-Warning -Message "could not locate store for credential certificates on '$Hostname' with path: $CertStoreLocation"
	}

	# if path to credential files found...
	If (Test-Path -Path $Path -PathType 'Container') {
		# retrieve credential files where content contains matching subject
		Try {
			$CredentialFiles = Get-ChildItem -Path $Path -Filter '*.txt' -File -ErrorAction 'Stop' | Where-Object { Select-String -InputObject $_ -Pattern $Pattern -SimpleMatch:$SimpleMatch -Quiet }
		}
		Catch {
			Write-Warning -Message "could not retrieve credential files on '$Hostname' from path: $Path"
			Return
		}
	}
	Else {
		Write-Warning -Message "could not locate folder for credential files on '$Hostname' with path: $Path"
	}

	# create list for credential details
	$List = [System.Collections.Generic.List[System.Object]]::new()

	# add credential files to list
	ForEach ($CredentialFile in $local:CredentialFiles) {
		# retrieve subject from credential file
		$Subject = (Select-String -InputObject $CredentialFile -Pattern $Pattern -SimpleMatch:$SimpleMatch -List).Line.Replace('Subject: ', $null)
		# if subject contains invalid characters...
		If (Test-CmsInvalidSubject -Subject $Subject) {
			# warn and continue
			Write-Warning -Message "the subject in the certificate file on '$Hostname' with '$($CredentialFile.FullName)' path contains one or more of the following invalid characters: '\' (backslash)"
			Continue
		}
		# retrieve CommonName from subject in credential file
		$CommonName = $Subject.Split(', ', [System.StringSplitOptions]::RemoveEmptyEntries).Where({ $_.StartsWith('CN=') }).Replace('CN=', $null)
		# retrieve Identity from subject in credential file
		$Identity = $Subject.Split(', ', [System.StringSplitOptions]::RemoveEmptyEntries).Where({ $_.StartsWith('OU=') }).Replace('OU=', $null)
		# check list for existing entries
		$Entry = $List | Where-Object { $_.Identity -eq $Identity -and $_.CommonName -eq $CommonName }
		# if entry found...
		If ($null -ne $Entry) {
			# update credential entry
			$Entry.Path = $CredentialFile.FullName
		}
		# if entry not found...
		Else {
			# create credential entry
			$ListEntry = [PSCustomObject]@{
				ComputerName = $HostName
				Identity     = $Identity
				CommonName   = $CommonName
				Thumbprint   = [string]::Empty
				Path         = $CredentialFile.FullName
			}
			# add new credential entry to list
			$List.Add($ListEntry)
		}
	}

	# add credential certificates to list
	ForEach ($CredentialCert in $local:CredentialCerts) {
		# retrieve subject from certificate
		$Subject = $CredentialCert.Subject
		# if subject contains invalid characters...
		If (Test-CmsInvalidSubject -Subject $Subject) {
			# warn and continue
			Write-Warning -Message "the subject of the certificate on '$Hostname' with '$($CredentialCert.Thumbprint)' thumbprint contains one or more of the following invalid characters: '\' (backslash)"
			Continue
		}
		# retrieve CommonName from subject in credential certificate
		$CommonName = $Subject.Split(', ', [System.StringSplitOptions]::RemoveEmptyEntries).Where({ $_.StartsWith('CN=') }).Replace('CN=', $null)
		# retrieve Identity from subject in credential certificate
		$Identity = $Subject.Split(', ', [System.StringSplitOptions]::RemoveEmptyEntries).Where({ $_.StartsWith('OU=') }).Replace('OU=', $null)
		# check list for existing entries
		$Entry = $List | Where-Object { $_.Identity -eq $Identity -and $_.CommonName -eq $CommonName }
		# if entry found...
		If ($null -ne $Entry) {
			# update credential entry
			$Entry.Thumbprint = $CredentialCert.Thumbprint
		}
		# if entry not found...
		Else {
			# create credential entry
			$ListEntry = [PSCustomObject]@{
				ComputerName = $HostName
				Identity     = $Identity
				CommonName   = $CommonName
				Thumbprint   = $CredentialCert.Thumbprint
				Path         = [string]::Empty
			}
			# add new credential entry to list
			$List.Add($ListEntry)
		}
	}

	# display list entries
	$List | Sort-Object -Property 'Identity', 'CommonName' | Format-Table -AutoSize ComputerName, Identity, CommonName, Thumbprint, Path
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
	Specifies the mode for the function. Must be one of: Grant, Revoke, Reset, Show

	.PARAMETER Principals
	Specifies one or more security principals.

	.PARAMETER ComputerName
	Specifies the name of one or more remote computers.

	.INPUTS
	None.

	.OUTPUTS
	None.

	#>

	[CmdletBinding(DefaultParameterSetName = 'Identity')]
	Param (
		[Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Thumbprint')]
		[string]$Thumbprint,
		[Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Identity')]
		[string]$Identity,
		[Parameter(Mandatory = $true, Position = 1)][ValidateSet('Grant', 'Revoke', 'Reset', 'Show')]
		[string]$Mode,
		[Parameter(Mandatory = $false)]
		[object[]]$Principals,
		[Parameter(Mandatory = $false)]
		[string[]]$ComputerName,
		[Parameter(DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if identity contains invalid characters...
	If ($PSBoundParameters.ContainsKey('Identity') -and (Test-CmsInvalidIdentity -Identity $Identity)) {
		# warn and return
		Write-Warning -Message "the value provided for the Identity parameter contains one or more of the following invalid characters: '\' (backslash), '=' (equal sign)"
		Return
	}

	# if computername provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# remove ComputerName parameter from bound parameters
		$null = $PSBoundParameters.Remove('ComputerName')

		# define required functions
		$FunctionNames = 'Test-CmsInvalidIdentity', 'Get-CertificatePrivateKeyPath', 'Update-CmsCredentialAccess'

		# define list for function script blocks
		$FunctionScriptBlocks = [System.Collections.Generic.List[System.String]]::new()

		# add script block for required functions to list
		ForEach ($FunctionName in $FunctionNames) {
			# get function definition
			Try {
				$FunctionDefinition = (Get-Command -Name $FunctionName -ErrorAction 'Stop').Definition
			}
			Catch {
				Write-Warning -Message "could not retrieve definition on '$Hostname' for function: $FunctionName"
				Throw $_
			}
			# create function script block and add to list
			$FunctionScriptBlocks.Add("function $FunctionName {$FunctionDefinition}")
		}

		# update access to credential on remote computer
		ForEach ($RemoteComputerName in $ComputerName) {
			# if remote computer name is local computer name...
			If ($RemoteComputerName -match "^$Hostname($|\..*)") {
				# set include local computer then continue
				$local:IncludeLocalComputer = $true
				Continue
			}
			# run function on remote computer
			Try {
				Invoke-Command -ComputerName $RemoteComputerName -ScriptBlock {
					# import functions
					ForEach ($FunctionScriptBlock in $using:FunctionScriptBlocks) {
						. ([ScriptBlock]::Create($FunctionScriptBlock))
					}
					# run functions
					Update-CmsCredentialAccess @using:PSBoundParameters
				}
			}
			Catch {
				Write-Warning -Message "could not invoke function(s) on '$RemoteComputerName' computer: $($_.Exception.Message)"
				Throw $_
			}
		}

		# if include local computer not set...
		If ($null -eq $local:IncludeLocalComputer) {
			# return after running function on remote computers
			Return
		}
	}

	# if thumbprint provided...
	If ($PSBoundParameters.ContainsKey('Thumbprint')) {
		# create path for certificate by thumbprint
		$CertificatePath = Join-Path -Path $CertStoreLocation -ChildPath $Thumbprint
		# retrieve certificate by thumbprint
		Try {
			$Certificate = Get-Item -Path $CertificatePath -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not locate certificate in '$CertStoreLocation' on '$Hostname' with thumbprint: $Thumbprint"
			Throw $_
		}
	}
	# if thumbprint not provided...
	Else {
		# define pattern as organizational unit of Identity followed by organization of CmsCredentials
		$Pattern = "OU=$Identity, O=CmsCredentials$"
		# retrieve latest certificate with matching subject
		Try {
			$Certificate = Get-ChildItem -Path $CertStoreLocation -DocumentEncryptionCert -ErrorAction 'Stop' | Where-Object { Select-String -InputObject $_.Subject -Pattern $Pattern -Quiet } | Sort-Object -Property 'NotBefore' | Select-Object -Last 1
		}
		Catch {
			Throw $_
		}

		# if certificate not found...
		If ($null -eq $local:Certificate) {
			# declare and return
			Write-Warning -Message "could not locate certificate in '$CertStoreLocation' on '$Hostname' with identity: $Identity"
			Throw [System.Management.Automation.ItemNotFoundException]
		}
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
		'Show' {
			$AclObject.Access | Format-Table -Property @(
				# display current hostname as computername
				@{Name = 'ComputerName'; Expression = { $Hostname } }
				# display identity reference as principal
				@{Name = 'Principal'; Expression = { $_.IdentityReference } }
				# display file system rights as access but remove ', Synchronize' from read to avoid confusion
				@{Name = 'Access'; Expression = { $_.FileSystemRights.ToString().Replace(', Synchronize', $null) } }
			)
			Return
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

	# grant access to credential on local computer
	Try {
		Update-CmsCredentialAccess @PSBoundParameters
	}
	Catch {
		Write-Warning -Message "could not call Update-CmsCredentialAccess function on '$Hostname' computer: $($_.Exception.Message)"
		Throw $_
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

	# grant access to credential on local computer
	Try {
		Update-CmsCredentialAccess @PSBoundParameters
	}
	Catch {
		Write-Warning -Message "could not call Update-CmsCredentialAccess function on '$Hostname' computer: $($_.Exception.Message)"
		Throw $_
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

	# grant access to credential on local computer
	Try {
		Update-CmsCredentialAccess @PSBoundParameters
	}
	Catch {
		Write-Warning -Message "could not call Update-CmsCredentialAccess function on '$Hostname' computer: $($_.Exception.Message)"
		Throw $_
	}
}

Function Show-CmsCredentialAccess {
	<#
	.SYNOPSIS
	Displays access to the private key protecting a CMS credential

	.DESCRIPTION
	Displays access to the private key protecting a CMS credential. Read access to the associated private key is required to decrypt a CMS credential.

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
	PS> Show-CmsCredentialAccess -Identity "testcredential"

	.EXAMPLE
	PS> Show-CmsCredentialAccess -Identity "testcredential" -ComputerName "server1", "server2"

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
	$PSBoundParameters.Add('Mode', 'Show')

	# grant access to credential on local computer
	Try {
		Update-CmsCredentialAccess @PSBoundParameters
	}
	Catch {
		Write-Warning -Message "could not call Update-CmsCredentialAccess function on '$Hostname' computer: $($_.Exception.Message)"
		Throw $_
	}
}

# define functions to export
$FunctionsToExport = @(
	'Export-CmsCredentialCertificate'
	'New-CmsCredentialCertificate'
	'Get-CmsCredential'
	'Protect-CmsCredential'
	'Remove-CmsCredential'
	'Show-CmsCredential'
	'Grant-CmsCredentialAccess'
	'Reset-CmsCredentialAccess'
	'Revoke-CmsCredentialAccess'
	'Show-CmsCredentialAccess'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport
