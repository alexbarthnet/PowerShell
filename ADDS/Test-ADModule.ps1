[CmdletBinding()]
param (
    [uint32]$Limit = [uint32]5,
    [uint32]$Seconds = [int32]1,
    [uint32]$WaitTime = [int32]0,
    [uint32]$Multiplier = [int32]0
)

# import Active Directory module and intentionally ignore errors
Import-Module -Name ActiveDirectory -ErrorAction Ignore

# test connection to Windows Update
$ModuleLoaded = (Get-Module).Name -contains 'ActiveDirectory'

# define integers for while loop and reporting
# wait limit not reached and module not loaded...
while ($Multiplier -lt $Limit -and -not $ModuleLoaded) {
    # increment multiplier
    $Multiplier++

    # record total time
    $WaitTime += ($Seconds * $Multiplier)

    # wait for collection update to complete
    Write-Host "...waiting an additional '$($Seconds * $Multiplier)' seconds"
    Start-Sleep -Seconds ($Seconds * $Multiplier)

    # import Active Directory module and intentionally ignore errors
    Import-Module -Name ActiveDirectory -ErrorAction Ignore

    # test connection to Windows Update
    $ModuleLoaded = (Get-Module).Name -contains 'ActiveDirectory'
}

# if module loaded...
if ($ModuleLoaded) {
    # ...and wait time incurred...
    if ($WaitTime -gt 0) {
        # ...declare module loaded and wait time
        "{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), "...loaded ActiveDirectory module after '$WaitTime' seconds"
    }
    # ...and wait time not incurred...
    else {
        # ...declare module loaded
        "{0}`t{1}" -f [System.Datetime]::UtcNow.ToString('o'), '...loaded ActiveDirectory module'

    }
}
# if module not loaded...
else {
    # ...declare wait time before throwing exception
    Write-Warning -Message "could not load ActiveDirectory module after '$WaitTime' seconds"

    # throw exception
    throw
}
