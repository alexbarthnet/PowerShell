#requires -Module ActiveDirectory,ADSecurityFunctions

param(
    # name of script represented by the object
    [Parameter(Mandatory)]
    [string]$ScriptName,
    # name of principal with rights to the object
    [Parameter(Mandatory)]
    [string]$Principal,
    # containers to create; default is all container types
    [Parameter(Mandatory)][ValidateSet('Parameters', 'State')]
    [string[]]$Container,
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
    [string]$ScriptObjectsContainer = "CN=$ScriptName,$ScriptStorageContainer",
    # container for parameters of named script
    [Parameter(DontShow)]
    [string]$ScriptParametersContainer = "CN=Parameters,$ScriptObjectsContainer",
    # container for state of named script
    [Parameter(DontShow)]
    [string]$ScriptStateContainer = "CN=State,$ScriptObjectsContainer"
)

# retrieve script storage container
try {
    $null = Get-ADObject -Server $Server -Identity $ScriptStorageContainer -ErrorAction 'Stop'
}
catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
    # create script storage container
    try {
        New-ADObject -Server $Server -Name 'ScriptStorage' -Path $ProgramDataContainer -Type 'Container' -ErrorAction 'Stop'
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

# retrieve container for named script
try {
    $null = Get-ADObject -Server $Server -Identity $ScriptObjectsContainer -ErrorAction 'Stop'
}
catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
    # create container for named script
    try {
        New-ADObject -Server $Server -Name $ScriptName -Path $ScriptStorageContainer -Type 'Container' -ErrorAction 'Stop'
    }
    catch {
        Write-Warning -Message "could not create container for provided script name: $($_.Exception.Message)"
        throw $_
    }
    # report state
    Write-Host "created container for provided script name: $ScriptObjectsContainer"
}
catch {
    Write-Warning -Message "could not retrieve container for provided script name: $($_.Exception.Message)"
    throw $_
}

# if container parameter not provided or container parameter contains Parameters...
if (!$PSBoundParameters.ContainsKey('Container') -or $script:Container -contains 'Parameters') {
    # retrieve parameters container for named script
    try {
        $null = Get-ADObject -Server $Server -Identity $ScriptParametersContainer -ErrorAction 'Stop'
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        # create parameters container for named script
        try {
            New-ADObject -Server $Server -Name 'Parameters' -Path $ScriptObjectsContainer -Type 'Container' -ErrorAction 'Stop'
        }
        catch {
            Write-Warning -Message "could not create parameters container for provided script name: $($_.Exception.Message)"
            throw $_
        }
        # report state
        Write-Host "created parameters container for provided script name: $ScriptParametersContainer"
    }
    catch {
        Write-Warning -Message "could not retrieve parameters container for provided script name: $($_.Exception.Message)"
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
        $AccessRule = New-ADAccessRule -SecurityIdentifier $SecurityIdentifier -Preset 'Contact' -ErrorAction 'Stop'
    }
    catch {
        Write-Warning -Message "could not create access rule for principal: $($_.Exception.Message)"
        throw $_
    }

    # update state container security
    try {
        Update-ADSecurity -Server $Server -Identity $ScriptStateContainer -AccessRule $AccessRule -ErrorAction 'Stop'
    }
    catch {
        Write-Warning -Message "could not update access rules on state container: $($_.Exception.Message)"
        throw $_
    }

    # report state
    Write-Host "granted '$Principal' principal rights to create contact objects in state container for provided script name: $ScriptStateContainer"
}

# if container parameter not provided or container parameter contains State...
if (!$PSBoundParameters.ContainsKey('Container') -or $script:Container -contains 'State') {
    # retrieve state container for named script
    try {
        $null = Get-ADObject -Server $Server -Identity $ScriptStateContainer -ErrorAction 'Stop'
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        # create state container for named script
        try {
            New-ADObject -Server $Server -Name 'State' -Path $ScriptObjectsContainer -Type 'Container' -ErrorAction 'Stop'
        }
        catch {
            Write-Warning -Message "could not create state container for provided script name: $($_.Exception.Message)"
            throw $_
        }
        # report state
        Write-Host "created state container for provided script name: $ScriptStateContainer"
    }
    catch {
        Write-Warning -Message "could not retrieve state container for provided script name: $($_.Exception.Message)"
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
        $AccessRule = New-ADAccessRule -SecurityIdentifier $SecurityIdentifier -Preset 'Contact' -ErrorAction 'Stop'
    }
    catch {
        Write-Warning -Message "could not create access rule for principal: $($_.Exception.Message)"
        throw $_
    }

    # update state container security
    try {
        Update-ADSecurity -Server $Server -Identity $ScriptStateContainer -AccessRule $AccessRule -ErrorAction 'Stop'
    }
    catch {
        Write-Warning -Message "could not update access rules on state container: $($_.Exception.Message)"
        throw $_
    }

    # report state
    Write-Host "granted '$Principal' principal rights to create contact objects in state container for provided script name: $ScriptStateContainer"
}