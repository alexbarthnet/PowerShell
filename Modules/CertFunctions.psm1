Function ConvertTo-X509Certificate {
	<#
	.SYNOPSIS
	Convert an input into an X.509 certificate object.

	.DESCRIPTION
	Convert an input into an X.509 certificate object. The input can be a byte array, a collection where the first element is a byte array, or the string representation of a byte array.

	.PARAMETER InputObject
	Specifies the input that represents an X.509 certificate

	.INPUTS
	None.

	.OUTPUTS
	None.

	#>
	[CmdletBinding()]
	Param (
		[Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
		[object]$InputObject
	)

	# create empty certificate object
	$Certificate = New-Object -TypeName 'System.Security.Cryptography.X509Certificates.X509Certificate2'

	# import byte array into certificate object
	If ( $InputObject[0] -is [byte[]] ) {
		$Certificate.Import($InputObject[0])
	}
	ElseIf ( $InputObject -is [byte[]] ) {
		$Certificate.Import($InputObject)
	}
	Else {
		$Certificate.Import([byte[]]$InputObject)
	}

	# return populated certificate object
	$Certificate
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
$functions_to_export += 'Test-Thumbprint'

# export module members
Export-ModuleMember -Function $functions_to_export