function Get-ADScriptStateObject {
    [cmdletbinding()]
    param (
        # PDC of the domain
        [Parameter(DontShow)]
        [string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
        # identity of the script state object
        [string]$Identity = $script:ScriptStateObjectIdentity
    )

    # retrieve script state object from AD
    try {
        $ScriptStateObject = Get-ADObject -Server $Server -Identity $Identity -Properties 'notes'
    }
    catch {
        return $_
    }

    # retrieve script state as JSON from attribute on AD object
    $ScriptStateAsJson = $ScriptStateObject.notes

    # retrieve script state object from JSON
    try {
        ConvertFrom-Json -InputObject $ScriptStateAsJson -ErrorAction 'Stop'
    }
    catch {
        return $_
    }
}
