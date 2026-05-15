#requires -Modules 'ActiveDirectory'

########################################
# function to embed in scripts
########################################

function Assert-ScriptParametersContainer {
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
        [string]$ParentScriptContainer = "CN=ScriptParameters,$ProgramDataContainer",
        # base name of command or script
        [Parameter(Position = 0)][ValidateScript({ $_ -ne 'ScriptBlock' })]
        [string]$CommandBaseName = (Get-PSCallStack)[0].Command -replace '^<|\.ps1$|>$'
    )

    # define named script parameter container
    $script:ScriptParametersContainer = 'CN={0},{1}' -f $CommandBaseName, $ParentScriptContainer

    # report object identity
    Write-Verbose -Message "Script Parameters container: $script:ScriptParametersContainer"
}

function Export-ScriptParameterValueToAD {
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

function Import-ScriptParameterValueFromAD {
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
        $script:PSBoundParameters.Add($Parameter, $ParameterValue)
    }
    catch {
        throw $_
    }
}

########################################
# function to export for management
########################################

function Initialize-ScriptParameterValueInAD {
    [cmdletbinding()]
    param (
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
        [string]$ParentScriptContainer = "CN=ScriptParameters,$ProgramDataContainer",
        # named script parameters container
        [Parameter(DontShow)]
        [string]$ScriptParametersContainer = "CN=$ScriptName,$ParentScriptContainer",
        # name of parameter to store
        [Parameter(Mandatory)]
        [string]$Parameter,
        # value of parameter to store
        [Parameter(ValueFromPipeline)]
        [object]$Value
    )

    # validate named script container
    try {
        $null = Get-ADObject -Server $Server -Identity $ScriptParametersContainer -ErrorAction 'Stop'
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        Write-Warning -Message "could not locate named script container: $($_.Exception.Message)"
        throw $_
    }
    catch {
        Write-Warning -Message "could not retrieve named script container: $($_.Exception.Message)"
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

# define functions to export
$FunctionsToExport = @(
    'Initialize-ScriptParameterValueInAD'
)

# export functions from module
Export-ModuleMember -Function $FunctionsToExport
