<#
.SYNOPSIS
Convert an attribute on an Active Directory object into an X.509 certificate object.

.DESCRIPTION
Convert an attribute on an Active Directory object into an X.509 certificate object. The input can be a byte array, a collection where the first element is a byte array, or the string representation of a byte array.

.PARAMETER Identity
Specifies the Active Directory object to retrieve

.PARAMETER Attribute
Specifies the attribute on the Active Directory object that represents an X.509 certificate

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