[CmdletBinding(SupportsShouldProcess)]
Param(
	[Parameter(Position = 0)]
	[string]$Url
)

Function Assert-ItemPropertyValue {
	[CmdletBinding(SupportsShouldProcess)]
	Param(
		[Parameter(Mandatory)]
		$Path,
		[Parameter(Mandatory)]
		$Name,
		[Parameter(Mandatory)]
		$Value,
		[Parameter(Mandatory)]
		$PropertyType
	)

	# retrieve current values
	Try {
		$CurrentValue = Get-ItemPropertyValue -Path $Path -Name $Name
	}
	Catch {
		Write-Warning -Message "could not retrieve value(s) of '$Name' property at '$Path' path: $($_.Exception.Message)"
		Return
	}

	# if property type is multi-string...
	If ($PropertyType -eq 'MultiString') {
		$UpdateRequired = [bool](Compare-Object -ReferenceObject $CurrentValue -DifferenceObject $Value)
	}
	Else {
		$UpdateRequired = $CurrentValue -ne $Value
	}

	# if update to values required...
	If ($UpdateRequired) {
		# define should process strings
		$ShouldProcessAction = 'update value(s)'
		$ShouldProcessTarget = $Name

		# if WhatIf provided...
		If ($PSCmdlet.ShouldProcess($ShouldProcessTarget, $ShouldProcessAction)) {
			# update values
			Try {
				$null = New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $PropertType -Force
			}
			Catch {
				Write-Warning -Message "could not update value(s) of '$Name' property: $($_.Exception.Message)"
				Return
			}

			# report state and return true
			Write-Host "Updated value(s) of '$Name' property: $Value"
			Return $true
		}
	}
	Else {
		# report state
		Write-Host "Verified value(s) of '$Name' property: $Value"
	}


}

# retrieve required values from registry
$Path = (Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration').PSPath

# if URL not provided...
if (!$PSBoundParameters.ContainsKey('Url')) {
	# retrieve pre-configured URL from registry
	Try {
		$Url = Get-ItemPropertyValue -Path $Path -Name 'CAServiceURL'
	}
	Catch {
		Return $_
	}
}

# retrieve CA type
Try {
	$CAType = Get-ItemPropertyValue -Path $Path -Name 'CAType'
}
Catch {
	Return $_
}

# reference: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wcce/4fa5241c-d10e-4011-87e0-c74753d725a3
# if CAType maps to Enterprise Root CA or Standalone Root CA...
If ($CAType -in 0, 3) {
	$Root = $true
}

# if root CA requested...
If ($Root) {
	# define ordered dictionary of hashtables for root CAs
	$Dictionary = [ordered]@{
		CACertPublicationURLs = @{
			Value        = '0:C:\Windows\system32\CertSrv\CertEnroll\%3%4.crt', "2:http://$Url/pki/%3%4.crt"
			PropertyType = 'MultiString'
		}
		CRLPublicationURLs    = @{
			Value        = '1:C:\Windows\system32\CertSrv\CertEnroll\%3%8.crl', "2:http://$Url/pki/%3%8.crl"
			PropertyType = 'MultiString'
		}
		CRLPeriod             = @{
			Value        = 'Months'
			PropertyType = 'String'
		}
		CRLPeriodUnits        = @{
			Value        = 1
			PropertyType = 'DWord'
		}
		CRLOverlapPeriod      = @{
			Value        = 'Weeks'
			PropertyType = 'String'
		}
		CRLOverlapUnits       = @{
			Value        = 1
			PropertyType = 'DWord'
		}
		CRLDeltaPeriod        = @{
			Value        = 'Days'
			PropertyType = 'String'
		}
		CRLDeltaPeriodUnits   = @{
			Value        = 0
			PropertyType = 'DWord'
		}
		CRLDeltaOverlapPeriod = @{
			Value        = 'Hours'
			PropertyType = 'String'
		}
		CRLDeltaOverlapUnits  = @{
			Value        = 0
			PropertyType = 'DWord'
		}
		ValidityPeriod        = @{
			Value        = 'Years'
			PropertyType = 'String'
		}
		ValidityPeriodUnits   = @{
			Value        = 10
			PropertyType = 'DWord'
		}
	}
}
Else {
	# define ordered dictionary of hashtables for issuing CAs
	$Dictionary = [ordered]@{
		CACertPublicationURLs = @{
			Value        = '0:C:\Windows\system32\CertSrv\CertEnroll\%3%4.crt', "2:http://$Url/pki/%3%4.crt"
			PropertyType = 'MultiString'
		}
		CRLPublicationURLs    = @{
			Value        = '65:C:\Windows\system32\CertSrv\CertEnroll\%3%8%9.crl', "6:http://$Url/pki/%3%8%9.crl"
			PropertyType = 'MultiString'
		}
		CRLPeriod             = @{
			Value        = 'Weeks'
			PropertyType = 'String'
		}
		CRLPeriodUnits        = @{
			Value        = 2
			PropertyType = 'DWord'
		}
		CRLOverlapPeriod      = @{
			Value        = 'Days'
			PropertyType = 'String'
		}
		CRLOverlapUnits       = @{
			Value        = 4
			PropertyType = 'DWord'
		}
		CRLDeltaPeriod        = @{
			Value        = 'Days'
			PropertyType = 'String'
		}
		CRLDeltaPeriodUnits   = @{
			Value        = 1
			PropertyType = 'DWord'
		}
		CRLDeltaOverlapPeriod = @{
			Value        = 'Hours'
			PropertyType = 'String'
		}
		CRLDeltaOverlapUnits  = @{
			Value        = 6
			PropertyType = 'DWord'
		}
		ValidityPeriod        = @{
			Value        = 'Years'
			PropertyType = 'String'
		}
		ValidityPeriodUnits   = @{
			Value        = 3
			PropertyType = 'DWord'
		}
	}
}

# loop through keys in dictionary
ForEach ($Name in $Dictionary.Keys) {
	# retrieve parameters hashtable from dictionary
	$Parameters = $Dictionary[$Name]

	# assert values
	Try {
		$ValueUpdated = Assert-ItemPropertyValue @Parameters -Path $Path -Name $Name
	}
	Catch {
		Write-Warning -Message "could not assert value(s) for '$Name'"
	}

	# if value updated...
	If ($ValueUpdated) {
		$RestartRequired = $true
	}
}

# if restart required...
If ($RestartRequired) {
	# define should process strings
	$ShouldProcessTarget = 'CertSvc'
	$ShouldProcessAction = 'restarted service'

	# if WhatIf provided...
	If ($PSCmdlet.ShouldProcess($ShouldProcessTarget, $ShouldProcessAction)) {
		# stop service
		Write-Output "`nStopping CertSvc before CA configuration..."
		Stop-Service 'CertSvc'

		# start the service
		Write-Output "`nStarting CertSvc after CA configuration..."
		Start-Service 'CertSvc'

		# wait while the CA fully starts
		Write-Output "...waiting for CertSvc to complete startup`n"
		Start-Sleep -Seconds 15

	}
	# define should process strings
	$ShouldProcessTarget = 'CertUtil'
	$ShouldProcessAction = 'issued new CRLs'
	
	# if WhatIf provided...
	If ($PSCmdlet.ShouldProcess($ShouldProcessTarget, $ShouldProcessAction)) {
		# issue a new CRL
		Invoke-Expression 'certutil -crl'
	}
}
