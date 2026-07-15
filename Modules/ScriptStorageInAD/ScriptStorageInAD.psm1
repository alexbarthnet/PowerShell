#requires -Modules 'ActiveDirectory'

################################################
# functions to embed in either script type
################################################

function Assert-ScriptStorageContainers {
    [CmdletBinding()]
    param(
        # distinguished name of the domain
        [Parameter(DontShow)]
        [string]$DomainDistinguishedName = $([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName),
        # program data container
        [Parameter(DontShow)]
        [string]$ProgramDataContainer = "CN=Program Data,$DomainDistinguishedName",
        # parent script container
        [Parameter(DontShow)]
        [string]$ParentScriptContainer = "CN=ScriptStorage,$ProgramDataContainer",
        # name of script or command; default value is retrieved from call stack
        [Parameter(Position = 0)][ValidateScript({ $_ -ne 'ScriptBlock' })]
        [string]$ScriptName = (Get-PSCallStack)[0].Command -replace '^<|\.ps1$|>$'
    )

    # define named script storage container
    $script:ScriptStorageContainer = 'CN={0},{1}' -f $ScriptName, $ParentScriptContainer

    # define named script parameter container
    $script:ScriptParametersContainer = 'CN=Parameters,{0}' -f $script:ScriptStorageContainer

    # define named script state parameter container
    $script:ScriptStateContainer = 'CN=State,{0}' -f $script:ScriptStorageContainer

    # report object identities
    Write-Verbose -Message "Script Storage container: $script:ScriptStorageContainer"
    Write-Verbose -Message "Script Parameters container: $script:ScriptParametersContainer"
    Write-Verbose -Message "Script State container: $script:ScriptStateContainer"
}

################################################
# functions to embed for parameter scripts
################################################

function Export-ScriptParameterValueToAD {
    [cmdletbinding()]
    param (
        # PDC of the domain
        [Parameter(DontShow)]
        [string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
        # name of parameter
        [Parameter(Position = 0, Mandatory)]
        [string]$Parameter,
        # value of parameter
        [Parameter(Position = 1, Mandatory)]
        [object]$Value
    )

    # define identity of AD object
    $Identity = 'CN={0},{1}' -f $Parameter, $script:ScriptParametersContainer

    # convert parameter value to CLI XML
    try {
        $ParameterValueAsCliXml = [System.Management.Automation.PSSerializer]::Serialize($Value)
    }
    catch {
        Write-Warning -Message "could not serialize value of '$Parameter' parameter: $($_.Exception.Message)"
        throw $_
    }

    # store parameter value as CLI XML in attribute on AD object
    try {
        # update AD object with parameter value
        Set-ADObject -Server $Server -Identity $Identity -Replace @{ 'notes' = $ParameterValueAsCliXml } -ErrorAction 'Stop'

        # report state
        Write-Host "updated '$Parameter' parameter value on existing '$Identity' object"
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        # create AD object with parameter value
        try {
            $null = New-ADObject -Server $Server -Name $Parameter -Path $script:ScriptParametersContainer -Type 'contact' -OtherAttributes @{ 'notes' = $ParameterValueAsCliXml } -ErrorAction 'Stop'
        }
        catch {
            Write-Warning -Message "could not export '$Parameter' parameter value to '$Identity' object: $($_.Exception.Message)"
            throw $_
        }

        # report state
        Write-Host "exported '$Parameter' parameter value to new '$Identity' object"
    }
    catch {
        throw $_
    }
}

function Import-ScriptParameterValueFromAD {
    [cmdletbinding()]
    param (
        # PDC of the domain
        [Parameter(DontShow)]
        [string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
        # name of parameter
        [Parameter(Position = 0, Mandatory)]
        [string]$Parameter,
        # switch parameter to override the value of a bound parameter
        [Parameter(Position = 1)]
        [switch]$Force,
        # switch parameter to skip creating an object with the usnChanged value of the parameter object
        [Parameter(Position = 1)]
        [switch]$SkipUsnChangedObject

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
        $ParameterObject = Get-ADObject -Server $Server -Identity $Identity -Properties 'notes', 'usnChanged' -ErrorAction 'Stop'
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        Write-Warning -Message "could not locate object for '$Parameter' parameter object with identity: $Identity"
        throw $_
    }
    catch {
        Write-Warning -Message "could not retrieve object for '$Parameter' parameter object with identity: $Identity"
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
        New-Variable -Name $Parameter -Value $ParameterValue -Scope script -Force -ErrorAction 'Stop'
    }
    catch {
        Write-Warning -Message "could not create '$Parameter' variable with value: $($ParameterObject.uSNChanged)"
        throw $_
    }

    # report state
    Write-Verbose -Message "imported '$Parameter' variable with value: $ParameterObjectValue"

    # update bound parameters
    try {
        $script:PSBoundParameters.Add($Parameter, $ParameterValue)
    }
    catch {
        Write-Warning -Message "could not update PSBoundParameters with '$Parameter' variable and value"
        throw $_
    }

    # report state
    Write-Verbose -Message "updated PSBoundParmeters with '$Parameter' parameter and value"

    # if skip USN changed is present...
    if ($SkipUsnChangedObject.IsPresent) {
        return
    }

    # set variable for USN changed of parameter
    try {
        New-Variable -Name "UsnChangedFor$Parameter" -Value $ParameterObject.uSNChanged -Scope script -Force -ErrorAction 'Stop'
    }
    catch {
        Write-Warning -Message "could not create 'UsnChangedFor$Parameter' variable with value: $($ParameterObject.uSNChanged)"
        throw $_
    }

    # report state
    Write-Verbose -Message "created 'UsnChangedFor$Parameter' variable with value: $($ParameterObject.uSNChanged)"
}

################################################
# functions to embed for state scripts
################################################

function Export-ScriptStateToAD {
    [cmdletbinding()]
    param (
        # PDC of the domain
        [Parameter(DontShow)]
        [string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
        # object for script state
        [Parameter(Position = 0, Mandatory)]
        [object]$ScriptState,
        # value of parameter
        [Parameter(Position = 1)]
        [string]$ParameterSetName = $script:PSCmdlet.ParameterSetName
    )

    # define identity of AD object
    $Identity = 'CN={0},{1}' -f $ParameterSetName, $script:ScriptStateContainer

    # convert script state to JSON
    try {
        $ScriptStateAsJSON = ConvertTo-Json -InputObject $ScriptState -Depth 100 -Compress -ErrorAction 'Stop'
    }
    catch {
        Write-Warning -Message "could not create JSON string from script state object for '$ParameterSetName' parameter set"
        throw $_
    }

    # store script state as JSON in attribute on AD object
    try {
        # update AD object with script state
        Set-ADObject -Server $Server -Identity $Identity -Replace @{ 'notes' = $ScriptStateAsJSON } -ErrorAction 'Stop'

        # report state
        Write-Host "Recorded script state for '$Parameter' parameter set to existing object with identity: $Identity"
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        # create AD object with parameter value
        try {
            $null = New-ADObject -Server $Server -Name $ParameterSetName -Path $script:ScriptStateContainer -Type 'contact' -OtherAttributes @{ 'notes' = $ScriptStateAsJSON } -ErrorAction 'Stop'
        }
        catch {
            Write-Warning -Message "could not export script state for '$ParameterSetName' parameter set to new object with identity: $Identity"
            throw $_
        }

        # report state
        Write-Host "Exported script state for '$ParameterSetName' parameter set to new object with identity: $Identity"
    }
    catch {
        throw $_
    }
}

function Import-ScriptStateFromAD {
    [cmdletbinding()]
    param (
        # PDC of the domain
        [Parameter(DontShow)]
        [string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
        # value of parameter
        [Parameter(Position = 0)]
        [string]$ParameterSetName = $script:PSCmdlet.ParameterSetName
    )

    # define identity of AD object
    $Identity = 'CN={0},{1}' -f $ParameterSetName, $script:ScriptStateContainer

    # retrieve parameter object from AD
    try {
        $ParameterObject = Get-ADObject -Server $Server -Identity $Identity -Properties 'notes'
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        Write-Warning -Message "could not locate script state object for '$ParameterSetName' parameter set with identity: $Identity"
        throw $_
    }
    catch {
        Write-Warning -Message "could not retrieve script state object for '$ParameterSetName' parameter set with identity: $Identity"
        throw $_
    }

    # retrieve script state as JSON from attribute on AD object
    $ScriptStateAsJSON = $ParameterObject.notes

    # restore script state from CLI XML
    try {
        ConvertFrom-Json -InputObject $ScriptStateAsJSON -ErrorAction 'Stop'
    }
    catch {
        Write-Warning -Message "could not create script state object from value in 'notes' property on object with identity: $Identity"
        throw $_
    }

    # report state
    Write-Verbose -Message "Retrieved script state script state for '$ParameterSetName' parameter set from object with identity: $Identity"
}

################################################
# function to export for initializing objects
################################################

function Initialize-ScriptParameterValueInAD {
    [cmdletbinding()]
    param (
        # name of script represented by the object
        [Parameter(Mandatory)]
        [string]$ScriptName,
        # name of parameter to store
        [Parameter(Mandatory)]
        [string]$Parameter,
        # value of parameter to store
        [Parameter(ValueFromPipeline)]
        [object]$Value
    )

    # assert script storage container names
    try {
        Assert-ScriptStorageContainers -ScriptName $ScriptName
    }
    catch {
        Write-Warning -Message "could not assert script storage containers for '$ScriptName' script or command"
        throw $_
    }

    # call function
    try {
        Export-ScriptParameterValueToAD -Parameter $Parameter -Value $Value
    }
    catch {
        return $_
    }
}

function Initialize-ScriptStateInAD {
    [cmdletbinding()]
    param (
        # name of script represented by the object
        [Parameter(Mandatory)]
        [string]$ScriptName,
        # name of parameter set for script state object
        [Parameter(Position = 1, Mandatory)]
        [string]$ParameterSetName,
        # name of properties on script state object
        [Parameter(Position = 2, Mandatory)]
        [string[]]$Properties
    )

    # assert script storage container names
    try {
        Assert-ScriptStorageContainers -ScriptName $ScriptName
    }
    catch {
        Write-Warning -Message "could not assert script storage containers for '$ScriptName' script or command"
        throw $_
    }

    # create hashtable for script state object
    $ScriptStateHashtable = @{}

    # populate hashtable with properties
    foreach ($Property in $Properties) {
        try {
            $ScriptStateHashtable[$Property] = [System.String]::Empty
        }
        catch {
            Write-Warning -Message "could not add '$Property' to hashtable for script state object"
            throw $_
        }
    }

    # create script state object
    try {
        $ScriptState = [pscustomobject]$ScriptStateHashtable
    }
    catch {
        Write-Warning -Message "could not create script state object from hashtable with properties"
        throw $_
    }

    # call function
    try {
        Export-ScriptStateToAD -ScriptState $ScriptState -ParameterSetName $ParameterSetName
    }
    catch {
        throw $_
    }
}

# define functions to export
$FunctionsToExport = @(
    'Initialize-ScriptParameterValueInAD'
    'Initialize-ScriptStateInAD'
)

# export functions from module
Export-ModuleMember -Function $FunctionsToExport
