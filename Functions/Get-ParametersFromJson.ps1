function Get-ParametersFromJson {
    [CmdletBinding()]
    param(
        # Parameter help description
        [Parameter(Position = 0, Mandatory)][ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' })]
        [string]$Path
    )

    # inherit verbose preference from script scope
    $VerbosePreference = $script:VerbosePreference

    # retrieve content of JSON file
    try {
        $Json = Get-Content -Path $Path -ErrorAction 'Stop'
    }
    catch {
        throw $_
    }

    # create parameters object from JSON
    try {
        $ParametersObject = ConvertFrom-Json -InputObject $Json -ErrorAction 'Stop'
    }
    catch {
        throw $_
    }

    # retrieve command from script scope
    try {
        $Command = Get-Command -Name $script:PSCommandPath
    }
    catch {
        throw $_
    }

    # retrieve parameter sets from command
    try {
        $ParameterSets = $Command.ParameterSets
    }
    catch {
        throw $_
    }

    # retrieve parameter names from named parameter set on command
    $ParameterNames = $ParameterSets.Where({ $_.Name -eq $script:PSCmdlet.ParameterSetName }).Parameters.Name
    
    # loop through parameter names in parameters object
    :NextParameterName foreach ($ParameterName in $ParametersObject.PSObject.Properties.Name) {
        # if parameter name not defined on command...
        if ($ParameterName -notin $ParameterNames) {
            # report and continue to next parameter name
            Write-Verbose -Message "skipping '$ParameterName' parameter from JSON as the parameter is not defined on the command"
            continue NextParameterName
        }

        # if parameter name defined at runtime...
        if ($script:PSBoundParameters.ContainsKey($ParameterName)) {
            # report and continue to next parameter name
            Write-Verbose -Message "skipping '$ParameterName' parameter from JSON as the parameter was already bound at run time"
            continue NextParameterName
        }

        # retrieve parameter value from parameters object
        $ParameterValue = $ParametersObject.$ParameterName

        # add parameter to bound parameters in script scope
        try {
            $script:PSBoundParameters.Add($ParameterName, $ParameterValue)
        }
        catch {
            throw $_
        }

        # create variable from parameter in script scope
        try {
            Set-Variable -Name $ParameterName -Value $ParameterValue -Scope 'Script'
        }
        catch {
            throw $_
        }

        # report state
        Write-Verbose -Message "assigned '$ParameterName' parameter from JSON"
    }
}
