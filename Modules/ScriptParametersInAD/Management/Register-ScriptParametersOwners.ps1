#requires -Module ActiveDirectory,ADSecurityFunctions

[CmdletBinding()]
param(
    # name of principal to add to parent script container ACL
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

# create access rule
try {
    $AccessRule = New-ADAccessRule -SecurityIdentifier $SecurityIdentifier -Rights 'GenericAll' -ErrorAction 'Stop'
}
catch {
    Write-Warning -Message "could not create access rule for principal: $($_.Exception.Message)"
    throw $_
}

# update container security
try {
    Update-ADSecurity -Server $Server -Identity $ParentScriptContainer -AccessRule $AccessRule -ErrorAction 'Stop'
}
catch {
    Write-Warning -Message "could not update access rules on container: $($_.Exception.Message)"
    throw $_
}

# report state
Write-Host "granted '$Principal' principal Full Control rights on parent script container: $ParentScriptContainer"
