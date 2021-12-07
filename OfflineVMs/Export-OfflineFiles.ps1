[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(  
    [Parameter(Mandatory = $True, ParameterSetName = 'Export')]
    [switch]$Export,
    [Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
    [switch]$Clear,
    [Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
    [switch]$Remove,
    [Parameter(Mandatory = $True, ParameterSetName = 'Add')]
    [switch]$Add,
    [Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
    [Parameter(Mandatory = $True, ParameterSetName = 'Add')]
    [ValidatePattern('^[^\*]+$')]
    [string]$VMName,
    [Parameter(Mandatory = $True, ParameterSetName = 'Add')]
    [ValidatePattern('^[^\*]+$')]
    [string]$Source,
    [Parameter(Mandatory = $True, ParameterSetName = 'Add')]
    [ValidatePattern('^[^\*]+$')]
    [string]$Target,
    [Parameter(ParameterSetName = 'Add')]
    [switch]$Purge
)

# build configuration file path from script
$xml_path = $PSCommandPath.Replace('.ps1', '.xml')
$xml_test = Test-Path -Path $xml_path

# clear required objects then check file
$xml = @()
If ($xml_test) {
    # retrieve XML file name
    $xml_name = (Get-Item -Path $xml_path).Name
    # create object from XML file
    $xml += Import-Clixml -Path $xml_path
} 
Else {
    # define expected XML file name
    $xml_name = $xml_path.Split('\')[-1]
}

switch ($true) {
    $Reset { 
        Write-Output "Resetting '$xml_name'"
        If ($xml_test) { Remove-Item -Path $xml_path -Force }
    }
    $View { 
        Write-Output "Displaying '$xml_name'"
        $xml | Select-Object VMName, Source, Target, Purge
    }
    $Clear { 
        Write-Output "Clearing '$xml_name'"
        @() | Export-Clixml -Path $xml_path
    }
    $Remove { 
        # remove matching entries from object
        $xml = $xml | Where-Object { $_.VMName -ne $VMName }
        $xml | Export-Clixml -Path $xml_path
        # declare changes then show current state
        Write-Output "Updating '$xml_name' to remove '$VMName'"
        $xml | Select-Object VMName, Source, Target, Purge
    }
    $Add { 
        # create custom object from parameters and add to object
        $xml += [pscustomobject]@{ VMName = $VMName ; Purge = $Purge ; Source = $Source ; Target = $Target }
        $xml | Export-Clixml -Path $xml_path
        # declare changes then show current state
        Write-Output "Updating '$xml_name' to add '$VMName'"
        $xml | Select-Object VMName, Source, Target, Purge
    }
    Default { 
        # define and start transcript
        $log_path = $PSCommandPath.Replace('.ps1', '.txt')
        Start-Transcript -Path $log_path -Force
        # declare start then process entries
        Write-Output "Exporting with '$xml_name'"
        If ($xml.Count) {
            $xml | ForEach-Object { 
                # process entry
                $vm_name = $_.VMName
                $file_purge = $_.Purge
                $file_source = $_.Source
                $file_target = $_.Target
                # check for VM on local system
                $vm_check = $null
                $vm_check = Get-VM | Where-Object { $_.Name -eq $vm_name }
                If ($vm_check) {
                    # retrieve VM credentials
                    Set-Location -Path $PSScriptRoot
                    $global:Credential = $null
                    .\Unprotect-CmsCredentials.ps1 -Target $vm_name
                    If ($global:Credential) {
                        # connect to VM
                        $vm_direct = $null
                        $vm_direct = New-PSSession -VMName $vm_name -Credential $global:Credential
                        If ($vm_direct) {
                            # verify source
                            If (Invoke-Command -Session $vm_direct -ScriptBlock { Test-Path -Path $using:file_source }) {
                                # retrieve files from source
                                $file_list = $null
                                $file_list = Invoke-Command -Session $vm_direct -ScriptBlock { Get-ChildItem -Path $using:file_source }
                                If ($file_list) {
                                    # verify target
                                    $target_check = $null
                                    $target_check = { If ( Test-Path -Path $file_target ) { Get-Item -Path $file_target } Else { New-Item -ItemType Directory -Path $file_target } }
                                    If ($target_check) { 
                                        # determine if target should be cleaned before writing files
                                        If ($file_purge) {
                                            Write-Output "Clearing '$file_target' before copy"
                                            Get-ChildItem -Path $file_target | Remove-Item -Force
                                        }
                                        # copy files from VM to target
                                        $file_list.FullName | Copy-Item -FromSession $vm_direct -Destination $file_target -Force -Verbose
                                    }
                                    Else {
                                        Write-Output "Could not locate destination folder: '$file_target'"
                                    }
                                }
                                Else {
                                    Write-Output "Could not retrieve files in '$file_source' on VM"
                                }
                            }
                            Else {
                                Write-Output "Could not find '$file_source' on VM"
                            }
                            # disconnect from VM
                            $vm_direct | Remove-PSSession
                        }
                        Else {
                            Write-Output "Could not create PowerShell Direct session for VM: '$vm_name'"        
                        }
                    }
                    Else {
                        Write-Output "Could not locate credentials for VM: '$vm_name'"    
                    }
                }
                Else {
                    Write-Output "Could not locate VM: '$vm_name'"
                }
            }
        }
        Else {
            Write-Output "XML file is empty: '$xml_name'"
        }
        # stop transcript
        Stop-Transcript
    }
}
