[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(Position = 0, Mandatory, ValueFromPipeline)]
	[string]$Path,
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

# retrieve text of request
Try {
	$RequestText = [System.IO.File]::ReadAllText($Path)
}
Catch {
	Write-Warning -Message "could not retrieve text from '$Path' file: $($_.Exception.Message)"
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

# submit request to CA
Try {
	$Status = $RequestObject.Submit(0, $RequestText, $null, $ConfigString)
}
Catch {
	Write-Warning -Message "could not submit request to CA object: $($_.Exception.Message)"
	Return
}

# report state
Write-Host "submitted certificate request from file: $Path"

# reference: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wcce/c084a3e3-4df3-4a28-9a3b-6b08487b04f3
# if status is not 5...
If ($Status -ne '5') {
	Write-Warning -Message "request not in a valid state; status is '$Status'"
	Return
}

# retrieve request id
Try {
	$RequestID = $RequestObject.GetRequestId()
}
Catch {
	Write-Warning -Message "could not retrieve request ID: $($_.Exception.Message)"
	Return
}

# report state
Write-Host "received certificate request ID: $RequestID"

# if passthru requested...
If ($PassThru) {
	Return $RequestID
}
