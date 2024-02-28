<#
.SYNOPSIS
Display information about the certificate presented by remote host.

.DESCRIPTION
Display information about the certificate presented by remote host. The script will display the Thumbprint, Subject, Issuer, and any Subject Alternate Names.

.PARAMETER Hostname
The fully-qualified hostname of the remote system.

.PARAMETER Port
The TCP port on the remote system. The default value is 443.

.PARAMETER Chain
Switch parameter to build a certificate chain for the retrieved certificate.

.PARAMETER Passthru
Switch parameter to return the certificate or certificate chain as objects instead of displaying information. Cannot be combined with the Validate parameter.

.PARAMETER Validate
Switch parameter to validate the certificate or certificate chain against the local certificate store. Cannot be combined with the Passthru parameter.

.INPUTS
System.String

.OUTPUTS
System.String, X509Certificate2, X509Chain

.EXAMPLE
.\Get-CertificateFromHost.ps1 -Hostname 'www.google.com'

.EXAMPLE
.\Get-CertificateFromHost.ps1 -Hostname 'www.google.com' -Chain

.EXAMPLE
.\Get-CertificateFromHost.ps1 -Hostname 'www.google.com' -Passthru

.EXAMPLE
.\Get-CertificateFromHost.ps1 -Hostname 'www.google.com' -Chain -Passthru

.EXAMPLE
.\Get-CertificateFromHost.ps1 -Hostname 'smtp.gmail.com' -Port 465

.EXAMPLE
.\Get-CertificateFromHost.ps1 -Hostname 'smtp.gmail.com' -Port 465 -Chain

.EXAMPLE
.\Get-CertificateFromHost.ps1 -Hostname 'smtp.gmail.com' -Port 465 -Passthru

.EXAMPLE
.\Get-CertificateFromHost.ps1 -Hostname 'smtp.gmail.com' -Port 465 -Chain -Passthur
#>

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Default')]
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
			Write-Error $_
			Return
		}
	}
	Catch {
		Write-Host 'Could not securely connect to remote host'
		Write-Error $_
		Return
	}
	Finally {
		# close secure connection
		$SSLStream.Dispose()
	}
}
Catch {
	Write-Host 'Could not connect to remote host'
	Write-Error $_
	Return
}
Finally {
	# close remote connection
	If ($null -ne $TCPSocket) {
		$TCPSocket.Dispose()
	}
}

# build certificate chain from remote server certificate
If ($Chain -or $Validate) {
	Try {
		# create certificate chain object
		$X509Chain = New-Object -TypeName 'System.Security.Cryptography.X509Certificates.X509Chain'
		$X509Chain.ChainPolicy.RevocationMode = 'NoCheck'
		# build certificate chain from remote server certificate
		$X509ChainValid = $X509Chain.Build($Certificate)
	}
	Catch {
		Write-Host 'Could not build certificate chain'
		Write-Error $_
		Return
	}
}

# return results
If ($Chain) {
	If ($PassThru) {
		# return certificate chain
		$X509Chain.ChainElements.Certificate
	}
	Else {
		# return certificate chain information
		$X509Chain.ChainElements.Certificate | Format-List Thumbprint, Subject, Issuer, DnsNameList
		# declare if certificate chain is trusted
		If ($Validate) {
			Write-Host "Certificate chain validated: $X509ChainValid"
			If ($X509Chain.ChainStatus.Count -eq 0) {
				Write-Host 'Certificate chain is trusted'
			}
			Else {
				Write-Host 'Certificate chain is NOT trusted:'
				$X509Chain.ChainStatus | Format-List Status, StatusInformation
			}
			Write-Host "`n"
		}
	}
}
Else {
	If ($PassThru) {
		# return certificate
		$Certificate
	}
	Else {
		# return certificate information
		$Certificate | Format-List Thumbprint, Subject, Issuer, DnsNameList
		# declare if certificate is trusted
		If ($Validate) {
			Write-Host "Certificate chain validated: $X509ChainValid"
			If ($X509Chain.ChainStatus.Count -eq 0) {
				Write-Host 'Certificate is trusted'
			}
			Else {
				Write-Host 'Certificate is NOT trusted:'
				$X509Chain.ChainStatus | Format-List Status, StatusInformation
			}
			Write-Host "`n"
		}
	}
}
