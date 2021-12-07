Param(
    [Parameter(Mandatory = $True)]
    [ValidateScript({Test-Path -Path $_})]
    [string]$Request,
    [switch]$Chain
)

# define transcript file and start transcript
$log_file = $PSCommandPath.Replace('.ps1', '.txt')
Start-Transcript -Path $log_file -Force

# submit request 
$certreq_response = Invoke-Expression -Command "certreq -f -q -config - -submit $Request"
If ($certreq_response -join "," -notmatch "pending") { Exit }
Write-Output "Submitted certificate request"

# retrieve requests
$requests = $null
$requests = Invoke-Expression -Command "certutil -view -out RequestId,CommonName queue csv" | ConvertFrom-Csv
If ($null -eq $requests) { Exit } Else { $request_id = ($requests | Select-Object -Last 1)."Issued Request ID" }
Write-Output "Retrieved request ID: $request_id"

# issue certificate
$reissue = ""
$reissue = Invoke-Expression -Command "certutil -resubmit $request_id"
If ($reissue -join "," -notmatch "successfully") { Exit }
Write-Output "Issued certificate"

# retrieve certificate
$cert_cer = $Request.Replace((Get-Item -Path $Request).Extension,".cer")
$cert_p7b = $Request.Replace((Get-Item -Path $Request).Extension,".p7b")
Invoke-Expression -Command "certreq -f -q -config - -retrieve $request_id $cert_cer $cert_p7b"
Write-Output "Exported signed certificate: $cert_cer"
Write-Output "Exported complete P7B chain: $cert_p7b"

# remove request
Remove-Item -Path $Request -Force
Write-Output "Deleted certificate request: $Request"

# start transcript
Stop-Transcript
