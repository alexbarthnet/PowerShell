#requires -module ActiveDirectory

[CmdletBinding(SupportsShouldProcess)]
param(
    # hashtable mapping relative path and properties of objects in the configuration container
    [Parameter(DontShow)]
    [hashtable]$ConfigurationContextContainerObjects = @{
        'CN=Accepted Domains,CN=Transport Settings,CN=%DOMAIN%,CN=Microsoft Exchange,CN=Services' = @{ 
            SourceClass    = 'msExchAcceptedDomain'
            TargetClass    = 'msExchAcceptedDomain'
            AttributeTable = @{ msExchAcceptedDomainName = 'msExchAcceptedDomainName' }
        }
    },
    # hashtable mapping relative path and properties of objects in the configuration container
    [Parameter(DontShow)]
    [hashtable]$DefaultNamingContextContainerObjects = @{
        # 'OU=People' = @{ objectGuid = 'sourceObjectGuid' }
    },
    [Parameter(DontShow)]
    [string]$SourceServer = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().PdcRoleOwner.Name,
    [Parameter(DontShow)]
    [string]$TargetServer = $env:COMPUTERNAME,
    [Parameter(DontShow)]
	[string]$PartitionsDN = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().Schema.Name.Replace('CN=Schema', 'CN=Partitions'),
	[Parameter(DontShow)]
	[string]$DomainNCName = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName,
	[Parameter(DontShow)]
	[string]$DomainNBName = [System.DirectoryServices.DirectorySearcher]::new("LDAP://$PartitionsDN", "(nCName=$DomainNCName)", 'CN', 'OneLevel').FindOne().Properties['CN'][0]
)

begin {
    function Sync-ADObjectChildren {
        [CmdletBinding(SupportsShouldProcess)]
        param (
            [Parameter(Mandatory)]
            [string]$SourceIdentity,
            [Parameter(Mandatory)]
            [string]$TargetIdentity,
            [Parameter(Mandatory)]
            [string]$SourceClass,
            [Parameter(Mandatory)]
            [string]$TargetClass,
            [Parameter(Mandatory)]
            [hashtable]$AttributeTable
        )

        # retrieve source properties from mapped configuration
        $SourceProperties = $AttributeTable.Keys -as [string[]]

        # retrieve target properties from mapped configuration
        $TargetProperties = $AttributeTable.Values -as [string[]]

        # retrieve objects from source server
        try {
            $SourceObjects = Get-ADObject -Server $SourceServer -SearchBase $SourceIdentity -SearchScope OneLevel -LDAPFilter "(objectClass=$SourceClass)" -Properties $SourceProperties
        }
        catch {
            Write-Warning -Message "could not retrieve objects under '$SourceIdentity' identity from '$SourceServer' source server: $($_.Exception.Message)"
            throw $_
        }

        # retrieve objects from target server
        try {
            $TargetObjects = Get-ADObject -Server $TargetServer -SearchBase $TargetIdentity -SearchScope OneLevel -LDAPFilter "(objectClass=$TargetClass)" -Properties $TargetProperties
        }
        catch {
            Write-Warning -Message "could not retrieve objects under '$TargetIdentity' identity from '$TargetServer' target server: $($_.Exception.Message)"
            throw $_
        }

        # report state
        Write-Host "`r`nsource => target"

        # loop through objects from source server
        :NextSourceObject foreach ($SourceObject in $SourceObjects) {
            # report state
            Write-Host "located source: $($SourceObject.DistinguishedName)"

            # define identity for target object
            $TargetObjectIdentity = $SourceObject.DistinguishedName.Replace($SourceIdentity, $TargetIdentity)

            # if target object found...
            if ($TargetObjectIdentity -in $TargetObjects.DistinguishedName) {
                # retrieve target object
                $TargetObject = $TargetObjects | Where-Object { $_.DistinguishedName -eq $TargetObjectIdentity }
                # report state and continue
                Write-Host "located target: $TargetObjectIdentity"
                # loop through attributes
                foreach ($SourceAttribute in $AttributeTable.Keys) {
                    # retrieve target attribute
                    $TargetAttribute = $AttributeTable[$SourceAttribute]
                    # if values match...
                    if ($SourceObject.$SourceAttribute -eq $TargetObject.$TargetAttribute) {
                        Write-Host "checked target: $TargetObjectIdentity; attribute: $TargetAttribute; value: $($SourceObject.$SourceAttribute)"
                        continue NextSourceObject
                    }
                    # if values do not match...
                    else {
                        # update target object
                        try {
                            Set-ADObject -Server $TargetServer -Identity $TargetObjectIdentity -Replace @{ $TargetAttribute = $SourceObject.$SourceAttribute } -ErrorAction 'Stop'
                        }
                        catch {
                            Write-Warning -Message "could not update '$TargetAttribute' attribute of '$TargetObjectIdentity' object with '$($SourceObject.$SourceAttribute)' value from '$($SourceObject.DistinguishedName)' object: $($_.Exception.Message)"
                            throw $_
                        }

                        # report state and continue
                        Write-Host "updated target: $TargetObjectIdentity; attribute: $TargetAttribute; value: $($SourceObject.$SourceAttribute)"
                    }
                }

                # continue to next object
                continue NextSourceObject                
            }

            # define other attributes hashtable
            $OtherAttributes = @{}

            # loop through attributes
            foreach ($SourceAttribute in $AttributeTable.Keys) {
                # retrieve target attribute
                $TargetAttribute = $AttributeTable[$SourceAttribute]

                # add target attribute and source value to hashtable 
                $OtherAttributes[$TargetAttribute] = $SourceObject.$SourceAttribute
            }

            # create target object
            try {
                New-ADObject -Server $TargetServer -Name $SourceObject.Name -Path $TargetIdentity -Type $TargetClass -ErrorAction 'Stop' -OtherAttributes $OtherAttributes
            }
            catch {
                Write-Warning -Message "could not create object under '$TargetIdentity' identity from '$TargetServer' target server: $($_.Exception.Message)"
                throw $_
            }

            # report state
            Write-Host "created target: $TargetObjectIdentity; attributes: $($OtherAttributes.Keys); values: $($OtherAttributes.Values)"
        }

        # report state
        Write-Host "`r`ntarget => source"

        # loop through objects from target server
        :NextTargetObject foreach ($TargetObject in $TargetObjects) {
            # report state
            Write-Host "located target: $($TargetObject.DistinguishedName)"

            # define identity for source object
            $SourceObjectIdentity = $TargetObject.DistinguishedName.Replace($TargetIdentity, $SourceIdentity)

            # if source object found...
            if ($SourceObjectIdentity -in $SourceObjects.DistinguishedName) {
                # report state and continue
                Write-Host "located source: $SourceObjectIdentity"
                continue NextTargetObject
            }

            # remove target object
            try {
                Remove-ADObject -Server $TargetServer -Identity $TargetObject.DistinguishedName -Confirm:$false -ErrorAction 'Stop'
            }
            catch {
                Write-Warning -Message "could not remove object under '$TargetIdentity' identity from '$TargetServer' target server: $($_.Exception.Message)"
                throw $_
            }

            # report state
            Write-Host "removed target: $TargetObjectIdentity"
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
        # define initial parameters for Sync-ADObjectChildren
        $SyncADObjectChildren = @{
            ErrorAction = [System.Management.Automation.ActionPreference]::Stop
        }

        # update parameters with source identity from relative path and source configuration container
        $SyncADObjectChildren['SourceIdentity'] = '{0},{1}' -f $RelativePath, $SourceRootDSE.configurationNamingContext -replace '%DOMAIN%', $DomainNBName

        # update parameters with target identity from relative path and target configuration container
        $SyncADObjectChildren['TargetIdentity'] = '{0},{1}' -f $RelativePath, $TargetRootDSE.configurationNamingContext -replace '%DOMAIN%', $DomainNBName

        # update parameters with source class
        $SyncADObjectChildren['SourceClass'] = $ConfigurationContextContainerObjects[$RelativePath]['SourceClass']

        # update parameters with target class
        $SyncADObjectChildren['TargetClass'] = $ConfigurationContextContainerObjects[$RelativePath]['TargetClass']

        # update parameters with attributes hashtable
        $SyncADObjectChildren['AttributeTable'] = $ConfigurationContextContainerObjects[$RelativePath]['AttributeTable']

        # if whatif requested...
        if ($WhatIfPreference -eq 'Continue') {
            # update parameters to include WhatIf
            $SyncADObjectChildren['WhatIf'] = $true
        }

        # if verbose requested...
        if ($VerbosePreference -eq 'Continue') {
            # report parameters
            foreach ($Parameter in $SyncADObjectChildren.GetEnumerator()) {
                Write-Verbose -Message "SyncADObjectChildren: $($Parameter.Key) = $($Parameter.Value)"
            }
        }

        # sync child objects from source object to target object
        try {
            Sync-ADObjectChildren @SyncADObjectChildren
        }
        catch {
            return $_
        }
    }

    # loop through the relative paths in default naming context
    :NextRelativePath foreach ($RelativePath in $DefaultNamingContextContainerObjects.Keys) {
        # define initial parameters for Sync-ADObjectChildren
        $SyncADObjectChildren = @{
            ErrorAction = [System.Management.Automation.ActionPreference]::Stop
        }

        # update parameters with source identity from relative path and source configuration container
        $SyncADObjectChildren['SourceIdentity'] = '{0},{1}' -f $RelativePath, $SourceRootDSE.defaultNamingContext -replace '%DOMAIN%', $DomainNBName

        # update parameters with target identity from relative path and target configuration container
        $SyncADObjectChildren['TargetIdentity'] = '{0},{1}' -f $RelativePath, $TargetRootDSE.defaultNamingContext -replace '%DOMAIN%', $DomainNBName

        # update parameters with source class
        $SyncADObjectChildren['SourceClass'] = $DefaultNamingContextContainerObjects[$RelativePath]['SourceClass']

        # update parameters with target class
        $SyncADObjectChildren['TargetClass'] = $DefaultNamingContextContainerObjects[$RelativePath]['TargetClass']

        # update parameters with attributes hashtable
        $SyncADObjectChildren['AttributeTable'] = $DefaultNamingContextContainerObjects[$RelativePath]['AttributeTable']

        # if whatif requested...
        if ($WhatIfPreference -eq 'Continue') {
            # update parameters to include WhatIf
            $SyncADObjectChildren['WhatIf'] = $true
        }

        # if verbose requested...
        if ($VerbosePreference -eq 'Continue') {
            # report parameters
            foreach ($Parameter in $SyncADObjectChildren.GetEnumerator()) {
                Write-Verbose -Message "SyncADObjectChildren: $($Parameter.Key) = $($Parameter.Value)"
            }
        }

        # sync attributes from source object to target object
        try {
            Sync-ADObjectChildren @SyncADObjectChildren
        }
        catch {
            return $_
        }
    }
}
