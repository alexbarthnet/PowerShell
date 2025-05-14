[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
    [Parameter(Position = 0, Mandatory, ValueFromPipeline)]
    [uint32]$RequestID,
    [Parameter(Position = 1)]
    [switch]$PassThru
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

# create admin object
Try {
    $AdminObject = New-Object -ComObject 'CertificateAuthority.Admin'
}
Catch {
    Write-Warning -Message "could not create CA admin object: $($_.Exception.Message)"
    Return
}

# resubmit request
Try {
    $AdminObject.ResubmitRequest($ConfigString, $RequestID)
}
Catch {
    Write-Warning -Message "could not issue pending certificate with '$RequestID' request ID: $($_.Exception.Message)"
    Return
}

# report state
Write-Host "approved certificate request with request ID: $RequestID"

# if passthru requested...
If ($PassThru) {
    Return $RequestID
}
