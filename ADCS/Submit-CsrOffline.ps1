Param(
	[Parameter(Position = 0, Mandatory = $True)][ValidateScript({ Test-Path -Path $_ })]
	[string]$Path,
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

# define transcript file from script path and start transcript
Start-Transcript -Path $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, "_$HostName.txt") -Force

# retrieve requests from path
$certreq_files = @()
$certreq_files = Get-ChildItem -Path $Path -Filter *.req

# proocess requests
ForEach ($certreq_file in $certreq_files) {
	# submit request
	$certreq_response = [string]::Empty
	$certreq_response = Invoke-Expression -Command "certreq -f -q -config - -submit $($certreq_file.FullName)"
	If (($certreq_response -join ',') -notmatch 'pending') {
		Write-Output 'ERROR: submitting certificate request'
		$certreq_response -join ','
		Return
	}
	Else {
		Write-Output 'Submitted certificate request'
	}

	# retrieve requests
	$certreq_submitted = $null
	$certreq_submitted = Invoke-Expression -Command 'certutil -view -out RequestId,CommonName queue csv' | ConvertFrom-Csv
	If ($null -eq $certreq_submitted) {
		Write-Output 'ERROR: retrieving request IDs'
		Return
	}
	Else {
		$certreq_id = ($certreq_submitted | Select-Object -Last 1).'Issued Request ID'
		Write-Output "Retrieved request ID: $certreq_id"
	}

	# issue certificate via resubmit
	$certreq_resubmit = [string]::Empty
	$certreq_resubmit = Invoke-Expression -Command "certutil -resubmit $certreq_id"
	If (($certreq_resubmit -join ',') -notmatch 'successfully') { 
		Write-Output 'ERROR: issuing certificate'
		$certreq_resubmit -join ','
		Return
	}
	Else {
		Write-Output 'Issued certificate'
	}
	
	# define certificate file
	$certreq_cer = $certreq_file.FullName.Replace($certreq_file.Extension, '.cer')
	$certreq_p7b = $certreq_file.FullName.Replace($certreq_file.Extension, '.p7b')
	
	# retrieve certificate
	$certreq_retrieve = [string]::Empty
	$certreq_retrieve = Invoke-Expression -Command "certreq -f -q -config - -retrieve $certreq_id $certreq_cer $certreq_p7b"
	If ((Test-Path -Path $certreq_cer) -and (Test-Path -Path $certreq_p7b)) {
		# report certificates
		Write-Output "Retrieved signed certificate: $certreq_cer"
		Write-Output "Retrieved complete P7B chain: $certreq_p7b"

		# remove request
		$certreq_file | Remove-Item -Force
		Write-Output "Deleted certificate request: $certreq_file"
	}
	Else {
		Write-Output 'ERROR: retrieving certificate'
		$certreq_retrieve -join ','
		Return
	}
}

# start transcript
Stop-Transcript
