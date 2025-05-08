Param(
	[Parameter(Position = 0,Mandatory = $True)]
	[string]$Url,
	[Parameter(Position = 1)]
	[switch]$Root,
	[Parameter(DontShow)]
	[string]$HostName = ([System.Environment]::MachineName.ToLowerInvariant())
)

# define transcript file from script path and start transcript
Start-Transcript -Path $PSCommandPath.Replace((Get-Item -Path $PSCommandPath).Extension, "_$HostName.txt") -Force

# stop service
Write-Output "`nStopping CertSvc before CA configuration..."
Stop-Service "CertSvc"

# retrieve required values from registry
$CA_Config = (Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration").PSPath

# AIA

# define AIA values
$CA_AIA = "0:C:\Windows\system32\CertSrv\CertEnroll\%3%4.crt", "2:http://$Url/pki/%3%4.crt"

# set the AIA entries
New-ItemProperty -Path $CA_Config -Name "CACertPublicationURLs" -Value $CA_AIA -PropertyType MultiString -Force | Out-Null
Write-Output "...set AIA extensions to default local path and public URL: $Url"
ForEach ($AIA in $CA_AIA) { Write-Output "`t$AIA" }

# CDP

# define CDP  values
$CA_RootCA_CDP = "1:C:\Windows\system32\CertSrv\CertEnroll\%3%8.crl", "2:http://$Url/pki/%3%8.crl"
$CA_Issuer_CDP = "65:C:\Windows\system32\CertSrv\CertEnroll\%3%8%9.crl", "6:http://$Url/pki/%3%8%9.crl"

# set the CDP entries based upon the switch
If ($Root) { $CA_CDP = $CA_RootCA_CDP } Else { $CA_CDP = $CA_Issuer_CDP }

# set the CDP entries
New-ItemProperty -Path $CA_Config -Name "CRLPublicationURLs" -Value $CA_CDP -PropertyType MultiString -Force | Out-Null
Write-Output "...set CDP extensions to default local path and public URL:"
ForEach ($CDP in $CA_CDP) { Write-Output "`t$CDP" }

# CRL

# define CRL duration values
$CA_RootCA_CRL_Period_Type = "Months"
$CA_RootCA_CRL_Period_Unit = "1"
$CA_Issuer_CRL_Period_Type = "Weeks"
$CA_Issuer_CRL_Period_Unit = "2"

# select CRL duration based upon CA type
If ($Root) { $CA_CRL_Period_Type = $CA_RootCA_CRL_Period_Type } Else { $CA_CRL_Period_Type = $CA_Issuer_CRL_Period_Type }
If ($Root) { $CA_CRL_Period_Unit = $CA_RootCA_CRL_Period_Unit } Else { $CA_CRL_Period_Unit = $CA_Issuer_CRL_Period_Unit }

# set CRL duration
New-ItemProperty -Path $CA_Config -Name "CRLPeriod" -Value $CA_CRL_Period_Type -PropertyType String -Force | Out-Null
New-ItemProperty -Path $CA_Config -Name "CRLPeriodUnits" -Value $CA_CRL_Period_Unit -PropertyType DWord -Force | Out-Null
Write-Output "...set CRL duration to $CA_CRL_Period_Unit $CA_CRL_Period_Type"

# CRL overlap

# define CRL overlap values
$CA_RootCA_CRL_Overlap_Type = "Weeks"
$CA_RootCA_CRL_Overlap_Unit = "1"
$CA_Issuer_CRL_Overlap_Type = "Days"
$CA_Issuer_CRL_Overlap_Unit = "4"

# select CRL overlap based upon CA type
If ($Root) { $CA_CRL_Overlap_Type = $CA_RootCA_CRL_Overlap_Type } Else { $CA_CRL_Overlap_Type = $CA_Issuer_CRL_Overlap_Type }
If ($Root) { $CA_CRL_Overlap_Unit = $CA_RootCA_CRL_Overlap_Unit } Else { $CA_CRL_Overlap_Unit = $CA_Issuer_CRL_Overlap_Unit }

# set CRL overlap
New-ItemProperty -Path $CA_Config -Name "CRLOverlapPeriod" -Value $CA_CRL_Overlap_Type -PropertyType String -Force | Out-Null
New-ItemProperty -Path $CA_Config -Name "CRLOverlapUnits" -Value $CA_CRL_Overlap_Unit -PropertyType DWord -Force | Out-Null
Write-Output "...set CRL overlap time to $CA_CRL_Overlap_Unit $CA_CRL_Overlap_Type"

# delta CRL

# define delta CRL duration values
$CA_RootCA_CRL_Delta_Period_Type = "Days"
$CA_RootCA_CRL_Delta_Period_Unit = "0"
$CA_Issuer_CRL_Delta_Period_Type = "Days"
$CA_Issuer_CRL_Delta_Period_Unit = "1"

# select delta CRL duration based upon CA type
If ($Root) { $CA_CRL_Delta_Period_Type = $CA_RootCA_CRL_Delta_Period_Type } Else { $CA_CRL_Delta_Period_Type = $CA_Issuer_CRL_Delta_Period_Type }
If ($Root) { $CA_CRL_Delta_Period_Unit = $CA_RootCA_CRL_Delta_Period_Unit } Else { $CA_CRL_Delta_Period_Unit = $CA_Issuer_CRL_Delta_Period_Unit }

# set delta CRL duration
New-ItemProperty -Path $CA_Config -Name "CRLDeltaPeriod" -Value $CA_CRL_Delta_Period_Type -PropertyType String -Force | Out-Null
New-ItemProperty -Path $CA_Config -Name "CRLDeltaPeriodUnits" -Value $CA_CRL_Delta_Period_Unit -PropertyType DWord -Force | Out-Null
Write-Output "...set Delta CRL duration to $CA_CRL_Delta_Period_Unit $CA_CRL_Delta_Period_Type"

# delta CRL overlap

# define delta CRL overlap values
$CA_RootCA_CRL_Delta_Overlap_Type = "Minutes"
$CA_RootCA_CRL_Delta_Overlap_Unit = "0"
$CA_Issuer_CRL_Delta_Overlap_Type = "Hours"
$CA_Issuer_CRL_Delta_Overlap_Unit = "6"

# select delta CRL overlap based upon CA type
If ($Root) { $CA_CRL_Delta_Overlap_Type = $CA_RootCA_CRL_Delta_Overlap_Type } Else { $CA_CRL_Delta_Overlap_Type = $CA_Issuer_CRL_Delta_Overlap_Type }
If ($Root) { $CA_CRL_Delta_Overlap_Unit = $CA_RootCA_CRL_Delta_Overlap_Unit } Else { $CA_CRL_Delta_Overlap_Unit = $CA_Issuer_CRL_Delta_Overlap_Unit }

# set delta CRL overlap
New-ItemProperty -Path $CA_Config -Name "CRLDeltaOverlapPeriod" -Value $CA_CRL_Delta_Overlap_Type -PropertyType String -Force | Out-Null
New-ItemProperty -Path $CA_Config -Name "CRLDeltaOverlapUnits" -Value $CA_CRL_Delta_Overlap_Unit -PropertyType DWord -Force | Out-Null
Write-Output "...set Delta CRL overlap time to $CA_CRL_Delta_Overlap_Unit $CA_CRL_Delta_Overlap_Type"

# validity

# define the certificate maximum validity
$CA_RootCA_Validity_Type = "Years"
$CA_RootCA_Validity_Unit = "10"
$CA_Issuer_Validity_Type = "Years"
$CA_Issuer_Validity_Unit = "3"

# select certificate maximum validity based upon CA type
If ($Root) { $CA_Validity_Type = $CA_RootCA_Validity_Type } Else { $CA_Validity_Type = $CA_Issuer_Validity_Type }
If ($Root) { $CA_Validity_Unit = $CA_RootCA_Validity_Unit } Else { $CA_Validity_Unit = $CA_Issuer_Validity_Unit }

# set certificate maximum validity 
New-ItemProperty -Path $CA_Config -Name "ValidityPeriod" -Value $CA_Validity_Type -PropertyType String -Force | Out-Null
New-ItemProperty -Path $CA_Config -Name "ValidityPeriodUnits" -Value $CA_Validity_Unit -PropertyType DWord -Force | Out-Null
Write-Output "...set maximum certificate age to $CA_Validity_Unit $CA_Validity_Type"

# start the service
Write-Output "`nStarting CertSvc after CA configuration..."
Start-Service "CertSvc"

# wait while the CA fully starts
Write-Output "...waiting for CertSvc to complete startup`n"
Start-Sleep -Seconds 15

# issue a new CRL
Invoke-Expression "certutil -crl"

# start transcript
Stop-Transcript
