[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(  
    [Parameter(Mandatory = $True, ParameterSetName = 'Object')]
    [switch]$Object,
    [Parameter(Mandatory = $True, ParameterSetName = 'User')]
    [switch]$User,
    [Parameter(Mandatory = $True, ParameterSetName = 'Group')]
    [switch]$Group,
    [Parameter(Mandatory = $True, ParameterSetName = 'Object')]
    [Parameter(Mandatory = $True, ParameterSetName = 'User')]
    [Parameter(Mandatory = $True, ParameterSetName = 'Group')]
    [string]$Identity
)

# initialize the object
$ad_object = $null

# process the parameters
switch ($true) {
    $Object { $ad_object = (Get-ADObject -Identity $Identity).DistinguishedName }
    $User { $ad_object = (Get-ADUser -Identity $Identity).DistinguishedName }
    $Group { $ad_object = (Get-ADGroup -Identity $Identity).DistinguishedName }
    Default { $ad_object = $null }
}

# check AD object
If ($null -eq $ad_object) {
    Write-Host "[$(Get-Date -Format 's')] ERROR: object not found, verify provided information!"
    Exit
}
Else {
    # check scheduler
    $ad_sync_status = $null
    $ad_sync_status = (Get-ADSyncScheduler).SyncCycleInProgress
    If ($ad_sync_status) {
        Write-Host "[$(Get-Date -Format 's')] ERROR: sync in progress, wait until current sync finishes!"
        Exit
    }

    # stop the scheduler
    Write-Host "[$(Get-Date -Format 's')] Disabling scheduler..."
    Set-ADSyncScheduler -SyncCycleEnabled $false
    $ad_sync_enabled = $null
    $ad_sync_enabled = (Get-ADSyncScheduler).SyncCycleEnabled
    If ($ad_sync_enabled) {
        Write-Host "[$(Get-Date -Format 's')] ERROR: could not stop scheduler, cannot continue!"
        Exit
    }

    # sync the single object
    Write-Host "[$(Get-Date -Format 's')] Performing Single Object Sync on: $ad_object"
    $global:ad_sync_results = Invoke-ADSyncSingleObjectSync -DistinguishedName $ad_object -NoHtmlReport | ConvertFrom-Json

    # declare the results
    Write-Host "[$(Get-Date -Format 's')] Results saved in the global `$ad_sync_results object"

    # stop the scheduler
    Write-Host "[$(Get-Date -Format 's')] Enabling scheduler..."
    Set-ADSyncScheduler -SyncCycleEnabled $true
    $ad_sync_enabled = $null
    $ad_sync_enabled = (Get-ADSyncScheduler).SyncCycleEnabled
    If ($ad_sync_enabled) {
        Write-Host "[$(Get-Date -Format 's')] ...started scheduler"
        Exit
    }
    Else {
        Write-Host "[$(Get-Date -Format 's')] ERROR: could not start scheduler!"
    }
}
