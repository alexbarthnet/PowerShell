function Import-ADScriptParameterValue {
    [cmdletbinding()]
    param (
        # PDC of the domain
        [Parameter(DontShow)]
        [string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
        # name of parameter
        [Parameter(Mandatory, Position = 0)]
        [string]$Parameter,
        # value of parameter
        [Parameter(Mandatory, Position = 1)]
        [switch]$Force
    )

    # if parameter was already bound...
    if ($script:PSBoundParameters.ContainsKey($Parameter) -and -not $Force.IsPresent) {
        Write-Warning -Message "found existing bound parameter for '$Parameter' parameter; skipping import from AD script storage"
        return
    }

    # define identity of AD object
    $Identity = 'CN={0},{1}' -f $Parameter, $script:ScriptParametersContainer

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

    # set variable for parameter
    try {
        New-Variable -Name $Parameter -Value $ParameterValue -Scope script -Force
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
