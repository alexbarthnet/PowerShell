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
    [object]$Value,
    # object for parameter
    [Parameter(DontShow)]
    [string]$ScriptParameterObject = "CN=$Parameter,$ScriptParametersContainer"
)

# convert parameter value to CLI XML
try {
    $ParameterValueAsCliXml = [System.Management.Automation.PSSerializer]::Serialize($Value)
}
catch {
    return $_
}

# store parameter value as CLI XML in attribute on AD object
try {
    # update AD object with parameter value
    Set-ADObject -Server $Server -Identity $ScriptParameterObject -Replace @{ 'notes' = $ParameterValueAsCliXml }

    # report state
    Write-Host "Set '$Parameter' parameter value on existing '$ScriptParameterObject' object"
}
catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
    # create AD object with parameter value
    try {
        $null = New-ADObject -Server $Server -Name $Parameter -Path $ScriptParametersContainer -Type 'contact' -OtherAttributes @{ 'notes' = $ParameterValueAsCliXml}
    }
    catch {
        Write-Warning -Message "could not create '$ScriptParameterObject' object for '$ScriptName' script: $($_.Exception.Message)"
        throw $_
    }

    # report state
    Write-Host "Set '$Parameter' parameter value on new '$ScriptParameterObject' object"
}
catch {
    return $_
}
