Function ConvertTo-X509Certificate {
    [CmdletBinding()]
    Param (
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        [object]$Input
    )

    # create empty certificate object
    $x509_cert = New-Object -TypeName 'System.Security.Cryptography.X509Certificates.X509Certificate2'

    # import the certificate data into the object
    switch ($true) {
        { $Input[0] -is [byte[]] } { $x509_cert.Import($Input[0]) }
        { $Input -is [byte[]] } { $x509_cert.Import($Input) }
        Default { $x509_cert.Import([byte[]]$Input) }
    }
    
    # return populated certificate object
    $x509_cert 
}

Function Test-Thumbprint {
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