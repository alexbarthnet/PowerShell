param(
    [string]$TaskName = 'EnableBootMenuWithShortTimeout'
)

# retrieve scheduled tasks
try {
    $ScheduledTasks = Get-ScheduledTask -TaskPath '\'
}
catch {
    throw $_
}

# if task exists...
if ($TaskName -in $ScheduledTasks.TaskName) {
    # unregister scheduled task
    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    catch {
        throw $_
    }
}

# define array for scheduled task actions
$Action = @()

# define scheduled task action for displaying the boot menu
try {
    $Action += New-ScheduledTaskAction -Execute '%windir%\System32\bcdedit.exe' -Argument '/set {bootmgr} displaybootmenu yes'
}
catch {
    throw $_
}

# define scheduled task action for setting the boot menu timeout
try {
    $Action += New-ScheduledTaskAction -Execute '%windir%\System32\bcdedit.exe' -Argument '/set {bootmgr} timeout 5'
}
catch {
    throw $_
}

# define scheduled task principal
try {
    $Principal = New-ScheduledTaskPrincipal -RunLevel 'Highest' -LogonType 'ServiceAccount' -UserId 'SYSTEM'
}
catch {
    throw $_
}

# define scheduled task trigger
try {
    $Trigger = New-ScheduledTaskTrigger -AtStartup
}
catch {
    throw $_
}

# register scheduled task
try {
    $null = Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal
}
catch {
    throw $_
}
