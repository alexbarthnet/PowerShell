Write-Output 'Checking if PSGallery is a trusted repository...'
If ( (Get-PSRepository -Name 'PSGallery').InstallationPolicy -ne 'Trusted' ) {
	Write-Output '...setting PSGallery as a trusted repository'
	Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
}
Else {
	Write-Output '...found PSGallery is a trusted repository'
}