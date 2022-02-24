Param(  
	[string]$Attribute,
	[string]$ObjectDN,
	[string]$User,
	[string]$Computer
)

# retrieve DN of user object
If ($User) {
	# determine if user value is UPN or SAM
	If ($User -match "@") {
		$ad_filter = "userPrincipalName -eq '$User'"
	}
	Else {
		$ad_filter = "sAMAccountName -eq '$User'"
	}

	# retrieve user object from AD
	$ad_user = $null
	$ad_user = Get-ADUser -Filter $ad_filter

	# retrieve DN for user object if it exists
	If ($ad_user) {
		$ObjectDN = $ad_user.distinguishedName
	}
	Else {
		Write-Host 'ERROR: unable to locate user with provided inputs'
		Exit
	}
} 

# retrieve DN of computer object
If ($Computer) {
	# retrieve computer object from AD
	$ad_computer = $null
	$ad_computer = Get-ADComputer -Filter "SamAccountName -eq '$User$'"

	# retrieve DN for computer object if it exists
	If ($ad_computer) {
		$ObjectDN = $ad_computer.distinguishedName
	}
	Else {
		Write-Host 'ERROR: unable to locate computer with provided inputs'
		Return
	}
}

# set attribute for user or computer if not attribute provided
If ($User -or $Computer -and ($null -eq $Attribute)) {
	$Attribute = 'userCertificate'
}

# check for required inputs
If ($ObjectDN -and $Attribute) {
	# declare inputs
	Write-Host 'Retrieving certificate from AD object: ' + $objectDN
	Write-Host 'Retrieving certificate from attribute: ' + $Attribute
}
Else {
	# declare error
	Write-Host 'ERROR: minimum required inputs not provided'
	Exit
}

# retrieve object
$ad_object = $null
$ad_object = Get-ADObject -Filter "distinguishedName -eq '$objectDN'" -Properties *
If ($ad_object) {
	# retrieve attribute from object
	$ad_attr = $null
	$ad_attr = $ad_object.$Attribute
	If ($ad_attr) {
		New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $ad_attr
	}
}
Else {
	Write-Host 'ERROR: unable to locate object with provided inputs'
}
