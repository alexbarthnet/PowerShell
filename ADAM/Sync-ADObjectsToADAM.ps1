#requires -module ActiveDirectory

[CmdletBinding(SupportsShouldProcess)]
param(
    # hashtable mapping relative path and properties of objects in the configuration container
    [Parameter(DontShow)]
    [hashtable]$ConfigurationContextContainerObjects = @{
        'CN=Partitions' = @{ uPNSuffixes = 'uPNSuffixes' }
    },
    # hashtable mapping relative path and properties of objects in the configuration container
    [Parameter(DontShow)]
    [hashtable]$DefaultNamingContextContainerObjects = @{
        # 'OU=People' = @{ objectGuid = 'sourceObjectGuid' }
    },
    [Parameter(DontShow)]
    [string]$SourceServer = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().PdcRoleOwner.Name,
    [Parameter(DontShow)]
    [string]$TargetServer = $env:COMPUTERNAME
)

begin {
    function Sync-ADObjectProperties {
        [CmdletBinding(SupportsShouldProcess)]
        param (
            [Parameter(Mandatory)]
            [string]$SourceIdentity,
            [Parameter(Mandatory)]
            [string]$TargetIdentity,
            [Parameter(Mandatory)]
            [hashtable]$AttributeTable
        )

        # retrieve source properties from mapped configuration
        $SourceProperties = $AttributeTable.Keys -as [string[]]

        # retrieve target properties from mapped configuration
        $TargetProperties = $AttributeTable.Values -as [string[]]

        # retrieve object from source server
        try {
            $SourceObject = Get-ADObject -Server $SourceServer -Identity $SourceIdentity -Properties $SourceProperties
        }
        catch {
            Write-Warning -Message "could not retrieve object with '$SourceIdentity' identity from '$SourceServer' source server: $($_.Exception.Message)"
            throw $_
        }

        # retrieve object from target server
        try {
            $TargetObject = Get-ADObject -Server $TargetServer -Identity $TargetIdentity -Properties $TargetProperties
        }
        catch {
            Write-Warning -Message "could not retrieve object with '$TargetIdentity' identity from '$TargetServer' target server: $($_.Exception.Message)"
            throw $_
        }

        # define hashtables for property handling
        $AddAttributes = @{}
        $ClearAttributes = @{}
        $ReplaceAttributes = @{}

        # loop through properties
        :NextProperty foreach ($SourceProperty in $SourceProperties) {
            # extract target property
            $TargetProperty = $AttributeTable[$SourceProperty]

            # create string from sorted property values from claimed department user
            $SourcePropertyAsStringArray = ($SourceObject.$SourceProperty -as [string[]] | Sort-Object) -join ','

            # create string from sorted property values from claimant EID
            $TargetPropertyAsStringArray = ($TargetObject.$TargetProperty -as [string[]] | Sort-Object) -join ','

            # if property values on source object and property values on target object are empty...
            if ([string]::IsNullOrEmpty($SourcePropertyAsStringArray) -and [string]::IsNullOrEmpty($TargetPropertyAsStringArray)) {
                # continue to next property
                continue NextProperty
            }

            # if property values on source object match property values on target object...
            if ($SourcePropertyAsStringArray -eq $TargetPropertyAsStringArray) {
                # continue to next property
                continue NextProperty
            }

            # if properties values on target object are empty...
            if ([string]::IsNullOrEmpty($TargetPropertyAsStringArray)) {
                # report values to be added
                Write-Verbose -Message "$TargetIdentity; $TargetProperty; will add value(s): $SourcePropertyAsStringArray"
                # add property name and parameter values to hashtable for adding properties
                $AddAttributes.Add($Property, $SourceObject.$SourceProperty -as [string[]])
                # continue to next property
                continue NextProperty
            }

            # report property values found
            Write-Warning -Message "$TargetIdentity; $TargetProperty; found existing value(s): $TargetPropertyAsStringArray"

            # if parameter values are empty...
            if ([string]::IsNullOrEmpty($SourcePropertyAsStringArray)) {
                # warn property values will be cleared
                Write-Warning -Message "$TargetIdentity; $TargetProperty; will clear value"
                # add property to list for clearing properties
                $ClearAttributes.Add($TargetProperty)
            }
            # if parameter values provided...
            else {
                # warn attribute values will be replaced
                Write-Warning -Message "$TargetIdentity; $TargetProperty; will replace value(s) with: $SourcePropertyAsStringArray"
                # add attribute name and parameter values to hashtable for replacing properties
                $ReplaceAttributes.Add($TargetProperty, $SourceObject.$SourceProperty -as [string[]])
            }
        }

        # define parameters for Set-ADObject
        $SetADObject = @{
            Server      = $TargetServer
            Identity    = $TargetIdentity
            ErrorAction = [System.Management.Automation.ActionPreference]::Stop
        }

        # switch through attribute counts
        switch ($true) {
            { $ClearAttributes.Count -ne 0 } {
                # set Clear parameter to ClearAttributes list
                $SetADObject['Clear'] = $ClearAttributes -as [string[]]
            }
            { $AddAttributes.Keys.Count -ne 0 } {
                # set Add parameter to AddAttributes hashtable
                $SetADObject['Add'] = $AddAttributes
            }
            { $ReplaceAttributes.Keys.Count -ne 0 } {
                # set Replace parameter to ReplaceAttributes hashtable
                $SetADObject['Replace'] = $ReplaceAttributes
            }
            Default {
                # report verified and continue
                Write-Host "$TargetIdentity; verified object and properties"
                continue NextRelativePath
            }
        }

        # if verbose requested...
        if ($VerbosePreference -eq 'Continue') {
            # report parameters
            foreach ($Parameter in $SetADObject.GetEnumerator()) {
                Write-Verbose -Message "$TargetIdentity; SetADObject: $($Parameter.Key) = $($Parameter.Value)"
            }
        }

        # if should process...
        if ($PSCmdlet.ShouldProcess("$TargetIdentity", 'update properties on object')) {
            # update user
            try {
                Set-ADObject @SetADObject
            }
            catch {
                return $_
            }

            # report state
            Write-Host "$TargetIdentity; updated properties on object"
        }
    }
}

process {
    # retrieve configuration container from source server
    try {
        $SourceRootDSE = Get-ADRootDSE -Server $SourceServer -ErrorAction 'Stop'
    }
    catch {
        Write-Warning -Message "could not retrieve RootDSE from '$SourceServer' source server: $($_.Exception.Message)"
        throw $_
    }

    # retrieve configuration container from target server
    try {
        $TargetRootDSE = Get-ADRootDSE -Server $TargetServer -ErrorAction 'Stop'
    }
    catch {
        Write-Warning -Message "could not retrieve RootDSE from '$TargetServer' target server: $($_.Exception.Message)"
        throw $_
    }

    # loop through the relative paths in configuration context
    :NextRelativePath foreach ($RelativePath in $ConfigurationContextContainerObjects.Keys) {
        # create source identity from relative path and source configuration container
        $SourceIdentity = '{0},{1}' -f $RelativePath, $SourceRootDSE.configurationNamingContext

        # create target identity from relative path and target configuration container
        $TargetIdentity = '{0},{1}' -f $RelativePath, $TargetRootDSE.configurationNamingContext

        # retrieve hashtable
        $AttributeTable = $ConfigurationContextContainerObjects[$RelativePath]

        # define parameters for Sync-ADObjectProperties
        $SyncADObjectProperties = @{
            SourceIdentity = $SourceIdentity
            TargetIdentity = $TargetIdentity
            AttributeTable = $AttributeTable
            ErrorAction    = [System.Management.Automation.ActionPreference]::Stop
        }

        # if whatif requested...
        if ($WhatIfPreference -eq 'Continue') {
            # update parameters to include WhatIf
            $SyncADObjectProperties['WhatIf'] = $true
        }

        # if verbose requested...
        if ($VerbosePreference -eq 'Continue') {
            # report parameters
            foreach ($Parameter in $SyncADObjectProperties.GetEnumerator()) {
                Write-Verbose -Message "SyncADObjectProperties: $($Parameter.Key) = $($Parameter.Value)"
            }
        }

        # sync attributes from source object to target object
        try {
            Sync-ADObjectProperties @SyncADObjectProperties
        }
        catch {
            return $_
        }
    }

    # loop through the relative paths in default naming context
    :NextRelativePath foreach ($RelativePath in $DefaultNamingContextContainerObjects.Keys) {
        # create source identity from relative path and source configuration container
        $SourceIdentity = '{0},{1}' -f $RelativePath, $SourceRootDSE.defaultNamingContext

        # create target identity from relative path and target configuration container
        $TargetIdentity = '{0},{1}' -f $RelativePath, $TargetRootDSE.defaultNamingContext

        # retrieve hashtable
        $AttributeTable = $DefaultNamingContextContainerObjects[$RelativePath]

        # define parameters for Sync-ADObjectProperties
        $SyncADObjectProperties = @{
            SourceIdentity = $SourceIdentity
            TargetIdentity = $TargetIdentity
            AttributeTable = $AttributeTable
            ErrorAction    = [System.Management.Automation.ActionPreference]::Stop
        }

        # if whatif requested...
        if ($WhatIfPreference -eq 'Continue') {
            # update parameters to include WhatIf
            $SyncADObjectProperties['WhatIf'] = $true
        }

        # if verbose requested...
        if ($VerbosePreference -eq 'Continue') {
            # report parameters
            foreach ($Parameter in $SyncADObjectProperties.GetEnumerator()) {
                Write-Verbose -Message "SyncADObjectProperties: $($Parameter.Key) = $($Parameter.Value)"
            }
        }

        # sync attributes from source object to target object
        try {
            Sync-ADObjectProperties @SyncADObjectProperties
        }
        catch {
            return $_
        }
    }
}
