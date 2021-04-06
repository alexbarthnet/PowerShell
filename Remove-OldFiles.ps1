# define logging function
function Write-LogToScreenAndFile {
    Param (
        [Parameter(Mandatory=$true,Position=0)][String]$log,
        [Parameter(Mandatory=$true,Position=1)][String]$text
    )
    $text_withdate = (Get-Date -Format yyyyMMddHHmmss) + "," + $text
    $text_withdate | Write-Output
    $text_withdate | Out-File -Force -Append -Encoding ascii -FilePath $Log
}

# check logging
$script_hostname = ([System.Net.Dns]::GetHostName()).ToLower()
$script_log_path = ("C:\Storage\Scripts\Remove-OldFiles\logs")
$script_log_name = ((Get-Date -Format yyyyMMdd) + "-" + $script_hostname + ".txt")
$script_log_file = ($script_log_path + "\" + $script_log_name)
If (Test-Path $script_log_file) {
    $log_file_exists = $true
    Try {
        Write-LogToScreenAndFile -Log $script_log_file -Text ($script_hostname + ",script-start-append")
    } Catch {
        Write-LogToScreenAndFile -Log $script_log_file -Text ($script_hostname + ",script-start-append-ERROR")
        Exit $LASTEXITCODE
    }    
} Else {
    Try {
        New-Item -Path $script_log_path -Name $script_log_name -Force | Out-Null
        Write-LogToScreenAndFile -Log $script_log_file -Text ($script_hostname + ",script-start-newfile")
    } Catch {
        Write-LogToScreenAndFile -Log $script_log_file -Text ($script_hostname + ",script-start-newfile-ERROR")
        Exit $LASTEXITCODE
    }    
}

# check if log file already existed:
If ($log_file_exists) {
    Write-LogToScreenAndFile -Log $script_log_file -Text ($script_hostname + ",script-already-run-today-EXITING")
    Exit
} Else {
    Write-LogToScreenAndFile -Log $script_log_file -Text ($script_hostname + ",script-not-run-today-STARTING")
}

# load mapping file
$map_oldfiles = Import-Csv -Path '.\Remove-OldFiles.txt'
If ($map_oldfiles) {
    Write-LogToScreenAndFile -Log $script_log_file -Text ($script_hostname + ",mapping-file-has-content")
} Else {
    Write-LogToScreenAndFile -Log $script_log_file -Text ($script_hostname + ",mapping-file-has-no-content")
}

# process the cluster mapping file
$map_oldfiles | ForEach-Object {
    # get base strings for this pass
    $days_to_keep = $_.Days
    $dir_to_purge = $_.Folder
    $day_to_purge = $null
    
    # empty arrays
    $old_files = $null
    $old_folders = $null

    # declare start
    Write-LogToScreenAndFile -Log $script_log_file -Text ($script_hostname + ","+ $dir_to_purge + ",checking for directory...")
    If (Test-Path $dir_to_purge) {
        Write-LogToScreenAndFile -Log $script_log_file -Text ($script_hostname + ","+ $dir_to_purge + ",directory found, setting date...")
        $day_to_purge = (Get-Date).AddDays(-$days_to_keep)

        # remove old files first
        Write-LogToScreenAndFile -Log $script_log_file -Text ($script_hostname + ","+ $dir_to_purge + ",removing files written before: " + $day_to_purge)
        $old_files = Get-ChildItem -Path $dir_to_purge -Recurse -Attributes !Directory | Where-Object {$_.LastWriteTime -lt $day_to_purge}
        If ($old_files) {
            $old_files | ForEach-Object {
                Write-LogToScreenAndFile -Log $script_log_file -Text ($script_hostname + ","+ $dir_to_purge + ",removing file: " + $_.FullName)
                # $_ | Remove-Item -Force
            }
        }

        # remove old folders last
        Write-LogToScreenAndFile -Log $script_log_file -Text ($script_hostname + ","+ $dir_to_purge + ",removing folders written before: " + $day_to_purge)
        $old_folders = Get-ChildItem -Path $dir_to_purge -Recurse -Attributes Directory | Where-Object {$_.LastWriteTime -lt $day_to_purge}
        If ($old_folders) {
            $old_folders | ForEach-Object {
                Write-LogToScreenAndFile -Log $script_log_file -Text ($script_hostname + ","+ $dir_to_purge + ",removing folder: " + $_.FullName)
                # $_ | Remove-Item -Force
            }
        }
    } Else {
        Write-LogToScreenAndFile -Log $script_log_file -Text ($script_hostname + ","+ $dir_to_purge + ",directory found, skipping!")
    }
}
