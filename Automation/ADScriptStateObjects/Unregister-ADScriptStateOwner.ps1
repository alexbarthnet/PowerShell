#requires -Module ActiveDirectory,ADSecurityFunctions

param(
    # name of principal to remove from script state container ACL
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
    # name for script state container
    [Parameter(DontShow)]
    [string]$ScriptStateContainerName = 'ScriptState',
    # container for script states
    [Parameter(DontShow)]
    [string]$ScriptStateContainer = "CN=$ScriptStateContainerName,$ProgramDataContainer"
)

# retrieve script state container
try {
    $null = Get-ADObject -Server $Server -Identity $ScriptStateContainer -ErrorAction 'Stop'
}
catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
    # create script state container
    try {
        New-ADObject -Server $Server -Name $ScriptStateContainerName -Path $ProgramDataContainer -Type 'Container'
    }
    catch {
        Write-Warning -Message "could not create script state container: $($_.Exception.Message)"
        throw $_
    }
    # report state
    Write-Host "created script state container: $ScriptStateContainer"
}
catch {
    Write-Warning -Message "could not retrieve script state container: $($_.Exception.Message)"
    throw $_
}

# retrieve security identifier
try {
    $SecurityIdentifier = Get-ADSecurityIdentifier -Server $Server -Principal $Principal -ErrorAction 'Stop'
}
catch {
    Write-Warning -Message "could not retrieve security identifier for principal: $($_.Exception.Message)"
    throw $_
}

# update container security
try {
    Revoke-ADSecurity -Server $Server -Identity $ScriptStateContainer -SecurityIdentifier $SecurityIdentifier -ErrorAction 'Stop'
}
catch {
    Write-Warning -Message "could not revoke access rules on container: $($_.Exception.Message)"
    throw $_
}

# report state
Write-Host "revoked '$Principal' principal rights to manage script state container: $ScriptStateContainer"
