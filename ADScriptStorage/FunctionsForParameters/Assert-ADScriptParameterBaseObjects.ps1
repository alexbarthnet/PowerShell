function Assert-ADScriptParameterBaseObjects {
    param(
        # distinguished name of the domain
        [Parameter(DontShow)]
        [string]$DomainDistinguishedName = $([System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName),
        # container for program data
        [Parameter(DontShow)]
        [string]$ProgramDataContainer = "CN=Program Data,$DomainDistinguishedName",
        # container for script storage
        [Parameter(DontShow)]
        [string]$ScriptStorageContainer = "CN=ScriptStorage,$ProgramDataContainer"
    )

    # if invocation name is empty...
    if ([string]::IsNullOrEmpty($script:MyInvocation.InvocationName)) {
        # create exception
        $Exception = [System.Management.Automation.ItemNotFoundException]::new('Assert-ADScriptParameterBaseObjects : Found empty InvocationName on $MyInvocation object in script scope')

        # throw error record with exception
        throw [System.Management.Automation.ErrorRecord]::new($Exception, 'InvocationNameNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, 'InvocationName')
    }
    # if invocation name is not empty...
    else {
        # retrieve path to script from command path
        $MyCommandPath = $script:MyInvocation.MyCommand.Path
    }

    # if command path is not an absolute path...
    if (![System.IO.Path]::IsPathRooted($MyCommandPath)) {
        # get unresolved absolute path
        try {
            $MyCommandPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($MyCommandPath)
        }
        catch {
            Write-Warning -Message "could not create absolute path from command path: $MyCommandPath"
            throw $_
        }

        # report absolute path
        Write-Warning -Message "converted relative path of command path to absolute path: $MyCommandPath"
    }

    # retrieve base name script object
    try {
        $MyCommandPathItem = Get-Item -Path $MyCommandPath -ErrorAction 'Stop'
    }
    catch {
        Write-Warning -Message "could not retrieve item for '$MyCommandPath' script: $($_.Exception.Message)"
        throw $_
    }

    # define script object base name
    $script:MyCommandPathBaseName = $MyCommandPathItem.BaseName

    # report object identity
    Write-Verbose -Message "AD Script command path base name: $script:MyCommandPathBaseName"

    # define script object container
    $ScriptObjectContainer = 'CN={0},{1}' -f $script:MyCommandPathBaseName, $ScriptStorageContainer

    # report object identity
    Write-Verbose -Message "AD Script Storage container: $ScriptObjectContainer"

    # define script parameters container
    $script:ScriptParametersContainer = 'CN=Parameters,CN={0}' -f $ScriptObjectContainer

    # report object identity
    Write-Verbose -Message "AD Script Parameters container: $script:ScriptParametersContainer"
}
