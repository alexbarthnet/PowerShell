#requires -Module ActiveDirectory,ADSecurityFunctions

param(
    # name of script represented by the object
    [Parameter(Mandatory)]
    [string]$ScriptName,
    # name of principal with rights to the object
    [Parameter(Mandatory)]
    [string]$Principal,
    # path of the domain
    [Parameter(DontShow)]
    [string]$DomainPath = $([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName),
    # PDC of the domain
    [Parameter(DontShow)]
    [string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
    # container for program data
    [Parameter(DontShow)]
    [string]$ProgramDataContainer = "CN=Program Data,$DomainPath",
    # name for script states container
    [Parameter(DontShow)]
    [string]$ScriptStatesContainerName = 'ScriptStates',
    # container for script states
    [Parameter(DontShow)]
    [string]$ScriptStatesContainer = "CN=$ScriptStatesContainerName,$ProgramDataContainer",
    # container for named script
    [Parameter(DontShow)]
    [string]$Identity = "CN=$ScriptName,$ScriptStatesContainer"
)

# retrieve container for named script
try {
    $null = Get-ADObject -Server $Server -Identity $Identity -ErrorAction 'Stop'
}
catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
    Write-Warning -Message "could not locate container for provided script name"
    return
}
catch {
    Write-Warning -Message "could not retrieve container for provided script name: $($_.Exception.Message)"
    throw $_
}

# remove container
try {
    Remove-ADObject -Server $Server -Identity $Identity -Recursive -Confirm:$false -ErrorAction 'Stop'
}
catch {
    Write-Warning -Message "could not remove containerfor provided script name: $($_.Exception.Message)"
    throw $_
}

# report state
Write-Host "removed container for provided script name: $Identity"
