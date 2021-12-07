# define certificate template text
$CmsTemplate = @"
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

Function Get-CmsComputers {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0)]
        [switch]$Cluster,
        [Parameter(Position = 1)][AllowEmptyCollection()]
        [string[]]$ClusterName,
        [Parameter(Position = 2)][AllowEmptyCollection()]
        [string[]]$ComputerName
    )

    # define empty array
    $CmsComputers = @()

    # retrieve local cluster name if requested
    If ($Cluster) {
        $ClusSvc = $null
        $ClusSvc = Get-Service | Where-Object { $_.Name -eq 'ClusSvc' -and $_.StartType -ne 'Disabled' }
        If ($null -ne $ClusSvc) {
            Try { $ClusterName += (Get-Cluster).Name }
            Catch { Write-Host 'ERROR: could not retrieve local cluster name' }
        }
        Else {
            Write-Host 'ERROR: cluster service is not running on local host'
        }
    }

    # add computers to array from ClusterName argument
    If ($ClusterName.Count) {
        ForEach ($cluster_name in $ClusterName) {
            Try {
                $cluster_nodes = $null
                $cluster_nodes = Invoke-Command -ComputerName $cluster_name -ScriptBlock { (Get-ClusterNode).Name }
                $cluster_nodes | ForEach-Object { $CmsComputers += $_ }
            }
            Catch { 
                Write-Host "ERROR: could not retrieve list of cluster nodes from '$cluster_name'"
            }
        }
    }

    # add computers to array from ComputerName argument
    If ($ComputerName) {
        $ComputerName | ForEach-Object { $CmsComputers += $_ }
    }    

    # remove duplicate computers
    $CmsComputers | Select-Object -Unique
}

Function Protect-CmsCredentialSecret {
    <#
        .SYNOPSIS
        Encrypts credentials to a host using CMS 
    #>

    # ingest parameters
    [CmdletBinding()]
    Param (
        [Parameter(Position = 0)]    
        [string]$cms_target,
        [Parameter(Position = 1)]
        [pscredential]$cms_cred,
        [Parameter(Position = 2)]
        [string]$cms_prefix,
        [Parameter(Position = 3)]
        [string]$cms_template,
        [Parameter(Position = 4)]
        [bool]$cms_reset
    )   

    # define strings
    $cms_date = Get-Date -Format yyyyMMddhhmmss
    $cms_host = [System.Environment]::MachineName.ToLower()
    $cms_root = [System.Environment]::GetFolderPath('CommonApplicationData')
    $cms_path = Join-Path -Path $cms_root -ChildPath ($cms_prefix, $cms_host -join '_')
    $cms_file = Join-Path -Path $cms_path -ChildPath (($cms_prefix, $cms_host, $cms_target, $cms_date -join '_') + '.txt')
    $cms_regx = 'CN=' + ($cms_host, $cms_target -join '-') + '-\d{14}'
    
    # verify cms folder
    If (!(Test-Path -Path $cms_path)) { New-Item -ItemType Directory -Path $cms_path | Out-Null }

    # check if a new certificate should be made regardless of current certs
    $cms_make = $false
    If ($cms_reset) {
        # declare the certificate should be made
        $cms_make = $true
        Write-Host ('CMS certificate reset requested, creating...')
    }
    Else {
        # retrieve any certificates matching regex
        $cms_cert = $null
        $cms_cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' -DocumentEncryptionCert | Where-Object { $_.Subject -match $cms_regx } | Sort-Object 'Subject' | Select-Object -Last 1
        # check certificates
        If ($cms_cert) {
            # retrieve certificate subject
            $cms_subject = $cms_cert.Subject
            # declare certificate found
            $cms_make = $true
            Write-Host ('CMS certificate found, subject: ' + $cms_subject)
        }
        Else {
            # declare the certificate should be made
            $cms_make = $true 
            Write-Host ('CMS certificate not found, creating...')
        }
    }

    # create the certificate 
    If ($cms_make) {
        # define certificate subject
        $cms_subject = 'CN=' + ($cms_host, $cms_target, $cms_date -join '-')

        # create temporary files
        $cert_inf = New-TemporaryFile
        $cert_cer = New-TemporaryFile
        
        # create certificate template
        $cert_txt = $cms_template -replace 'CN=<SUBJECT>', $cms_subject 
        $cert_txt | Out-File -FilePath $cert_inf

        # create certificate
        Try {
            certreq.exe -new -f -q $cert_inf $cert_cer | Out-Null
        }
        Catch {
            # figure out what to put here!
        }    
        
        # remove temporary files
        Remove-Item -Path $cert_inf -Force
        Remove-Item -Path $cert_cer -Force

        # check local machine store for new certificate
        $cms_cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' -DocumentEncryptionCert | Where-Object { $_.Subject -eq $cms_subject } | Select-Object -Last 1
        If ($cms_cert) {
            # declare certificate subject
            Write-Host ('CMS certificate created, subject: ' + $cms_subject)
        }
        Else {
            # declare error and exit
            Write-Host ('ERROR: could not create CMS certificate: ' + $cms_subject)
        }
    }

    # if a CMS cert exists...
    If ($cms_cert) {
        # create custom object for export
        $cms_custom_cred = $null
        $cms_custom_cred = [pscustomobject]@{
            Username = $cms_cred.Username
            Password = $cms_cred.GetNetworkCredential().Password
        }

        # encrypt credentials to local certificate
        Try {
            $cms_custom_cred | ConvertTo-Json | Protect-CmsMessage -To $cms_cert.Thumbprint -OutFile $cms_file
            $cms_made = $true
            Write-Host ('CMS file created: ' + $cms_file)
        }
        Catch {
            $cms_made = $false
            Write-Host 'ERROR: could not encrypt the CMS file'
        }

        # if CMS was made, clean up files and certificates
        If ($cms_made) {
            # remove old certificates files
            $cms_cert_old = Get-ChildItem -Path 'Cert:\LocalMachine\My' -DocumentEncryptionCert | Where-Object { $_.Subject -match $cms_regx } | Sort-Object -Property 'Subject' | Select-Object -SkipLast 1
            $cms_cert_old | ForEach-Object {
                Write-Host ('Removing old CMS certificate: ' + $_.Subject)
                $_ | Remove-Item -Force
            }

            # remove old credential files
            $cms_file_old = Get-ChildItem -Path $cms_path | Where-Object { $_.BaseName -match $cms_regx.Replace('CN=', $null) } | Sort-Object -Property 'Name' | Select-Object -SkipLast 1
            $cms_file_old | ForEach-Object {
                Write-Host ('Removing old CMS credential: ' + $_.FullName)
                $_ | Remove-Item -Force
            }
        }
    }
}

Function Remove-CmsCredentialSecret {
    <#
        .SYNOPSIS
        Encrypts credentials to a host using CMS 
    #>

    # ingest parameters
    [CmdletBinding()]
    Param (
        [Parameter(Position = 0)]    
        [string]$cms_target,
        [Parameter(Position = 1)]
        [string]$cms_prefix
    )

    # define strings
    $cms_host = [System.Environment]::MachineName
    $cms_root = [System.Environment]::GetFolderPath('CommonApplicationData')
    $cms_path = Join-Path -Path $cms_root -ChildPath ($cms_prefix, $cms_host -join '_')
    
    # remove certificates
    $cms_cert_filter = 'CN=' + ($cms_host, $cms_target -join '-') + '-\d{14}'
    $cms_cert_old = Get-ChildItem -Path 'Cert:\LocalMachine\My' -DocumentEncryptionCert | Where-Object { $_.Subject -match $cms_cert_filter }
    $cms_cert_old | ForEach-Object {
        Write-Host ('Removing CMS certificate: ' + $_.Subject)
        $_ | Remove-Item -Force
    }

    # remove credential files
    $cms_file_filter = ($cms_prefix, $cms_host, $cms_target -join '_') + '-\d{14}'
    $cms_file_old = Get-ChildItem -Path $cms_path | Where-Object { $_.BaseName -match $cms_file_filter }
    $cms_file_old | ForEach-Object {
        Write-Host ('Removing CMS credential: ' + $_.FullName)
        $_ | Remove-Item -Force
    }
}

Function Update-CmsCredentialAccess {
    <#
        .SYNOPSIS
        Encrypts credentials to a host using CMS 
    #>

    # ingest parameters
    [CmdletBinding()]
    Param (
        [Parameter(Position = 0)]
        [string]$cms_mode,
        [Parameter(Position = 1)]
        [string]$cms_target,
        [Parameter(Position = 2)]
        [string]$cms_prefix,
        [Parameter(Position = 3)]
        [string[]]$cms_principals
    )

    # define strings
    $cms_host = [System.Environment]::MachineName
    $cms_regx = 'CN=' + ($cms_host, $cms_target -join '-') + '-\d{14}'

    # retrieve SIDs for principals
    $cms_sids = @()
    switch ($cms_mode) {
        'Reset' {
            $cms_sids += [System.Security.Principal.SecurityIdentifier]('S-1-5-18') # add NT AUTHORITY\SYSTEM
            $cms_sids += [System.Security.Principal.SecurityIdentifier]('S-1-5-32-544') # add BUILTIN\Administrators
        }
        Default {
            ForEach ($cms_principal in $cms_principals) {
                Try {
                    $cms_principal = (New-Object System.Security.Principal.NTAccount([System.Environment]::UserDomainName,$cms_principal))
                    $cms_sids += $cms_principal.Translate([System.Security.Principal.SecurityIdentifier])
                }
                Catch {
                    Write-Host ('WARNING: unable to translate principal to SID: ' + $cms_principal)
                }
            }        
        }
    }

    # check local machine store for existing certificate
    $cms_cert = $null
    $cms_cert = Get-ChildItem -Path 'Cert:\LocalMachine\My' -DocumentEncryptionCert | Where-Object { $_.Subject -match $cms_regx } | Sort-Object 'NotBefore' | Select-Object -Last 1
    If ($cms_cert) {
        # declare certificate subject
        Write-Host ('CMS certificate found, subject: ' + $cms_cert.Subject)
        # retrieve private key
        $cms_key = Join-Path -Path 'C:\ProgramData\Microsoft\Crypto\RSA\MachineKeys' -ChildPath $cms_cert.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName
        # retrieve private key permissions
        $cms_acl = Get-Acl -Path $cms_key
        # clear ACL for a reset
        # process SIDs
        switch ($cms_mode) {
            'Grant' {
                ForEach ($cms_sid in $cms_sids) {
                    # create ACE and add to ACL
                    $cms_ace = New-Object System.Security.AccessControl.FileSystemAccessRule @($cms_sid, 'Read', 'Allow')
                    $cms_acl.AddAccessRule($cms_ace)
                }
                Write-Host ('Granting read access to ' + $cms_sids.Count + ' principals...')
            }
            'Revoke' {
                ForEach ($cms_sid in $cms_sids) {
                    # find ACE with matching SID and remove from ACL
                    $cms_ace = $cms_acl.Access | Where-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -match $cms_sid } 
                    $cms_ace | ForEach-Object { $cms_acl.RemoveAccessRule($_) } | Out-Null
                }
                Write-Host ('Revoking read access for ' + $cms_sids.Count + ' principals...')
            }
            'Reset' {
                # remove all ACEs from ACL
                $cms_acl.Access | ForEach-Object { $cms_acl.RemoveAccessRule($_) } | Out-Null
                Write-Host ('Removing all permissions...')
                ForEach ($cms_sid in $cms_sids) {
                    # create ACE and add to ACL
                    $cms_ace = (New-Object System.Security.AccessControl.FileSystemAccessRule @($cms_sid, 'FullControl', 'Allow'))
                    $cms_acl.AddAccessRule($cms_ace)
                }
                Write-Host ('Granting full control permissions to: NT AUTHORITY\SYSTEM')
                Write-Host ('Granting full control permissions to: BUILTIN\Administrators')
            }
        }
        # update ACL on private key
        Set-Acl -Path $cms_key -AclObject $cms_acl
        Write-Host ('CMS certificate permissions updated: ' + $cms_cert.Subject)
    }
    Else {
        Write-Host ('ERROR: CMS certificate not found: ' + $cms_cert.Subject)
    }
}

Function Protect-CmsCredentials {
    [CmdletBinding(DefaultParameterSetName = 'Cred')]
    Param(  
        [Parameter(Position = 0, Mandatory = $True)]
        [string]$Target,
        [Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Cred', ValueFromPipeline = $true)]
        [pscredential]$Cred,
        [Parameter(Position = 1, Mandatory = $True, ParameterSetName = 'Pass')]
        [string]$Username,
        [Parameter(Position = 2, Mandatory = $True, ParameterSetName = 'Pass')]
        [securestring]$Password,
        [ValidateScript({ Test-Path -Path $_ })]
        [string]$Template,
        [string]$Prefix = 'cms',
        [string[]]$ComputerName,
        [string[]]$ClusterName,
        [switch]$Cluster,
        [switch]$Reset
    )    

    # check credentials
    If ($null -ne $Cred) {
        $Creds = $Cred
    }
    Else {
        $Creds = New-Object System.Management.Automation.PSCredential -ArgumentList $Username, $Password
    }

    # import template if requested
    If ([string]::IsNullOrEmpty($Template)) {
        $CmsTemplateText = $CmsTemplate
    }
    Else {    
        $CmsTemplateText = Get-Content -Path $Template
    }
    
    # get computer names
    $CmsComputers = @()
    $CmsComputers += Get-CmsComputers -Cluster:$Cluster -ClusterName $ClusterName -ComputerName $ComputerName

    # encrypt credentials to certificate
    If ($CmsComputers.Count -gt 0) {
        ForEach ($CmsComputer in $CmsComputers) {
            Try {
                Invoke-Command -ComputerName $CmsComputer -ScriptBlock ${function:Protect-CmsCredentialSecret} -ArgumentList $Target, $Creds, $Prefix, $CmsTemplateText, $Reset
            }
            Catch {
                Write-Host "ERROR: could not protect credentials on '$CmsComputer'"
            }
        }
    }
    Else {
        Protect-CmsCredentialSecret $Target $Creds $Prefix $CmsTemplateText $Reset
    }
}

Function Remove-CmsCredentials {
    [CmdletBinding(DefaultParameterSetName = 'Pass')]
    Param(  
        [Parameter(Position = 0, Mandatory = $True)]
        [string]$Target,
        [Parameter(Position = 1)]
        [string]$Prefix = 'cms',
        [Parameter(Position = 2)]
        [string[]]$ComputerName,
        [Parameter(Position = 3)]
        [string[]]$ClusterName,
        [Parameter(Position = 4)]
        [switch]$Cluster
    )    

    # get computer names
    $CmsComputers = @()
    $CmsComputers += Get-CmsComputers -Cluster:$Cluster -ClusterName $ClusterName -ComputerName $ComputerName

    # encrypt credentials to certificate
    If ($CmsComputers.Count -gt 0) {
        ForEach ($CmsComputer in $CmsComputers) {
            Try {
                Invoke-Command -ComputerName $CmsComputer -ScriptBlock ${function:Remove-CmsCredentialSecret} -ArgumentList $Target, $Prefix
            }
            Catch {
                Write-Host "ERROR: could not remove credentials on '$CmsComputer'"
            }
        }
    }
    Else {
        Remove-CmsCredentialSecret $Target $Prefix
    }
}

Function Unprotect-CmsCredentials {
    Param(  
        [Parameter(Position = 0, Mandatory = $True)]
        [string]$Target,
        [Parameter(Position = 1)]
        [string]$Prefix = 'cms',
        [Parameter(Position = 2)]
        [switch]$PasswordOnly
    )

    # define required strings
    $cms_host = [System.Environment]::MachineName
    $cms_root = [System.Environment]::GetFolderPath('CommonApplicationData')
    $cms_path = Join-Path -Path $cms_root -ChildPath ($Prefix + '_' + $cms_host)

    # verify cms folder
    If (Test-Path -Path $cms_path) { 
        # get cms file matching the host and target
        $cms_file = Get-ChildItem -Path $cms_path | Where-Object { $_.BaseName -match $Target -and $_.BaseName -match $cms_host } | Sort-Object BaseName | Select-Object -Last 1
        If ($cms_file) {
            # convert the encrypted file into an object
            Try {
                $cms_object = Get-Content -Path $cms_file.FullName | Unprotect-CmsMessage | ConvertFrom-Json
            }
            Catch {
                Write-Output 'ERROR: could not decrypt the CMS file'
                Return
            }
            # return the credentials based upon the params
            If ($cms_object.Username -and $cms_object.Password) {
                If ($PasswordOnly) {
                    # return a PSCustomObject with username and password
                    [PSCustomObject]@{Username = $cms_object.Username; Password = $cms_object.Password }
                }
                Else {
                    # return a PSCredential
                    New-Object 'System.Management.Automation.PSCredential' -ArgumentList $cms_object.Username, ($cms_object.Password | ConvertTo-SecureString -AsPlainText -Force)
                }    
            }
            Else {
                Write-Output 'ERROR: could not find required objects in CMS file'
                Return
            }
        }
        Else {
            Write-Output "ERROR: could not find a CMS file for target: $Target"
            Return
        }
    }
    Else {
        Write-Output "ERROR: could not find the CMS folder: $cms_path"
        Return
    }
}

Function Grant-CmsCredentialAccess {
    [CmdletBinding()]
    Param(  
        [Parameter(Position = 0, Mandatory = $True)]
        [string]$Target,
        [Parameter(Position = 1, Mandatory = $True)]
        [string[]]$Principals,
        [Parameter(Position = 2)]
        [string]$Prefix = 'cms',
        [Parameter(Position = 3)]
        [string[]]$ComputerName,
        [Parameter(Position = 4)]
        [string[]]$ClusterName,
        [Parameter(Position = 5)]
        [switch]$Cluster
    )

    # get computer names
    $CmsComputers = @()
    $CmsComputers += Get-CmsComputers -Cluster:$Cluster -ClusterName $ClusterName -ComputerName $ComputerName
    
    # encrypt credentials to certificate
    If ($CmsComputers.Count -gt 0) {
        ForEach ($CmsComputer in $CmsComputers) {
            Try {
                Invoke-Command -ComputerName $CmsComputer -ScriptBlock ${function:Update-CmsCredentialAccess} -ArgumentList 'Grant', $Target, $Prefix, $Principals
            }
            Catch {
                Write-Host "ERROR: could not grant credential access on '$CmsComputer'"
            }
        }
    }
    Else {
        Update-CmsCredentialAccess 'Grant' $Target $Prefix $Principals
    }    
}

Function Reset-CmsCredentialAccess {
    [CmdletBinding()]
    Param(  
        [Parameter(Position = 0, Mandatory = $True)]
        [string]$Target,
        [Parameter(Position = 1)]
        [string]$Prefix = 'cms',
        [Parameter(Position = 2)]
        [string[]]$ComputerName,
        [Parameter(Position = 3)]
        [string[]]$ClusterName,
        [Parameter(Position = 4)]
        [switch]$Cluster
    )

    # get computer names
    $CmsComputers = @()
    $CmsComputers += Get-CmsComputers -Cluster:$Cluster -ClusterName $ClusterName -ComputerName $ComputerName
        
    # encrypt credentials to certificate
    If ($CmsComputers.Count -gt 0) {
        ForEach ($CmsComputer in $CmsComputers) {
            Try {
                Invoke-Command -ComputerName $CmsComputer -ScriptBlock ${function:Update-CmsCredentialAccess} -ArgumentList 'Reset', $Target, $Prefix
            }
            Catch {
                Write-Host "ERROR: could not Reset credential access on '$CmsComputer'"
            }
        }
    }
    Else {
        Update-CmsCredentialAccess 'Reset' $Target $Prefix
    }    
}

Function Revoke-CmsCredentialAccess {
    [CmdletBinding()]
    Param(  
        [Parameter(Position = 0, Mandatory = $True)]
        [string]$Target,
        [Parameter(Position = 1, Mandatory = $True)]
        [string[]]$Principals,
        [Parameter(Position = 2)]
        [string]$Prefix = 'cms',
        [Parameter(Position = 3)]
        [string[]]$ComputerName,
        [Parameter(Position = 4)]
        [string[]]$ClusterName,
        [Parameter(Position = 5)]
        [switch]$Cluster
    )
    # get computer names
    $CmsComputers = @()
    $CmsComputers += Get-CmsComputers -Cluster:$Cluster -ClusterName $ClusterName -ComputerName $ComputerName
        
    # encrypt credentials to certificate
    If ($CmsComputers.Count -gt 0) {
        ForEach ($CmsComputer in $CmsComputers) {
            Try {
                Invoke-Command -ComputerName $CmsComputer -ScriptBlock ${function:Update-CmsCredentialAccess} -ArgumentList 'Revoke', $Target, $Prefix, $Principals
            }
            Catch {
                Write-Host "ERROR: could not revoke credential access on '$CmsComputer'"
            }
        }
    }
    Else {
        Update-CmsCredentialAccess 'Revoke' $Target $Prefix $Principals
    }    
}

# define functions to export
$functions_to_export = @()
$functions_to_export += 'Protect-CmsCredentials'
$functions_to_export += 'Remove-CmsCredentials'
$functions_to_export += 'Unprotect-CmsCredentials'
$functions_to_export += 'Grant-CmsCredentialAccess'
$functions_to_export += 'Reset-CmsCredentialAccess'
$functions_to_export += 'Revoke-CmsCredentialAccess'

# export module members
Export-ModuleMember -Function $functions_to_export -Variable $CmsTemplate
