[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
	[Parameter(ParameterSetName = 'Default', Position = 0, Mandatory = $True)][ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' })]
	[string]$RequestFile,
	[Parameter(ParameterSetName = 'Request', Position = 0, Mandatory = $True)]
	[uint32]$RequestID,
	[Parameter(ParameterSetName = 'Default', Position = 1)]
	[Parameter(ParameterSetName = 'Request', Position = 1, Mandatory = $True)]
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

# if request file provided...
If ($PSBoundParameters.ContainsKey('RequestFile')) {
	# retrieve text of request
	Try {
		$RequestText = [System.IO.File]::ReadAllText($RequestFile)
	}
	Catch {
		Write-Warning -Message "could not retrieve text from '$RequestFile' file: $($_.Exception.Message)"
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
	Write-Host "submitted certificate request for file: $($RequestFile.FullName)"

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
	Write-Host "created certificate request ID: $RequestID"
}

# if outfile provided...
If ($PSBoundParameters.('OutFile')) {
	# resubmit request
	Try {
		$ConfigObject.ResubmitRequest($ConfigString, $RequestID)
	}
	Catch {
		Write-Warning -Message "could not issue pending certificate with '$RequestID' request ID: $($_.Exception.Message)"
		Return
	}

	# report state
	Write-Host "issued certificate from request ID: $RequestID"

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
	Write-Host "saved certificate from '$RequestID' request ID to file: $OutFile"
}
