<#
.SYNOPSIS
Retrieves ADFS certificates from metadata

.DESCRIPTION
Retrieves ADFS certificates from metadata

.PARAMETER Hostname
The hostname for the ADFS service

.PARAMETER Uri
The URI for the ADFS metadata

.PARAMETER ChildPath
The child path for the certificate update files. The full path is formed by joining the path from the JSON file and the value of this parameter.

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Update-AdfsCertificate.ps1 -Json C:\Content\adfs\config.json -ChildPath 'certificates'
#>

[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	# URI for metadata
	[Parameter(ParameterSetName = 'Default', Mandatory = $True)]
	[uri]$Uri,
	# string for ADFS service name
	[Parameter(ParameterSetName = 'Hostname', Mandatory = $True)]
	[string]$Hostname,
	# child path to metadata folder
	[Parameter(ParameterSetName = 'Hostname', DontShow)]
	[string]$Prefix = 'https://',
	[Parameter(ParameterSetName = 'Hostname', DontShow)]
	[string]$Suffix = '/FederationMetadata/2007-06/FederationMetadata.xml'
)

# if hostname provided...
If ($PSCmdlet.ParameterSetName -eq 'Hostname') {
	# create URI object
	$Uri = [System.Uri]::new("$Prefix$Hostname$Suffix")
}

# request metadata
Try {
	$WebRequest = Invoke-WebRequest -Uri $Uri -UseBasicParsing
}
Catch {
	Write-Warning "could not retrieve metadata: $($_.ToString())"
	Return
}

# create XML object
$Xml = [System.Xml.XmlDocument]::new()

# extract metadata as XML
Try {
	$Xml.LoadXml($WebRequest.Content)
}
Catch {
	Write-Warning "could not retrieve metadata: $($_.ToString())"
	Return
}

# create list to hold custom objects
$List = [System.Collections.Generic.List[object]]::new()

# extract signing certificate strings
Try {
	$SigningCertificates = $Xml.EntityDescriptor.IDPSSODescriptor.KeyDescriptor.Where({ $_.use -eq 'signing'}).KeyInfo.X509Data.X509Certificate
}
Catch {
	Write-Warning "could not extract signing certificates: $($_.ToString())"
	Return
}

# define counter
$Index = 1

# process each signing certificate string
ForEach ($SigningCertificate in $SigningCertificates) {
	# convert signing certificate string to byte array
	Try {
		$SigningCertificateBytes = [System.Convert]::FromBase64String($SigningCertificate)
	}
	Catch {
		Write-Warning "could not convert signing certificate to byte array: $($_.ToString())"
		Return
	}

	# create certificate object from byte array
	Try {
		$X509Certificate2 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($SigningCertificateBytes)
	}
	Catch {
		Write-Warning "could not create certificate from byte array: $($_.ToString())"
		Return
	}
	
	# create custom certificate object
	Try {
	$CertificateObject = [PSCustomObject]@{ Type = 'signing'; Index = $Index; Certificate = $X509Certificate2 }
	}
	Catch {
		Write-Warning "could not create custom object with certificate: $($_.ToString())"
		Return
	}

	# add certificate object to list
	Try {
		$List.Add($CertificateObject)
	}
	Catch {
		Write-Warning "could not add certificate object to list: $($_.ToString())"
		Return
	}
	
	# increment index
	$Index++
}

# extract encryption certificate strings
Try {
	$EncryptionCertificates = $Xml.EntityDescriptor.SPSSODescriptor.KeyDescriptor.Where({ $_.use -eq 'encryption'}).KeyInfo.X509Data.X509Certificate
}
Catch {
	Write-Warning "could not extract encryption certificates: $($_.ToString())"
	Return
}

# define counter
$Index = 1

# process each encryption certificate string
ForEach ($EncryptionCertificate in $EncryptionCertificates) {
	# convert encryption certificate string to byte array
	Try {
		$CertificateBytes = [System.Convert]::FromBase64String($EncryptionCertificate)
	}
	Catch {
		Write-Warning "could not convert encryption certificate to byte array: $($_.ToString())"
		Return
	}

	# create certificate object from byte array
	Try {
		$X509Certificate2 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($CertificateBytes)
	}
	Catch {
		Write-Warning "could not create certificate from byte array: $($_.ToString())"
		Return
	}
	
	# create custom certificate object
	Try {
	$CertificateObject = [PSCustomObject]@{ Type = 'encryption'; Index = $Index; Certificate = $X509Certificate2 }
	}
	Catch {
		Write-Warning "could not create custom object with certificate: $($_.ToString())"
		Return
	}

	# add certificate object to list
	Try {
		$List.Add($CertificateObject)
	}
	Catch {
		Write-Warning "could not add certificate object to list: $($_.ToString())"
		Return
	}
	
	# increment index
	$Index++
}

Return $List
