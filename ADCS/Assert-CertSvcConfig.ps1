[CmdletBinding(SupportsShouldProcess)]
Param(
	[Parameter(Position = 0, Mandatory = $True)]
	[string]$Url,
	[Parameter(Position = 1)]
	[switch]$Root
)

# retrieve required values from registry
$CA_Config = (Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration').PSPath

################
# AIA
################

# reset state
$CurrentValue = $null
$DesiredValue = $null

# define desired values
$DesiredValues = '0:C:\Windows\system32\CertSrv\CertEnroll\%3%4.crt', "2:http://$Url/pki/%3%4.crt"

# retrieve current values
Try {
	$CurrentValues = Get-ItemPropertyValue -Path $CA_Config -Name 'CACertPublicationURLs'
}
Catch {
	Write-Warning -Message "could not retrieve AIA values: $($_.Exception.Message)"
	Return
}

# compare values
Try {
	$UpdateRequired = [bool](Compare-Object -ReferenceObject $CurrentValues -DifferenceObject $DesiredValues)
}
Catch {
	Write-Warning -Message "could not compare AIA values: $($_.Exception.Message)"
	Return
}

# if update to values required...
If ($UpdateRequired) {
	# update global boolean
	$ValuesUpdated = $True

	# define should process strings
	$ShouldProcessTarget = 'CACertPublicationURLs'
	$ShouldProcessAction = 'update values'

	# if WhatIf provided...
	If ($PSCmdlet.ShouldProcess($ShouldProcessTarget, $ShouldProcessAction)) {
		# update values
		Try {
			$null = New-ItemProperty -Path $CA_Config -Name 'CACertPublicationURLs' -Value $DesiredValues -PropertyType MultiString -Force
		}
		Catch {
			Write-Warning -Message "could not update AIA URLs: $($_.Exception.Message)"
			Return
		}

		# report state
		Write-Host "Updated AIA values: $DesiredValues"
	}
}
Else {
	# report state
	Write-Host "Verified AIA values: $CurrentValues"
}

################
# CDP
################

# reset state
$CurrentValue = $null
$DesiredValue = $null

# if root requested...
If ($Root) {
	# define desired values for root CA
	$DesiredValues = '1:C:\Windows\system32\CertSrv\CertEnroll\%3%8.crl', "2:http://$Url/pki/%3%8.crl"
}
Else {
	# define desired values for issuing CA
	$DesiredValues = '65:C:\Windows\system32\CertSrv\CertEnroll\%3%8%9.crl', "6:http://$Url/pki/%3%8%9.crl"
}

# retrieve current values
Try {
	$CurrentValues = Get-ItemPropertyValue -Path $CA_Config -Name 'CRLPublicationURLs'
}
Catch {
	Write-Warning -Message "could not retrieve CDP values: $($_.Exception.Message)"
	Return
}

# compare CDP values
Try {
	$UpdateRequired = [bool](Compare-Object -ReferenceObject $CurrentValues -DifferenceObject $DesiredValues)
}
Catch {
	Write-Warning -Message "could not compare CDP values: $($_.Exception.Message)"
	Return
}

# if update to AIA values required...
If ($UpdateRequired) {
	# update global boolean
	$ValuesUpdated = $True

	# define should process strings
	$ShouldProcessTarget = 'CRLPublicationURLs'
	$ShouldProcessAction = 'update values'

	# if WhatIf provided...
	If ($PSCmdlet.ShouldProcess($ShouldProcessTarget, $ShouldProcessAction)) {
		# update value
		Try {
			$null = New-ItemProperty -Path $CA_Config -Name 'CRLPublicationURLs' -Value $DesiredValues -PropertyType MultiString -Force
		}
		Catch {
			Write-Warning -Message "could not update CDP URLs: $($_.Exception.Message)"
			Return
		}

		# report state
		Write-Host "Updated CDP values: $DesiredValues"
	}
}
Else {
	# report state
	Write-Host "Verified CDP values: $CurrentValues"
}

####################
# CRL period type
####################

# reset state
$CurrentValue = $null
$DesiredValue = $null

# if root requested...
If ($Root) {
	# define desired value for root CAs
	$DesiredValue = 'Months'
}
Else {
	# define desired value for issuing CAs
	$DesiredValue = 'Weeks'
}

# retrieve current value
Try {
	$CurrentValue = Get-ItemPropertyValue -Path $CA_Config -Name 'CRLPeriod'
}
Catch {
	Write-Warning -Message "could not retrieve CRL Period type value: $($_.Exception.Message)"
	Return
}

# compare values
Try {
	$UpdateRequired = $CurrentValue -ne $DesiredValue
}
Catch {
	Write-Warning -Message "could not compare CRL Period type value: $($_.Exception.Message)"
	Return
}

# if update to value required...
If ($UpdateRequired) {
	# update global boolean
	$ValuesUpdated = $True

	# define should process strings
	$ShouldProcessTarget = 'CRLPeriod'
	$ShouldProcessAction = 'update values'

	# if WhatIf provided...
	If ($PSCmdlet.ShouldProcess($ShouldProcessTarget, $ShouldProcessAction)) {
		# update value
		Try {
			$null = New-ItemProperty -Path $CA_Config -Name 'CRLPeriod' -Value $DesiredValue -PropertyType String -Force
		}
		Catch {
			Write-Warning -Message "could not update CRL Period type value: $($_.Exception.Message)"
			Return
		}

		# report state
		Write-Host "Updated CRL Period type value: $DesiredValue"
	}
}
Else {
	# report state
	Write-Host "Verified CRL Period type value: $CurrentValue"
}

####################
# CRL period unit
####################

# reset state
$CurrentValue = $null
$DesiredValue = $null

# if root requested...
If ($Root) {
	# define desired value for root CAs
	$DesiredValue = 1
}
Else {
	# define desired value for issuing CAs
	$DesiredValue = 2
}

# retrieve current value
Try {
	$CurrentValue = Get-ItemPropertyValue -Path $CA_Config -Name 'CRLPeriodUnits'
}
Catch {
	Write-Warning -Message "could not retrieve CRL Period unit value: $($_.Exception.Message)"
	Return
}

# compare values
Try {
	$UpdateRequired = $CurrentValue -ne $DesiredValue
}
Catch {
	Write-Warning -Message "could not compare CRL Period unit value: $($_.Exception.Message)"
	Return
}

# if update to value required...
If ($UpdateRequired) {
	# update global boolean
	$ValuesUpdated = $True

	# define should process strings
	$ShouldProcessTarget = 'CRLPeriodUnits'
	$ShouldProcessAction = 'update values'

	# if WhatIf provided...
	If ($PSCmdlet.ShouldProcess($ShouldProcessTarget, $ShouldProcessAction)) {
		# update value
		Try {
			$null = New-ItemProperty -Path $CA_Config -Name 'CRLPeriodUnits' -Value $DesiredValue -PropertyType DWord -Force
		}
		Catch {
			Write-Warning -Message "could not update CRL Period unit value: $($_.Exception.Message)"
			Return
		}

		# report state
		Write-Host "Updated CRL Period unit value: $DesiredValue"
	}
}
Else {
	# report state
	Write-Host "Verified CRL Period unit value: $CurrentValue"
}

####################
# CRL overlap type
####################

# reset state
$CurrentValue = $null
$DesiredValue = $null

# if root requested...
If ($Root) {
	# define desired value for root CAs
	$DesiredValue = 'Weeks'
}
Else {
	# define desired value for issuing CAs
	$DesiredValue = 'Days'
}

# retrieve current value
Try {
	$CurrentValue = Get-ItemPropertyValue -Path $CA_Config -Name 'CRLOverlapPeriod'
}
Catch {
	Write-Warning -Message "could not retrieve CRL Overlap type value: $($_.Exception.Message)"
	Return
}

# compare values
Try {
	$UpdateRequired = $CurrentValue -ne $DesiredValue
}
Catch {
	Write-Warning -Message "could not compare CRL Overlap type value: $($_.Exception.Message)"
	Return
}

# if update to value required...
If ($UpdateRequired) {
	# update global boolean
	$ValuesUpdated = $True

	# define should process strings
	$ShouldProcessTarget = 'CRLOverlapPeriod'
	$ShouldProcessAction = 'update values'

	# if WhatIf provided...
	If ($PSCmdlet.ShouldProcess($ShouldProcessTarget, $ShouldProcessAction)) {
		# update value
		Try {
			$null = New-ItemProperty -Path $CA_Config -Name 'CRLOverlapPeriod' -Value $DesiredValue -PropertyType String -Force
		}
		Catch {
			Write-Warning -Message "could not update CRL Overlap type value: $($_.Exception.Message)"
			Return
		}

		# report state
		Write-Host "Updated CRL Overlap type value: $DesiredValue"
	}
}
Else {
	# report state
	Write-Host "Verified CRL Overlap type value: $CurrentValue"
}

####################
# CRL overlap unit
####################

# reset state
$CurrentValue = $null
$DesiredValue = $null

# if root requested...
If ($Root) {
	# define desired value for root CAs
	$DesiredValue = 1
}
Else {
	# define desired value for issuing CAs
	$DesiredValue = 4
}

# retrieve current value
Try {
	$CurrentValue = Get-ItemPropertyValue -Path $CA_Config -Name 'CRLOverlapUnits'
}
Catch {
	Write-Warning -Message "could not retrieve CRL Overlap unit value: $($_.Exception.Message)"
	Return
}

# compare values
Try {
	$UpdateRequired = $CurrentValue -ne $DesiredValue
}
Catch {
	Write-Warning -Message "could not compare CRL Overlap unit value: $($_.Exception.Message)"
	Return
}

# if update to value required...
If ($UpdateRequired) {
	# update global boolean
	$ValuesUpdated = $True

	# define should process strings
	$ShouldProcessTarget = 'CRLOverlapUnits'
	$ShouldProcessAction = 'update values'

	# if WhatIf provided...
	If ($PSCmdlet.ShouldProcess($ShouldProcessTarget, $ShouldProcessAction)) {
		# update value
		Try {
			$null = New-ItemProperty -Path $CA_Config -Name 'CRLOverlapUnits' -Value $DesiredValue -PropertyType DWord -Force
		}
		Catch {
			Write-Warning -Message "could not update CRL Overlap unit value: $($_.Exception.Message)"
			Return
		}

		# report state
		Write-Host "Updated CRL Overlap unit value: $DesiredValue"
	}
}
Else {
	# report state
	Write-Host "Verified CRL Overlap unit value: $CurrentValue"
}

########################
# Delta CRL period type
########################

# reset state
$CurrentValue = $null
$DesiredValue = $null

# if root requested...
If ($Root) {
	# define desired value for root CAs
	$DesiredValue = 'Days'
}
Else {
	# define desired value for issuing CAs
	$DesiredValue = 'Days'
}

# retrieve current value
Try {
	$CurrentValue = Get-ItemPropertyValue -Path $CA_Config -Name 'CRLDeltaPeriod'
}
Catch {
	Write-Warning -Message "could not retrieve Delta CRL Period type value: $($_.Exception.Message)"
	Return
}

# compare values
Try {
	$UpdateRequired = $CurrentValue -ne $DesiredValue
}
Catch {
	Write-Warning -Message "could not compare Delta CRL Period type value: $($_.Exception.Message)"
	Return
}

# if update to value required...
If ($UpdateRequired) {
	# update global boolean
	$ValuesUpdated = $True

	# define should process strings
	$ShouldProcessTarget = 'CRLDeltaPeriod'
	$ShouldProcessAction = 'update values'

	# if WhatIf provided...
	If ($PSCmdlet.ShouldProcess($ShouldProcessTarget, $ShouldProcessAction)) {
		# update value
		Try {
			$null = New-ItemProperty -Path $CA_Config -Name 'CRLDeltaPeriod' -Value $DesiredValue -PropertyType String -Force
		}
		Catch {
			Write-Warning -Message "could not update Delta CRL Period type value: $($_.Exception.Message)"
			Return
		}

		# report state
		Write-Host "Updated Delta CRL Period type value: $DesiredValue"
	}
}
Else {
	# report state
	Write-Host "Verified Delta CRL Period type value: $CurrentValue"
}

####################
# Delta CRL period unit
####################

# reset state
$CurrentValue = $null
$DesiredValue = $null

# if root requested...
If ($Root) {
	# define desired value for root CAs
	$DesiredValue = 0
}
Else {
	# define desired value for issuing CAs
	$DesiredValue = 1
}

# retrieve current value
Try {
	$CurrentValue = Get-ItemPropertyValue -Path $CA_Config -Name 'CRLDeltaPeriodUnits'
}
Catch {
	Write-Warning -Message "could not retrieve Delta CRL Period unit value: $($_.Exception.Message)"
	Return
}

# compare values
Try {
	$UpdateRequired = $CurrentValue -ne $DesiredValue
}
Catch {
	Write-Warning -Message "could not compare Delta CRL Period unit value: $($_.Exception.Message)"
	Return
}

# if update to value required...
If ($UpdateRequired) {
	# update global boolean
	$ValuesUpdated = $True

	# define should process strings
	$ShouldProcessTarget = 'CRLDeltaPeriodUnits'
	$ShouldProcessAction = 'update values'

	# if WhatIf provided...
	If ($PSCmdlet.ShouldProcess($ShouldProcessTarget, $ShouldProcessAction)) {
		# update value
		Try {
			$null = New-ItemProperty -Path $CA_Config -Name 'CRLDeltaPeriodUnits' -Value $DesiredValue -PropertyType DWord -Force
		}
		Catch {
			Write-Warning -Message "could not update Delta CRL Period unit value: $($_.Exception.Message)"
			Return
		}

		# report state
		Write-Host "Updated Delta CRL Period unit value: $DesiredValue"
	}
}
Else {
	# report state
	Write-Host "Verified Delta CRL Period unit value: $CurrentValue"
}

####################
# Delta CRL overlap type
####################

# reset state
$CurrentValue = $null
$DesiredValue = $null

# if root requested...
If ($Root) {
	# define desired value for root CAs
	$DesiredValue = 'Hours'
}
Else {
	# define desired value for issuing CAs
	$DesiredValue = 'Hours'
}

# retrieve current value
Try {
	$CurrentValue = Get-ItemPropertyValue -Path $CA_Config -Name 'CRLDeltaOverlapPeriod'
}
Catch {
	Write-Warning -Message "could not retrieve Delta CRL Overlap type value: $($_.Exception.Message)"
	Return
}

# compare values
Try {
	$UpdateRequired = $CurrentValue -ne $DesiredValue
}
Catch {
	Write-Warning -Message "could not compare Delta CRL Overlap type value: $($_.Exception.Message)"
	Return
}

# if update to value required...
If ($UpdateRequired) {
	# update global boolean
	$ValuesUpdated = $True

	# define should process strings
	$ShouldProcessTarget = 'CRLDeltaOverlapPeriod'
	$ShouldProcessAction = 'update values'

	# if WhatIf provided...
	If ($PSCmdlet.ShouldProcess($ShouldProcessTarget, $ShouldProcessAction)) {
		# update value
		Try {
			$null = New-ItemProperty -Path $CA_Config -Name 'CRLDeltaOverlapPeriod' -Value $DesiredValue -PropertyType String -Force
		}
		Catch {
			Write-Warning -Message "could not update Delta CRL Overlap type value: $($_.Exception.Message)"
			Return
		}

		# report state
		Write-Host "Updated Delta CRL Overlap type value: $DesiredValue"
	}
}
Else {
	# report state
	Write-Host "Verified Delta CRL Overlap type value: $CurrentValue"
}

########################
# Delta CRL overlap unit
########################

# reset state
$CurrentValue = $null
$DesiredValue = $null

# if root requested...
If ($Root) {
	# define desired value for root CAs
	$DesiredValue = 0
}
Else {
	# define desired value for issuing CAs
	$DesiredValue = 6
}

# retrieve current value
Try {
	$CurrentValue = Get-ItemPropertyValue -Path $CA_Config -Name 'CRLDeltaOverlapUnits'
}
Catch {
	Write-Warning -Message "could not retrieve Delta CRL Overlap unit value: $($_.Exception.Message)"
	Return
}

# compare values
Try {
	$UpdateRequired = $CurrentValue -ne $DesiredValue
}
Catch {
	Write-Warning -Message "could not compare Delta CRL Overlap unit value: $($_.Exception.Message)"
	Return
}

# if update to value required...
If ($UpdateRequired) {
	# update global boolean
	$ValuesUpdated = $True

	# define should process strings
	$ShouldProcessTarget = 'CRLDeltaOverlapUnits'
	$ShouldProcessAction = 'update values'

	# if WhatIf provided...
	If ($PSCmdlet.ShouldProcess($ShouldProcessTarget, $ShouldProcessAction)) {
		# update value
		Try {
			$null = New-ItemProperty -Path $CA_Config -Name 'CRLDeltaOverlapUnits' -Value $DesiredValue -PropertyType DWord -Force
		}
		Catch {
			Write-Warning -Message "could not update Delta CRL Overlap unit value: $($_.Exception.Message)"
			Return
		}

		# report state
		Write-Host "Updated Delta CRL Overlap unit value: $DesiredValue"
	}
}
Else {
	# report state
	Write-Host "Verified Delta CRL Overlap unit value: $CurrentValue"
}

########################
# validity type
########################

# reset state
$CurrentValue = $null
$DesiredValue = $null

# if root requested...
If ($Root) {
	# define desired value for root CAs
	$DesiredValue = 'Years'
}
Else {
	# define desired value for issuing CAs
	$DesiredValue = 'Years'
}

# retrieve current value
Try {
	$CurrentValue = Get-ItemPropertyValue -Path $CA_Config -Name 'ValidityPeriod'
}
Catch {
	Write-Warning -Message "could not retrieve Validity Period type value: $($_.Exception.Message)"
	Return
}

# compare values
Try {
	$UpdateRequired = $CurrentValue -ne $DesiredValue
}
Catch {
	Write-Warning -Message "could not compare Validity Period type value: $($_.Exception.Message)"
	Return
}

# if update to value required...
If ($UpdateRequired) {
	# update global boolean
	$ValuesUpdated = $True

	# define should process strings
	$ShouldProcessTarget = 'ValidityPeriod'
	$ShouldProcessAction = 'update values'

	# if WhatIf provided...
	If ($PSCmdlet.ShouldProcess($ShouldProcessTarget, $ShouldProcessAction)) {
		# update value
		Try {
			$null = New-ItemProperty -Path $CA_Config -Name 'ValidityPeriod' -Value $DesiredValue -PropertyType String -Force
		}
		Catch {
			Write-Warning -Message "could not update Validity Period type value: $($_.Exception.Message)"
			Return
		}

		# report state
		Write-Host "Updated Validity Period type value: $DesiredValue"
	}
}
Else {
	# report state
	Write-Host "Verified Validity Period type value: $CurrentValue"
}

########################
# validity unit
########################

# reset state
$CurrentValue = $null
$DesiredValue = $null

# if root requested...
If ($Root) {
	# define desired value for root CAs
	$DesiredValue = 10
}
Else {
	# define desired value for issuing CAs
	$DesiredValue = 3
}

# retrieve current value
Try {
	$CurrentValue = Get-ItemPropertyValue -Path $CA_Config -Name 'ValidityPeriodUnits'
}
Catch {
	Write-Warning -Message "could not retrieve Validity Period unit value: $($_.Exception.Message)"
	Return
}

# compare values
Try {
	$UpdateRequired = $CurrentValue -ne $DesiredValue
}
Catch {
	Write-Warning -Message "could not compare Validity Period unit value: $($_.Exception.Message)"
	Return
}

# if update to value required...
If ($UpdateRequired) {
	# update global boolean
	$ValuesUpdated = $True

	# define should process strings
	$ShouldProcessTarget = 'ValidityPeriodUnits'
	$ShouldProcessAction = 'update values'

	# if WhatIf provided...
	If ($PSCmdlet.ShouldProcess($ShouldProcessTarget, $ShouldProcessAction)) {
		# update value
		Try {
			$null = New-ItemProperty -Path $CA_Config -Name 'ValidityPeriodUnits' -Value $DesiredValue -PropertyType DWord -Force
		}
		Catch {
			Write-Warning -Message "could not update Validity Period unit value: $($_.Exception.Message)"
			Return
		}

		# report state
		Write-Host "Updated Validity Period unit value: $DesiredValue"
	}
}
Else {
	# report state
	Write-Host "Verified Validity Period unit value: $CurrentValue"
}

# if values updated...
If ($ValuesUpdated) {
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
