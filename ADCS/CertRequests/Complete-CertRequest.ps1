[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
    [Parameter(Position = 0, Mandatory = $True, ValueFromPipeline)]
    [uint32]$RequestID,
    [Parameter(Position = 1, Mandatory = $True)]
    [string]$OutFile
)

# create configuration object
Try {
    $ConfigObject = New-Object -ComObject 'CertificateAuthority.Config'
}
Catch {
    Write-Warning -Message "could not create CA configuration object: $($_.Exception.Message)"
    Return
}

# retrieve configuration string
Try {
    $ConfigString = $ConfigObject.GetConfig(4)
}
Catch {
    Write-Warning -Message "could not retrieve configuration string: $($_.Exception.Message)"
    Return
}

# create request object
Try {
    $RequestObject = New-Object -ComObject 'CertificateAuthority.Request'
}
Catch {
    Write-Warning -Message "could not create CA request object: $($_.Exception.Message)"
    Return
}

# load request object with certificate
Try {
    $RequestObject.RetrievePending($RequestID, $ConfigString)
}
Catch {
    Write-Warning -Message "could not retrieve issued certificate with '$RequestID' request ID: $($_.Exception.Message)"
    Return
}

# retrieve base64 encoded certificate text from request object
$Value = $RequestObject.GetCertificate(0)

# save certificate to file
Try {
    Set-Content -Path $OutFile -Value $Value
}
Catch {
    Write-Warning -Message "could not save issued certificate with '$RequestID' request ID to '$OutFile' file: $($_.Exception.Message)"
    Return
}

# report state
Write-Host "wrote certificate from '$RequestID' request ID to file: $OutFile"
