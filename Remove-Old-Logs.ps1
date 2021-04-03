# set the file locations
$hostname_vm = [System.Net.Dns]::GetHostName().ToLower()
$map_folders = '.\remove-old-logs.csv'

# process the cluster mapping file
Import-Csv -Path $map_folders | ForEach-Object {
    # get base strings for this pass
    $dir_to_purge = $_.Folder
    $days_to_keep = $_.Days
    $remove_files = $null
    $day_to_purge = $null

    # declare start
    Write-Host "======================== $dir_to_purge ========================"
    Write-Host ($hostname_vm + ","+ $dir_to_purge + " - checking for directory...")
    If (Test-Path $Path) {
        Write-Host ($hostname_vm + ","+ $dir_to_purge + " - directory found, validating days to keep...")
        $day_to_purge = (Get-Date).AddDays(-$days_to_keep)
        Write-Host ($hostname_vm + ","+ $dir_to_purge + " - directory found, removing files written before: " + $day_to_purge)
        $remove_files = Get-ChildItem -Path $dir_to_purage -Recurse | Where-Object {$_.LastWriteTime -lt $day_to_purge}
        IF ($remove_files) {
            $remove_files | ForEach-Object {
                Write-Host ($hostname_vm + ","+ $dir_to_purge + " - removing: " + $_.FullName)
                $_ | Remove-Item -Force
            }
        }
    }
}
