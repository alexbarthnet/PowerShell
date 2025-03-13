<#
.SYNOPSIS
Run PowerShell scripts from a 'CD-ROM' drive.

.DESCRIPTION
Run PowerShell scripts from a 'CD-ROM' drive. The primary intent is enable arbitrary scripts to be run during Windows setup from one or more mounted ISO images without manipulation of the WIM image.

.INPUTS
None.

.OUTPUTS
None. The function does not generate any output.

.NOTES
This script will search for scripts in a 'Scripts' folder on mounted volumes with the 'CD-ROM' drive type. The scripts are run in alphabetical order from the volumes

.LINK
https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nn-wuapi-iinstallationresult

.LINK
https://learn.microsoft.com/en-us/windows/win32/api/wuapi/nf-wuapi-iupdatesearcher-search

.LINK
https://learn.microsoft.com/en-us/windows/win32/api/wuapi/ne-wuapi-operationresultcode

.LINK
https://learn.microsoft.com/en-us/windows/win32/wua_sdk/searching--downloading--and-installing-updates

.LINK
https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-deployment-runsynchronous-runsynchronouscommand-willreboot

#>
# define transcript path
$BaseName = Get-Item -Path $PSCommandPath | Select-Object -ExpandProperty BaseName
$TranscriptPath = Join-Path -Path ([System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')) -ChildPath "$BaseName.txt"
$ScriptStateXML = Join-Path -Path ([System.Environment]::GetEnvironmentVariable('TEMP', 'Machine')) -ChildPath "$BaseName.xml"

# start transcript
$null = Start-Transcript -Path $TranscriptPath -Force -Append

# if state file found...
If ([System.IO.File]::Exists($ScriptStateXML)) {
    # retrieve state
    Try {
        $ScriptStates = Import-Clixml -Path $ScriptStateXML
    }
    Catch {
        Exit 101
    }
}
# if state file not found...
Else {
    # create empty array for script states
    $ScriptStates = @()
}

# get optical drive volumes with mounted images
$Volumes = (Get-Volume).Where({ $_.DriveType -eq 'CD-ROM' -and $_.Size -gt 0 })

# if no optional drive volumes found...
If ($Volumes.Count -eq 0) {
    Write-Host "No volumes found with drive type of 'CD-ROM'"
    Exit 0
}

# define overall exit code
[int]$ExitCode = 0

# loop through drive letters
ForEach ($DriveLetter in $Volumes.DriveLetter) {
    # define path from drive letter
    $Path = '{0}:\scripts' -f $DriveLetter

    # if path not found...
    If (![System.IO.Directory]::Exists($Path)) {
        Continue
    }

    # retrieve scripts in path
    $Scripts = Get-ChildItem -Path $Path | Sort-Object -Property FullName

    # loop through scripts in path
    :NextScript ForEach ($Script in $Scripts.FullName) {
        # retrieve script state from previous run
        $ScriptState = $ScriptStates.Where({ $_.Script -eq $Script })

        # process exit code from previous run
        If ($ScriptState.ExitCode -eq 0) {
            Continue NextScript
        }

        # define parameters
        $StartProcess = @{
            FilePath     = 'PowerShell.exe'
            ArgumentList = '-File "{0}"' -f $Script
            Wait         = $true
            Passthru     = $true
        }

        # run script
        Try {
            Start-Process $StartProcess
        }
        Catch {
            Write-Warning -Message "could not run '$Script' script: $($_.Exception.Message)"
        }

        # record exit code from current run
        $ExitCodeFromCurrentRun = $LASTEXITCODE

        # if script state exists...
        If ($ScriptState.Script) {
            # update exit code for script state
            $ScriptState.ExitCode = $ExitCodeFromCurrentRun
        }
        # if script state does not exist...
        Else {
            # add entry to script states
            $ScriptStates += [pscustomobject]@{
                Script   = $Script
                ExitCode = $ExitCodeFromCurrentRun
            }
        }

        # update script state file
        $ScriptStates | Export-Clixml -Path $ScriptStateXML

        # if exit code from current run is an error...
        If ($ExitCodeFromCurrentRun -notin 0, 1, 2) {
            # immediately exit with exit code from current run
            Exit $ExitCodeFromCurrentRun
        }

        # if exit code from current run is greater than overall exit code...
        If ($ExitCodeFromCurrentRun -gt $ExitCode) {
            # update overall exit code
            $ExitCode = $ExitCodeFromCurrentRun
        }
    }
}

# return highest exit code

# stop transcript
$null = Stop-Transcript
