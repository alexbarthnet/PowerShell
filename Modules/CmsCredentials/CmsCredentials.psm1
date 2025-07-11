Function Invoke-Function {
	Param(
		[Parameter(Mandatory = $true, ValueFromPipeline = $true)]
		[string[]]$ComputerName,
		[Parameter(Mandatory = $false, Position = 0)]
		[string]$Function = (Get-PSCallStack)[0].FunctionName,
		[Parameter(Mandatory = $false)]
		[hashtable]$Parameters = (Get-Variable -Name 'PSBoundParameters' -Scope 1 -ValueOnly),
		[Parameter(Mandatory = $false)]
		[string[]]$AdditionalFunctions,
		[Parameter(Mandatory = $false)]
		[string[]]$PrerequisiteFunctions,
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if parameters contains computer name...
	If ($Parameters.ContainsKey('ComputerName')) {
		# remove ComputerName parameter from parameters
		$null = $Parameters.Remove('ComputerName')
	}

	# create list for function names and populate with primary function
	$FunctionNames = [System.Collections.Generic.List[System.String]]::new()

	# add function name to list
	$FunctionNames.Add($Function)

	# add additional functions to list
	ForEach ($AdditionalFunction in $local:AdditionalFunctions) {
		# if function not already in list...
		If (!$local:FunctionNames.Contains($AdditionalFunction)) {
			$local:FunctionNames.Add($AdditionalFunction)
		}
	}

	# add prerequisite functions to list
	ForEach ($PrerequisiteFunction in $local:PrerequisiteFunctions) {
		# if function not already in list...
		If (!$local:FunctionNames.Contains($PrerequisiteFunction)) {
			$local:FunctionNames.Add($PrerequisiteFunction)
		}
	}

	# create list for function script blocks
	$FunctionScriptBlocks = [System.Collections.Generic.List[System.String]]::new()

	# process each function
	ForEach ($FunctionName in $local:FunctionNames) {
		# get function definition
		Try {
			$FunctionDefinition = (Get-Command -Name $FunctionName -CommandType 'Function' -ErrorAction 'Stop').Definition
		}
		Catch {
			Write-Warning -Message "could not retrieve definition for '$FunctionName' function on host: $local:Hostname"
			Throw $_
		}

		# if function definition is empty...
		If ([string]::IsNullOrEmpty($local:FunctionDefinition)) {
			Write-Warning -Message "found empty definition for '$FunctionName' function on host: $local:Hostname"
			Throw [System.Management.Automation.ErrorRecord]::new([System.ArgumentException]::new(), 'Function definition is an empty string', 'InvalidData', $FunctionName)
		}

		# create function script block and add to list
		$local:FunctionScriptBlocks.Add("function $FunctionName {$FunctionDefinition}")
	}

	# show credential on remote computer
	:NextRemoteComputer ForEach ($RemoteComputerName in $local:ComputerName) {
		# if remote computer name is local computer name...
		If ($RemoteComputerName.Split('.')[0] -eq $local:Hostname) {
			# run prerequisite functions on local computer
			ForEach ($PrerequisiteFunction in $local:PrerequisiteFunctions) {
				. $PrerequisiteFunction
			}

			# run function
			& $local:Function @local:Parameters

			# continue to next remote computer
			Continue NextRemoteComputer
		}

		# define script for Invoke-Command
		$ScriptBlock = {
			# import functions
			ForEach ($FunctionScriptBlock in $using:FunctionScriptBlocks) {
				. ([ScriptBlock]::Create($FunctionScriptBlock))
			}

			# run prerequisite functions
			ForEach ($PrerequisiteFunction in $using:PrerequisiteFunctions) {
				. $PrerequisiteFunction
			}

			# run function
			. $using:Function @using:Parameters
		}

		# run function on remote computer
		Try {
			Invoke-Command -ComputerName $local:RemoteComputerName -ScriptBlock $local:ScriptBlock
		}
		Catch {
			Write-Warning -Message "could not invoke $local:Function function on remote host: $local:RemoteComputerName"
			Throw $_
		}
	}
}

Function Find-CmsCertificate {
	<#
	.SYNOPSIS
	Retrieves a certificate used to protect a credential with CMS.

	.DESCRIPTION
	Retrieves a certificate used to protect a credential with CMS.

	.PARAMETER Identity
	Specifies the identity of an existing CMS certificate. Cannot be combined with the Thumbprint or PfxFile parameters.

	.PARAMETER Thumbprint
	Specifies the thumbprint of an existing CMS certificate. Cannot be combined with the Identity or PfxFile parameters.

	.PARAMETER PfxFile
	Specifies the path to a PFX file containing an existing CMS certificate. Cannot be combined with the Identity or Thumbprint parameters.

	.PARAMETER All
	Specifies that all matching CMS certificates should be returned. Requires the Identity parameter.

	.PARAMETER AllowEmptyReturn
	Specifies that no error should be returned when no CMS certificates are found. Requires the Identity parameter.

	.PARAMETER Password
	Specifies the password to the PFX file as a secure string. Requires the PfxFile parameter.

	.INPUTS
	None.

	.OUTPUTS
	System.Security.Cryptography.X509Certificates.X509Certificate2

	.EXAMPLE
	PS> Find-CmsCertificate -Identity "testcredential"

	#>

	[CmdletBinding(DefaultParameterSetName = 'Identity')]
	Param(
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'Thumbprint')]
		[string]$Thumbprint,
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'PfxFile')]
		[string]$PfxFile,
		[Parameter(Position = 1, Mandatory = $false, ParameterSetName = 'PfxFile')]
		[securestring]$Password,
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'Identity')]
		[string]$Identity,
		[Parameter(Position = 1, Mandatory = $false, ParameterSetName = 'Identity')]
		[switch]$All,
		[Parameter(Mandatory = $false)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
		[Parameter(Mandatory = $false)]
		[switch]$AllowEmptyReturn,
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if thumbprint provided...
	If ($PSBoundParameters.ContainsKey('Thumbprint')) {
		# define parameters string for reporting
		$WithParameters = "with '{0}' thumbprint in '{1}' store" -f $local:Thumbprint, $local:CertStoreLocation

		# create path for certificate by thumbprint
		$CertificatePath = Join-Path -Path $local:CertStoreLocation -ChildPath $local:Thumbprint

		# retrieve certificate by thumbprint
		Try {
			$Certificate = Get-Item -Path $local:CertificatePath -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not locate certificate $local:WithParameters on host: $local:Hostname"
			Throw $_
		}
	}

	# if PFX file provided...
	If ($PSBoundParameters.ContainsKey('PfxFile')) {
		# if PfxFile is not an absolute path...
		If (![System.IO.Path]::IsPathRooted($PfxFile)) {
			# get unresolved absolute path
			Try {
				$PfxFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PfxFile)
			}
			Catch {
				Write-Warning "could not create absolute path from the provided PfxFile parameter: $PfxFile"
				Throw $_
			}
		}

		# define parameters string for reporting
		$WithParameters = "with '{0}' path" -f $local:PfxFile

		# retrieve PFX file by path
		Try {
			$null = Get-Item -Path $local:PfxFile -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not locate PFX file $local:WithParameters on host: $local:Hostname"
			Throw $_
		}

		# define required parameters for Get-PfxData
		$GetPfxData = @{
			FilePath    = $local:PfxFile
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# define optional parameters for Get-PfxData
		If ($PSBoundParameters.ContainsKey('Password')) {
			$GetPfxData.Add('Password', $local:Password)
		}

		# get PFX data from PFX file
		Try {
			$PfxData = Get-PfxData @local:GetPfxData
		}
		Catch {
			Write-Warning -Message "could not retrieve PFX data from file $local:WithParameters on host: $local:Hostname"
			Throw $_
		}

		# filter certificate by EKU
		Try {
			$local:MatchingCertificates = $local:PfxData.EndEntityCertificates.Where({ $_.EnhancedKeyUsageList.FriendlyName -contains 'Document Encryption' })
		}
		Catch {
			Write-Warning -Message "could not filter for Document Encryption certificates in PFX data from file $local:WithParameters on host: $local:Hostname"
			Throw $_
		}

		# retrieve latest certificate
		Try {
			$Certificate = $local:MatchingCertificates | Sort-Object -Property 'NotBefore' | Select-Object -Last 1
		}
		Catch {
			Write-Warning -Message "could not sort or select latest Document Encryption certificates from '$local:CertStoreLocation' on host: $local:Hostname"
			Throw $_
		}

		# if certificate not found and allow empty return not requested...
		If (!$local:Certificate -and !$local:AllowEmptyReturn) {
			# create exception
			$Exception = [System.Management.Automation.ItemNotFoundException]::new("Find-CmsCertificate : Could not find Document Encryption certificate in PFX file $local:WithParameters")
			# throw error record with exception
			Throw [System.Management.Automation.ErrorRecord]::new($Exception, 'CertificateNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $PfxFile)
		}
	}

	# if an identity provided...
	If ($PSBoundParameters.ContainsKey('Identity')) {
		# define parameters string for reporting
		$WithParameters = "with '{0}' identity in '{1}' store" -f $local:Identity, $local:CertStoreLocation

		# retrieve CMS certificates
		Try {
			$Certificates = Get-ChildItem -Path $local:CertStoreLocation -DocumentEncryptionCert -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not retrieve Document Encryption certificates from '$local:CertStoreLocation' store on host: $local:Hostname"
			Throw $_
		}

		# define pattern matches a GUID
		$Pattern = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'

		# define a string that starts with an organizational unit of Identity and ends with with organization of CmsCredentials
		$Tail = "OU=$Identity, O=CmsCredentials"

		# filter certificate where subject matches pattern and ends with tail
		Try {
			$MatchingCertificates = $local:Certificates.Where({ $_.GetNameInfo('SimpleName', $false) -match $local:Pattern -and $_.Subject.EndsWith($local:Tail, [System.StringComparison]::InvariantCultureIgnoreCase) })
		}
		Catch {
			Write-Warning -Message "could not filter Document Encryption certificates from '$local:CertStoreLocation' store on host: $local:Hostname"
			Throw $_
		}

		# if all certificates requested...
		If ($PSBoundParameters.ContainsKey('All')) {
			# return all matching certificates without regards to AllowEmptyReturn parameter
			Return $MatchingCertificates
		}

		# retrieve latest certificate
		Try {
			$Certificate = $local:MatchingCertificates | Sort-Object -Property 'NotBefore' | Select-Object -Last 1
		}
		Catch {
			Write-Warning -Message "could not sort or select latest Document Encryption certificates from '$local:CertStoreLocation' on host: $local:Hostname"
			Throw $_
		}

		# if certificate not found and allow empty return not requested...
		If (!$local:Certificate -and !$local:AllowEmptyReturn) {
			# create exception
			$Exception = [System.Management.Automation.ItemNotFoundException]::new("Find-CmsCertificate : Could not find Document Encryption certificate $local:WithParameters")
			# throw error record with exception
			Throw [System.Management.Automation.ErrorRecord]::new($Exception, 'CertificateNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Identity)
		}
	}

	# if certificate not found...
	If (!$local:Certificate) {
		Return $null
	}

	# define invalid subject string...
	$InvalidSubject = [System.Collections.Generic.List[System.String]]::new()

	# if invalid certificate subject found...
	switch ($local:Certificate.Subject) {
		# empty string
		{ [string]::IsNullOrEmpty($_) } {
			$InvalidSubject.Add('empty string')
		}
		# escaped backslash
		{ $_.Contains('\\') } {
			$InvalidSubject.Add('escaped backslash')
		}
		# escaped comma
		{ $_.Contains('\,') } {
			$InvalidSubject.Add('escaped comma')
		}
		# escaped equal sign
		{ $_.Contains('\=') } {
			$InvalidSubject.Add('escaped equal sign')
		}
		# escaped double quotation mark
		{ $_.Contains('\"') } {
			$InvalidSubject.Add('escaped double quotes')
		}
		# escaped single quotation mark
		{ $_.Contains('\''') } {
			$InvalidSubject.Add('escaped single quotes')
		}
	}

	# if invalid subject defined...
	If ($local:InvalidSubject.Count) {
		Write-Warning -Message "found certificate with an invalid subject ($($local:InvalidSubject -join ', ') $local:Parameters on host: $local:Hostname"
		Return $null
	}

	# return certificate
	Return $local:Certificate
}

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
		$CertificatePath = Join-Path -Path $local:CertStoreLocation -ChildPath $local:Thumbprint
		# retrieve certificate by thumbprint
		Try {
			$Certificate = Get-Item -Path $local:CertificatePath -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not locate certificate with '$($local:Certificate.Thumbprint)' thumbprint in '$local:CertStoreLocation' store on host: $local:Hostname"
			Throw $_
		}
	}

	# if certificate does not have a private key...
	If (!$local:Certificate.HasPrivateKey) {
		Write-Warning -Message "could not locate private key for certificate with '$($local:Certificate.Thumbprint)' thumbprint on host: $local:Hostname"
		Return $null
	}

	# retrieve algorithm for keypair
	$Algorithm = $local:Certificate.PublicKey.Oid.FriendlyName

	# retrieve private key using algorithm-specific method
	switch ($local:Algorithm) {
		'DSA' {
			$PrivateKey = [System.Security.Cryptography.X509Certificates.DSACertificateExtensions]::GetDSAPrivateKey($local:Certificate)
		}
		'ECDsa' {
			$PrivateKey = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($Clocal:ertificate)
		}
		'RSA' {
			$PrivateKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($local:Certificate)
		}
		Default {
			Write-Warning -Message "found unsupported '$local:Algorithm' algorithm for certificate with '$($local:Certificate.Thumbprint)' thumbprint on host: $local:Hostname"
			Return $null
		}
	}

	# if private key was not retrieved...
	If ($null -eq $local:PrivateKey) {
		Write-Verbose -Message "could not retrieve private key for certificate with '$($local:Certificate.Thumbprint)' thumbprint on host: $local:Hostname"
		Return $null
	}

	# retrieve private key unique name
	$UniqueName = $local:PrivateKey.Key.UniqueName

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
		$PrivateKeyPath = Get-ChildItem -Path $local:Path -Recurse -Filter $local:UniqueName | Select-Object -First 1 -ExpandProperty 'FullName'
	}
	Catch {
		Write-Warning -Message "could not search '$local:Path' path for object with '$local:UniqueName' unique name on host: $local:Hostname"
		Throw $_
	}

	# if private key file found...
	If ($local:PrivateKeyPath) {
		Return $local:PrivateKeyPath
	}
	Else {
		Write-Warning -Message "could not find path to private key for certificate with '$($local:Certificate.Thumbprint)' thumbprint on host: $local:Hostname"
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

	Param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$Identity,
		[Parameter(Mandatory = $false)]
		[string]$Pattern = '[\\,="]' # '[^\w\s\.\-]'
	)

	# test length
	If ([string]::IsNullOrEmpty($Identity) -or $Identity.Length -gt 64) {
		Return $true
	}

	# test pattern against identity
	If (Select-String -InputObject $local:Identity -Pattern $local:Pattern -Quiet) {
		Return $true
	}

	# return false if no tests passed
	Return $false
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

	Param (
		[Parameter(Mandatory = $true, Position = 0)]
		[string]$Subject,
		[Parameter(Mandatory = $false)]
		[string]$Pattern = '[\\"]'
	)

	# test pattern against identity
	If (Select-String -InputObject $local:Subject -Pattern $local:Pattern -Quiet) {
		Return $true
	}
	Else {
		Return $false
	}
}

Function Export-CmsCredentialCertificate {
	<#
	.SYNOPSIS
	Exports the public key and PFX file of a certificate for protecting credentials with CMS.

	.DESCRIPTION
	Exports the public key and PFX file of a certificate for protecting credentials with CMS. The PFX file is protected using DPAPI.

	.PARAMETER Certificate
	Specifies a certificate for protecting credentials with CMS. Cannot be combined with the Thumbprint or Identity parameter.

	.PARAMETER Thumbprint
	Specifies the thumbprint of a certificate for protecting credentials with CMS. Cannot be combined with the Certificate or Identity parameter.

	.PARAMETER Identity
	Specifies the identity of a certificate for protecting credentials with CMS. Cannot be combined with the Certificate or Thumbprint parameter.

	.PARAMETER ProtectTo
	Specifies one or more security principals to grant access to the PFX file via DPAPI. Cannot be combined with the Password parameter

	.PARAMETER Password
	Specifies the password to the PFX file as a secure string. Cannot be combined with the ProtectTo parameter

	.PARAMETER Path
	Specifies the path for the exported public key and PFX file when not overriden by the FilePath or PfxFilePath parameters.

	.PARAMETER FilePath
	Specifies the path for the exported public key.

	.PARAMETER PfxFile
	Specifies the path for the exported PFX file.

	.INPUTS
	System.Security.Cryptography.X509Certificates.X509Certificate2.

	.OUTPUTS
	None.

	.NOTES
	The -ProtectTo parameter of the Export-PfxCertificate cannot be used in a remote session due to second-hop limitations.

	#>

	[CmdletBinding(DefaultParameterSetName = 'CertificateWithProtectTo')]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'CertificateWithProtectTo', ValueFromPipeline = $true)]
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'CertificateWithPassword', ValueFromPipeline = $true)]
		[System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'ThumbprintWithProtectTo')]
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'ThumbprintWithPassword')]
		[string]$Thumbprint,
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'IdentityWithProtectTo')]
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'IdentityWithPassword')]
		[string]$Identity,
		[Parameter(Position = 1, Mandatory = $true, ParameterSetName = 'CertificateWithProtectTo')]
		[Parameter(Position = 1, Mandatory = $true, ParameterSetName = 'ThumbprintWithProtectTo')]
		[Parameter(Position = 1, Mandatory = $true, ParameterSetName = 'IdentityWithProtectTo')]
		[string[]]$ProtectTo,
		[Parameter(Position = 1, Mandatory = $true, ParameterSetName = 'CertificateWithPassword')]
		[Parameter(Position = 1, Mandatory = $true, ParameterSetName = 'ThumbprintWithPassword')]
		[Parameter(Position = 1, Mandatory = $true, ParameterSetName = 'IdentityWithPassword')]
		[securestring]$Password,
		[Parameter(Position = 2)]
		[string]$FilePath,
		[Parameter(Position = 3)]
		[string]$PfxFile,
		[Parameter(Position = 4)]
		[switch]$SkipPublicKey,
		[Parameter(Position = 5)]
		[switch]$SkipPfxFile,
		[Parameter(DontShow)]
		[string]$Path = $CmsCredentials['PathForCmsFiles'],
		[Parameter(DontShow)]
		[string]$PfxPath = $CmsCredentials['PathForPfxFiles'],
		[Parameter(DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if identity is too long or contains invalid characters...
	If ($PSBoundParameters.ContainsKey('Identity') -and (Test-CmsInvalidIdentity -Identity $Identity)) {
		# warn and return
		Write-Warning -Message "the value provided for the Identity parameter contains more than 64 characters or one or more of the following invalid characters: '\' (backslash), '=' (equal sign)"
		Return
	}

	# if thumbprint provided...
	If ($PSBoundParameters.ContainsKey('Thumbprint')) {
		# find CMS certificate with thumbprint
		Try {
			$Certificate = Find-CmsCertificate -Thumbprint $local:Thumbprint -CertStoreLocation $local:CertStoreLocation
		}
		Catch {
			Throw $_
		}
	}

	# if identity provided...
	If ($PSBoundParameters.ContainsKey('Identity')) {
		# find CMS certificate with identity
		Try {
			$Certificate = Find-CmsCertificate -Identity $local:Identity -CertStoreLocation $local:CertStoreLocation
		}
		Catch {
			Throw $_
		}
	}

	# if certificate not found...
	If (!$local:Certificate) {
		# return without warning; warnings provided by Find-CmsCertificate
		Return
	}

	# if skip public key not requested...
	If (!$local:SkipPublicKey) {
		# if FilePath provided...
		If ($PSBoundParameters.ContainsKey('FilePath')) {
			# if FilePath is not an absolute path...
			If (![System.IO.Path]::IsPathRooted($FilePath)) {
				# get unresolved absolute path
				Try {
					$FilePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FilePath)
				}
				Catch {
					Write-Warning "could not create absolute path from the provided FilePath parameter: $FilePath"
					Throw $_
				}
			}
		}
		# if FilePath not provided...
		Else {
			#retrieve simple name from certificate
			$ChildPath = $local:Certificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)

			# define FilePath as simple name with .cer extension in default cms file path
			$FilePath = Join-Path -Path $local:Path -ChildPath "$local:ChildPath.cer"
		}

		# if FilePath not found...
		If (![System.IO.File]::Exists($FilePath)) {
			# define parameters for New-Item
			$NewItem = @{
				Path        = $local:FilePath
				Force       = $true
				ItemType    = 'File'
				ErrorAction = [System.Management.Automation.ActionPreference]::Stop
			}

			# create file and path to file
			Try {
				$null = New-Item @NewItem | Remove-Item -Force
			}
			Catch {
				Write-Warning -Message "could not create file with '$local:FilePath' path on host: $local:Hostname"
				Throw $_
			}
		}

		# define parameters for Export-PfxCertificate
		$ExportCertificate = @{
			Cert        = $local:Certificate
			FilePath    = $local:FilePath
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# export certificate as .pfx
		Try {
			$null = Export-Certificate @local:ExportCertificate
		}
		Catch {
			Write-Warning -Message "could not export public key for certificate with '$($local:Certificate.Thumbprint)' thumbprint on host: $local:Hostname"
			Throw $_
		}

		# if FilePath not provided...
		If (!$PSBoundParameters.ContainsKey('FilePath')) {
			Write-Host "exported public key for certificate with '$($local:Certificate.Thumbprint)' thumbprint to path: $local:FilePath"
		}
	}

	# if skip pfx file not requested...
	If (!$local:SkipPfxFile) {
		# if PfxFile provided...
		If ($PSBoundParameters.ContainsKey('PfxFile')) {
			# if PfxFile is not an absolute path...
			If (![System.IO.Path]::IsPathRooted($PfxFile)) {
				# get unresolved absolute path
				Try {
					$PfxFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PfxFile)
				}
				Catch {
					Write-Warning "could not create absolute path from the provided PfxFile parameter: $PfxFile"
					Throw $_
				}
			}
		}
		# if PfxFile not provided...
		Else {
			#retrieve simple name from certificate
			$ChildPath = $local:Certificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)

			# define PfxFile as simple name with .pfx extension in default pfx file path
			$PfxFile = Join-Path -Path $local:PfxPath -ChildPath "$local:ChildPath.pfx"
		}

		# define parameters for New-Item
		$NewItem = @{
			Path        = $local:PfxFile
			Force       = $true
			ItemType    = 'File'
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# create file and path to file
		Try {
			$null = New-Item @NewItem | Remove-Item -Force
		}
		Catch {
			Write-Warning -Message "could not create file with '$local:PfxFile' path on host: $local:Hostname"
			Throw $_
		}

		# define parameters for Export-PfxCertificate
		$ExportPfxCertificate = @{
			Cert                  = $local:Certificate
			FilePath              = $local:PfxFile
			ChainOption           = [Microsoft.CertificateServices.Commands.ExportChainOption]::EndEntityCertOnly
			CryptoAlgorithmOption = [Microsoft.CertificateServices.Commands.CryptoAlgorithmOptions]::AES256_SHA256
			ErrorAction           = [System.Management.Automation.ActionPreference]::Stop
		}

		# if ProtectTo provided...
		If ($PSBoundParameters.ContainsKey('ProtectTo')) {
			# update parameters for Export-PfxCertificate
			$ExportPfxCertificate['ProtectTo'] = $local:ProtectTo
		}

		# if Password to provided...
		If ($PSBoundParameters.ContainsKey('Password')) {
			# update parameters for Export-PfxCertificate
			$ExportPfxCertificate['Password'] = $local:Password
		}

		# export certificate as .pfx
		Try {
			$null = Export-PfxCertificate @local:ExportPfxCertificate
		}
		Catch {
			Write-Warning -Message "could not export PFX file for certificate with '$($local:Certificate.Thumbprint)' thumbprint on host: $local:Hostname"
			Throw $_
		}

		# if PfxFile not provided...
		If (!$PSBoundParameters.ContainsKey('PfxFile')) {
			Write-Host "exported PFX file for certificate with '$($local:Certificate.Thumbprint)' thumbprint to path: $local:PfxFile"
		}
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

	# if identity is too long or contains invalid characters...
	If (Test-CmsInvalidIdentity -Identity $local:Identity) {
		# warn and return
		Write-Warning -Message "the value provided for the Identity parameter contains more than 64 characters or one or more of the following invalid characters: '\' (backslash), '=' (equal sign)"
		Return
	}

	# if computername provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# define parameters for Invoke-Function
		$InvokeFunction = @{
			ComputerName = $ComputerName
		}

		# invoke function remotely
		Try {
			Invoke-Function @InvokeFunction
		}
		Catch {
			Throw $_
		}

		# return calling Invoke-Function
		Return
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
			Write-Warning -Message 'CmsCredentials cannot create self-signed certificates on non-Windows platforms'
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

	.PARAMETER Identity
	Specifies the identity of the CMS credential. Cannot be combined with the FilePath parameter.

	.PARAMETER FilePath
	Specifies the path to a CMS credential file. Cannot be combined with the Identity parameter.

	.PARAMETER Certificate
	Specifies the X.509 certificate object that encrypted the CMS credential file. Requires the FilePath parameter and cannot be combined with the Thumbprint or PfxFile parameters.

	.PARAMETER Thumbprint
	Specifies the thumbprint of the X.509 certificate that encrypted the CMS credential file. Requires the FilePath parameter and cannot be combined with the Certificate or PfxFile parameters.

	.PARAMETER PfxFile
	Specifies the path to the PFX file that encrypted the CMS credential file. Requires the FilePath parameter and cannot be combined with the Certificate or Thumbprint parameters.

	.PARAMETER Password
	Specifies the password to the PFX file as a secure string. Requires the PfxFile parameter.

	.PARAMETER ComputerName
	Specifies the name of one or more remote computers. Requires the Identity or Thumbprint parameters.

	.PARAMETER AsPlainText
	Specifies the credential should be returned as a plain-text password. The credential will be returned as a PSCustomObject with Username and Password properties.

	.PARAMETER AsVariable
	Specifies the credential should be stored as a variable instead of returned as an object. The name and scope of the variable are set by the 'VariableName' and 'VariableScope' parameters.

	.PARAMETER VariableName
	Specifies the name of the variable that will store the credential when the AsVariable parameter is set. The default value is 'Credential'

	.PARAMETER VariableScope
	Specifies the scope of the variable that will store the credential when the AsVariable parameter is set. The default value is 'Global'

	.PARAMETER Force
	Specifies that an existing variable with the requested name and scope should be overwritten without prompting.

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
		[Parameter(ParameterSetName = 'Identity', Position = 0, Mandatory)]
		[string]$Identity,
		[Parameter(ParameterSetName = 'FilePath', Position = 0, Mandatory, ValueFromPipeline)]
		[Parameter(ParameterSetName = 'Certificate', Position = 0, Mandatory)]
		[Parameter(ParameterSetName = 'Thumbprint', Position = 0, Mandatory)]
		[Parameter(ParameterSetName = 'PfxFile', Position = 0, Mandatory)]
		[string]$FilePath,
		[Parameter(ParameterSetName = 'Certificate', Position = 1, Mandatory)]
		[System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
		[Parameter(ParameterSetName = 'Thumbprint', Position = 1, Mandatory)]
		[string]$Thumbprint,
		[Parameter(ParameterSetName = 'PfxFile', Position = 1, Mandatory)]
		[string]$PfxFile,
		[Parameter(ParameterSetName = 'PfxFile')]
		[securestring]$Password,
		[Parameter(Mandatory = $false)]
		[switch]$AsPlainText,
		[Parameter(Mandatory = $false)]
		[switch]$AsVariable,
		[Parameter(DontShow)]
		[string]$VariableName = 'Credential',
		[Parameter(DontShow)]
		[string]$VariableScope = 'Global',
		[Parameter(DontShow)]
		[switch]$Force,
		[Parameter(ParameterSetName = 'Identity')]
		[Parameter(ParameterSetName = 'Thumbprint')]
		[string[]]$ComputerName,
		[Parameter(DontShow)]
		[string]$Path = $CmsCredentials['PathForCmsFiles'],
		[Parameter(DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if identity is too long or contains invalid characters...
	If ($PSBoundParameters.ContainsKey('Identity') -and (Test-CmsInvalidIdentity -Identity $Identity)) {
		Write-Warning -Message "the value provided for the Identity parameter contains more than 64 characters or one or more of the following invalid characters: '\' (backslash), '=' (equal sign)"
		Return $null
	}

	# if computername provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# define parameters for Invoke-Function
		$InvokeFunction = @{
			ComputerName          = $ComputerName
			AdditionalFunctions   = 'Find-CmsCertificate', 'Test-CmsInvalidIdentity'
			PrerequisiteFunctions = 'Initialize-CmsCredentialSettings'
		}

		# invoke function remotely
		Try {
			Invoke-Function @InvokeFunction
		}
		Catch {
			Throw $_
		}

		# return calling Invoke-Function
		Return
	}

	# if file path provided...
	If ($PSBoundParameters.ContainsKey('FilePath')) {
		# if FilePath is not an absolute path...
		If (![System.IO.Path]::IsPathRooted($FilePath)) {
			# get unresolved absolute path
			Try {
				$FilePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FilePath)
			}
			Catch {
				Write-Warning "could not create absolute path from the provided FilePath parameter: $FilePath"
				Throw $_
			}
		}

		# if file path is not a file...
		If (![System.IO.File]::Exists($local:FilePath)) {
			Write-Warning -Message "could not locate credential file with '$local:FilePath' path on host: $local:Hostname"
			Return $null
		}
	}

	# if thumbprint provided...
	If ($PSBoundParameters.ContainsKey('Thumbprint')) {
		# find CMS certificate with thumbprint
		Try {
			$Certificate = Find-CmsCertificate -Thumbprint $local:Thumbprint -CertStoreLocation $local:CertStoreLocation
		}
		Catch {
			Throw $_
		}
	}

	# if PFX file provided...
	If ($PSBoundParameters.ContainsKey('PfxFile')) {
		# if PfxFile is not an absolute path...
		If (![System.IO.Path]::IsPathRooted($PfxFile)) {
			# get unresolved absolute path
			Try {
				$PfxFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PfxFile)
			}
			Catch {
				Write-Warning "could not create absolute path from the provided PfxFile parameter: $PfxFile"
				Throw $_
			}
		}

		# define required parameters for Find-CmsCertificate
		$FindCmsCertificate = @{
			PfxFile = $local:PfxFile
		}

		# define optional parameters for Find-CmsCertificate
		If ($PSBoundParameters.ContainsKey('Password')) {
			$FindCmsCertificate.Add('Password', $local:Password)
		}

		# find CMS certificate from PFX file
		Try {
			$Certificate = Find-CmsCertificate @FindCmsCertificate
		}
		Catch {
			Throw $_
		}
	}

	# if identity provided...
	If ($PSBoundParameters.ContainsKey('Identity')) {
		# find CMS certificate with identity
		Try {
			$Certificate = Find-CmsCertificate -Identity $local:Identity -CertStoreLocation $local:CertStoreLocation
		}
		Catch {
			Throw $_
		}
	}

	# if identity provided...
	If ($PSBoundParameters.ContainsKey('Identity')) {
		# if path is not a folder...
		If (!([System.IO.Directory]::Exists($local:Path))) {
			Write-Warning -Message "could not locate folder for credential files with '$local:Path' path on host: $local:Hostname"
			Return $null
		}

		# retrieve CMS credential files
		Try {
			$CredentialFiles = Get-ChildItem -Path $local:Path -Filter '*.txt' -File -ErrorAction 'Stop' | Sort-Object -Property 'LastWriteTime' -Descending
		}
		Catch {
			Write-Warning -Message "could not retrieve credential files from '$local:Path' path on host: $local:Hostname"
			Throw $_
		}

		# define subject as the tail of an X.509 distinguished name with organizational unit of the Identity followed by organization of CmsCredentials
		$Subject = "OU=$local:Identity, O=CmsCredentials"

		# retrieve latest CMS credential file with matching subject
		:CredentialFiles ForEach ($CredentialFile in $CredentialFiles) {
			# create stream reader
			Try {
				$StreamReader = [System.IO.StreamReader]::new($CredentialFile.FullName)
			}
			Catch {
				Write-Warning -Message "could not open credential file with '$($CredentialFile.FullName)' path on host: $local:Hostname"
				Throw $_
			}

			# retrieve first line
			Try {
				$FirstLine = $StreamReader.ReadLine()
			}
			Catch {
				Write-Warning -Message "could not read first line of credential file with '$($CredentialFile.FullName)' path on host: $local:Hostname"
				Throw $_
			}

			# close stream reader
			Try {
				$StreamReader.Close()
			}
			Catch {
				Write-Warning -Message "could not open credential file with '$($CredentialFile.FullName)' path on host: $local:Hostname"
				Throw $_
			}

			# if first line ends with subject...
			If ($FirstLine.EndsWith($local:Subject, [System.StringComparison]::InvariantCultureIgnoreCase)) {
				# set file path and break out of foreach loop
				$FilePath = $CredentialFile.FullName
				Break CredentialFiles
			}
		}

		# if CMS credential file not found...
		If ([string]::IsNullOrEmpty($local:FilePath)) {
			Write-Warning -Message "could not locate credential file for '$Identity' identity in path: $Path"
			Return $null
		}
	}

	# define required parameters for Unprotect-CmsMessage
	$UnprotectCmsMessage = @{
		Path        = $local:FilePath
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# define optional parameters for Unprotect-CmsMessage
	If ($local:Certificate) {
		$UnprotectCmsMessage['To'] = $local:Certificate
	}

	# decrypt content of credential file
	Try {
		$InputObject = Unprotect-CmsMessage @local:UnprotectCmsMessage
	}
	Catch {
		Write-Warning -Message "could not decrypt content in file with '$local:FilePath' path on host: $local:Hostname"
		Throw $_
	}

	# convert content from JSON string into custom object
	Try {
		$PSCustomObject = ConvertFrom-Json -InputObject $local:InputObject -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not convert decrypted content in file with '$local:FilePath' path on host: $local:Hostname"
		Throw $_
	}

	# verify username property
	If ($null -eq $local:PSCustomObject.Username) {
		Write-Warning -Message "could not locate 'Username' property in file with '$local:FilePath' path on host: $local:Hostname"
		Throw [System.Management.Automation.ItemNotFoundException]
	}

	# verify password property
	If ($null -eq $local:PSCustomObject.Password) {
		Write-Warning -Message "could not locate 'Password' property in file with '$local:FilePath' path on host: $local:Hostname"
		Throw [System.Management.Automation.ItemNotFoundException]
	}

	# if variable requested...
	If ($local:AsVariable -and -not $local:Force) {
		# retrieve existing variables in the requested scope
		Try {
			$local:Variables = Get-Variable -Scope $local:VariableScope
		}
		Catch {
			Write-Warning -Message "could not retrieve variables in the '$local:VariableScope' scope on host: $local:Hostname"
		}

		# if requested global variable already set...
		If ($local:VariableName -in $local:Variables.Name) {
			Write-Warning -Message "found existing '$local:VariableName' variable in the '$local:VariableScope' scope on host: $local:Hostname; continue and overwrite variable?" -WarningAction Inquire
		}
	}

	# if plain text requested...
	If ($local:AsPlainText) {
		# if variable requested...
		If ($local:AsVariable) {
			# create variable in requested scope containing PSCustomObject
			Try {
				Set-Variable -Name $local:VariableName -Scope $local:VariableScope -Value $local:PSCustomObject -Force
			}
			Catch {
				Write-Warning -Message "could not return credential as '$local:VariableName' variable in the '$local:VariableScope' scope on host: $local:Hostname"
			}

			# report variable created
			If ($PSCmdlet.ParameterSetName -eq 'Identity') {
				Write-Verbose -Message "created '$local:VariableName' variable with plaintext credential for '$Identity'"
			}
			Else {
				Write-Verbose -Message "created '$local:VariableName' variable with plaintext credential from '$FilePath'"
			}

			# return after creating variable
			Return
		}
		Else {
			# return the PSCustomObject as-is
			Return $local:PSCustomObject
		}
	}

	# if domain not included in credential...
	If ([string]::IsNullOrEmpty($local:PSCustomObject.Domain)) {
		# retrieve username from object as-is
		$Username = $local:PSCustomObject.Username
	}
	Else {
		# combine domain and username from object
		$Username = $local:PSCustomObject.Domain, $local:PSCustomObject.Username -join '\'
	}

	# convert password property into secure string
	Try {
		$SecureString = ConvertTo-SecureString -String $local:PSCustomObject.Password -AsPlainText -Force -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not convert 'Password' property to a SecureString on host: $local:Hostname"
		Throw $_
	}

	# create PSCredential object
	Try {
		$PSCredential = [System.Management.Automation.PSCredential]::new($local:Username, $local:SecureString)
	}
	Catch {
		Write-Warning -Message "could not create PSCredential object on host: $local:Hostname"
		Throw $_
	}

	# if variable requested...
	If ($local:AsVariable) {
		# create variable in requested scope containing PSCredential
		Try {
			Set-Variable -Name $local:VariableName -Scope $local:VariableScope -Value $local:PSCredential -Force
		}
		Catch {
			Write-Warning -Message "could not return credential as '$local:VariableName' variable in the '$local:VariableScope' scope on host: $local:Hostname"
		}

		# report variable created
		If ($PSCmdlet.ParameterSetName -eq 'Identity') {
			Write-Verbose -Message "created '$local:VariableName' variable with PSCredential object for '$Identity'"
		}
		Else {
			Write-Verbose -Message "created '$local:VariableName' variable with PSCredential object from '$FilePath'"
		}

		# return after creating variable
		Return
	}
	Else {
		# return PSCredential object
		Return $local:PSCredential
	}
}

Function Export-CmsCredential {
	<#
	.SYNOPSIS
	Exports the CMS credential and certificate files for the provided identity.

	.DESCRIPTION
	Exports the CMS credential and certificate files for the provided identity.

	.PARAMETER Identity
	Specifies the identity of the CMS credential.

	.PARAMETER FilePath
	Specifies the path to the CMS credential file.

	.PARAMETER PfxFile
	Specifies the path to the PFX file that containing the CMS certificate.

	.PARAMETER ProtectTo
	Specifies one or more security principals to grant access to the PFX file via DPAPI. Cannot be combined with the Password parameter

	.PARAMETER Password
	Specifies the password to the PFX file as a secure string. Cannot be combined with the ProtectTo parameter

	.PARAMETER Force
	Switch to overwrite an existing credential file and PFX file.

	.INPUTS
	None.

	.OUTPUTS
	None.

	#>

	[CmdletBinding(DefaultParameterSetName = 'ProtectTo')]
	Param(
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'ProtectTo')]
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'Password')]
		[string]$Identity,
		[Parameter(Position = 1, Mandatory = $true, ParameterSetName = 'ProtectTo')]
		[Parameter(Position = 1, Mandatory = $true, ParameterSetName = 'Password')]
		[string]$FilePath,
		[Parameter(Position = 2, Mandatory = $true, ParameterSetName = 'ProtectTo')]
		[Parameter(Position = 2, Mandatory = $true, ParameterSetName = 'Password')]
		[string]$PfxFile,
		[Parameter(Position = 3, Mandatory = $true, ParameterSetName = 'ProtectTo')]
		[string[]]$ProtectTo,
		[Parameter(Position = 3, Mandatory = $true, ParameterSetName = 'Password')]
		[securestring]$Password,
		[Parameter(DontShow)]
		[switch]$Force,
		[Parameter(DontShow)]
		[string]$Path = $CmsCredentials['PathForCmsFiles'],
		[Parameter(DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# find CMS certificate with identity
	Try {
		$Certificate = Find-CmsCertificate -Identity $local:Identity -CertStoreLocation $local:CertStoreLocation
	}
	Catch {
		Throw $_
	}

	# if path is not a folder...
	If (!([System.IO.Directory]::Exists($local:Path))) {
		Write-Warning -Message "could not locate folder for credential files with '$local:Path' path on host: $local:Hostname"
		Return $null
	}

	# retrieve CMS credential files
	Try {
		$CredentialFiles = Get-ChildItem -Path $local:Path -Filter '*.txt' -File -ErrorAction 'Stop' | Sort-Object -Property 'LastWriteTime' -Descending
	}
	Catch {
		Write-Warning -Message "could not retrieve credential files from '$local:Path' path on host: $local:Hostname"
		Throw $_
	}

	# define subject as the tail of an X.509 distinguished name with organizational unit of the Identity followed by organization of CmsCredentials
	$Subject = "OU=$local:Identity, O=CmsCredentials"

	# retrieve latest CMS credential file with matching subject
	:CredentialFiles ForEach ($CredentialFile in $CredentialFiles) {
		# create stream reader
		Try {
			$StreamReader = [System.IO.StreamReader]::new($CredentialFile.FullName)
		}
		Catch {
			Write-Warning -Message "could not open credential file with '$($CredentialFile.FullName)' path on host: $local:Hostname"
			Throw $_
		}

		# retrieve first line
		Try {
			$FirstLine = $StreamReader.ReadLine()
		}
		Catch {
			Write-Warning -Message "could not read first line of credential file with '$($CredentialFile.FullName)' path on host: $local:Hostname"
			Throw $_
		}

		# close stream reader
		Try {
			$StreamReader.Close()
		}
		Catch {
			Write-Warning -Message "could not open credential file with '$($CredentialFile.FullName)' path on host: $local:Hostname"
			Throw $_
		}

		# if first line ends with subject...
		If ($FirstLine.EndsWith($local:Subject, [System.StringComparison]::InvariantCultureIgnoreCase)) {
			# set file path and break out of foreach loop
			$OriginalFilePath = $CredentialFile.FullName
			Break CredentialFiles
		}
	}

	# if CMS credential file not found...
	If ([string]::IsNullOrEmpty($local:OriginalFilePath)) {
		Write-Warning -Message "could not locate credential file for '$Identity' identity in path: $Path"
		Return $null
	}

	# define initial parameters for CMS certificate export
	$ExportCmsCredentialCertificate = @{
		Certificate   = $Certificate
		PfxFilePath   = $PfxFile
		SkipPublicKey = $true
	}

	# if ProtectTo provided...
	If ($PSBoundParameters.ContainsKey('ProtectTo')) {
		$ExportCmsCredentialCertificate['ProtectTo'] = $ProtectTo
	}

	# if Password provided...
	If ($PSBoundParameters.ContainsKey('Password')) {
		$ExportCmsCredentialCertificate['Password'] = $Password
	}

	# export CMS certificate
	Try {
		Export-CmsCredentialCertificate @ExportCmsCredentialCertificate
	}
	Catch {
		Throw $_
	}

	# if destination file found and force not requested...
	If ([System.IO.File]::Exists($FilePath) -and -not $Force) {
		Write-Warning -Message 'skipping credential file export; found existing credential file with matching guid'
	}
	# if destination file not found or force requested...
	Else {
		# define parameters for New-Item
		$NewItem = @{
			Path        = $local:FilePath
			Force       = $true
			ItemType    = 'File'
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# create file and path to file
		Try {
			$null = New-Item @NewItem | Remove-Item -Force
		}
		Catch {
			Write-Warning -Message "could not create file with '$local:FilePath' path on host: $local:Hostname"
			Throw $_
		}

		# define parameters for Copy-Item
		$CopyItem = @{
			Path        = $local:OriginalFilePath
			Destination = $local:FilePath
			Force       = $true
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# export CMS credential file
		Try {
			Copy-Item @CopyItem
		}
		Catch {
			Write-Warning -Message "could not copy '$local:OriginalFilePath' file to '$local:FilePath' path on host: $local:Hostname"
			Throw $_
		}
	}
}

Function Import-CmsCredential {
	<#
	.SYNOPSIS
	Imports a CMS credential file and certificate to the local computer.

	.DESCRIPTION
	Imports a CMS credential file and certificate to the local computer. The calling user must have permission to the public key that protects the credential or provide the password for the PFX file.

	.PARAMETER FilePath
	Specifies the path to a CMS credential file.

	.PARAMETER PfxFile
	Specifies the path to the PFX file that containing the CMS certificate.

	.PARAMETER Password
	Specifies the password to the PFX file as a secure string.

	.PARAMETER Exportable
	Switch parameter to import the CMS certificate with the exportable flag.

	.PARAMETER Force
	Switch to overwrite existing CMS certificates and credential files.

	.INPUTS
	None.

	.OUTPUTS
	None.

	#>

	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline)]
		[string]$FilePath,
		[Parameter(Position = 1, Mandatory = $true)]
		[string]$PfxFile,
		[Parameter(Mandatory = $false)]
		[securestring]$Password,
		[Parameter(Mandatory = $false)]
		[switch]$Exportable,
		[Parameter(Mandatory = $false)]
		[switch]$Force,
		[Parameter(DontShow)]
		[string]$Path = $CmsCredentials['PathForCmsFiles'],
		[Parameter(DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
		[Parameter(DontShow)]
		[string]$Pattern = '^CN=(?<FileName>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}), OU=(?<Identity>.+), O=CmsCredentials$',
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if FilePath is not an absolute path...
	If (![System.IO.Path]::IsPathRooted($FilePath)) {
		# get unresolved absolute path
		Try {
			$FilePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FilePath)
		}
		Catch {
			Write-Warning "could not create absolute path from the provided FilePath parameter: $FilePath"
			Throw $_
		}
	}

	# if file path is not a file...
	If (![System.IO.File]::Exists($local:FilePath)) {
		Write-Warning -Message "could not locate credential file with '$local:FilePath' path on host: $local:Hostname"
		Return $null
	}

	# if PfxFile is not an absolute path...
	If (![System.IO.Path]::IsPathRooted($PfxFile)) {
		# get unresolved absolute path
		Try {
			$PfxFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PfxFile)
		}
		Catch {
			Write-Warning "could not create absolute path from the provided PfxFile parameter: $PfxFile"
			Throw $_
		}
	}

	# define required parameters for Find-CmsCertificate
	$FindCmsCertificate = @{
		PfxFile = $local:PfxFile
	}

	# define optional parameters for Find-CmsCertificate
	If ($PSBoundParameters.ContainsKey('Password')) {
		$FindCmsCertificate.Add('Password', $local:Password)
	}

	# find CMS certificate from PFX file
	Try {
		$Certificate = Find-CmsCertificate @FindCmsCertificate
	}
	Catch {
		Throw $_
	}

	# test subject against pattern
	Try {
		$SubjectMatchesPattern = $Certificate.Subject -match $Pattern
	}
	Catch {
		# warn and return
		Write-Warning -Message "could not compare subject of the certificate in the provided PFX file against the required pattern: $Pattern"
		Throw $_
	}

	# if subject does not match pattern...
	If (!$SubjectMatchesPattern) {
		# warn and return
		Write-Warning -Message "the subject of the certificate in the provided PFX file does not match the required regular expression: $Pattern"
		Return
	}

	# extract file name and identity from matches
	$FileName = $Matches.FileName
	$Identity = $Matches.Identity

	# if identity is too long or contains invalid characters...
	If (Test-CmsInvalidIdentity -Identity $local:Identity) {
		# warn and return
		Write-Warning -Message "the value for the Identity in the subject of the certificate in the provided PFX file contains more than 64 characters or one or more of the following invalid characters: '\' (backslash), '=' (equal sign)"
		Return
	}

	# construct path for certificate
	Try {
		$CertificatePath = Join-Path -Path $CertStoreLocation -ChildPath $Certificate.Thumbprint
	}
	Catch {
		Write-Warning -Message 'could not build path to test if certificate already exists'
		Throw $_
	}

	# test if certificate already imported
	Try {
		$CertificateFound = Test-Path -Path $CertificatePath -PathType Leaf
	}
	Catch {
		Write-Warning -Message 'could not test if certificate already exists'
		Throw $_
	}

	# if certificate found and force not requested...
	If ($CertificateFound -and -not $Force) {
		Write-Warning -Message 'skipping certificate install; found existing certificate with matching thumbprint'
	}
	# if certificate not found or force requested...
	Else {
		# define parameters
		$ImportPfxCertificate = @{
			FilePath          = $PfxFile
			Exportable        = $Exportable
			CertStoreLocation = $CertStoreLocation
			ErrorAction       = [System.Management.Automation.ActionPreference]::Stop
		}

		# import CMS certificate from PFX file
		Try {
			Import-PfxCertificate @ImportPfxCertificate
		}
		Catch {
			Throw $_
		}

		# report state
		Write-Host "imported credential certificate to store: '$CertStoreLocation'"
	}

	# construct path for destination file
	Try {
		$DestinationPath = Join-Path -Path $Path -ChildPath "$FileName.txt"
	}
	Catch {
		Write-Warning -Message 'could not build path for credential file'
		Throw $_
	}

	# if destination file exists and force not requested...
	If ([System.IO.File]::Exists($DestinationPath) -and -not $Force) {
		Write-Warning -Message 'skipping credential file install; found existing credential file with matching guid'
	}
	# if destination file does not exist or force requested...
	Else {
		# define parameters
		$CopyItem = @{
			Path        = $FilePath
			Destination = $DestinationPath
			Force       = $true
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# import CMS credential file
		Try {
			Copy-Item @CopyItem
		}
		Catch {
			Throw $_
		}

		# report state
		Write-Host "copied credential file to path: '$DestinationPath'"
	}
}

Function Protect-CmsCredential {
	<#
	.SYNOPSIS
	Protects a credential with CMS.

	.DESCRIPTION
	Protects a credential by encrypting it with a certificate using CMS. The calling user must have read access to the public key that will protect the credential.

	.PARAMETER Credential
	Specifies the PSCredential object to protect with CMS.

	.PARAMETER Identity
	Specifies the identity of a new or existing CMS certificate. Cannot be combined with the Certificate, Thumbprint, or PfxFile parameters. A new CMS certificate will be created if the provided identify does not map to an existing certificate and the Reset parameter is not set.

	.PARAMETER Certificate
	Specifies the X.509 certificate object that will encrypt the credential. Cannot be combined with the Thumbprint, PfxFile, or Identity parameters.

	.PARAMETER Thumbprint
	Specifies the thumbprint of the X.509 certificate that will encrypt the credential. Cannot be combined with the Certificate, PfxFile, or Identity parameters.

	.PARAMETER PfxFile
	Specifies the path to a PFX file that will encrypt the credential. Cannot be combined with the Certificate, Thumbprint, or Identity parameters.

	.PARAMETER OutFile
	Specifies the path for the CMS credential file. Requires the Certificate, Thumbprint, or PfxFile parameters.

	.PARAMETER Reset
	Switch to create a new CMS certificate and credential file for the provided identity. Requires the Identity parameter.

	.PARAMETER SkipCleanup
	Switch to skip removal of old CMS certificates and credential files for the provided identity. Requires the Identity parameter.

	.PARAMETER ComputerName
	Specifies the name of one or more remote computers. Requires the Identity or Thumbprint parameters.

	.INPUTS
	None.

	.OUTPUTS
	None.

	#>

	[CmdletBinding(DefaultParameterSetName = 'Identity')]
	Param (
		[Parameter(ValueFromPipeline = $true, Position = 0, Mandatory = $true)]
		[pscredential]$Credential,
		[Parameter(ParameterSetName = 'Certificate', Position = 1, Mandatory = $true)]
		[System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
		[Parameter(ParameterSetName = 'Thumbprint', Position = 1, Mandatory = $true)]
		[string]$Thumbprint,
		[Parameter(ParameterSetName = 'PfxFile', Position = 1, Mandatory = $true)]
		[string]$PfxFile,
		[Parameter(ParameterSetName = 'Certificate', Position = 2, Mandatory = $true)]
		[Parameter(ParameterSetName = 'Thumbprint', Position = 2, Mandatory = $true)]
		[Parameter(ParameterSetName = 'PfxFile', Position = 2, Mandatory = $true)]
		[string]$OutFile,
		[Parameter(ParameterSetName = 'Identity', Position = 1, Mandatory = $true)]
		[string]$Identity,
		[Parameter(ParameterSetName = 'Identity')]
		[switch]$Reset,
		[Parameter(ParameterSetName = 'Identity')]
		[switch]$SkipCleanup,
		[Parameter(ParameterSetName = 'Identity')]
		[Parameter(ParameterSetName = 'Thumbprint')]
		[string[]]$ComputerName,
		[Parameter(Mandatory = $false)]
		[switch]$Force,
		[Parameter(DontShow)]
		[string]$Path = $CmsCredentials['PathForCmsFiles'],
		[Parameter(DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if identity is too long or contains invalid characters...
	If ($PSBoundParameters.ContainsKey('Identity') -and (Test-CmsInvalidIdentity -Identity $local:Identity)) {
		# warn and return
		Write-Warning -Message "the value provided for the Identity parameter contains more than 64 characters or one or more of the following invalid characters: '\' (backslash), '=' (equal sign)"
		Return
	}

	# if computername provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# define parameters for Invoke-Function
		$InvokeFunction = @{
			ComputerName          = $local:ComputerName
			AdditionalFunctions   = 'Find-CmsCertificate', 'New-CmsCredentialCertificate', 'Remove-CmsCredential', 'Test-CmsInvalidIdentity'
			PrerequisiteFunctions = 'Initialize-CmsCredentialSettings'
		}

		# invoke function remotely
		Try {
			Invoke-Function @InvokeFunction
		}
		Catch {
			Throw $_
		}

		# return calling Invoke-Function
		Return
	}

	# if certificate provided...
	If ($PSBoundParameters.ContainsKey('Certificate')) {
		# if certificate subject is null or empty...
		If ([string]::IsNullOrEmpty($Certificate.Subject)) {
			# warn and return
			Write-Warning -Message 'provided certificate has an invalid subject: the subject is empty'
			Return
		}
	}

	# if thumbprint provided...
	If ($PSBoundParameters.ContainsKey('Thumbprint')) {
		# find CMS certificate with thumbprint
		Try {
			$Certificate = Find-CmsCertificate -Thumbprint $local:Thumbprint -CertStoreLocation $local:CertStoreLocation
		}
		Catch {
			Throw $_
		}
	}

	# if PFX file provided...
	If ($PSBoundParameters.ContainsKey('PfxFile')) {
		# if PfxFile is not an absolute path...
		If (![System.IO.Path]::IsPathRooted($PfxFile)) {
			# get unresolved absolute path
			Try {
				$PfxFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PfxFile)
			}
			Catch {
				Write-Warning "could not create absolute path from the provided PfxFile parameter: $PfxFile"
				Throw $_
			}
		}

		# find CMS certificate from PFX file
		Try {
			$Certificate = Find-CmsCertificate -PfxFile $local:PfxFile
		}
		Catch {
			Throw $_
		}
	}

	# if identity provided...
	If ($PSBoundParameters.ContainsKey('Identity')) {
		# if reset not requested...
		If (!$local:Reset) {
			# find CMS certificate with identity
			Try {
				$Certificate = Find-CmsCertificate -Identity $local:Identity -CertStoreLocation $local:CertStoreLocation -AllowEmptyReturn
			}
			Catch {
				Throw $_
			}
		}

		# if certificate not found...
		If (!$local:Certificate) {
			# create new certificate for identity
			Try {
				$Certificate = New-CmsCredentialCertificate -Identity $local:Identity
			}
			Catch {
				Write-Warning -Message "could not create certificate for '$local:Identity' identity on host: $local:Hostname"
				Throw $_
			}
		}

		# create file name from certificate
		$FileName = $local:Certificate.GetNameInfo('SimpleName', $false)

		# define CMS file path
		$OutFile = Join-Path -Path $local:Path -ChildPath "$local:FileName.txt"
	}

	# if certificate not found...
	If (!$local:Certificate) {
		# return without warning; warnings provided by Find-CmsCertificate or New-CmsCredentialCertificate
		Return
	}

	# convert network credential to JSON string
	Try {
		$Content = $Credential.GetNetworkCredential() | Select-Object -Property 'UserName', 'Password', 'Domain' | ConvertTo-Json -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not create JSON string from credential object on host: $local:Hostname"
		Throw $_
	}

	# encrypt credentials to recipient
	Try {
		$CmsMessage = Protect-CmsMessage -To $local:Certificate -Content $local:Content -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not encrypt credential to certificate with '$($Certificate.Subject)' subject on host: $local:Hostname"
		Throw $_
	}

	# insert subject and thumbprint lines into content of credential file
	Try {
		$Value = $local:CmsMessage.Insert(0, "Subject: $($local:Certificate.Subject)`r`nThumbprint: $($local:Certificate.Thumbprint)`r`n")
	}
	Catch {
		Write-Warning -Message "could not prefix encrypted credential with certificate subject and thumbprint on host: $local:Hostname"
		Throw $_
	}

	# if OutFile is not an absolute path...
	If (![System.IO.Path]::IsPathRooted($OutFile)) {
		# get unresolved absolute path
		Try {
			$OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
		}
		Catch {
			Write-Warning "could not create absolute path from the provided OutFile parameter: $OutFile"
			Throw $_
		}
	}

	# if CMS credential file found...
	If ([System.IO.File]::Exists($local:OutFile)) {
		# if force and reset not set...
		If (!$local:Force -and !$local:Reset) {
			Write-Warning -Message "existing file found; continue to overwrite file with '$local:OutFile' path on host: $local:Hostname" -WarningAction 'Inquire'
		}
	}
	# if CMS credential file not found...
	Else {
		# define parameters for New-Item
		$NewItem = @{
			Path        = $local:OutFile
			Force       = $true
			ItemType    = 'File'
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# create file and path to file
		Try {
			$null = New-Item @NewItem | Remove-Item -Force
		}
		Catch {
			Write-Warning -Message "could not create file with '$local:OutFile' path on host: $local:Hostname"
			Throw $_
		}
	}

	# save updated content to credential file
	Try {
		Set-Content -Path $local:OutFile -Value $local:Value -Encoding 'UTF8' -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not save encrypted credential to file with '$local:OutFile' path on host: $local:Hostname"
		Throw $_
	}

	# if identity provided and skip cleanup not requested...
	If ($PSBoundParameters.ContainsKey('Identity') -and -not $local:SkipCleanup) {
		# define parameters for Remove-CmsCredential
		$RemoveCmsCredential = @{
			Identity = $local:Identity
			Path     = $local:Path
			SkipLast = 1
		}

		# remove old CMS certificate and files
		Try {
			Remove-CmsCredential @RemoveCmsCredential
		}
		Catch {
			Write-Warning -Message "could not remove old CMS certificates and files for '$local:Identity' identity on host: $local:Hostname"
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
		[string]$Path = $CmsCredentials['PathForCmsFiles'],
		[Parameter(Mandatory = $false)]
		[uint16]$SkipLast = 0,
		[Parameter(Mandatory = $false)]
		[string[]]$ComputerName,
		[Parameter(DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if identity is too long or contains invalid characters...
	If ($PSBoundParameters.ContainsKey('Identity') -and (Test-CmsInvalidIdentity -Identity $Identity)) {
		# warn and return
		Write-Warning -Message "the value provided for the Identity parameter contains more than 64 characters or one or more of the following invalid characters: '\' (backslash), '=' (equal sign)"
		Return
	}

	# if computername provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# define parameters for Invoke-Function
		$InvokeFunction = @{
			ComputerName          = $ComputerName
			AdditionalFunctions   = 'Test-CmsInvalidIdentity', 'Test-CmsInvalidSubject'
			PrerequisiteFunctions = 'Initialize-CmsCredentialSettings'
		}

		# invoke function remotely
		Try {
			Invoke-Function @InvokeFunction
		}
		Catch {
			Throw $_
		}

		# return calling Invoke-Function
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
		Write-Warning -Message "could not locate certificate store with '$CertStoreLocation' path on host: $Hostname"
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
		Write-Warning -Message "could not locate folder for credential files with '$Path' path on host: $Hostname"
	}

	# remove old credential certificates
	ForEach ($Item in $local:CredentialCerts) {
		Try {
			Remove-Item -Path $Item.PSPath -Force -Verbose -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not remove certificate with '$($Item.PSPath)' path on host: $Hostname"
			Throw $_
		}
	}

	# remove old credential files
	ForEach ($Item in $local:CredentialFiles) {
		Try {
			Remove-Item -Path $Item.PSPath -Force -Verbose -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not remove file with '$($Item.PSPath)' path on host: $Hostname"
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
	PS> Show-CmsCredential -Thumbprint "0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b"

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
		[string]$Path = $CmsCredentials['PathForCmsFiles'],
		[Parameter(Mandatory = $false)]
		[string[]]$ComputerName,
		[Parameter(DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My',
		[Parameter(DontShow)]
		[string]$Hostname = [System.Environment]::MachineName.ToLowerInvariant()
	)

	# if identity is too long or contains invalid characters...
	If ($PSBoundParameters.ContainsKey('Identity') -and (Test-CmsInvalidIdentity -Identity $Identity)) {
		# warn and return
		Write-Warning -Message "the value provided for the Identity parameter contains more than 64 characters or one or more of the following invalid characters: '\' (backslash), '=' (equal sign)"
		Return
	}

	# if computername provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# define parameters for Invoke-Function
		$InvokeFunction = @{
			ComputerName          = $ComputerName
			AdditionalFunctions   = 'Test-CmsInvalidIdentity', 'Test-CmsInvalidSubject'
			PrerequisiteFunctions = 'Initialize-CmsCredentialSettings'
		}

		# invoke function remotely
		Try {
			Invoke-Function @InvokeFunction
		}
		Catch {
			Throw $_
		}

		# return calling Invoke-Function
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
	If ($PSBoundParameters.ContainsKey('Identity')) {
		# define pattern as organizational unit of Identity followed by organization of CmsCredentials
		$Pattern = "OU=$Identity, O=CmsCredentials$"
		$SimpleMatch = $false
	}

	# if pattern not defined...
	If (!$local:Pattern) {
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
	:NextCredentialFile ForEach ($CredentialFile in $local:CredentialFiles) {
		# retrieve subject from credential file
		$Subject = (Select-String -InputObject $CredentialFile -Pattern $Pattern -SimpleMatch:$SimpleMatch -List).Line.Replace('Subject: ', $null)
		# if subject contains invalid characters...
		If (Test-CmsInvalidSubject -Subject $Subject) {
			# warn and continue
			Write-Warning -Message "the subject in the certificate file on '$Hostname' with '$($CredentialFile.FullName)' path contains one or more of the following invalid characters: '\' (backslash)"
			Continue NextCredentialFile
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
	:NextCredentialCert ForEach ($CredentialCert in $local:CredentialCerts) {
		# retrieve subject from certificate
		$Subject = $CredentialCert.Subject
		# if subject contains invalid characters...
		If (Test-CmsInvalidSubject -Subject $Subject) {
			# warn and continue
			Write-Warning -Message "the subject of the certificate on '$Hostname' with '$($CredentialCert.Thumbprint)' thumbprint contains one or more of the following invalid characters: '\' (backslash)"
			Continue NextCredentialCert
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

	# if identity is too long or contains invalid characters...
	If ($PSBoundParameters.ContainsKey('Identity') -and (Test-CmsInvalidIdentity -Identity $Identity)) {
		# warn and return
		Write-Warning -Message "the value provided for the Identity parameter contains more than 64 characters or one or more of the following invalid characters: '\' (backslash), '=' (equal sign)"
		Return
	}

	# if computername provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# define parameters for Invoke-Function
		$InvokeFunction = @{
			ComputerName          = $ComputerName
			AdditionalFunctions   = 'Find-CmsCertificate', 'Test-CmsInvalidIdentity', 'Get-CertificatePrivateKeyPath'
			PrerequisiteFunctions = 'Initialize-CmsCredentialSettings'
		}

		# invoke function remotely
		Try {
			Invoke-Function @InvokeFunction
		}
		Catch {
			Throw $_
		}

		# return calling Invoke-Function
		Return
	}

	# if thumbprint provided...
	If ($PSBoundParameters.ContainsKey('Thumbprint')) {
		# find CMS certificate with thumbprint
		Try {
			$Certificate = Find-CmsCertificate -Thumbprint $local:Thumbprint -CertStoreLocation $local:CertStoreLocation
		}
		Catch {
			Throw $_
		}
	}

	# if identity provided...
	If ($PSBoundParameters.ContainsKey('Identity')) {
		# find CMS certificate with identity
		Try {
			$Certificate = Find-CmsCertificate -Identity $local:Identity -CertStoreLocation $local:CertStoreLocation
		}
		Catch {
			Throw $_
		}
	}

	# if certificate not found...
	If (!$local:Certificate) {
		# return without warning; warnings provided by Find-CmsCertificate
		Return
	}

	# retrieve private key path
	Try {
		$Path = Get-CertificatePrivateKeyPath -Certificate $Certificate
	}
	Catch {
		Write-Warning -Message "could not retrieve path to private key for certificate with $($local:Certificate.Thumbprint)' thumbprint on host: $local:Hostname"
		Throw $_
	}

	# if private key path not found...
	If ($null -eq $local:Path) {
		# declare and return
		Write-Warning -Message "could not locate private key for certificate with $($local:Certificate.Thumbprint)' thumbprint on host: $local:Hostname"
		Return
	}

	# retrieve private key permissions
	Try {
		$AclObject = Get-Acl -Path $Path -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not retrieve ACL for private key of certificate with $($local:Certificate.Thumbprint)' thumbprint on host: $local:Hostname"
		Throw $_
	}

	# create list for SIDs
	$SecurityIdentifiers = [System.Collections.Generic.List[System.Security.Principal.SecurityIdentifier]]::new()

	# create list for required SIDs
	$RequiredSecurityIdentifiers = [System.Collections.Generic.List[System.Security.Principal.SecurityIdentifier]]::new()

	# update list for required SIDs with NT AUTHORITY\SYSTEM
	$RequiredSecurityIdentifiers.Add([System.Security.Principal.SecurityIdentifier]::new('S-1-5-18'))

	# update list for required SIDs with BUILTIN\Administrators
	$RequiredSecurityIdentifiers.Add([System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))

	# get SIDs
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

	# process SIDs
	switch ($Mode) {
		'Reset' {
			ForEach ($IdentityReference in $AclObject.Access.IdentityReference) {
				# remove rule for IdentityReference
				$AclObject.PurgeAccessRules($IdentityReference)
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

	# ensure required SIDs are on ACL
	ForEach ($SecurityIdentifier in $RequiredSecurityIdentifiers) {
		# create 'FullControl' rule for SID
		$AccessRule = [System.Security.AccessControl.FileSystemAccessRule]::new($SecurityIdentifier, 'FullControl', 'Allow')
		# add rule to ACL
		$AclObject.AddAccessRule($AccessRule)
	}

	# update ACL on private key
	Try {
		Set-Acl -Path $Path -AclObject $AclObject -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not update ACL for private key of certificate with $($local:Certificate.Thumbprint)' thumbprint on host: $local:Hostname"
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

Function Initialize-CmsCredentialSettings {
	Param(
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::Machinename).ToLowerInvariant()
	)

	# define the static path to CMS Credentials folder in the Program Data folder
	$PathToDirectoryInProgramData = Join-Path -Path ([System.Environment]::GetFolderPath('CommonApplicationData')) -ChildPath 'CmsCredentials'

	# define the static path to CMS Credentials file containing module defaults
	$PathToFileWithModuleDefaults = Join-Path -Path $local:PathToDirectoryInProgramData -ChildPath 'CmsCredentials.json'

	# create hashtable with default values for supported parameters
	$Hashtable = @{
		PathForCmsFiles = $local:PathToDirectoryInProgramData
		PathForPfxFiles = $local:PathToDirectoryInProgramData
	}

	# if file found...
	If ([System.IO.File]::Exists($local:PathToFileWithModuleDefaults)) {
		# retrieve content from file
		Try {
			$Content = Get-Content -Path $local:PathToFileWithModuleDefaults -Raw -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not read CmsCredentials settings file at '$local:PathToFileWithModuleDefaults' path on host: $local:Hostname"
		}

		# if file is empty...
		If ([string]::IsNullOrEmpty($local:Content)) {
			Write-Warning -Message "found empty CmsCredentials settings file at '$local:PathToFileWithModuleDefaults' path on host: $local:Hostname"
		}
		# if file is not empty...
		Else {
			# convert file content from JSON to custom object
			Try {
				$JsonData = ConvertFrom-Json -InputObject $local:Content -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not create custom object from contents of CmsCredentials settings file at '$local:PathToFileWithModuleDefaults' path on host: $local:Hostname"
			}

			# if custom object exists...
			If ($null -ne $local:JsonData) {
				# process hashtable keys
				ForEach ($Key in $Hashtable.Keys) {
					# if value exists in custom object...
					If ($null -ne $JsonData.$Key) {
						# and value hashtable does not match value in custom object...
						If ($Hashtable.$Key -ne $Hashtable.$Key) {
							# update hashtable with value in custom object
							$Hashtable.$Key = $JsonData.$Key
						}
					}
				}
			}
		}
	}

	# create private variable from hashtable
	Try {
		New-Variable -Name 'CmsCredentials' -Value $local:Hashtable -Scope 'Global' -Force
	}
	Catch {
		Write-Warning -Message "could not create object while initializing CmsCredentials on host: $local:Hostname"
		Return $_
	}
}

Function Show-CmsCredentialSettings {
	Param(
		[Parameter(Mandatory = $false)]
		[string[]]$ComputerName,
		[Parameter(DontShow)]
		[string]$HostName = ([System.Environment]::Machinename).ToLowerInvariant()
	)

	# if computername provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# define parameters for Invoke-Function
		$InvokeFunction = @{
			ComputerName          = $ComputerName
			PrerequisiteFunctions = 'Initialize-CmsCredentialSettings'
		}

		# invoke function remotely
		Try {
			Invoke-Function @InvokeFunction
		}
		Catch {
			Throw $_
		}

		# return calling Invoke-Function
		Return
	}

	# if CmsCredential settings object exists...
	If ($global:CmsCredentials -isnot [hashtable]) {
		# initialize CMS Credential settings
		Initialize-CmsCredentialSettings
	}

	# create custom object from hashtable
	$JsonData = [pscustomobject]$global:CmsCredentials

	# display custom object
	$local:JsonData | Format-Table -Property @(
		# display current hostname as computername
		@{Name = 'ComputerName'; Expression = { $HostName } }
		# display path for CMS files
		@{Name = 'PathForCmsFiles'; Expression = { $_.PathForCmsFiles } }
		# display path for CMS files
		@{Name = 'PathForPfxFiles'; Expression = { $_.PathForCmsFiles } }
	)
}

Function Write-CmsCredentialSettings {
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param(
		[Parameter(Mandatory = $false)]
		[string[]]$ComputerName,
		[Parameter(Mandatory = $false, ParameterSetName = 'Default')]
		[string]$PathForCmsFiles,
		[Parameter(Mandatory = $false, ParameterSetName = 'Default')]
		[string]$PathForPfxFiles,
		[Parameter(Mandatory = $false, ParameterSetName = 'Reset')]
		[switch]$Reset
	)

	# if computername provided...
	If ($PSBoundParameters.ContainsKey('ComputerName')) {
		# define parameters for Invoke-Function
		$InvokeFunction = @{
			ComputerName          = $ComputerName
			PrerequisiteFunctions = 'Initialize-CmsCredentialSettings'
		}

		# invoke function remotely
		Try {
			Invoke-Function @InvokeFunction
		}
		Catch {
			Throw $_
		}

		# return calling Invoke-Function
		Return
	}

	# define the static path to CMS Credentials folder in the Program Data folder
	$PathToDirectoryInProgramData = Join-Path -Path ([System.Environment]::GetFolderPath('CommonApplicationData')) -ChildPath 'CmsCredentials'

	# define the static path to CMS Credentials file containing module defaults
	$PathToFileWithModuleDefaults = Join-Path -Path $local:PathToDirectoryInProgramData -ChildPath 'CmsCredentials.json'

	# create hashtable with default values for supported parameters
	$Hashtable = @{
		PathForCmsFiles = $local:PathToDirectoryInProgramData
		PathForPfxFiles = $local:PathToDirectoryInProgramData
	}

	# if directory not found...
	If (![System.IO.Directory]::Exists($local:PathToDirectoryInProgramData)) {
		# define parameters for New-Item
		$NewItem = @{
			Path        = $local:PathToDirectoryInProgramData
			Force       = $true
			ItemType    = 'Directory'
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# create directory and path to directory
		Try {
			$null = New-Item @NewItem | Remove-Item -Force
		}
		Catch {
			Write-Warning -Message "could not create directory with '$local:PathToDirectoryInProgramData' path on host: $local:Hostname"
			Throw $_
		}
	}

	# if file not found...
	If (![System.IO.File]::Exists($local:PathToFileWithModuleDefaults)) {
		# define parameters for New-Item
		$NewItem = @{
			Path        = $local:PathToFileWithModuleDefaults
			Force       = $true
			ItemType    = 'File'
			ErrorAction = [System.Management.Automation.ActionPreference]::Stop
		}

		# create file and path to file
		Try {
			$null = New-Item @NewItem | Remove-Item -Force
		}
		Catch {
			Write-Warning -Message "could not create file with '$local:PathToFileWithModuleDefaults' path on host: $local:Hostname"
			Throw $_
		}
	}

	# if file found and Reset not requested...
	If ([System.IO.File]::Exists($local:PathToFileWithModuleDefaults) -and -not $local:Reset) {
		# retrieve content from file
		Try {
			$Content = Get-Content -Path $local:PathToFileWithModuleDefaults -Raw -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not read CmsCredentials settings file at '$local:PathToFileWithModuleDefaults' path on host: $local:Hostname"
		}

		# if file is empty...
		If ([string]::IsNullOrEmpty($local:Content)) {
			Write-Warning -Message "found empty CmsCredentials settings file at '$local:PathToFileWithModuleDefaults' path on host: $local:Hostname"
		}
		# if file is not empty...
		Else {
			# convert file content from JSON to custom object
			Try {
				$JsonData = ConvertFrom-Json -InputObject $local:Content -ErrorAction 'Stop'
			}
			Catch {
				Write-Warning -Message "could not create custom object from contents of CmsCredentials settings file at '$local:PathToFileWithModuleDefaults' path on host: $local:Hostname"
			}

			# if custom object exists...
			If ($null -ne $local:JsonData) {
				# define boolean for updates
				$HashtableUpdated = $false

				# process hashtable keys
				ForEach ($Key in $Hashtable.Keys) {
					# if value exists in custom object...
					If ($null -ne $JsonData.$Key) {
						# and value hashtable does not match value in custom object...
						If ($Hashtable.$Key -ne $JsonData.$Key) {
							# update hashtable with value in custom object
							$Hashtable.$Key = $JsonData.$Key
							# record hashtable was updated
							$HashtableUpdated = $true
						}
					}
				}

				# if hashtable not updated...
				If (!$HashtableUpdated) {
					# return as no changes found to existing file
					Return
				}
			}
		}
	}

	# convert hashtable to JSON
	Try {
		$JsonText = $local:Hashtable | ConvertTo-Json -Depth 100 -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not convert settings to JSON for CmsCredentials: $local:PathToFileWithModuleDefaults"
		Return $_
	}

	# save JSON to file
	Try {
		Set-Content -Path $local:PathToFileWithModuleDefaults -Value $local:JsonText -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not write settings file for CmsCredentials: $local:PathToFileWithModuleDefaults"
		Return $_
	}

	# if CmsCredentials already initialized...
	If ($null -ne $global:CmsCredentials) {
		# re-initialize CmsCredetntials
		Try {
			Initialize-CmsCredentialSettings
		}
		Catch {
			Write-Warning -Message "could not re-initialize CmsCredentials: $local:PathToFileWithModuleDefaults"
			Return $_
		}
	}
}

# define functions to export
$FunctionsToExport = @(
	'Find-CmsCertificate'
	'Export-CmsCredentialCertificate'
	'New-CmsCredentialCertificate'
	'Get-CmsCredential'
	'Export-CmsCredential'
	'Import-CmsCredential'
	'Protect-CmsCredential'
	'Remove-CmsCredential'
	'Show-CmsCredential'
	'Grant-CmsCredentialAccess'
	'Reset-CmsCredentialAccess'
	'Revoke-CmsCredentialAccess'
	'Show-CmsCredentialAccess'
	'Initialize-CmsCredentialSettings'
	'Show-CmsCredentialSettings'
	'Write-CmsCredentialSettings'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport

# initialize module
Initialize-CmsCredentialSettings