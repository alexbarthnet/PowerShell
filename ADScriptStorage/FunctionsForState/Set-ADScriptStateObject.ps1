function Set-ADScriptStateObject {
    [cmdletbinding()]
    param (
        # PDC of the domain
        [Parameter(DontShow)]
        [string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
        # identity of the script state object
        [string]$Identity = $script:ScriptStateObjectIdentity,
        # script state object
        [Parameter(ValueFromPipeline)]
        [object]$ScriptState
    )

    # convert script state to JSON
    try {
        $ScriptStateAsJson = ConvertTo-Json -InputObject $ScriptState -Depth 100 -ErrorAction 'Stop'
    }
    catch {
        return $_
    }

    # store script state as JSON in attribute on AD object
    try {
        Set-ADObject -Server $Server -Identity $Identity -Replace @{ 'notes' = $ScriptStateAsJson }
    }
    catch {
        return $_
    }
}
