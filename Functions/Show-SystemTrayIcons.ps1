function Show-SystemTrayIcons {
    # retrieve GUIDs for apps 
    $GUIDs = Get-ChildItem -Path 'HKCU:\Control Panel\NotifyIconSettings' -Name

    # loop through GUIDs
    foreach ($GUID in $GUIDs) {
        # define path
        $Path = "HKCU:\Control Panel\NotifyIconSettings\{0}" -f $GUID

        # set IsPromoted
        Set-ItemProperty -Path $Path -Name IsPromoted -Value 1
    }
}
