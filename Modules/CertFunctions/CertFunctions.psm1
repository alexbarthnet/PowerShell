Function ConvertTo-PEMCertificate {
	<#
	.SYNOPSIS
	Convert an input object into a PEM-formatted certificate.

	.DESCRIPTION
	Convert an input object into an PEM-formatted certificate. The input object can be a byte array, a collection where the first element is a byte array, or the string representation of a byte array.

	.PARAMETER InputObject
	Specifies the input object that represents an X.509 certificate

	.PARAMETER AsPrivateKey
	Specifies the string should use the private key header and footer instead of the certificate header and footer.

	.INPUTS
	System.ByteArray,System.Collections,System.String. A byte array, a collection containing a byte array as the first element, or the string representation of a byte array.

	.OUTPUTS
	String. A PEM-formatted certificate.

	#>
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		$InputObject,
		[Parameter(Position = 1)]
		[switch]$AsPrivateKey,
		[Parameter(Position = 2)]
		[string]$NewLine = [System.Environment]::NewLine
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

	# create base64-encoded string from byte array
	Try {
		$Base64String = [Convert]::ToBase64String($ByteArray, [Base64FormattingOptions]::InsertLineBreaks)
	}
	Catch {
		Throw $_
	}

	# if private key requested...
	If ($AsPrivateKey) {
		# create PEM-formatted string for a private key from base64-encoded string
		$PemFormattedString = '-----BEGIN PRIVATE KEY-----', $Base64String, '-----END PRIVATE KEY-----' -join $NewLine
	}
	# if private key not requested...
	Else {
		# create PEM-formatted string for a certificate from base64-encoded string
		$PemFormattedString = '-----BEGIN CERTIFICATE-----', $Base64String, '-----END CERTIFICATE-----' -join $NewLine
	}

	# update NewLine characters
	if ($NewLine -ne "`r`n") {
		$PemFormattedString = $PemFormattedString -replace "`r`n", $NewLine
	}

	# return PEM-formatted string
	Return $PemFormattedString
}

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

Function Export-CertificateAsPem {
	<#
	.SYNOPSIS
	Export an X.509 certificate object in PEM format.

	.DESCRIPTION
	Export an X.509 certificate object in PEM format.

	.PARAMETER Certificate
	Specifies the X.509 certificate to export.

	.PARAMETER Path
	Specifies the path where the certificate will be saved. If the path is a directory, a "certificate.pem" file will be created in the directory.

	.PARAMETER IncludeChain
	Switch to include the certificate chain.

	.PARAMETER IncludePrivateKey
	Switch to include the certificate private key.

	.INPUTS
	X509Certificate2. An object representing an X.509 certificate.

	.OUTPUTS
	String. A string containing the PEM-formatted certificates in CA Bundle order.

	#>
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
		[Parameter(Position = 1)]
		[string]$Path,
		[Parameter(Position = 2)]
		[switch]$IncludeChain,
		[Parameter(Position = 3)]
		[switch]$IncludePrivateKey,
		[Parameter(Position = 4)]
		[string]$NewLine = [System.Environment]::NewLine,
		[Parameter(Position = 5)]
		[Microsoft.PowerShell.Commands.FileSystemCmdletProviderEncoding]$Encoding = [Microsoft.PowerShell.Commands.FileSystemCmdletProviderEncoding]::ASCII
	)

	# creat empty string for certificate
	$CertificateString = [System.String]::Empty

	# if private key should be exported...
	If ($IncludePrivateKey) {
		# retrieve private key for certificate
		Try {
			$PrivateKeyAsByteArray = Get-CertificatePrivateKeyObject -Certificate $Certificate -AsByteArray
		}
		Catch {
			Write-Warning -Message "could not retrieve private key for certificate with '$($Certificate.Thumbprint)' thumbprint: $($_.Exception.Message)"
			Return $null
		}

		# if private key retrieved...
		If ($PrivateKeyAsByteArray) {
			# convert private key byte array to PEM-formatted string
			Try {
				$PrivateKeyInPEM = ConvertTo-PEMCertificate -InputObject $PrivateKeyAsByteArray -AsPrivateKey -NewLine $NewLine
			}
			Catch {
				Throw $_
			}
		}
		# if private key not retrieved...
		Else {
			# warn and inquire
			Write-Warning -Message 'could not retrieve private key for certificate; continue to create PEM file without private key?' -WarningAction Inquire
			$PrivateKeyInPEM = [string]::Empty
		}

		# add encoded data to string
		If ([string]::IsNullOrEmpty($CertificateString)) {
			$CertificateString = $PrivateKeyInPEM
		}
		Else {
			$CertificateString = $CertificateString, $PrivateKeyInPEM -join $NewLine
		}
	}

	# get certificate bundle with original certificate
	Try {
		$CertificateBundle = Get-CertificateBundle -Certificate $Certificate -IncludeCertificate -NewLine $NewLine
	}
	Catch {
		Throw $_
	}

	# add certificate bundle to string
	If ([string]::IsNullOrEmpty($CertificateString)) {
		$CertificateString = $CertificateBundle
	}
	Else {
		$CertificateString = $CertificateString, $CertificateBundle -join $NewLine
	}

	# update NewLine characters
	if ($NewLine -ne "`r`n") {
		$CertificateString = $CertificateString -replace "`r`n", $NewLine
	}

	# if path provided...
	If ($PSBoundParameters.ContainsKey('Path')) {
		# if path is a directory...
		If (Test-Path -Path $Path -PathType Container) {
			# ...append ca-bundle.crt to path
			$Path = Join-Path -Path $Path -ChildPath 'certificate.pem'
		}

		# write the certificate bundle to path
		Try {
			Set-Content -Path $Path -Value $CertificateBundle -Encoding $Encoding
		}
		Catch {
			Throw $_
		}
	}
	# if path not provided...
	Else {
		# display bundle
		Return $CertificateBundle
	}
}

Function Get-CertificateBundle {
	<#
	.SYNOPSIS
	Creates a CA Bundle from an X.509 certificate object.

	.DESCRIPTION
	Creates a CA Bundle from an X.509 certificate object.

	.PARAMETER Certificate
	Specifies the X.509 certificate for which the CA Bundle will be built.

	.PARAMETER Path
	Specifies the path where the CA Bundle will be saved. If the provided path is a directory, a "ca-bundle.crt" file will be created in the directory.

	.PARAMETER IncludeCertificate
	Switch to include the original X.509 certificate object in the CA Bundle.

	.PARAMETER RootFirst
	Switch to place the root certificate first. The chain order is determined by the NotBefore property on the certificate objects.

	.INPUTS
	X509Certificate2. An object representing an X.509 certificate.

	.OUTPUTS
	String. A string containing the PEM-formatted certificates in CA Bundle order.

	#>
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
		[Parameter(Position = 1)]
		[string]$Path,
		[Parameter(Position = 2)]
		[switch]$IncludeCertificate,
		[Parameter(Position = 3)]
		[switch]$RootFirst,
		[Parameter(Position = 4)]
		[string]$NewLine = [System.Environment]::NewLine,
		[Parameter(Position = 5)]
		[Microsoft.PowerShell.Commands.FileSystemCmdletProviderEncoding]$Encoding = [Microsoft.PowerShell.Commands.FileSystemCmdletProviderEncoding]::ASCII
	)

	# get certificate chain from certificate
	Try {
		$CertificateChain = Get-CertificateChain -Certificate $Certificate
	}
	Catch {
		Throw $_
	}

	# if root first requested...
	If ($RootFirst) {
		$CertificateChain = $CertificateChain | Sort-Object -Property 'NotBefore'
	}

	# creat empty string for CA bundle
	$CertificateBundle = [System.String]::Empty

	# process each certificate in certificate chain
	:CertificateInChain ForEach ($CertificateInChain in $CertificateChain) {
		# if thumbprint of certificate in chain matches thumbprint of provided certificate and IncludeCertificate not set...
		If ($CertificateInChain.Thumbprint -eq $Certificate.Thumbprint -and -not $IncludeCertificate) {
			# ...continue to next certificate in chain
			Continue CertificateInChain
		}

		# convert certificate to PEM-formatted string
		Try {
			$CertificateInChainPEM = ConvertTo-PEMCertificate -InputObject $CertificateInChain.RawData -NewLine $NewLine
		}
		Catch {
			Write-Warning -Message 'could not create PEM-formatted string from byte array'
			Return $_
		}

		# add formatted certificate data to bundle
		If ([string]::IsNullOrEmpty($CertificateBundle)) {
			$CertificateBundle = $CertificateInChainPEM
		}
		Else {
			$CertificateBundle = $CertificateBundle, $CertificateInChainPEM -join $NewLine
		}
	}

	# update NewLine characters
	if ($NewLine -ne "`r`n") {
		$CertificateBundle = $CertificateBundle -replace "`r`n", $NewLine
	}

	# if path provided...
	If ($PSBoundParameters.ContainsKey('Path')) {
		# if path is a directory...
		If (Test-Path -Path $Path -PathType Container) {
			# ...append ca-bundle.crt to path
			$Path = Join-Path -Path $Path -ChildPath 'ca-bundle.crt'
		}

		# write the certificate bundle to path
		Try {
			Set-Content -Path $Path -Value $CertificateBundle -Encoding $Encoding -NoNewline
		}
		Catch {
			Throw $_
		}
	}
	# if path not provided...
	Else {
		# display bundle
		Return $CertificateBundle
	}
}

Function Format-ReversedDistinguishedName {
	<#
	.SYNOPSIS
	Reverses the order of the elements of a distingiushed name.

	.DESCRIPTION
	Reverses the order of the elements of a distingiushed name.

	.PARAMETER DistinguishedName
	Specifies the distinguished name to be reversed.

	.PARAMETER Separator
	Specifies the separator character in the distinguished name. The default value is the comma (,) character.

	.INPUTS
	String. A string containing a distinguished name.

	.OUTPUTS
	String. A string containing the original elements of the distinguished name in reverse.

	#>
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true)]
		[string]$DistinguishedName,
		[Parameter(Position = 1)]
		[string]$Separator = ','
	)

	# split DistinguishedName
	$DistinguishedNameArray = $DistinguishedName -split $Separator -ne [String]::Empty

	# reverse array elements
	[System.Array]::Reverse($DistinguishedNameArray)

	# join array elements
	$ReveresedDistinguishedName = $DistinguishedNameArray -join $Separator

	# return ReversedDistinguishedName
	Return $ReveresedDistinguishedName
}

Function Format-ReversedString {
	<#
	.SYNOPSIS
	Reverses the characters in a string.

	.DESCRIPTION
	Reverses the characters in a string.

	.PARAMETER String
	Specifies the string to be reversed.

	.PARAMETER Count
	Specifies the count of characters to be considered a single element in the string. The default value is 1 character.

	.INPUTS
	String. A string.

	.OUTPUTS
	String. A string containing the characters of the original string in reverse.

	#>
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true)]
		[string]$String,
		[Parameter(Position = 1)]
		[int32]$Count = 1
	)

	# split String
	$StringArray = $String -split "(\w{$($Count.ToString())})" -ne [String]::Empty

	# reverse array elements
	[System.Array]::Reverse($StringArray)

	# join array elements
	$ReveresedStringArray = $StringArray -join [String]::Empty

	# return ReveresedStringArray
	Return $ReveresedStringArray
}

Function Get-CertificateAltSecurityIdentity {
	<#
	.SYNOPSIS
	Retrieves the alternate security identity from a certificate.

	.DESCRIPTION
	Retrieves the alternate security identity from a certificate.

	.PARAMETER Certificate
	Specifies the X.509 certificate for which the identity will be built.

	.PARAMETER MappingType
	Specifies the type of mapping returned by the function. The valid values are detailed below. The default value is 'IssuerAndSerialNumber'.
	 - IssuerAndSerialNumber
	 - SKI
	 - SHA1PublicKey
	 - IssuerAndSubject
	 - SubjectOnly
	 - RFC822
	 - PrincipalName

	.INPUTS
	X509Certificate2. An object representing an X.509 certificate.

	.OUTPUTS
	String. A string containing an alternate security identity.

	.LINK
	https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-pkca/282ed46a-97c2-4fab-8456-a6bd67b9ba71

	.LINK
	https://learn.microsoft.com/en-us/entra/identity/authentication/concept-certificate-based-authentication-certificateuserids#supported-patterns-for-certificate-user-ids

	.LINK
	https://support.microsoft.com/en-us/topic/kb5014754-certificate-based-authentication-changes-on-windows-domain-controllers-ad2c23b0-15d8-4340-a468-4d4f3b188f16#bkmk_certmap

	#>
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
		[Parameter(Position = 1)][ValidateSet('IssuerAndSerialNumber', 'SKI', 'SHA1PublicKey', 'IssuerAndSubject', 'SubjectOnly', 'RFC822')]
		[string]$Type = 'IssuerAndSerialNumber'
	)

	# verify certificate properties
	switch ($Type) {
		'IssuerAndSerialNumber' {
			# if Issuer empty or not found...
			If ([String]::IsNullOrEmpty($Certificate.Issuer)) {
				# ...warn and return
				Write-Warning 'Issuer empty or not found on certificate'
				Return $null
			}

			# if SerialNumber empty or not found...
			If ([String]::IsNullOrEmpty($Certificate.SerialNumber)) {
				# ...warn and return
				Write-Warning 'SerialNumber empty or not found on certificate'
				Return $null
			}
		}
		'SKI' {
			# if SubjectKeyIdentifier not found...
			If ([String]::IsNullOrEmpty($Certificate.Extensions.SubjectKeyIdentifier)) {
				# ...warn and return
				Write-Warning 'SubjectKeyIdentifier empty or not found on certificate'
				Return $null
			}

			# if SubjectKeyIdentifier is not unique...
			If ($Certificate.Extensions.SubjectKeyIdentifier.Count -gt 1) {
				# ...warn and return
				Write-Warning 'Multiple SubjectKeyIdentifier extensions found on certificate'
				Return $null
			}
		}
		'SHA1PublicKey' {
			# if Thumbprint empty or not found...
			If ([String]::IsNullOrEmpty($Certificate.Thumbprint)) {
				# ...warn and return
				Write-Warning 'Thumbprint empty or not found on certificate'
				Return $null
			}
		}
		'IssuerAndSubject' {
			# if Issuer empty or not found...
			If ([String]::IsNullOrEmpty($Certificate.Issuer)) {
				# ...warn and return
				Write-Warning 'Issuer empty or not found on certificate'
				Return $null
			}

			# if Subject empty or not found...
			If ([String]::IsNullOrEmpty($Certificate.Subject)) {
				# ...warn and return
				Write-Warning 'Subject not found on certificate'
				Return $null
			}
		}
		'SubjectOnly' {
			# if Subject empty or not found...
			If ([String]::IsNullOrEmpty($Certificate.Subject)) {
				# ...warn and return
				Write-Warning 'Subject not found on certificate'
				Return $null
			}
		}
		'RFC822' {
			# if UserPrincipalName empty or not found...
			If ([String]::IsNullOrEmpty($Certificate.Extensions.UserPrincipalName)) {
				# ...warn and return
				Write-Warning 'UserPrincipalName not found on certificate'
				Return $null
			}

			# if UserPrincipalName is not unique...
			If ($Certificate.Extensions.UserPrincipalName.Count -gt 1) {
				# ...warn and return
				Write-Warning 'Multiple UserPrincipalName extensions found on certificate'
				Return $null
			}
		}
		'PrincipalName' {
			# if UserPrincipalName empty or not found...
			If ([String]::IsNullOrEmpty($Certificate.Extensions.UserPrincipalName)) {
				# ...warn and return
				Write-Warning 'UserPrincipalName not found on certificate'
				Return $null
			}

			# if UserPrincipalName is not unique...
			If ($Certificate.Extensions.UserPrincipalName.Count -gt 1) {
				# ...warn and return
				Write-Warning 'Multiple UserPrincipalName extensions found on certificate'
				Return $null
			}
		}
	}

	# create alternate security identity
	switch ($Type) {
		'IssuerAndSerialNumber' {
			# get the reversed issuer
			$ReversedIssuer = Format-ReversedDistinguishedName -DistinguishedName $Certificate.Issuer

			# get the reversed serial number respecting byte boundaries
			$ReversedSerialNumber = Format-ReversedString -String $Certificate.SerialNumber -Count 2

			# create alternate security identity
			$CertificateAltSecurityIdentity = "X509:<I>$ReversedIssuer<SR>$ReversedSerialNumber"
		}
		'SKI' {
			# create alternate security identity
			$CertificateAltSecurityIdentity = "X509:<SKI>$($Certificate.Extensions.SubjectKeyIdentifier)"
		}
		'SHA1PublicKey' {
			# create alternate security identity
			$CertificateAltSecurityIdentity = "X509:<SHA1-PUKEY>$($Certificate.Thumbprint)"
		}
		'IssuerAndSubject' {
			# get the reversed issuer
			$ReversedIssuer = Format-ReversedDistinguishedName -DistinguishedName $Certificate.Issuer

			# get the reversed subject
			$ReversedSubject = Format-ReversedDistinguishedName -DistinguishedName $Certificate.Subject

			# create alternate security identity
			$CertificateAltSecurityIdentity = "X509:<I>$ReversedIssuer<S>$ReversedSubject"
		}
		'SubjectOnly' {
			# get the reversed subject
			$ReversedSubject = Format-ReversedDistinguishedName -DistinguishedName $Certificate.Subject

			# create alternate security identity
			$CertificateAltSecurityIdentity = "X509:<S>$ReversedSubject"
		}
		'RFC822' {
			# create alternate security identity
			$CertificateAltSecurityIdentity = "X509:<RFC822>$($Certificate.Extensions.UserPrincipalName)"
		}
		'PrincipalName' {
			# create alternate security identity
			$CertificateAltSecurityIdentity = "X509:<PN>$($Certificate.Extensions.UserPrincipalName)"
		}
	}

	# return alternate security identity
	Return $CertificateAltSecurityIdentity
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
		[System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
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
		# validate port number
		If ($Port -eq -1) {
			switch ($UriBuilder.Scheme) {
				'ldap' {
					$Port = 389
				}
				'ldaps' {
					$Port = 636
				}
				Default {
					Write-Warning 'unable to determine port number from Uri'
					Return $null
				}
			}
		}

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

		# if chain not requested...
		If (!$Chain) {
			# return certificate
			Return $Certificate
		}

		# get certificate chain from certificate
		Try {
			$CertificateChain = Get-CertificateChain -Certificate $Certificate
		}
		Catch {
			Throw $_
		}

		# return certificate chain
		Return $CertificateChain
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

Function Get-CertificatePrivateKeyObject {
	<#
	.SYNOPSIS
	Returns an object representing the private key for an X.509 certificate.

	.DESCRIPTION
	Returns an object representing the private key for an X.509 certificate.

	.PARAMETER Certificate
	Specifies an X.509 certificate object.

	.PARAMETER AsByteArray
	Switch parameter to return private key as a byte array

	.INPUTS
	X509Certificate2. An object representing an X.509 certificate.

	.OUTPUTS
	Object, Byte[]. An object or byte array representing the private key for the provided certificate.

	#>
	[CmdletBinding()]
	Param(
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
		[Parameter(Position = 1)]
		[switch]$AsByteArray
	)

	# if certificate private key not present...
	If (!$Certificate.HasPrivateKey) {
		Write-Warning -Message 'the provided certificate does not have an associated private key'
		Return $null
	}

	# if certificate public OID not present...
	If (!$Certificate.PublicKey.Oid.FriendlyName) {
		Write-Warning -Message 'the provided certificate does not have an algorithm defined'
		Return $null
	}

	# retrieve certificate algorithm from public key
	$Algorithm = $Certificate.PublicKey.Oid.FriendlyName

	# if algorithm is not supported...
	If ($Algorithm -notin 'DSA', 'ECC', 'RSA') {
		Write-Warning -Message "the provided certificate has an unsupported algorithm: $Algorithm"
		Return $null
	}

	# retrieve private key using algorithm-specific method
	Try {
		switch ($Algorithm) {
			'DSA' {
				$PrivateKey = [System.Security.Cryptography.X509Certificates.DSACertificateExtensions]::GetDSAPrivateKey($Certificate)
			}
			'ECC' {
				$PrivateKey = [System.Security.Cryptography.X509Certificates.ECDsaCertificateExtensions]::GetECDsaPrivateKey($Certificate)
			}
			'RSA' {
				$PrivateKey = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
			}
		}
	}
	Catch {
		Throw $_
	}

	# if byte array not requested...
	If ($AsByteArray) {
		# if private key export policy does not include plain text export...
		If (!($PrivateKey.Key.ExportPolicy -band [System.Security.Cryptography.CngExportPolicies]::AllowPlaintextExport)) {
			# define CNG property parameters
			$CngPropertyName = 'ExportPolicy'
			$CngPropertyValues = [System.Security.Cryptography.CngExportPolicies]::AllowExport -bor [System.Security.Cryptography.CngExportPolicies]::AllowPlaintextExport
			$CngPropertyOptions = [System.Security.Cryptography.CngPropertyOptions]::Persist

			# create CNG property
			$CngProperty = [System.Security.Cryptography.CngProperty]::New($CngPropertyName, $CngPropertyValues, $CngPropertyOptions)

			# update CNG property
			Try {
				$PrivateKey.Key.SetProperty($CngProperty)
			}
			Catch {
				Write-Warning -Message 'the private key cannot be returned as a byte array: private key does not permit plain-text export'
				Return $null
			}
		}

		# retrieve byte array for private key
		Try {
			$ByteArray = $PrivateKey.Key.Export([Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob)
		}
		Catch {
			Throw $_
		}

		# return byte array
		Return $ByteArray
	}

	# return private key object
	Return $PrivateKey
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
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'Certificate', ValueFromPipeline = $true)]
		[System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'Thumbprint')]
		[string]$Thumbprint,
		[Parameter(Position = 1, DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My'
	)

	# if thumbprint provided...
	If ($PSCmdlet.ParameterSetName -eq 'Thumbprint') {
		Try {
			$Certificate = Get-Item -Path (Join-Path -Path $CertStoreLocation -ChildPath $Thumbprint)
		}
		Catch {
			Write-Warning -Message "could not locate certificate with '$Thumbprint' thumbprint in the '$CertStoreLocation' key store"
			Return $null
		}
	}

	# retrieve private key for certificate
	Try {
		$PrivateKeyObject = Get-CertificatePrivateKeyObject -Certificate $Certificate
	}
	Catch {
		Write-Warning -Message "could not retrieve private key for certificate with '$($Certificate.Thumbprint)' thumbprint: $($_.Exception.Message)"
		Return $null
	}

	# if private key was retrieved...
	If ($PrivateKeyObject) {
		# retrieve private key unique name
		$UniqueName = $PrivateKeyObject.Key.UniqueName
	}
	Else {
		Write-Warning -Message "could not locate private key for certificate with '$($Certificate.Thumbprint)' thumbprint: $($_.Exception.Message)"
		Return $null
	}

	# if certificate is machine key...
	If ($PrivateKeyObject.Key.IsMachineKey) {
		# ...get machine key container
		$Path = Join-Path -Path ([System.Environment]::GetFolderPath('CommonApplicationData')) -ChildPath 'Microsoft\Crypto'
	}
	# if certificate is not machine key...
	Else {
		# ...get user key container
		$Path = Join-Path -Path ([System.Environment]::GetFolderPath('ApplicationData')) -ChildPath 'Microsoft\Crypto'
	}

	# search key container for private key file
	Try {
		$PrivateKeyPath = Get-ChildItem -Path $Path -Recurse -Filter $UniqueName | Select-Object -First 1 -ExpandProperty FullName
	}
	Catch {
		Write-Warning -Message "Error searching for private key in container '$Path'"
		Return $null
	}

	# if private key file found...
	If ($PrivateKeyPath) {
		# report and return
		Write-Verbose -Message "Certificate '$($Certificate.Thumbprint)' private key: $PrivateKeyPath"
		Return $PrivateKeyPath
	}
	Else {
		Write-Verbose -Message "Could not find private key file for certificate '$($Certificate.Thumbprint)'"
		Return $null
	}
}

Function Get-PfxPrivateKey {
	<#
	.SYNOPSIS
	Retrieves the private key from a PFX file.

	.DESCRIPTION
	Retrieves the private key from a PFX file. The private key is returned as a PEM-formatted string unless the AsByteArray switch parameter is provided.

	.PARAMETER PfxPath
	Specifies the path to a PFX file

	.PARAMETER Password
	Specifies the password to the PFX file.

	.PARAMETER AsByteArray
	Switch to return the private key as a byte array instead of a PEM-formatted string.

	.INPUTS
	String. A string containing the path to a PFX file

	.OUTPUTS
	Byte[], String. A byte array representing the public key in the PFX file or a string containing the public key in PEM format.

	#>
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' })]
		[string]$PfxFile,
		[Parameter(Position = 1)]
		[SecureString]$Password,
		[Parameter(Position = 2)]
		[switch]$AsByteArray
	)

	# create certificate object from PFX file with exportable flag
	Try {
		$Certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($PfxFile, $Password, [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
	}
	Catch {
		Write-Warning -Message "could not create certificate oobject from provided file: '$PfxFile'"
		Return $_
	}

	# retrieve private key object
	Try {
		$ByteArray = Get-CertificatePrivateKeyObject -Certificate $Certificate -AsByteArray
	}
	Catch {
		Write-Warning -Message "could not retrieve private key for certificate with '$($Certificate.Thumbprint)' thumbprint: $($_.Exception.Message)"
		Return $null
	}

	# if byte array requested...
	If ($AsByteArray) {
		# ...return byte array
		Return $ByteArray
	}

	# convert byte array to PEM-formatted string
	Try {
		$PemCertificate = ConvertTo-PEMCertificate -InputObject $ByteArray -AsPrivateKey
	}
	Catch {
		Write-Warning -Message 'could not create PEM-formatted string from byte array'
		Return $_
	}

	# return PEM-encoded string
	Return $PemCertificate
}

Function Get-PfxPublicKey {
	<#
	.SYNOPSIS
	Retrieves the public key from a PFX file.

	.DESCRIPTION
	Retrieves the public key from a PFX file. The public key is returned as a PEM-formatted string unless the AsByteArray switch parameter is provided.

	.PARAMETER PfxPath
	Specifies the path to a PFX file

	.PARAMETER Password
	Specifies the password to the PFX file.

	.PARAMETER AsByteArray
	Switch to return the public key as a byte array instead of a PEM-formatted string.

	.INPUTS
	String. A string containing the path to a PFX file

	.OUTPUTS
	Byte[], String. A byte array representing the public key in the PFX file or a string containing the public key in PEM format.

	#>
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)][ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' })]
		[string]$PfxFile,
		[Parameter(Position = 1)]
		[SecureString]$Password,
		[Parameter(Position = 2)]
		[switch]$AsByteArray
	)

	# create certificate object from PFX file with exportable flag
	Try {
		$Certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($PfxFile, $Password, [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
	}
	Catch {
		Write-Warning -Message "could not create certificate oobject from provided file: '$PfxFile'"
		Return $_
	}

	# if byte array requested...
	If ($AsByteArray) {
		# ...return byte array
		Return $Certificate.RawData
	}

	# convert byte array to PEM-formatted string
	Try {
		$PemCertificate = ConvertTo-PEMCertificate -InputObject $Certificate.RawData
	}
	Catch {
		Write-Warning -Message 'could not create PEM-formatted string from byte array'
		Return $_
	}

	# return PEM-encoded string
	Return $PemCertificate
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
	If ($PSCmdlet.ParameterSetName -eq 'Thumbprint') {
		Try {
			$Certificate = Get-Item -Path (Join-Path -Path $CertStoreLocation -ChildPath $Thumbprint)
		}
		Catch {
			Write-Warning -Message "could not retrieve certificate with thumbprint '$Thumbprint' from the local machine key store"
			Return $null
		}
	}

	# retrieve private key path
	Try {
		$Path = Get-CertificatePrivateKeyPath -Certificate $Certificate
	}
	Catch {
		Write-Warning -Message "could not retrieve private key path for certificate with '$($Certificate.Thumbprint)' thumbprint"
		Return
	}

	# if private key path is null...
	If ($null -eq $Path) {
		# ...report and return
		Write-Warning -Message "could not locate private key for certificate with '$($Certificate.Thumbprint)' thumbprint"
		Return
	}

	# retrieve private key ACL
	Try {
		$Acl = Get-Acl -Path $Path
	}
	Catch {
		Write-Warning -Message "could not retrieve ACL on private key for certificate with '$($Certificate.Thumbprint)' thumbprint"
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
				Write-Warning -Message "could not create ACE for princpal: $Principal"
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
			Write-Host "Updated ACL on private key for certificate with '$($Certificate.Thumbprint)' thumbprint"
		}
		Catch {
			Write-Warning -Message "could not update ACL on private key for certificate with '$($Certificate.Thumbprint)' thumbprint"
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
	If ($PSCmdlet.ParameterSetName -eq 'Thumbprint') {
		Try {
			$Certificate = Get-Item -Path (Join-Path -Path $CertStoreLocation -ChildPath $Thumbprint)
		}
		Catch {
			Write-Warning -Message "could not retrieve certificate with thumbprint '$Thumbprint' from the '$CertStoreLocation' key store"
			Return $null
		}
	}

	# retrieve private key path
	Try {
		$Path = Get-CertificatePrivateKeyPath -Certificate $Certificate
	}
	Catch {
		Write-Warning -Message "could not retrieve private key path for certificate with '$($Certificate.Thumbprint)' thumbprint"
		Return
	}

	# if private key path is null...
	If ($null -eq $Path) {
		# ...report and return
		Write-Warning -Message "could not locate private key for certificate with '$($Certificate.Thumbprint)' thumbprint"
		Return
	}

	# retrieve private key ACL
	Try {
		$Acl = Get-Acl -Path $Path
	}
	Catch {
		Write-Warning -Message "could not retrieve ACL on private key for certificate with '$($Certificate.Thumbprint)' thumbprint"
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
			Write-Host "Updated ACL on private key for certificate with '$($Certificate.Thumbprint)' thumbprint"
		}
		Catch {
			Write-Warning -Message "could not update ACL on private key for certificate with '$($Certificate.Thumbprint)' thumbprint"
			Return $_
		}
	}
}

Function Register-ServiceCertificate {
	[CmdletBinding(DefaultParameterSetName = 'Certificate')]
	Param(
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'Certificate', ValueFromPipeline = $true)]
		[System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'Thumbprint')]
		[string]$Thumbprint,
		[Parameter(Position = 1, Mandatory = $true)]
		[string]$Name,
		[Parameter(Position = 2, DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My'
	)

	# retrieve certificate with thumbprint
	If ($PSCmdlet.ParameterSetName -eq 'Thumbprint') {
		Try {
			$Certificate = Get-Item -Path (Join-Path -Path $CertStoreLocation -ChildPath $Thumbprint)
		}
		Catch {
			Write-Warning -Message "could not retrieve certificate with thumbprint '$Thumbprint' from the local machine key store"
			Return $null
		}
	}

	# retrieve service by name
	Try {
		$Service = Get-Service -Name $Name -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not retrieve service with name '$Name' on the local machine"
		Return $null
	}

	# define parameters
	$GrantCertificatePermissions = @{
		Certificate = $Certificate
		Principals  = 'NT SERVICE\{0}' -f $Service.ServiceName
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# update permissions on private key
	Try {
		Grant-CertificatePermissions @GrantCertificatePermissions
	}
	Catch {
		Write-Warning -Message "could not grant permissions on private key to '$Name' service: $($_.Exception.Message)"
		Return $null
	}

	# retrieve registry path for certificate
	$SystemPath = 'HKLM:\SOFTWARE\Microsoft\SystemCertificates\My\Certificates\{0}' -f $Certificate.Thumbprint

	# test registry path for certificate
	$SystemPathFound = Test-Path -Path $SystemPath -PathType 'Container'

	# if certificate registry path not found...
	If (!$SystemPathFound) {
		Write-Warning -Message 'could not locate certificate registry key for certificate in local machine key store'
		Return $null
	}

	# define registry path for service certificate store
	$ServicePath = 'HKLM:\SOFTWARE\Microsoft\Cryptography\Services\{0}\SystemCertificates\My\Certificates' -f $Service.ServiceName, $Certificate.Thumbprint

	# test registry path for service certificate store
	$ServicePathFound = Test-Path -Path $ServicePath -PathType 'Container'

	# if service path not found...
	If (!$ServicePathFound) {
		Try {
			New-Item -ItemType 'Key' -Path $ServicePath -Force -ErrorAction 'Stop'
		}
		Catch {
			Write-Warning -Message "could not create certificate registry key for certificate store for '$Name' service: $($_.Exception.Message)"
			Return $null
		}
	}

	# copy system certificate registry key to service certificate registry key
	Try {
		Copy-Item -Path $SystemPath -Destination $ServicePath -Force -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not copy certificate registry key from local machine store to certificate store for '$Name' service: $($_.Exception.Message)"
		Return $null
	}
}

Function Unregister-ServiceCertificate {
	[CmdletBinding(DefaultParameterSetName = 'Certificate')]
	Param(
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'Certificate', ValueFromPipeline = $true)]
		[System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
		[Parameter(Position = 0, Mandatory = $true, ParameterSetName = 'Thumbprint')]
		[string]$Thumbprint,
		[Parameter(Position = 1, Mandatory = $true)]
		[string]$Name,
		[Parameter(Position = 2, DontShow)]
		[string]$CertStoreLocation = 'Cert:\LocalMachine\My'
	)

	# retrieve certificate with thumbprint
	If ($PSCmdlet.ParameterSetName -eq 'Thumbprint') {
		Try {
			$Certificate = Get-Item -Path (Join-Path -Path $CertStoreLocation -ChildPath $Thumbprint)
		}
		Catch {
			Write-Warning -Message "could not retrieve certificate with thumbprint '$Thumbprint' from the local machine key store"
			Return $null
		}
	}

	# retrieve service by name
	Try {
		$Service = Get-Service -Name $Name -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not retrieve service with name '$Name' on the local machine"
		Return $null
	}

	# define parameters
	$RevokeCertificatePermissions = @{
		Certificate = $Certificate
		Principals  = 'NT SERVICE\{0}' -f $Service.ServiceName
		ErrorAction = [System.Management.Automation.ActionPreference]::Stop
	}

	# update permissions on private key
	Try {
		Revoke-CertificatePermissions @RevokeCertificatePermissions
	}
	Catch {
		Write-Warning -Message "could not revoke permissions on private key from '$Name' service: $($_.Exception.Message)"
		Return $_
	}

	# define registry path for service certificate store
	$ServicePath = 'HKLM:\SOFTWARE\Microsoft\Cryptography\{0}\SystemCertificates\My\Certificates\{1}' -f $Service.ServiceName, $Certificate.Thumbprint

	# test registry path for service certificate store
	$ServicePathFound = Test-Path -Path $ServicePath -PathType 'Container'

	# if service path not found...
	If (!$ServicePathFound) {
		Write-Warning -Message "could not locate certificate registry key in certificate store for '$Name' service"
		Return $null
	}

	# copy system certificate registry key to service certificate registry key
	Try {
		Remove-Item -Path $ServicePath -Recurse -ErrorAction 'Stop'
	}
	Catch {
		Write-Warning -Message "could not remove certificate registry key from certificate store for '$Name' service: $($_.Exception.Message)"
		Return $_
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
$FunctionsToExport = @(
	'ConvertTo-PEMCertificate'
	'ConvertTo-X509Certificate'
	'Export-CertificateAsPEM'
	'Get-CertificateBundle'
	'Format-ReversedDistinguishedName'
	'Format-ReversedString'
	'Get-CertificateAltSecurityIdentity'
	'Get-CertificateBundle'
	'Get-CertificateChain'
	'Get-CertificateFromAD'
	'Get-CertificateFromUri'
	'Get-CertificatePrivateKeyObject'
	'Get-CertificatePrivateKeyPath'
	'Get-PfxPrivateKey'
	'Get-PfxPublicKey'
	'Grant-CertificatePermissions'
	'Revoke-CertificatePermissions'
	'Register-ServiceCertificate'
	'Unregister-ServiceCertificate'
	'Test-Thumbprint'
)

# export module members
Export-ModuleMember -Function $FunctionsToExport