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

Function Get-CertificateFromHost {
	<#
	.SYNOPSIS
	Retrieve or validate the certificate presented by a remote host.

	.DESCRIPTION
	Retrieve or validate the certificate or certificate chain presented by a remote host.

	.PARAMETER Hostname
	Specifies the DNS hostname of the remote host.

	.PARAMETER Port
	Specifies the TCP port on the remote host.

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
		[string]$Hostname,
		[Parameter(Position = 1)]
		[int32]$Port = 443,
		[Parameter(Position = 2)]
		[int32]$Timeout = 3000,
		[Parameter()]
		[switch]$Chain,
		[Parameter(ParameterSetName = 'Validate')]
		[switch]$Validate
	)

	# check hostname for included port number
	If ($Hostname -match '([0-9A-z.\-:]*):([0-9]*)') {
		# set hostname to first match
		$Hostname = $matches[1]
		# if port not explicitly set...
		If ($null -eq $PSBoundParameters['Port']) {
			# ...set port to second match
			$Port = $matches[2]
		}
	}

	# resolve hostname
	Try {
		$null = Resolve-DnsName -Name $Hostname -QuickTimeout -ErrorAction 'Stop' -Verbose:$false
	}
	Catch {
		Write-Warning $_.ToString()
		Return
	}

	# retrieve certificate from remote server
	Try {
		# define tcp client
		$TcpClient = New-Object 'System.Net.Sockets.TcpClient'
		# connect tcp client
		$TcpHandle = $TcpClient.BeginConnect($Hostname, $Port, $null, $null)
		# check tcp client
		$TcpResult = $TcpHandle.AsyncWaitHandle.WaitOne($Timeout, $false)
		# if connected before timeout...
		If ($TcpResult) {
			# ...complete connection
			$TcpClient.EndConnect($TcpHandle)
		}
		# if not connected before timeout...
		Else {
			# ...close the connection and return a null
			$TcpClient.Close()
			Write-Warning 'connection timed out'
			Return $null
		}
		# open stream to remove server
		$TcpClientStream = $TcpClient.GetStream()
		# define System.Net.Security.RemoteCertificateValidationCallback delegate that always returns true
		$RemoteCertificateValidationCallback = { param($delegate_sender, $delegate_certificate, $delegate_chain, $delegate_sslPolicyErrors) return $true }
		# define sslstream
		$SSLStream = New-Object -TypeName 'System.Net.Security.SSLStream' -ArgumentList @($TcpClientStream, $true, $RemoteCertificateValidationCallback)
		# authenticate to hostname
		$SSLStream.AuthenticateAsClient($Hostname)
		# get certificate sent by remote server
		$Certificate = New-Object -TypeName 'System.Security.Cryptography.X509Certificates.X509Certificate2' -ArgumentList $SSLStream.RemoteCertificate
	}
	Catch {
		Throw $_
	}
	Finally {
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
$functions_to_export += 'Get-CertificateFromHost'
$functions_to_export += 'Test-Thumbprint'

# export module members
Export-ModuleMember -Function $functions_to_export