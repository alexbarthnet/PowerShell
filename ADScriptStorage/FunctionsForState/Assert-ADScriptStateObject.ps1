function Assert-ADScriptStateObject {
    [cmdletbinding()]
    param (
        # PDC of the domain    
        [Parameter(DontShow)]
        [string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
        # identity of the script state object
        [string]$Identity = $script:ScriptStateObjectIdentity,
        # switch to reset the script state object to the default defined by the script
        [switch]$Reset
    )

    # retrieve AD script object
    try {
        $null = Get-ADObject -Server $Server -Identity $Identity -ErrorAction 'Stop'
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        # retrieve name and path from identity
        $Name, $Path = $Identity.Split('=', 2)[1].Split(',', 2)

        # create AD script object
        try {
            $NewADObject = New-ADObject -Server $Server -Name $Name -Path $Path -Type 'contact' -PassThru
        }
        catch {
            Write-Warning -Message "could not create '$Identity' object for '$script:MyCommandPathBaseName' script: $($_.Exception.Message)"
            throw $_
        }
    }
    catch {
        Write-Warning -Message "could not retrieve '$Identity' object for '$script:MyCommandPathBaseName' script: $($_.Exception.Message)"
        throw $_
    }

    # if reset or new AD object created...
    if ($Reset.IsPresent -or $NewADObject) {
        # update AD script object with default state
        try {
            $script:ScriptStateDefaultObject | Set-ADScriptStateObject -Server $Server -Identity $Identity
        }
        catch {
            Write-Warning -Message "could not update '$Identity' object for '$script:MyCommandPathBaseName' script: $($_.Exception.Message)"
            throw $_
        }
    }
}
