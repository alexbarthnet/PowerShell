#requires -Module ActiveDirectory,ADSecurityFunctions

[CmdletBinding()]
param(
    # name of principal to remove from parent script container ACL
    [Parameter(Mandatory)]
    [string]$Principal,
    # distinguished name of the domain
    [Parameter(DontShow)]
    [string]$DomainDistinguishedName = $([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName),
    # PDC of the domain
    [Parameter(DontShow)]
    [string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
    # program data container
    [Parameter(DontShow)]
    [string]$ProgramDataContainer = "CN=Program Data,$DomainDistinguishedName",
    # parent script container
    [Parameter(DontShow)]
    [string]$ParentScriptContainer = "CN=ScriptParameters,$ProgramDataContainer"
)

# retrieve parent script container
try {
    $null = Get-ADObject -Server $Server -Identity $ParentScriptContainer -ErrorAction 'Stop'
}
catch {
    Write-Warning -Message "could not retrieve parent script container: $($_.Exception.Message)"
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
    Revoke-ADSecurity -Server $Server -Identity $ParentScriptContainer -SecurityIdentifier $SecurityIdentifier -ErrorAction 'Stop'
}
catch {
    Write-Warning -Message "could not revoke access rules on container: $($_.Exception.Message)"
    throw $_
}

# report state
Write-Host "revoked '$Principal' principal rights on parent script container: $ParentScriptContainer"
