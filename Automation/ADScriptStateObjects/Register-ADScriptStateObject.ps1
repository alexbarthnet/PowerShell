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
catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
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
catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
    # create container for named script
    try {
        New-ADObject -Server $Server -Name $ScriptName -Path $ScriptsContainer -Type 'Container' -ErrorAction 'Stop'
    }
    catch {
        Write-Warning -Message "could not create container for provided script name: $($_.Exception.Message)"
        throw $_
    }
    # report state
    Write-Host "created container for provided script name: $Identity"
}
catch {
    Write-Warning -Message "could not retrieve container for provided script name: $($_.Exception.Message)"
    throw $_
}

# retrieve security identifier
try {
    $SecurityIdentifier = Get-ADSecurityIdentifier -Principal $Principal -ErrorAction 'Stop'
}
catch {
    Write-Warning -Message "could not retrieve security identifier for principal: $($_.Exception.Message)"
    throw $_
}

# create access rule
try {
    $AccessRule = New-ADAccessRule -SecurityIdentifier $SecurityIdentifier -Preset 'Contact' -ErrorAction 'Stop'
}
catch {
    Write-Warning -Message "could not create access rule for principal: $($_.Exception.Message)"
    throw $_
}

# update container security
try {
    Update-ADSecurity -Identity $Identity -AccessRule $AccessRule -ErrorAction 'Stop'
}
catch {
    Write-Warning -Message "could not update access rules on container: $($_.Exception.Message)"
    throw $_
}

# report state
Write-Host "granted '$Principal' principal rights to create contact objects in container for provided script name: $Identity"
