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
    # container for all scripts
    [Parameter(DontShow)]
    [string]$ScriptsContainer = "CN=Scripts,$ProgramDataContainer",
    # container for named script
    [Parameter(DontShow)]
    [string]$Identity = "CN=$ScriptName,$ScriptsContainer"
)

# retrieve container for all scripts
try {
    $null = Get-ADObject -Server $Server -Identity $ScriptsContainer -ErrorAction 'Stop'
}
catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
    # create container for all scripts
    try {
        New-ADObject -Server $Server -Name 'Scripts' -Path $ProgramDataContainer -Type 'Container'
    }
    catch {
        Write-Warning -Message "could not create container for all scripts: $($_.Exception.Message)"
        throw $_
    }
    # report state
    Write-Host "created container for all scripts: $ScriptsContainer"
}
catch {
    Write-Warning -Message "could not retrieve container for all scripts: $($_.Exception.Message)"
    throw $_
}

# retrieve container for named script
try {
    $null = Get-ADObject -Server $Server -Identity $Identity -Properties 'nTSecurityDescriptor'
}
catch [System.DirectoryServices.ActiveDirectory.ActiveDirectoryObjectNotFoundException] {
    Write-Warning -Message "could not locate container for provided script name"
    return
}
catch {
    Write-Warning -Message "could not retrieve container for provided script name: $($_.Exception.Message)"
    throw $_
}

# remove container
try {
    Remove-ADObject -Server $Server -Identity $Identity -Recursive -Confirm:$false
}
catch {
    Write-Warning -Message "could not remove containerfor provided script name: $($_.Exception.Message)"
    throw $_
}

# report state
Write-Host "removed container for provided script name: $Identity"
