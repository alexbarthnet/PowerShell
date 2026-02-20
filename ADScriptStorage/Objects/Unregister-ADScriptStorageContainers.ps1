#requires -Module ActiveDirectory,ADSecurityFunctions

param(
    # name of script represented by the object
    [Parameter(Mandatory)]
    [string]$ScriptName,
    # name of principal with rights to the object
    [Parameter(Mandatory)]
    [string]$Principal,
    # distinguished name of the domain
    [Parameter(DontShow)]
    [string]$DomainDistinguishedName = $([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName),
    # PDC of the domain
    [Parameter(DontShow)]
    [string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
    # container for program data
    [Parameter(DontShow)]
    [string]$ProgramDataContainer = "CN=Program Data,$DomainDistinguishedName",
    # container for script storage
    [Parameter(DontShow)]
    [string]$ScriptStorageContainer = "CN=ScriptStorage,$ProgramDataContainer",
    # container for named script
    [Parameter(DontShow)]
    [string]$ScriptObjectsContainer = "CN=$ScriptName,$ScriptStorageContainer"
)

# retrieve container for named script
try {
    $null = Get-ADObject -Server $Server -Identity $ScriptObjectsContainer -ErrorAction 'Stop'
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
    Remove-ADObject -Server $Server -Identity $ScriptObjectsContainer -Recursive -Confirm:$false -ErrorAction 'Stop'
}
catch {
    Write-Warning -Message "could not remove container for provided script name: $($_.Exception.Message)"
    throw $_
}

# report state
Write-Host "removed container for provided script name: $ScriptObjectsContainer"
