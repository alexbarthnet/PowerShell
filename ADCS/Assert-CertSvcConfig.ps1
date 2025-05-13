[CmdletBinding(SupportsShouldProcess)]
Param(
	[Parameter(Position = 0, Mandatory = $True)]
	[string]$Url,
	[Parameter(Position = 1)]
	[switch]$Root
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
				Write-Warning -Message "could not update value(s) of '$Name' property at '$Path' path: $($_.Exception.Message)"
				Return
			}

			# report state and return true
			Write-Host "Updated value(s) of '$Name' property at '$Path' path: $Value"
			Return $true
		}
	}
	Else {
		# report state
		Write-Host "Verified value(s) of '$Name' property at '$Path' path: $Value"
	}


}

# retrieve required values from registry
$Path = (Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration').PSPath

################
# AIA
################

# define parameters
$AssertItemPropertyValue = @{
	Path         = $Path
	Name         = 'CACertPublicationURLs'
	Value        = '0:C:\Windows\system32\CertSrv\CertEnroll\%3%4.crt', "2:http://$Url/pki/%3%4.crt"
	PropertyType = 'MultiString'
}

# assert values
Try {
	$ValueUpdated = Assert-ItemPropertyValue @AssertItemPropertyValue
}
Catch {
	Write-Warning -Message 'could not assert value(s) for '$($AssertItemPropertyValue['Name'])''
}

# if value updated...
If ($ValueUpdated) {
	$RestartRequired = $true
}

################
# CDP
################

# if root requested...
If ($Root) {
	# define value(s) for root CA
	$Value = '1:C:\Windows\system32\CertSrv\CertEnroll\%3%8.crl', "2:http://$Url/pki/%3%8.crl"
}
Else {
	# define value(s) for issuing CA
	$Value = '65:C:\Windows\system32\CertSrv\CertEnroll\%3%8%9.crl', "6:http://$Url/pki/%3%8%9.crl"
}

# define parameters
$AssertItemPropertyValue = @{
	Path         = $Path
	Name         = 'CRLPublicationURLs'
	Value        = $Value
	PropertyType = 'MultiString'
}

# assert values
Try {
	$ValueUpdated = Assert-ItemPropertyValue @AssertItemPropertyValue
}
Catch {
	Write-Warning -Message 'could not assert value(s) for '$($AssertItemPropertyValue['Name'])''
}

# if value updated...
If ($ValueUpdated) {
	$RestartRequired = $true
}

####################
# CRL period type
####################

# if root requested...
If ($Root) {
	# define desired value(s) for root CAs
	$Value = 'Months'
}
Else {
	# define desired value(s) for issuing CAs
	$Value = 'Weeks'
}

# define parameters
$AssertItemPropertyValue = @{
	Path         = $Path
	Name         = 'CRLPeriod'
	Value        = $Value
	PropertyType = 'String'
}

# assert values
Try {
	$ValueUpdated = Assert-ItemPropertyValue @AssertItemPropertyValue
}
Catch {
	Write-Warning -Message 'could not assert value(s) for '$($AssertItemPropertyValue['Name'])''
}

# if value updated...
If ($ValueUpdated) {
	$RestartRequired = $true
}

####################
# CRL period unit
####################

# if root requested...
If ($Root) {
	# define desired value(s) for root CAs
	$Value = 1
}
Else {
	# define desired value(s) for issuing CAs
	$Value = 2
}

# define parameters
$AssertItemPropertyValue = @{
	Path         = $Path
	Name         = 'CRLPeriodUnits'
	Value        = $Value
	PropertyType = 'DWord'
}

# assert values
Try {
	$ValueUpdated = Assert-ItemPropertyValue @AssertItemPropertyValue
}
Catch {
	Write-Warning -Message 'could not assert value(s) for '$($AssertItemPropertyValue['Name'])''
}

# if value updated...
If ($ValueUpdated) {
	$RestartRequired = $true
}

####################
# CRL overlap type
####################

# if root requested...
If ($Root) {
	# define desired value(s) for root CAs
	$Value = 'Weeks'
}
Else {
	# define desired value(s) for issuing CAs
	$Value = 'Days'
}

# define parameters
$AssertItemPropertyValue = @{
	Path         = $Path
	Name         = 'CRLOverlapPeriod'
	Value        = $Value
	PropertyType = 'String'
}

# assert values
Try {
	$ValueUpdated = Assert-ItemPropertyValue @AssertItemPropertyValue
}
Catch {
	Write-Warning -Message 'could not assert value(s) for '$($AssertItemPropertyValue['Name'])''
}

# if value updated...
If ($ValueUpdated) {
	$RestartRequired = $true
}

####################
# CRL overlap unit
####################

# if root requested...
If ($Root) {
	# define desired value(s) for root CAs
	$Value = 1
}
Else {
	# define desired value(s) for issuing CAs
	$Value = 4
}

# define parameters
$AssertItemPropertyValue = @{
	Path         = $Path
	Name         = 'CRLOverlapUnits'
	Value        = $Value
	PropertyType = 'DWord'
}

# assert values
Try {
	$ValueUpdated = Assert-ItemPropertyValue @AssertItemPropertyValue
}
Catch {
	Write-Warning -Message 'could not assert value(s) for '$($AssertItemPropertyValue['Name'])''
}

# if value updated...
If ($ValueUpdated) {
	$RestartRequired = $true
}

########################
# Delta CRL period type
########################

# if root requested...
If ($Root) {
	# define desired value(s) for root CAs
	$Value = 'Days'
}
Else {
	# define desired value(s) for issuing CAs
	$Value = 'Days'
}

# define parameters
$AssertItemPropertyValue = @{
	Path         = $Path
	Name         = 'CRLDeltaPeriod'
	Value        = $Value
	PropertyType = 'String'
}

# assert values
Try {
	$ValueUpdated = Assert-ItemPropertyValue @AssertItemPropertyValue
}
Catch {
	Write-Warning -Message 'could not assert value(s) for '$($AssertItemPropertyValue['Name'])''
}

# if value updated...
If ($ValueUpdated) {
	$RestartRequired = $true
}

####################
# Delta CRL period unit
####################

# if root requested...
If ($Root) {
	# define desired value(s) for root CAs
	$Value = 0
}
Else {
	# define desired value(s) for issuing CAs
	$Value = 1
}

# define parameters
$AssertItemPropertyValue = @{
	Path         = $Path
	Name         = 'CRLDeltaPeriodUnits'
	Value        = $Value
	PropertyType = 'DWord'
}

# assert values
Try {
	$ValueUpdated = Assert-ItemPropertyValue @AssertItemPropertyValue
}
Catch {
	Write-Warning -Message 'could not assert value(s) for '$($AssertItemPropertyValue['Name'])''
}

# if value updated...
If ($ValueUpdated) {
	$RestartRequired = $true
}

####################
# Delta CRL overlap type
####################

# if root requested...
If ($Root) {
	# define desired value(s) for root CAs
	$Value = 'Hours'
}
Else {
	# define desired value(s) for issuing CAs
	$Value = 'Hours'
}

# define parameters
$AssertItemPropertyValue = @{
	Path         = $Path
	Name         = 'CRLDeltaOverlapPeriod'
	Value        = $Value
	PropertyType = 'String'
}

# assert values
Try {
	$ValueUpdated = Assert-ItemPropertyValue @AssertItemPropertyValue
}
Catch {
	Write-Warning -Message 'could not assert value(s) for '$($AssertItemPropertyValue['Name'])''
}

# if value updated...
If ($ValueUpdated) {
	$RestartRequired = $true
}

########################
# Delta CRL overlap unit
########################

# if root requested...
If ($Root) {
	# define desired value(s) for root CAs
	$Value = 0
}
Else {
	# define desired value(s) for issuing CAs
	$Value = 6
}

# define parameters
$AssertItemPropertyValue = @{
	Path         = $Path
	Name         = 'CRLDeltaOverlapUnits'
	Value        = $Value
	PropertyType = 'DWord'
}

# assert values
Try {
	$ValueUpdated = Assert-ItemPropertyValue @AssertItemPropertyValue
}
Catch {
	Write-Warning -Message 'could not assert value(s) for '$($AssertItemPropertyValue['Name'])''
}

# if value updated...
If ($ValueUpdated) {
	$RestartRequired = $true
}

########################
# validity type
########################

# if root requested...
If ($Root) {
	# define desired value(s) for root CAs
	$Value = 'Years'
}
Else {
	# define desired value(s) for issuing CAs
	$Value = 'Years'
}

# define parameters
$AssertItemPropertyValue = @{
	Path         = $Path
	Name         = 'ValidityPeriod'
	Value        = $Value
	PropertyType = 'String'
}

# assert values
Try {
	$ValueUpdated = Assert-ItemPropertyValue @AssertItemPropertyValue
}
Catch {
	Write-Warning -Message 'could not assert value(s) for '$($AssertItemPropertyValue['Name'])''
}

# if value updated...
If ($ValueUpdated) {
	$RestartRequired = $true
}

########################
# validity unit
########################

# if root requested...
If ($Root) {
	# define desired value(s) for root CAs
	$Value = 10
}
Else {
	# define desired value(s) for issuing CAs
	$Value = 3
}

# define parameters
$AssertItemPropertyValue = @{
	Path         = $Path
	Name         = 'ValidityPeriodUnits'
	Value        = $Value
	PropertyType = 'DWord'
}

# assert values
Try {
	$ValueUpdated = Assert-ItemPropertyValue @AssertItemPropertyValue
}
Catch {
	Write-Warning -Message 'could not assert value(s) for '$($AssertItemPropertyValue['Name'])''
}

# if value updated...
If ($ValueUpdated) {
	$RestartRequired = $true
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
