#requires -Module ActiveDirectory,ADSecurityFunctions

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
    [string]$ParentScriptContainer = "CN=ScriptStorage,$ProgramDataContainer",
    # named script container
    [Parameter(DontShow)]
    [string]$NamedScriptContainer = "CN=$ScriptName,$ParentScriptContainer",
    # child script containers
    [Parameter(DontShow)]
    [string[]]$ChildContainers = @('Parameters', 'State'),
    # name of principal with rights to the object
    [Parameter(Mandatory)]
    [string]$Principal
)

# retrieve parent script container
try {
    $null = Get-ADObject -Server $Server -Identity $ParentScriptContainer -ErrorAction 'Stop'
}
catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
    # create parent script container
    try {
        $null = New-ADObject -Server $Server -Name 'ScriptStorage' -Path $ProgramDataContainer -Type 'Container' -ErrorAction 'Stop'
    }
    catch {
        Write-Warning -Message "could not create parent script container: $($_.Exception.Message)"
        throw $_
    }
    # report state
    Write-Host "created parent script container: $ParentScriptContainer"
}
catch {
    Write-Warning -Message "could not retrieve parent script container: $($_.Exception.Message)"
    throw $_
}

# retrieve container for named script
try {
    $null = Get-ADObject -Server $Server -Identity $NamedScriptContainer -ErrorAction 'Stop'
}
catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
    # create container for named script
    try {
        $null = New-ADObject -Server $Server -Name $ScriptName -Path $ParentScriptContainer -Type 'Container' -ErrorAction 'Stop'
    }
    catch {
        Write-Warning -Message "could not create named script container: $($_.Exception.Message)"
        throw $_
    }
    # report state
    Write-Host "created named script container: $NamedScriptContainer"
}
catch {
    Write-Warning -Message "could not retrieve named script container: $($_.Exception.Message)"
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
    Update-ADSecurity -Server $Server -Identity $NamedScriptContainer -AccessRule $AccessRule -ErrorAction 'Stop'
}
catch {
    Write-Warning -Message "could not update access rules on named script container: $($_.Exception.Message)"
    throw $_
}

# report state
Write-Host "granted '$Principal' principal rights to create and manage contact objects in named script container: $NamedScriptContainer"

# loop through child containers
foreach ($ChildContainer in $ChildContainers) {
    # define child script container DN
    $ChildScriptContainer = "CN=$ChildContainer,$NamedScriptContainer"

    # retrieve container for named script
    try {
        $null = Get-ADObject -Server $Server -Identity $ChildScriptContainer -ErrorAction 'Stop'
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        # create container for named script
        try {
            $null = New-ADObject -Server $Server -Name $ChildContainer -Path $NamedScriptContainer -Type 'Container' -ErrorAction 'Stop'
        }
        catch {
            Write-Warning -Message "could not create child script container: $($_.Exception.Message)"
            throw $_
        }
        # report state
        Write-Host "created child script container: $ChildScriptContainer"
    }
    catch {
        Write-Warning -Message "could not retrieve child script container: $($_.Exception.Message)"
        throw $_
    }
}
