[CmdletBinding()]
Param (
	[bool]$Bool,
	[switch]$Switch,
	[string]$String
)

# test switch
If ($null -eq $Switch) {
	Write-Host '$Switch is $null'
}
ElseIf ($Switch -eq $true) {
	Write-Host '$Switch is $true'
}
ElseIf ($Switch -eq $false) {
	Write-Host '$Switch is $false'
}
Else {
	Write-Host '$Switch is something unexpected...'
}

# test boolean
If ($null -eq $Bool) {
	Write-Host '$Bool is $null'
}
ElseIf ($Bool -eq $true) {
	Write-Host '$Bool is $true'
}
ElseIf ($Bool -eq $false) {
	Write-Host '$Bool is $false'
}
Else {
	Write-Host '$Bool is something unexpected...'
}

# test string
If ([string]::IsNullOrEmpty($String)) {
	Write-Host '$String is $null'
}
Else {
	Write-Host '$String is:' "'$String'"
}
