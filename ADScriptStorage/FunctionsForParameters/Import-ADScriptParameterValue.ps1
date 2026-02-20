function Import-ADScriptParameterValue {
    [cmdletbinding()]
    param (
        # PDC of the domain
        [Parameter(DontShow)]
        [string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
        # identity of the script parameters container
        [string]$Identity = $script:ScriptParametersContainer,
        # name of parameter
        [Parameter(Mandatory)]
        [string]$Parameter
    )

    # if parameter was already bound...
    if ($script:PSBoundParameters.ContainsKey($Parameter)) {
        Write-Warning -Message "found existing bound parameter for '$Parameter' parameter; skipping import from AD script storage"
        return
    }

    # retrieve parameter object from AD
    try {
        $ParameterObject = Get-ADObject -Server $Server -Identity "CN=$Parameter,$Identity" -Properties 'notes'
    }
    catch {
        throw $_
    }

    # retrieve parameter value as CLI XML from attribute on AD object
    $ParameterValueAsCliXml = $ParameterObject.notes

    # restore parameter value from CLI XML
    try {
        $ParameterValue = [System.Management.Automation.PSSerializer]::Deserialize($ParameterValueAsCliXml)
    }
    catch {
        throw $_
    }

    # update bound parameters
    try {
        $script:PSBoundParameters.Add($Parameter,$ParameterValue)
    }
    catch {
        throw $_
    }
}
