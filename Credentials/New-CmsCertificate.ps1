Param(  
    [string[]]$ComputerName,
    [string]$Prefix = 'cms',
    [switch]$Cluster,
    [string]$ClusterName
)

function Test-CmsCertificate {
    <#
        .SYNOPSIS
        Encrypts credentials to a host using CMS 
    #>

    # ingest parameters
    param
    (
        [string]$cms_prefix,
        [string]$cms_template
    )

    # define strings
    $cms_date = Get-Date -Format yyyyMMddhhmmss
    $cms_host = [System.Net.Dns]::GetHostName()
    $cms_subj = ($cms_host + '-' + $cms_date)
    $cms_root = [System.Environment]::GetFolderPath('CommonApplicationData')
    $cms_path = Join-Path -Path $cms_root -ChildPath ($cms_prefix + '_' + $cms_host)
    
    # verify cms folder
    If (!(Test-Path -Path $cms_path)) { New-Item -ItemType Directory -Path $cms_path | Out-Null }

    # check local machine store for existing certificate
    $cms_cert = $null
    $cms_cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' -DocumentEncryptionCert | Where-Object { $_.NotAfter -gt (Get-Date) } | Sort-Object 'NotBefore' | Select-Object -Last 1
    If ($cms_cert) {
        # declare certificate subject
        Write-Host ('CMS certificate found, subject: ' + $cms_cert.Subject)
    }
    Else {
        # declare certificate subject
        Write-Host ('CMS certificate not found, creating...')
        # create temporary files 
        $cert_inf = New-TemporaryFile
        $cert_cer = New-TemporaryFile
        
        # create certificate template
        $cert_txt = $cms_template -replace '<SUBJECT>', $cms_subj 
        $cert_txt | Out-File -FilePath $cert_inf

        # create certificate
        certreq.exe -new -f -q $cert_inf $cert_cer | Out-Null

        # check local machine store for new certificate
        $cms_cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' -DocumentEncryptionCert | Where-Object { $_.NotAfter -gt (Get-Date) } | Sort-Object 'NotBefore' | Select-Object -Last 1
        If ($cms_cert) {
            # declare certificate subject
            Write-Host ('CMS certificate created, subject: ' + $cms_cert.Subject)
        }
        Else {
            # declare error and exit
            Write-Host ('ERROR: could not create CMS certificate, exiting!')
            Exit
        }
    }
}

# define certificate template text
$Template = @"
[Version]
Signature=`"`$Windows NT`$`"

[Strings]
szOID_ENHANCED_KEY_USAGE = "2.5.29.37"
szOID_DOCUMENT_ENCRYPTION = "1.3.6.1.4.1.311.80.1"

[NewRequest]
Subject = `"CN=<SUBJECT>`"
MachineKeySet = True
KeyLength = 4096
KeySpec = AT_KEYEXCHANGE
HashAlgorithm = SHA512
Exportable = False
RequestType = Cert
KeyUsage = "CERT_KEY_ENCIPHERMENT_KEY_USAGE | CERT_DATA_ENCIPHERMENT_KEY_USAGE"
ValidityPeriod = "Years"
ValidityPeriodUnits = "100"

[Extensions]
%szOID_ENHANCED_KEY_USAGE% = "{text}%szOID_DOCUMENT_ENCRYPTION%"
"@

# retrieve local cluster name if requested
If ($Cluster) {
    Try { $ClusterName = (Get-Cluster).Name }
    Catch { Write-Output 'ERROR: could not retrieve local cluster name, exiting!' }
}

# define empty array
$Computers = @()

# add computers to array from ComputerName argument
If ($ComputerName) {
    $ComputerName | ForEach-Object { $Computers += $_ }
}

# add computers to array from ClusterName argument
If ($ClusterName) {
    Try { Invoke-Command -ComputerName $ClusterName -ScriptBlock {(Get-ClusterNode).Name} | ForEach-Object { $Computers += $_ } }
    Catch { Write-Output 'ERROR: could not retrieve list of cluster nodes, exiting!'; Exit }
}

# test CMS certificates for computer(s)
If ($Computers.Count -gt 0) {
    ForEach ($Computer in $Computers) {
        Invoke-Command -ComputerName $Computer -ScriptBlock ${function:Test-CmsCertificate} -ArgumentList $Target, $Cred, $Prefix, $Template
    }
}
Else {
    Test-CmsCertificate $Target $Cred $Prefix $Template
}
