[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(  
    [Parameter(Mandatory = $True, ParameterSetName = 'Copy')]
    [switch]$Copy,
    [Parameter(Mandatory = $True, ParameterSetName = 'Reset')]
    [switch]$Reset,
    [Parameter(Mandatory = $True, ParameterSetName = 'Clear')]
    [switch]$Clear,
    [Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
    [switch]$Remove,
    [Parameter(Mandatory = $True, ParameterSetName = 'Add')]
    [switch]$Add,
    [Parameter(Mandatory = $True, ParameterSetName = 'Remove')]
    [Parameter(Mandatory = $True, ParameterSetName = 'Add')]
    [ValidatePattern('^[^\*]+$')]
    [string]$Source,
    [Parameter(Mandatory = $True, ParameterSetName = 'Add')]
    [ValidatePattern('^[^\*]+$')]
    [string]$Target
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
        If ($xml_test) {Remove-Item -Path $xml_path -Force}
    }
    $Clear { 
        Write-Output "Clearing '$xml_name'"
        @() | Export-Clixml -Path $xml_path
    }
    $Remove { 
        # remove matching entries from object
        $xml = $xml | Where-Object { $_.Source -ne $Source }
        $xml | Export-Clixml -Path $xml_path
        # declare changes then show current state
        Write-Output "Updating '$xml_name' to remove '$Source'"
        $xml | Select-Object Source, Target
    }
    $Add { 
        # create custom object from parameters and add to object
        $xml += [pscustomobject]@{ Source = $Source ; Target = $Target }
        $xml | Export-Clixml -Path $xml_path
        # declare changes then show current state
        Write-Output "Updating '$xml_name' to add '$Source'"
        $xml | Select-Object Source, Target
    }
    $Copy { 
        # define and start transscript
        $log_path = $PSCommandPath.Replace('.ps1', '.txt')
        Start-Transcript -Path $log_path -Force
        # declare start then process entries
        Write-Output "Copying with '$xml_name'"
        If ($xml.Count) {
            $xml | ForEach-Object { 
                # process entry
                $file_source = $_.Source
                $file_target = $_.Target
                # verify source path paths
                If (Test-Path -Path $file_source) {
                    # force target path
                    $target_check = $null
                    $target_check = If ( Test-Path -Path $file_target ) { Get-Item -Path $file_target } Else { New-Item -ItemType Directory -Path $file_target }
                    If ($target_check) {
                        # declare action
                        Write-Output "Copying files from '$file_source' to '$file_target'"
                        # copy files from source to target
                        Get-ChildItem -Path $file_source | Copy-Item -Destination $file_target -Verbose
                        # remove pinned bit from scripts if copied from OneDrive
                        ForEach ($file in (Get-ChildItem -Path $file_target)) {
                            If ($file.Attributes -eq 524320) { Set-ItemProperty -Path $file -Name 'Attributes' -Value 'Archive' }
                        }
                    }
                    Else {
                        Write-Output "Could not find or create '$file_target'"
                    }
                }
                Else {
                    Write-Output "Could not find source path: '$file_source'"
                }
            }
            # process the entries in the XML for the cluster copy
            $xml | Select-Object -Property Target -Unique | ForEach-Object {
                $file_target = $_.Target
                $local = (Get-CimInstance -Class Win32_ComputerSystem).Name.ToLower()
                $nodes = (Get-ClusterNode).Name | Where-Object { $_ -ne $local }
                # run commands on nodes
                ForEach ($node in $nodes) {
                    # verify path on other node
                    $target_check = $null
                    $target_check = Invoke-Command -ComputerName $node -ScriptBlock { If ( Test-Path -Path $using:file_target ) { Get-Item -Path $using:file_target } Else { New-Item -ItemType Directory -Path $using:file_target } }
                    If ($target_check) {
                        # declare action
                        Write-Output "Copying files in '$file_target' from '$local' to '$node'"
                        # copy files to other node
                        Get-ChildItem -Path $file_target -Exclude *.log, *.csv, *.txt | Copy-Item -ToSession (New-PSSession -ComputerName $node) -Destination $file_target -Verbose
                    }
                    Else {
                        Write-Output "Could not find or create '$file_target' on '$node'"
                    }
                }
            }
        }
        Else {
            Write-Output "XML file is empty: '$xml_name'"
        }
        # stop transscript
        Stop-Transcript
    }
    Default {
        Write-Output "Displaying '$xml_name'"
        $xml | Select-Object Source, Target
    }
}
