Param(  
    [Parameter(Mandatory = $True)]
    [string]$Target,
    [string]$Prefix = 'cms',
    [switch]$PasswordOnly
)

# define required strings
$cms_host = [System.Environment]::MachineName.ToLower()
$cms_root = [System.Environment]::GetFolderPath('CommonApplicationData')
$cms_path = Join-Path -Path $cms_root -ChildPath ($Prefix + '_' + $cms_host)

# verify cms folder
If (Test-Path -Path $cms_path) { 
    # get cms file matching the host and target
    $cms_file = $null
    $cms_file = Get-ChildItem -Path $cms_path | Where-Object { $_.BaseName -match $Target -and $_.BaseName -match $cms_host } | Sort-Object BaseName | Select-Object -Last 1
    If ($cms_file) {
        # convert the encrypted file into an object
        Try {
            $cms_object = Get-Content -Path $cms_file.FullName | Unprotect-CmsMessage | ConvertFrom-Csv
        }
        Catch {
            Write-Output "ERROR: could not decrypt the CMS file: $($cms_file.Name)"
            Exit
        }
        # return the credentials based upon the params
        If ($cms_object.Username -and $cms_object.Password) {
            If ($PasswordOnly) {
                # create a PSCustomObject with username and password
                [PSCustomObject]@{Username = $cms_object.Username; Password = $cms_object.Password }
            }
            Else {
                # create a PSCredential using the custom object
                New-Object 'System.Management.Automation.PSCredential' -ArgumentList $cms_object.Username, ($cms_object.Password | ConvertTo-SecureString -AsPlainText -Force)
            }    
        }
        Else {
            Write-Output 'ERROR: could not find required objects in CMS file'
            Exit
        }
    }
    Else {
        Write-Output "ERROR: could not find a CMS file for target: $Target"
        Exit
    }
}
Else {
    Write-Output "ERROR: could not find the CMS folder: $cms_path"
    Exit
}
