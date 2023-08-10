Function ConvertTo-X509Certificate {
	<#
	.SYNOPSIS
	Convert an input object into an X.509 certificate object.

	.DESCRIPTION
	Convert an input object into an X.509 certificate object. The input object can be a byte array, a collection where the first element is a byte array, or the string representation of a byte array.

	.PARAMETER InputObject
	Specifies the input object that represents an X.509 certificate

	.INPUTS
	System.ByteArray,System.Collections,System.String. A byte array, a collection containing a byte array as the first element, or the string representation of a byte array.

	.OUTPUTS
	X509Certificate2. An X509Certificate2 object created from the input.

	#>
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		$InputObject
	)

	Write-Verbose $InputObject.GetType().FullName

	# if InputObject is a collection...
	If ( $InputObject -is [System.Collections.CollectionBase]) {
		# ...retrieve the first entry in the collection
		$InputObject = $InputObject[0]
	}

	# if InputObject is a byte array...
	If ( $InputObject -is [byte[]] ) {
		# ...copy InputObject to byte array
		$ByteArray = $InputObject
	}
	# if InputObject is a string...
	ElseIf ( $InputObject -is [string]) {
		# ...convert InputObject into a byte array
		$ByteArray = [System.Convert]::ToByte($InputObject)
	}
	# if InputObject is not a pre-configured type...
	Else {
		# ...cast InputObject into a byte array
		Try {
			$ByteArray = [byte[]]$InputObject
		}
		Catch {
			Throw $_
		}
	}

	# create new certificate object
	$Certificate = New-Object -TypeName 'System.Security.Cryptography.X509Certificates.X509Certificate2'

	# import byte array into certificate object
	Try {
		$Certificate.Import($ByteArray)
	}
	Catch {
		Throw $_
	}

	# return certificate object
	Return $Certificate
}

Function Get-CertificateChain {
	<#
	.SYNOPSIS
	Returns the X.509 certificates in the certificate chain from an X.509 certificate object.

	.DESCRIPTION
	Returns the X.509 certificates in the certificate chain from an X.509 certificate object.

	.PARAMETER Certificate
	Specifies the X.509 certificate for which the certificate chain will be built.

	.PARAMETER CheckRevocation
	Switch to check if any of the certificates in the chain have been revoked.

	.PARAMETER PassThru
	Switch to return the X.509 certificate chain instead of an array of the X.509 certificate objects in the certificate chain.

	.INPUTS
	X509Certificate2. An object representing an X.509 certificate.

	.OUTPUTS
	X509Chain, X509Certificate2. An object representing an X.509 certificate chain or the X.509 certificates in the certificate chain.

	#>
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[object]$Certificate,
		[Parameter(Position = 1)]
		[switch]$CheckRevocation,
		[Parameter(Position = 2)]
		[switch]$PassThru
	)

	# create certificate chain object
	$X509Chain = New-Object -TypeName 'System.Security.Cryptography.X509Certificates.X509Chain'

	# if revocation checking was not requested...
	If (-not $CheckRevocation) {
		# ...disable revocation checking
		$X509Chain.ChainPolicy.RevocationMode = 'NoCheck'
	}

	# build certificate chain from certificate
	Try {
		$null = $X509Chain.Build($Certificate)
	}
	Catch {
		Throw $_
	}

	# if pass thru is set...
	If ($PassThru) {
		# return certificate chain
		Return $X509Chain
	}
	Else {
		# return certificates in certificate chain
		Return $X509Chain.ChainElements.Certificate
	}
}

Function Get-CertificateFromAD {
	<#
	.SYNOPSIS
	Convert an attribute on an Active Directory object into an X.509 certificate object.

	.DESCRIPTION
	Convert an attribute on an Active Directory object into an X.509 certificate object. The input can be a byte array, a collection where the first element is a byte array, or the string representation of a byte array.

	.PARAMETER Identity
	Specifies the Active Directory object to retrieve

	.PARAMETER Attribute
	Specifies the attribute on the Active Directory object that represents an X.509 certificate

	.PARAMETER Chain
	Switch to return the certificate and all certificates in chain.

	.INPUTS
	System.String. A string representing the fully qualified distinguished name of an LDAP object.

	.OUTPUTS
	X509Certificate2. An object representing an X509 certificate.

	#>
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[object]$Identity,
		[Parameter(Position = 1)]
		[string]$Attribute = 'userCertificate',
		[Parameter(Position = 2)]
		[switch]$Chain
	)

	# if Identity is an ADobject...
	If ($Identity -is [Microsoft.ActiveDirectory.Management.ADObject]) {
		# ...and if Attribute is an ADPropertyValueCollection that contains at least one value...
		If ($Identity.$Attribute -is [Microsoft.ActiveDirectory.Management.ADPropertyValueCollection] -and $Identity.$Attribute.Count -ge 1) {
			# ...retrieve the values from the attribute on the object
			$Values = $Identity.$Attribute
		}
		# ...and if Attribute is not ADPropertyValueCollection or does not contain at least one value...
		Else {
			# ...retrieve the DN from the object
			$Identity = $Identity.DistinguishedName
		}
	}

	# if Identity is not ADObject or the Attribute on the ADObject is null...
	If ($Identity -isnot [Microsoft.ActiveDirectory.Management.ADObject]) {
		Try {
			# retrieve object via S.DS
			$Entry = [System.DirectoryServices.DirectoryEntry]::New("LDAP://$Identity")
			# retrieve values from attribute on the the object
			$Values = $Entry.$Attribute
		}
		Catch {
			Throw $_
		}
	}

	# create empty array for certificates
	$Certificates = @()

	# process each value in attribute
	ForEach ($Value in $Values) {
		# convert value to x509 certificate
		Try {
			# do *NOT* pipe the value to the function; the pipeline will unroll byte arrays and break the function
			$Certificate = ConvertTo-X509Certificate -InputObject $Value
		}
		Catch {
			Throw $_
		}
		# if chain requested...
		If ($Chain) {
			# ...retrieve chain...
			Try {
				$CertificateChain = Get-CertificateChain -Certificate $Certificate
			}
			Catch {
				Throw $_
			}
			# ...add certificates in chain to array
			ForEach ($Certificate in $CertificateChain) {
				$Certificates += $Certificate
			}
		}
		# if chain not requested...
		Else {
			# ...add certificate to array
			$Certificates += $Certificate
		}
	}

	# return results
	switch ($Certificates.Count) {
		0 { Return $null }
		1 { Return $Certificate }
		Default { Return $Certificates }
	}
}

Function Get-CertificateFromUri {
	<#
	.SYNOPSIS
	Retrieve or validate the certificate presented when requesting a URI from a remote host.

	.DESCRIPTION
	Retrieve or validate the certificate or certificate chain presented when requesting a URI from a remote host.

	.PARAMETER Uri
	Specifies the URI to query.

	.PARAMETER IPAddress
	Specifies the IP address of the remote host. This overrides the hostname discovered from the URI.

	.PARAMETER Port
	Specifies the TCP port on the remote host. This overrides the port discovered from the URI.

	.PARAMETER Timeout
	Specifies the connection timeout in milliseconds.

	.PARAMETER Chain
	Switch to return the certificate and all certificates in chain.

	.INPUTS
	System.String. A string representing a computer hostname.

	.OUTPUTS
	X509Certificate2. An object representing an X509 certificate.

	#>
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[string]$Uri,
		[Parameter()]
		[string]$IPAddress,
		[Parameter()]
		[int32]$Port,
		[Parameter()]
		[int32]$Timeout = 3000,
		[Parameter()]
		[switch]$Chain
	)

	Begin {
		# construct Uri object from parameter
		If ($Uri.Contains('://')) {
			$UriBuilder = [System.UriBuilder]::new($Uri)
		}
		Else {
			$UriBuilder = [System.UriBuilder]::new("https://$Uri")
		}

		# set hostname and targethost
		If ($PSBoundParameters.ContainsKey('IPAddress')) {
			$Hostname = $PSBoundParameters['IPAddress']
		}
		Else {
			$Hostname = $UriBuilder.Host
		}

		# if port not set via parameter...
		If (-not $PSBoundParameters.ContainsKey('Port')) {
			# retrieve port from UriBuilder
			$Port = $UriBuilder.Port
		}
	}

	Process {
		# create tcp client
		Try {
			$TcpClient = [System.Net.Sockets.TcpClient]::new()
		}
		Catch {
			Throw $_
		}

		# begin tcp client connection phase
		Try {
			$TcpHandle = $TcpClient.BeginConnect($Hostname, $Port, $null, $null)
		}
		Catch {
			Throw $_
		}

		# check tcp client connection phase
		Try {
			$TcpResult = $TcpHandle.AsyncWaitHandle.WaitOne($Timeout, $false)
		}
		Catch {
			Throw $_
		}

		# if not connected before timeout...
		If (-not $TcpResult) {
			# ...close the connection and return a null
			$TcpClient.Close()
			Write-Warning 'connection timed out'
			Return $null
		}

		# end tcp client connection phase
		Try {
			$TcpClient.EndConnect($TcpHandle)
		}
		Catch [System.Management.Automation.MethodInvocationException] {
			Write-Error $_.Exception.InnerException
			Throw $_
		}
		Catch {
			Throw $_
		}

		# open client stream to server
		Try {
			$TcpClientStream = $TcpClient.GetStream()
		}
		Catch {
			Throw $_
		}

		# define System.Net.Security.RemoteCertificateValidationCallback delegate that always returns true
		$RemoteCertificateValidationCallback = { param($delegate_sender, $delegate_certificate, $delegate_chain, $delegate_sslPolicyErrors) return $true }

		# create sslstream
		Try {
			$SSLStream = [System.Net.Security.SSLStream]::new($TcpClientStream, $true, $RemoteCertificateValidationCallback)
		}
		Catch {
			Throw $_
		}

		# submit SNI to server
		Try {
			$SSLStream.AuthenticateAsClient($UriBuilder.Host)
		}
		Catch {
			Throw $_
		}

		# get certificate sent by server
		Try {
			
			$Certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($SSLStream.RemoteCertificate)
		}
		Catch {
			Throw $_
		}

		# return results
		If ($Chain) {
			Try {
				$CertificateChain = Get-CertificateChain -Certificate $Certificate
			}
			Catch {
				Throw $_
			}
			Return $CertificateChain
		}
		Else {
			Return $Certificate
		}
	}

	End {
		If ($null -ne $SSLStream) {
			$SSLStream.Dispose()
		}
		If ($null -ne $TcpClientStream) {
			$TcpClientStream.Dispose()
		}
		If ($null -ne $TcpClient) {
			$TcpClient.Dispose()
		}
	}
}

Function Get-CertificatePrivateKeyPath {
	<#
	.SYNOPSIS
	Returns the path of the private key for an X.509 certificate.

	.DESCRIPTION
	Returns the path of the private key for an X.509 certificate.

	.PARAMETER Certificate
	Specifies an X.509 certificate object.

	.PARAMETER Thumbprint
	Specifies the thumbprint of an X.509 certificate.

	.PARAMETER MachineKeysPath
	Specifies the path to machine keys on the system.

	.PARAMETER CertStoreLocation
	Specifices the path to the certificate store to search for a certificate by thumbprint when the Thumbprint parameter is specified.

	.INPUTS
	X509Certificate2. An object representing an X.509 certificate.

	.OUTPUTS
	System.String. A string representing the path to the private key for the input.

	#>
	[CmdletBinding(DefaultParameterSetName = 'Certificate')]
	Param(
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'Certificate', ValueFromPipeline = $true)]
		[System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'Thumbprint')]
		[string]$Thumbprint,
		[Parameter(Position = 1, DontShow)]
		[string]$MachineKeysPath = (Join-Path -Path ([System.Environment]::GetFolderPath('CommonApplicationData')) -ChildPath 'Microsoft\Crypto\RSA\MachineKeys'),
		[Parameter(Position = 2, DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My'
	)

	# if thumbprint provided...
	If ($PSCmdlet.ParameterSetName = 'Thumbprint') {
		Try {
			$Certificate = Get-Item -Path (Join-Path -Path $CertStoreLocation -ChildPath $Thumbprint)
		}
		Catch {
			Write-Verbose -Message "Certificate with thumbprint '$Thumbprint' was not found in the machine key store"
			Return $null
		}
	}

	# if certificate has private key...
	If ($Certificate.HasPrivateKey) {
		# if certificate is machine key...
		If ($Certificate.PrivateKey.CspKeyContainerInfo.MachineKeyStore) {
			# retrieve path for private key
			$Path = Join-Path -Path $MachineKeysPath -ChildPath $Certificate.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
			Write-Verbose -Message "Certificate '$($Certificate.Thumbprint)' private key: $Path"
			Return $Path
		}
		Else {
			Write-Verbose -Message "Certificate '$($Certificate.Thumbprint)' is not in the machine key store"
			Return $null
		}
	}
	Else {
		Write-Verbose -Message "Certificate '$($Certificate.Thumbprint)' does not have a private key"
		Return $null
	}
}

Function Grant-CertificatePermissions {
	<#
	.SYNOPSIS
	Grants access to the private key of an X.509 certificate.

	.DESCRIPTION
	Adds access control entries to the access control list on the private key of an X.509 certificate.

	.PARAMETER Certificate
	Specifies the X.509 certificate with the private key.

	.PARAMETER Thumbprint
	Specifies the thumbprint of the X.509 certificate with the private key.

	.PARAMETER Principals
	Specifies the principals to add from the access control list.

	.PARAMETER AccessRights
	Specifies one or more FileSystemAccessRights to grant to the Principals.

	.INPUTS
	X509Certificate2. An object representing an X.509 certificate.

	.OUTPUTS
	None.

	#>
	[CmdletBinding(DefaultParameterSetName = 'Certificate')]
	Param(
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'Certificate', ValueFromPipeline = $true)]
		[System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'Thumbprint')]
		[string]$Thumbprint,
		[Parameter(Position = 1)][AllowEmptyCollection()]
		[string[]]$Principals,
		[Parameter(Position = 2)]
		[string[]]$AccessRights = @('Read', 'Synchronize'),
		[Parameter(Position = 3, DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My'
	)

	# retrieve certificate with thumbprint
	If ($PSCmdlet.ParameterSetName = 'Thumbprint') {
		Try {
			$Certificate = Get-Item -Path (Join-Path -Path $CertStoreLocation -ChildPath $Thumbprint)
		}
		Catch {
			Write-Host "ERROR: could not retrieve certificate with thumbprint '$Thumbprint' from the local machine key store"
			Return $null
		}
	}

	# retrieve private key path
	Try {
		$Path = Get-CertificatePrivateKeyPath -Certificate $Certificate
	}
	Catch {
		Write-Host 'ERROR: could not retrieve private key path for certificate'
		Return
	}

	# if private key path is null...
	If ($null -eq $Path) {
		# ...report and return
		Write-Host "ERROR: could not locate private key for certificate: '$($Certificate.Thumbprint)"
		Return
	}

	# retrieve private key ACL
	Try {
		$Acl = Get-Acl -Path $Path
	}
	Catch {
		Write-Host "ERROR: could not retrieve ACL on private key for certificate: '$($Certificate.Thumbprint)'"
		Return $_
	}

	# create list for ACEs
	$AccessRules = [System.Collections.Generic.List[object]]::new()

	# check ACL for requested ACEs
	ForEach ($Principal in $Principals) {
		$AccessRule = $Acl.Access | Where-Object { $_.IdentityReference -eq $Principal -and $_.FileSystemRights -eq $AccessRights }
		If ($null -eq $AccessRule) {
			Try {
				$AccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule @($Principal, $AccessRights, 'Allow')
				$AccessRules.Add($AccessRule)
				Write-Host "Created ACE for principal: $Principal"
			}
			Catch {
				Write-Host "ERROR: could not create ACE for princpal: $Principal"
				Return $_
			}
		}
		Else {
			Write-Host "Found existing ACE for principal: $Principal"
		}
	}

	# update ACL if required
	If ($AccessRules.Count -gt 0) {
		ForEach ($AccessRule in $AccessRules) { $Acl.AddAccessRule($AccessRule) }
		Try {
			$Acl | Set-Acl -Path $Path
			Write-Host "Updated ACL on private key for certificate: '$($Certificate.Thumbprint)'"
		}
		Catch {
			Write-Host "ERROR: could not update ACL on private key for certificate: '$($Certificate.Thumbprint)'"
			Return $_
		}
	}
}

Function Revoke-CertificatePermissions {
	<#
	.SYNOPSIS
	Revokes access to the private key of an X.509 certificate.

	.DESCRIPTION
	Removes access control entries from the access control list on the private key of an X.509 certificate.

	.PARAMETER Certificate
	Specifies the X.509 certificate with the private key.

	.PARAMETER Thumbprint
	Specifies the thumbprint of the X.509 certificate with the private key.

	.PARAMETER Principals
	Specifies the principals to remove from the access control list.

	.INPUTS
	X509Certificate2. An object representing an X.509 certificate.

	.OUTPUTS
	None.

	#>
	[CmdletBinding(DefaultParameterSetName = 'Certificate')]
	Param(
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'Certificate', ValueFromPipeline = $true)]
		[System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'Thumbprint')]
		[string]$Thumbprint,
		[Parameter(Position = 1)][AllowEmptyCollection()]
		[string[]]$Principals,
		[Parameter(Position = 2, DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My'
	)

	# retrieve certificate with thumbprint
	If ($PSCmdlet.ParameterSetName = 'Thumbprint') {
		Try {
			$Certificate = Get-Item -Path (Join-Path -Path $CertStoreLocation -ChildPath $Thumbprint)
		}
		Catch {
			Write-Host "ERROR: could not retrieve certificate with thumbprint '$Thumbprint' from the local machine key store"
			Return $null
		}
	}

	# retrieve private key path
	Try {
		$Path = Get-CertificatePrivateKeyPath -Certificate $Certificate
	}
	Catch {
		Write-Host 'ERROR: could not retrieve private key path for certificate'
		Return
	}

	# if private key path is null...
	If ($null -eq $Path) {
		# ...report and return
		Write-Host "ERROR: could not locate private key for certificate: '$($Certificate.Thumbprint)"
		Return
	}

	# retrieve private key ACL
	Try {
		$Acl = Get-Acl -Path $Path
	}
	Catch {
		Write-Host "ERROR: could not retrieve ACL on private key for certificate: '$($Certificate.Thumbprint)'"
		Return $_
	}

	# create list for ACEs
	$AccessRules = [System.Collections.Generic.List[object]]::new()

	# check ACL for requested ACEs
	ForEach ($Principal in $Principals) {
		$AccessRule = $Acl.Access | Where-Object { $_.IdentityReference -eq $Principal }
		If ($null -ne $AccessRule) {
			$AccessRules.Add($AccessRule)
			Write-Host "Found existing ACE for principal: $Principal"
		}
		Else {
			Write-Host "WARNING: could not find existing ACE for principal: $Principal"
		}
	}

	# update ACL if required
	If ($AccessRules.Count -gt 0) {
		# update ACL object
		ForEach ($AccessRule in $AccessRules) { 
			$Acl.RemoveAccessRule($AccessRule)
		}
		# set ACL object
		Try {
			$Acl | Set-Acl -Path $Path
			Write-Host "Updated ACL on private key for certificate: '$($Certificate.Thumbprint)'"
		}
		Catch {
			Write-Host "ERROR: could not update ACL on private key for certificate: '$($Certificate.Thumbprint)'"
			Return $_
		}
	}
}

Function Test-Thumbprint {
	<#
	.SYNOPSIS
	Tests if a string is a certificate thumbprint.

	.DESCRIPTION
	Tests if string is exactly 40 characters long and only contains hexadecimal characters. The function returns true if the string meets the criteria and false otherwise.

	.PARAMETER Thumbprint
	Specifies the string to be tested.

	.INPUTS
	System.String

	.OUTPUTS
	System.Boolean

	#>
	[CmdletBinding()]
	Param(
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[string]$Thumbprint
	)

	# validate input is 40 hexidecimal characters
	If ($Thumbprint -match '^[\dA-Fa-f]{40}$') {
		Return $true
	}
	Else {
		Return $false
	}
}

# define functions to export
$functions_to_export = @()
$functions_to_export += 'ConvertTo-X509Certificate'
$functions_to_export += 'Get-CertificateChain'
$functions_to_export += 'Get-CertificateFromAD'
$functions_to_export += 'Get-CertificateFromUri'
$functions_to_export += 'Grant-CertificatePermissions'
$functions_to_export += 'Revoke-CertificatePermissions'
$functions_to_export += 'Test-Thumbprint'

# export module members
Export-ModuleMember -Function $functions_to_export