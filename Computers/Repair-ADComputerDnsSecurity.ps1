#Requires -Modules ActiveDirectory,DnsServer

[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Default')]
param (
    # active directory rights for DNS record
    [Parameter(DontShow)]
    [System.DirectoryServices.ActiveDirectoryRights]$ActiveDirectoryRights = 'CreateChild, DeleteChild, ListChildren, ReadProperty, DeleteTree, ExtendedRight, Delete, GenericWrite, WriteDacl, WriteOwner',
    # name of the domain
    [Parameter(DontShow)]
    [string]$DomainName = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().Name,
    # path of the domain
    [Parameter(DontShow)]
    [string]$DomainPath = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().GetDirectoryEntry().DistinguishedName,
    # PDC of the domain
    [Parameter(DontShow)]
    [string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
    # scripts container of the domain
    [Parameter(DontShow)]
    [string]$ScriptStatesContainer = "CN=ScriptStates,CN=Program Data,$DomainPath",
    # object for default script state
    [Parameter(DontShow)]
    [object]$ScriptStateDefaultObject = [pscustomobject]@{
        whenCreated = [System.Datetime]::FromFileTimeUtc('0')
    },
    # properties for computer objects
    [Parameter(DontShow)]
    [string[]]$Properties = @(
        'DnsHostName'
        'SamAccountName'
        'SID'
    ),
    # switch to process all computers in an OU
    [Parameter(ParameterSetName = 'All')]
    [switch]$All,
    # switch to reset script state object
    [Parameter()]
    [switch]$Reset
)

begin {
    # get time started
    $TimeStarted = (Get-Date -Format 'FileDateTime')

    function Repair-ADComputerDnsRecordAcl {
        [CmdletBinding(SupportsShouldProcess)]
        param (
            [boolean]$Updated = $false,
            [psobject]$Computer
        )

        # define identity values
        $Identity = $Computer.dnsHostName
        $SamAccountName = $Computer.SamAccountName

        # if DNS host name is empty...
        if ([string]::IsNullOrEmpty($Computer.dnsHostName)) {
            Write-Host "$SamAccountName;dnsHostName;Computer attribute empty"
            return $false
        }

        # define escaped domain name
        $EscapedDomainName = '.{0}$' -f [System.Text.RegularExpressions.Regex]::Escape($DomainName)

        # extract hostname from dnsHostName
        $ExtractedHostName = $Computer.dnsHostName -replace $EscapedDomainName

        # if reconstructed hostname does not match hostname...
        if ("$ExtractedHostName.$DomainName" -ne $Computer.dnsHostName) {
            Write-Host "$SamAccountName;dnsHostName;Computer attribute has unexpected DNS host name: $($Computer.dnsHostName)"
            return $false
        }

        # define identity
        $Identity = 'DC={0},{1}' -f $ExtractedHostName, $DnsServerZone.DistinguishedName

        # retrieve DNS object
        try {
            $ADObject = Get-ADObject -Server $Server -Identity $Identity -Properties 'dnsRecord', 'nTSecurityDescriptor'
        }
        catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
            Write-Host "$SamAccountName;dnsRecord;DNS record not found"
            return
        }
        catch {
            Write-Host "$SamAccountName;dnsRecord;error retrieving DNS record: $($_.Exception.Message)"
            return $_
        }
		
        # TODO: check DNS record length
        # if DNS record length is not valid...
        # If ($ADObject.dnsRecord[0].Length) {
        #     Write-Host "$SamAccountName;dnsRecord;error retrieving DNS record: $($_.Exception.Message)"
        #     return
        # }

        # if timestamp in DNS record is empty...
        if ([System.BitConverter]::ToString($ADObject.dnsRecord[0][20..23]) -eq '00-00-00-00') {
            Write-Host "$SamAccountName;dnsRecord;skipping static DNS record"
            return $false
        }

        # retrieve NT security descriptor
        $nTSecurityDescriptor = $ADObject.nTSecurityDescriptor

        # retrieve explicit access rules with NT account identities
        $AccessRules = $nTSecurityDescriptor.GetAccessRules($true, $false, [System.Security.Principal.NTAccount])

        # loop through access rules
        foreach ($AccessRule in $AccessRules) {
            # if identity reference in access rule did not resolve...
            if ($AccessRule.IdentityReference.Value.StartsWith('S-1-5-21')) {
                # remove access rule from NT security descriptor
                $nTSecurityDescriptor.RemoveAccessRuleSpecific($AccessRule)

                # report updated
                Write-Host "$SamAccountName;dnsRecord;removed ACE with invalid identity from ACL: $($AccessRule.IdentityReference.Value)"
                $Updated = $true
            }
        }

        # retrieve explicit access rules with SID identities
        $AccessRules = $nTSecurityDescriptor.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])

        # loop through access rules
        foreach ($AccessRule in $AccessRules) {
            # if identity reference in access rule for computer has incorrect...
            if ($AccessRule.IdentityReference -eq $Computer.SID -and $AccessRule.ActiveDirectoryRights -ne $ActiveDirectoryRights) {
                # remove access rule from NT security descriptor
                $nTSecurityDescriptor.RemoveAccessRuleSpecific($AccessRule)

                # report updated
                Write-Host "$SamAccountName;dnsRecord;removed ACE for computer with incorrect rights from ACL: $($AccessRule.ActiveDirectoryRights)"
                $Updated = $true
            }
        }

        # retrieve explicit access rules with SID identities
        $AccessRules = $nTSecurityDescriptor.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])

        # if computer SID not in identity references...
        if ($Computer.SID -notin $AccessRules.IdentityReference) {
            # create access rule
            $NewAccessRule = [System.DirectoryServices.ActiveDirectoryAccessRule]::new($Computer.SID, $ActiveDirectoryRights, 'Allow')

            # add access rule
            $nTSecurityDescriptor.AddAccessRule($NewAccessRule)

            # report updated
            Write-Host "$SamAccountName;dnsRecord;added ACE for computer to ACL"
            $Updated = $true
        }

        # if record properties updated...
        if ($Updated) {
            # define ShouldProcess values
            $ShouldProcessMessage = "$SamAccountName;dnsRecord;would update computer DNS record"
            $ShouldProcessAction = 'Set-ADObject'
            $ShouldProcessTarget = $ADObject.DistinguishedName

            # if should process clears...
            if ($PSCmdlet.ShouldProcess($ShouldProcessMessage, $ShouldProcessAction, $ShouldProcessTarget)) {
                # update DNS record
                try {
                    $ADObject | Set-ADObject -Server $Server -Replace @{ nTSecurityDescriptor = $nTSecurityDescriptor } -ErrorAction 'Stop'
                }
                catch {
                    Write-Host "$SamAccountName;dnsRecord;error updated DNS record: $($_.Exception.Message)"
                    return $_
                }
		
                # report updated
                Write-Host "$SamAccountName;dnsRecord;updated computer DNS record"
            }

            # update boolean
            return $true
        }
        else {
            # report checked
            Write-Host "$SamAccountName;dnsRecord;checked computer DNS record"
            return $false
        }
    }

    function Assert-ADScriptStateBaseObjects {
        # if parameter set name is empty...
        if ([string]::IsNullOrEmpty($script:PSCmdLet.ParameterSetName)) {
            # create exception
            $Exception = [System.Management.Automation.ItemNotFoundException]::new('Assert-ADScriptStateBaseObjects : Found empty ParameterSetName on $PSCmdLet object in script scope')

            # throw error record with exception
            throw [System.Management.Automation.ErrorRecord]::new($Exception, 'ParameterSetNameNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, 'ParameterSetName')
        }
        # if parameter set name is empty...
        else {
            # retrieve parameter set name for script
            $script:ScriptParameterSetName = $PSCmdLet.ParameterSetName
        }
 
        # if invocation name is empty...
        if ([string]::IsNullOrEmpty($script:MyInvocation.InvocationName)) {
            # create exception
            $Exception = [System.Management.Automation.ItemNotFoundException]::new('Assert-ADScriptStateBaseObjects : Found empty InvocationName on $MyInvocation object in script scope')

            # throw error record with exception
            throw [System.Management.Automation.ErrorRecord]::new($Exception, 'InvocationNameNotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, 'InvocationName')
        }
        # if invocation name is not empty...
        else {
            # retrieve path to script from command path
            $script:MyCommandPath = $script:MyInvocation.MyCommand.Path
        }

        # if command path is not an absolute path...
        if (![System.IO.Path]::IsPathRooted($script:MyCommandPath)) {
            # get unresolved absolute path
            try {
                $script:MyCommandPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($script:MyCommandPath)
            }
            catch {
                Write-Warning -Message "could not create absolute path from command path: $script:MyCommandPath"
                throw $_
            }

            # report absolute path
            Write-Warning -Message "converted relative path of command path to absolute path: $script:MyCommandPath"
        }

        # retrieve base name script object
        try {
            $script:MyCommandPathBaseName = Get-Item -Path $script:MyCommandPath | Select-Object -ExpandProperty 'BaseName'
        }
        catch {
            Write-Warning -Message "could not retrieve item for '$script:MyCommandPath' script: $($_.Exception.Message)"
            throw $_
        }

        # define script object container
        $script:ScriptObjectContainer = 'CN={0},{1}' -f $script:MyCommandPathBaseName, $script:ScriptStatesContainer

        # report object identity
        Write-Verbose -Message "AD Script State container: $script:ScriptObjectContainer"

        # define script object identity
        $script:ScriptObjectIdentity = 'CN={0},{1}' -f $script:ScriptParameterSetName, $script:ScriptObjectContainer

        # report object identity
        Write-Verbose -Message "AD Script State object: $script:ScriptObjectIdentity"
    }

    function Assert-ADScriptStateObject {
        [cmdletbinding()]
        param (
            [Parameter(DontShow)]
            [string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
            [switch]$Reset,
            [string]$Identity,
            [string]$Attribute = 'notes'
        )

        # retrieve AD script object
        try {
            $null = Get-ADObject -Server $Server -Identity $script:ScriptObjectIdentity -ErrorAction 'Stop'
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
                Set-ADScriptState -Server $Server -Identity $Identity -Attribute $Attribute -ScriptState $ScriptStateDefaultObject
            }
            catch {
                Write-Warning -Message "could not update '$Identity' object for '$script:MyCommandPathBaseName' script: $($_.Exception.Message)"
                throw $_
            }
        }
    }

    function Get-ADScriptStateObject {
        [cmdletbinding()]
        param (
            # PDC of the domain
            [Parameter(DontShow)]
            [string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
            [string]$Identity = $script:ScriptObjectIdentity,
            [string]$Attribute = 'notes'
        )

        # retrieve script state as JSON from attribute on AD object
        try {
            $ScriptStateAsJson = Get-ADObject -Server $Server -Identity $Identity -Properties $Attribute | Select-Object -ExpandProperty $Attribute
        }
        catch {
            return $_
        }

        # retrieve script state object from JSON
        try {
            $ScriptState = ConvertFrom-Json -InputObject $ScriptStateAsJson
        }
        catch {
            # create script state object from default object
            $ScriptState = $ScriptStateDefaultObject
        }

        # return script state
        return $ScriptState
    }

    function Set-ADScriptStateObject {
        [cmdletbinding()]
        param (
            # PDC of the domain
            [Parameter(DontShow)]
            [string]$Server = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain().PdcRoleOwner.Name,
            [object]$ScriptState,
            [string]$Identity = $script:ScriptObjectIdentity,
            [string]$Attribute = 'notes'
        )

        # convert script state to JSON
        try {
            $ScriptStateAsJson = ConvertTo-Json -InputObject $ScriptState
        }
        catch {
            return $_
        }

        # store script state as JSON in attribute on AD object
        try {
            Set-ADObject -Server $Server -Identity $Identity -Replace @{ $Attribute = $ScriptStateAsJson }
        }
        catch {
            return $_
        }
    }

    # assert script state parameters
    try {
        Assert-ADScriptStateBaseObjects
    }
    catch {
        throw $_
    }

    # assert script state object exists
    try {
        $ScriptState = Assert-ADScriptState -Identity $ScriptObjectIdentity -Attribute $Attribute -Reset:$Reset
    }
    catch {
        throw $_
    }

    # define counters
    $DnsRecordAcls_checked = 0
    $DnsRecordAcls_errored = 0
    $DnsRecordAcls_updated = 0
}

process {
    # get script state
    try {
        $ScriptState = Get-ADScriptState -Identity $ScriptObjectIdentity -Attribute $Attribute
    }
    catch {
        Write-Warning "could not retrieve script state object: $($_.Exception.Message)"
        throw $_
    }

    # get zone for domain name
    try {
        $DnsServerZone = Get-DnsServerZone -ComputerName $Server -Name $DomainName -ErrorAction 'Stop'
    }
    catch {
        Write-Warning "could not retrieve '$DomainName' DNS zone object: $($_.Exception.Message)"
        throw $_
    }

    # define initial filter for Get-ADComputer
    # primary group ID to exclude domain controllers
    # user account control to exclude disabled computer objects
    $Filter = 'primaryGroupId -eq "515" -and userAccountControl -eq "4096"'

    # test when created
    if ([System.DateTime]::TryParse($ScriptState.WhenCreated, [ref][System.Datetime]::UtcNow) -and -not $All) {
        # warn and set all
        Write-Warning "forcing 'All' switch to true; could not parse '$($ScriptState.WhenCreated)' value in WhenCreated on ScriptState object as [System.DateTime]"
        $All = $true
    }

    # if all is not set or explicitly set to false...
    if ($All.IsPresent -eq $false -or $All -eq $false) {
        # update filter with when created from script state object
        $Filter = '{0} -and Created -gt "{1}"' -f $Filter, $ScriptState.whenCreated
    }

    # update when created in script state object
    $ScriptState.whenCreated = [System.DateTime]::UtcNow

    # define parameters for Get-ADComputer
    $GetADComputer = @{
        Server = $Server
        Filter = $Filter
    }

    # retrieve computers
    try {
        $ADComputers = Get-ADComputer @GetADComputer | Sort-Object -Property 'Name' | Select-Object -Property $Properties
    }
    catch {
        Write-Warning "could not update computer objects: $($_.Exception.Message)"
        throw $_
    }

    # retrieve count
    $ADComputersCount = $ADComputers | Measure-Object | Select-Object -ExpandProperty 'Count'

    # report count
    Write-Host "Found '$ADComputersCount' computer(s) created after '$WhenCreated'"

    # loop through computers
    :NextADComputer foreach ($ADComputer in $ADComputers) {
        # define parameters
        $RepairADComputerDnsRecordAcl = @{
            Computer = $ADComputer
            WhatIf   = $WhatIfPreference
        }

        # repair security
        try {
            $Repaired = Repair-ADComputerDnsRecordAcl @RepairADComputerDnsRecordAcl
        }
        catch {
            $DnsRecordAcls_errored++
            continue NextADComputer
        }

        # if repaired...
        if ($Repaired) {
            $DnsRecordAcls_updated++
        }
        else {
            $DnsRecordAcls_checked++
        }

        # if errored or updated is 5 or more...
        if ($DnsRecordAcls_errored -ge 5 -or $DnsRecordAcls_updated -ge 5) { return }
    }

    # set script state
    try {
        Set-ADScriptState -Identity $ScriptObjectIdentity -Attribute $Attribute -ScriptState $ScriptState
    }
    catch {
        Write-Warning "could not update script state object: $($_.Exception.Message)"
        throw $_
    }
}

end {
    # get time stopped
    $TimeStopped = (Get-Date -Format 'FileDateTime')

    # report summary
    Write-Host "Started: $TimeStarted"
    Write-Host "Stopped: $TimeStopped"
    Write-Host "DNS Records checked: $script:DnsRecordAcls_checked"
    Write-Host "DNS Records updated: $script:DnsRecordAcls_updated"
    Write-Host "DNS Records errored: $script:DnsRecordAcls_errored"
}
