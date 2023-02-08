Function ConvertTo-X509Certificate {
	<#
	.SYNOPSIS
	Convert an input object into an X.509 certificate object.

	.DESCRIPTION
	Convert an input object into an X.509 certificate object. The input object can be a byte array, a collection where the first element is a byte array, or the string representation of a byte array.

	.PARAMETER InputObject
	Specifies the input object that represents an X.509 certificate

	.INPUTS
	System.ByteArray,System.Collections,System.String. A byte array, 

	.OUTPUTS
	X509Certificate2. An X509Certificate2 object created from the input.

	#>
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		$InputObject
	)

	# create empty certificate object
	$Certificate = New-Object -TypeName 'System.Security.Cryptography.X509Certificates.X509Certificate2'

	# if InputObject is a collection and first element is a byte array...
	If ( $InputObject[0] -is [byte[]] ) {
		# ...retrieve byte array from first element of InputObject
		$ByteArray = $InputObject[0]
	}
	# if InputObject is a byte array...
	ElseIf ( $InputObject -is [byte[]] ) {
		# ...copy InputObject to byte array
		$ByteArray = $InputObject
	}
	# if InputObject is a byte array...
	ElseIf ( $InputObject -is [string]) {
		$ByteArray = [System.Convert]::ToByte($InputObject)
	}
	Else {
		Try {
			$ByteArray = [byte[]]$InputObject
		}
		Catch {
			Throw $_
		}
	}

	# import byte array into certificate object
	Try {
		$Certificate.Import($ByteArray)
	}
	Catch {
		Throw $_
	}

	# return populated certificate object
	Return $Certificate
}

Function Get-CertificateChain {
	<#
	.SYNOPSIS
	Builds a certificate chain from an X.509 certificate object.

	.DESCRIPTION
	Builds a certificate chain from an X.509 certificate object. The input must be an X.509 certificate object.

	.PARAMETER Certificate
	Specifies the input that represents an X.509 certificate

	.INPUTS
	X509Certificate2. An object representing an X509 certificate.

	.OUTPUTS
	X509Certificate2. An object representing an X509 certificate.

	#>
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[object]$Certificate,
		[Parameter(Position = 1)]
		[string]$Attribute = 'userCertificate'
	)

	Try {
		# create certificate chain object
		$X509Chain = New-Object -TypeName 'System.Security.Cryptography.X509Certificates.X509Chain'
		# disable 
		$X509Chain.ChainPolicy.RevocationMode = 'NoCheck'
		# build certificate chain from remote server certificate
		$X509Chain.Build($Certificate)
		# return certificate chain
		Return $X509Chain.ChainElements.Certificate
	}
	Catch {
		Throw $_
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
		[string]$Attribute = 'userCertificate'
	)

	# if Identity is an ADobject with and the Attribute is not null...
	If (($Identity -is [Microsoft.ActiveDirectory.Management.ADObject]) -and ($null -ne $Identity.$Attribute)) {
		# ...retrieve the value from the attribute on the object
		$Value = $Identity.$Attribute
	}
	# if Identity is not ADObject or the Attribute on the ADObject is null...
	Else {
		# ...try to retrieve an object via S.DS
		Try {
			$Entry = [System.DirectoryServices.DirectoryEntry]::New("LDAP://$Identity")
		}
		Catch {
			Throw $_
		}
		# ...then get attribute for object
		Try {
			$Value = $Entry.$Attribute
		}
		Catch {
			Throw $_
		}
	}

	# if Value is not null...
	If ($null -ne $Value[0]) {
		# ...pass value to convert function
		Try {
			$Certificate = $Value[0] | ConvertTo-X509Certificate
		}
		Catch {
			Throw $_
		}
	}
	# if Value is null...
	Else {
		# TODO find exception to throw
		Return $null
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

	.PARAMETER Chain
	Switch to return the certificate and all certificates in chain.

	.INPUTS
	System.String. A string representing a computer hostname.

	.OUTPUTS
	X509Certificate2. An object representing an X509 certificate.

	#>
	[CmdletBinding(DefaultParameterSetName = 'Default')]
	Param (
		# string for remote host
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[string]$Hostname,
		# int32 for remote port
		[Parameter(Position = 1)]
		[int32]$Port = 443,
		# switch for expanding from certificate to certificate chain
		[Parameter()]
		[switch]$Chain,
		# switch for returning object
		[Parameter(ParameterSetName = 'PassThru')]
		[switch]$PassThru,
		# switch for validating certificate is trusted
		[Parameter(ParameterSetName = 'Validate')]
		[switch]$Validate
	)

	# test hostname and port
	If (-not (Test-NetConnection -ComputerName $Hostname -Port $Port -InformationLevel 'Quiet')) {
		Write-Host 'could not connect to remote host'
		Return
	}

	# retrieve certificate from remote server
	Try {
		# connect to remote server
		$TcpSocket = New-Object 'System.Net.Sockets.TcpClient' -ArgumentList @($Hostname, $Port)
		$TcpSocketStream = $TcpSocket.GetStream()
		Try {
			# define System.Net.Security.RemoteCertificateValidationCallback delegate that always returns true
			$RemoteCertificateValidationCallback = { param($delegate_sender, $delegate_certificate, $delegate_chain, $delegate_sslPolicyErrors) return $true }
			# negotiate secure connection
			$SSLStream = New-Object -TypeName 'System.Net.Security.SSLStream' -ArgumentList @($TcpSocketStream, $true, $RemoteCertificateValidationCallback)
			$SSLStream.AuthenticateAsClient($Hostname)
			Try {
				# get certificate sent by remote server
				$Certificate = New-Object -TypeName 'System.Security.Cryptography.X509Certificates.X509Certificate2' -ArgumentList $SSLStream.RemoteCertificate
			}
			Catch {
				Write-Host 'Could not retrieve certificate from remote host'
				Throw $_
			}
		}
		Catch {
			Write-Host 'Could not securely connect to remote host'
			Throw $_
		}
		Finally {
			# close secure connection
			$SSLStream.Dispose()
		}
	}
	Catch {
		Write-Host 'Could not connect to remote host'
		Throw $_
	}
	Finally {
		# close remote connection
		If ($null -ne $TCPSocket) {
			$TCPSocket.Dispose()
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