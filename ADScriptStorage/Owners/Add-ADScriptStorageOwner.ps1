#requires -Module ActiveDirectory,ADSecurityFunctions

param(
    # name of principal to add to script storage container ACL
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
    # name for script storage container
    [Parameter(DontShow)]
    [string]$ScriptStorageContainerName = 'ScriptStorage',
    # container for script storage
    [Parameter(DontShow)]
    [string]$ScriptStorageContainer = "CN=$ScriptStorageContainerName,$ProgramDataContainer"
)

# retrieve script storage container
try {
    $null = Get-ADObject -Server $Server -Identity $ScriptStorageContainer -ErrorAction 'Stop'
}
catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
    # create script storage container
    try {
        New-ADObject -Server $Server -Name $ScriptStorageContainerName -Path $ProgramDataContainer -Type 'Container'
    }
    catch {
        Write-Warning -Message "could not create script storage container: $($_.Exception.Message)"
        throw $_
    }
    # report state
    Write-Host "created script storage container: $ScriptStorageContainer"
}
catch {
    Write-Warning -Message "could not retrieve script storage container: $($_.Exception.Message)"
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
    Update-ADSecurity -Server $Server -Identity $ScriptStorageContainer -AccessRule $AccessRule -ErrorAction 'Stop'
}
catch {
    Write-Warning -Message "could not update access rules on container: $($_.Exception.Message)"
    throw $_
}

# report state
Write-Host "granted '$Principal' principal rights to manage script storage container: $ScriptStorageContainer"
