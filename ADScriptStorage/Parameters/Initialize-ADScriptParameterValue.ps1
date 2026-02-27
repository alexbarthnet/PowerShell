#requires -Module ActiveDirectory,ADSecurityFunctions

[cmdletbinding()]
param (
    # name of script represented by the object
    [Parameter(Mandatory)]
    [string]$ScriptName,
    # distinguished name of the domain
    [Parameter(DontShow)]
    [string]$DomainDistinguishedName = $([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName),
    # container for program data
    [Parameter(DontShow)]
    [string]$ProgramDataContainer = "CN=Program Data,$DomainDistinguishedName",
    # container for script storage
    [Parameter(DontShow)]
    [string]$ScriptStorageContainer = "CN=ScriptStorage,$ProgramDataContainer",
    # container for named script
    [Parameter(DontShow)]
    [string]$ScriptObjectContainer = "CN=$ScriptName,$ScriptStorageContainer",
    # container for named script
    [Parameter(DontShow)]
    [string]$ScriptParametersContainer = "CN=Parameters,$ScriptObjectContainer",
    # name of parameter
    [Parameter(Mandatory)]
    [string]$Parameter,
    # value of parameter
    [Parameter(ValueFromPipeline)]
    [object]$Value
)

begin {
    function Export-ADScriptParameterValue {
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
            [object]$Value
        )

        # define identity of AD object
        $Identity = 'CN={0},{1}' -f $Parameter, $script:ScriptParametersContainer

        # convert parameter value to CLI XML
        try {
            $ParameterValueAsCliXml = [System.Management.Automation.PSSerializer]::Serialize($Value)
        }
        catch {
            throw $_
        }

        # store parameter value as CLI XML in attribute on AD object
        try {
            # update AD object with parameter value
            Set-ADObject -Server $Server -Identity $Identity -Replace @{ 'notes' = $ParameterValueAsCliXml }

            # report state
            Write-Host "Set '$Parameter' parameter value on existing '$Identity' object"
        }
        catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
            # create AD object with parameter value
            try {
                $null = New-ADObject -Server $Server -Name $Parameter -Path $script:ScriptParametersContainer -Type 'contact' -OtherAttributes @{ 'notes' = $ParameterValueAsCliXml }
            }
            catch {
                Write-Warning -Message "could not create '$Identity' object for '$ScriptName' script: $($_.Exception.Message)"
                throw $_
            }

            # report state
            Write-Host "Set '$Parameter' parameter value on new '$Identity' object"
        }
        catch {
            throw $_
        }
    }
}

process {
    # call function
    try {
        Export-ADScriptParameterValue -Parameter $Parameter -Value $Value
    }
    catch {
        return $_
    }
}