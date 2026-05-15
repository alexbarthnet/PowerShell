#requires -Module ActiveDirectory

[CmdletBinding()]
param(
    # name of script represented by the object
    [Parameter(Mandatory)]
    [string]$ScriptName,
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
    [string]$ParentScriptContainer = "CN=ScriptParameters,$ProgramDataContainer",
    # named script container
    [Parameter(DontShow)]
    [string]$NamedScriptContainer = "CN=$ScriptName,$ParentScriptContainer"
)

# retrieve container for named script
try {
    $null = Get-ADObject -Server $Server -Identity $NamedScriptContainer -ErrorAction 'Stop'
}
catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
    Write-Warning -Message "could not locate named script container"
    return
}
catch {
    Write-Warning -Message "could not retrieve named script container: $($_.Exception.Message)"
    throw $_
}

# remove container
try {
    Remove-ADObject -Server $Server -Identity $NamedScriptContainer -Recursive -Confirm:$false -ErrorAction 'Stop'
}
catch {
    Write-Warning -Message "could not remove named script container: $($_.Exception.Message)"
    throw $_
}

# report state
Write-Host "removed named script container: $NamedScriptContainer"
