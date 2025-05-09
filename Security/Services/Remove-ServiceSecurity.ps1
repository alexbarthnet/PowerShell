<#
.SYNOPSIS
Removes service access rights granted to a principal on a Windows service.

.DESCRIPTION
Removes service access rights granted to a principal on a Windows service.

.PARAMETER Name
The name of the Windows service. Required.

.PARAMETER Principal
The principal which will be removed from the access rights on the Windows service. Required.

.PARAMETER AccessRights
The access rights which will be granted to the principal on the Windows service. Required and must be one or more of the following values:
- SERVICE_QUERY_CONFIG - Required to call the QueryServiceConfig and QueryServiceConfig2 functions to query the service configuration.
- SERVICE_CHANGE_CONFIG - Required to call the ChangeServiceConfig or ChangeServiceConfig2 function to change the service configuration. Because this grants the caller the right to change the executable file that the system runs, it should be granted only to administrators.
- SERVICE_QUERY_STATUS - Required to call the QueryServiceStatus or QueryServiceStatusEx function to ask the service control manager about the status of the service.
- SERVICE_ENUMERATE_DEPENDENTS - Required to call the EnumDependentServices function to enumerate all the services dependent on the service.
- SERVICE_START - Required to call the StartService function to start the service.
- SERVICE_STOP - Required to call the ControlService function to stop the service.
- SERVICE_PAUSE_CONTINUE - Required to call the ControlService function to pause or continue the service.
- SERVICE_INTERROGATE - Required to call the ControlService function to ask the service to report its status immediately.
- SERVICE_USER_DEFINED_CONTROL - Required to call the ControlService function to specify a user-defined control code.
- DELETE - Required to call the DeleteService function to delete the service.
- READ_CONTROL - Required to call the QueryServiceObjectSecurity function to query the security descriptor of the service object.
- WRITE_DAC - Required to call the SetServiceObjectSecurity function to modify the Dacl member of the service object's security descriptor.
- WRITE_OWNER - Required to call the SetServiceObjectSecurity function to modify the Owner and Group members of the service object's security descriptor.
- SERVICE_ALL_ACCESS - Includes all access rights in this list.

.INPUTS
None.

.OUTPUTS
None. The script reports the actions taken and does not provide any actionable output.

.EXAMPLE
.\Remove-ServiceSecurity.ps1 -Name 'dnscache' -Principal 'NT AUTHORITY\Authenticated Users'
#>

[CmdletBinding()]
Param(
    [Parameter(Mandatory)]
    [string]$Name,
    [Parameter(Mandatory)]
    [string]$Principal,
    [Parameter()]
    [string[]]$AccessRights
)

Function Get-ADSecurityIdentifier {
    <#
        .SYNOPSIS
        Retrieve the security identifier for a security principal in Active Directory.
    
        .DESCRIPTION
        Retrieve the security identifier for a security principal in Active Directory.
    
        .PARAMETER Principal
        A object representing a security principal in Active Directory. Must be one of the following object types:
         - a Security Identifier object
         - an NTAccount object
         - an ADPrincipal-derived object such as an Active Directory user, computer, or group object
         - a string containing a Security Identifier in SDDL format
         - a string containing a value that can be translated into a Security Identifier object
    
        .PARAMETER Server
        An optional value to specify the domain controller to query for retrieving the security identifier
    
         .INPUTS
        System.String, System.Security.Principal.NTAccount, System.Security.Principal.SecurityIdentifier, Microsoft.ActiveDirectory.Management.ADPrincipal.
    
        .OUTPUTS
        System.Security.Principal.SecurityIdentifier.
    
        .EXAMPLE
        PS> Get-ADSecurityIdentifier -Principal 'Administrator'
    
        .EXAMPLE
        PS> Get-ADSecurityIdentifier -Principal 'Domain Users'
    
        .EXAMPLE
        PS> Get-ADSecurityIdentifier -Principal 'administrator@example.com'
        #>
    
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, Mandatory = $true, ValueFromPipeline = $true)]
        [object]$Principal,
        [Parameter(Position = 1)]
        [string]$Server
    )
    
    # if principal is a SecurityIdentifier object...
    If ($Principal -is [System.Security.Principal.SecurityIdentifier]) {
        # return principal as-is
        Return $Principal
    }
    
    # if principal is an NTAccount object...
    If ($Principal -is [System.Security.Principal.NTAccount]) {
        # return principal translated to SecurityIdentifier
        Return $Principal.Translate([System.Security.Principal.SecurityIdentifier])
    }
    
    # if principal is not a string...
    If ($Principal -isnot [System.String]) {
        Write-Warning -Message "an unsupported object type was provided: $($Principal.GetType().FullName)"
        Return $null
    }
    
    # if principal is a SID in SDDL format...
    If ($Principal -match '^S-1-\d{1,2}-\d+') {
        # return SecurityIdentifier constructed from principal
        Return [System.Security.Principal.SecurityIdentifier]::new($Principal)
    }
    
    # if principal matches the name of a well-known SID that only translate on servers or domain controllers...
    # reference: https://learn.microsoft.com/en-us/windows/win32/secauthz/well-known-sids
    switch -regex ($Principal) {
        # return SecurityIdentifier constructed from matching well-known SID
        '(^|^\w+\\)Account Operators$' {
            Return [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-548')
        }
        '(^|^\w+\\)Server Operators$' {
            Return [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-549')
        }
        '(^|^\w+\\)Print Operators$' {
            Return [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-550')
        }
        '(^|^\w+\\)Pre–Windows 2000 Compatible Access$' {
            Return [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-554')
        }
        '(^|^\w+\\)Incoming Forest Trust Builders$' {
            Return [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-557')
        }
        '(^|^\w+\\)Windows Authorization Access Group$' {
            Return [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-560')
        }
        '(^|^\w+\\)Terminal Server License Servers$' {
            Return [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-561')
        }
    }
    
    # if server provided...
    If ($PSBoundParameters.ContainsKey('Server')) {
        # define parameters for Get-ADObject
        $GetADObject = @{
            Server      = $Server
            Properties  = 'ObjectSid'
            ErrorAction = [System.Management.Automation.ActionPreference]::Stop
        }
    
        # retrieve object by UserPrincipalName
        Try {
            $ADObject = Get-ADObject @GetADObject -Filter "UserPrincipalName -eq '$Principal'"
        }
        Catch {
            Write-Warning -Message "could not query Active Directory for object by UserPrincipalName for principal: $Principal"
            Return $_
        }
    
        # if ADObject found...
        If ($ADObject) {
            Return $ADObject.ObjectSid
        }
    
        # retrieve object by SamAccountName
        Try {
            $ADObject = Get-ADObject @GetADObject -Filter "SamAccountName -eq '$Principal'"
        }
        Catch {
            Write-Warning -Message "could not query Active Directory for object by SamAccountName for principal: $Principal"
            Return $_
        }
    
        # if ADObject found...
        If ($ADObject) {
            Return $ADObject.ObjectSid
        }
    
        # retrieve object by SamAccountName with $ suffix for computer objects
        Try {
            $ADObject = Get-ADObject @GetADObject -Filter "SamAccountName -eq '$Principal$'"
        }
        Catch {
            Write-Warning -Message "could not query Active Directory for object by SamAccountName for principal: $Principal"
            Return $_
        }
    
        # if ADObject found...
        If ($ADObject) {
            Return $ADObject.ObjectSid
        }
    }
    
    # translate principal to SID
    Return ([System.Security.Principal.NTAccount]::new($Principal)).Translate([System.Security.Principal.SecurityIdentifier])
}

# define empty access mask for access rights
$AccessMask = 0

# loop through access rights
ForEach ($AccessRight in $AccessRights) {
    # if access right not defined in enum...
    If ($AccessRight -notin [ServiceAccessRights].GetEnumNames()) {
        Write-Warning "could not locate '$AccessRight' access right in ServiceAccessRights enum: $([ServiceAccessRights].GetEnumNames())"
        Return
    }
    # add access right to access mask
    $AccessMask = $AccessMask + [ServiceAccessRights]$AccessRight
}

# convert principal to SID
Try {
    $SecurityIdentifier = Get-ADSecurityIdentifier -Principal $Principal
}
Catch {
    Write-Warning "could not retrieve security identifier for principal: $Principal"
    Return $_
}

# retrieve services
Try {
    $Services = Get-Service -Name $Name
}
Catch {
    Write-Warning -Message "could not retrieve '$Name' service: $($_.Exception.Message)"
    $PSCmdlet.ThrowTerminatingError($_)
}

# retrieve name from service
$Service = $Services.Name

# retrieve registry key for service
Try {
    $RegistryKey = Get-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Service" -ErrorAction Stop
}
Catch {
    Write-Warning -Message "could not retrieve registry key for '$Service' service: $($_.Exception.Message)"
    Return $_
}

# if security is not a subkey of service...
If ('Security' -notin $RegistryKey.GetSubKeyNames()) {
    # continue to next service
    Return $_
}
    
# retrieve security subkey as writeable
Try {
    $SecuritySubKey = $RegistryKey.OpenSubKey('Security', $true)
}
Catch {
    Write-Warning -Message "could not open Security subkey for '$Service' service: $($_.Exception.Message)"
    Return $_
}

# retrieve byte array from security property of security subkey
Try {
    $Bytes = $SecuritySubKey.GetValue('Security')
}
Catch {
    Write-Warning -Message "could not retrieve value of Security property of Security subkey for '$Service' service: $($_.Exception.Message)"
    Return $_
}

# create a security descriptor object
# link: https://learn.microsoft.com/en-us/dotnet/api/system.security.accesscontrol.commonsecuritydescriptor
Try {
    $SecurityDescriptor = [System.Security.AccessControl.CommonSecurityDescriptor]::new($false, $false, $Bytes, 0)
}
Catch {
    Write-Warning -Message "could not create security descriptor for '$Service' service: $($_.Exception.Message)"
    Return $_
}

# filter access control entries in discretionary ACL
Try {
    $AccessControlEntries = $SecurityDescriptor.DiscretionaryAcl.Where({ $_.SecurityIdentifier -eq $SecurityIdentifier })
}
Catch {
    Write-Warning -Message "could not filter access control entries in security descriptor for '$Service' service: $($_.Exception.Message)"
    Return $_
}

# if multiple access control entries found...
If ($AccessControlEntries.Count -gt 1) {
    # report principal not found and return
    Write-Warning -Message "found multiple Access Control Entries '$Principal' for '$Service' service...how?"
    Return
}

# if no access control entry found...
If ($AccessControlEntries.Count -eq 0) {
    # report principal not found and return
    Write-Warning -Message "could not locate Access Rights for '$Principal' for '$Service' service"
    Return
}

# if single access control entry found...
If ($AccessControlEntries.Count -eq 1) {
    # define flags for legibility
    $AccessControlType = [System.Security.AccessControl.AccessControlType]::Allow
    $InheritanceFlags = [System.Security.AccessControl.InheritanceFlags]::None
    $PropagationFlags = [System.Security.AccessControl.PropagationFlags]::None

    # if access rights provided...
    If ($PSBoundParameters.ContainsKey('AccessRights')) {
        # retrieve current access mask
        $CurrentAccessMask = $AccessControlEntries[0].AccessMask

        # band current access mask against access mask for provided access rights
        $BandedAccessMask = $CurrentAccessMask -band $AccessMask

        # if none of the requested access rights are set...
        If ($BandedAccessMask -eq 0) {
            # report principal not found and return
            Write-Warning -Message "could not locate requested Access Rights for '$Principal' for '$Service' service"
            Return
        }

        # if all of the requested access rights are set...
        If ($BandedAccessMask -eq $AccessMask) {
            # define remove method and access mask to apply to access control entry
            $Method = 'RemoveAccess'
            $AccessMask = $AccessControlEntries[0].AccessMask
        }
        # if some of the reqeusted access rights are set...
        Else {
            # retrieve access rights that will remain
            $RemainingAccessMask = $CurrentAccessMask -bxor $BandedAccessMask

            # retrieve access rights provided but not originally set
            $MissingAccessMask = $AccessMask -bxor $BandedAccessMask
            
            # if missing access mask is not zero...
            If ($MissingAccessMask -gt 0) {
                Write-Warning "requested Access Rights not found for '$Principal' for '$Service' service: $([ServiceAccessRights]$MissingAccessMask)"
            }

            # define set method and remaining access mask to apply to access control entry
            $Method = 'SetAccess'
            $AccessMask = $RemainingAccessMask
        }
    }
    # if no access rights provided...
    Else {
        # define remove method and access mask to apply to access control entry
        $Method = 'RemoveAccess'
        $AccessMask = $AccessControlEntries[0].AccessMask
    }

    # switch on method...
    switch ($Method) {
        'SetAccess' {
            # update ACE in discretionary ACL of security descriptor
            # link: https://learn.microsoft.com/en-us/dotnet/api/system.security.accesscontrol.discretionaryacl.removeaccess
            Try {
                $SecurityDescriptor.DiscretionaryAcl.SetAccess($AccessControlType, $SecurityIdentifier, $AccessMask, $InheritanceFlags, $PropagationFlags)
            }
            Catch {
                Write-Warning -Message "could not update Access Rights for '$Principal' from Security Descriptor for '$Service' service: $($_.Exception.Message)"
            }
        }
        'RemoveAccess' {
            # remove ACE from discretionary ACL of security descriptor
            # link: https://learn.microsoft.com/en-us/dotnet/api/system.security.accesscontrol.discretionaryacl.removeaccess
            Try {
                $SecurityDescriptor.DiscretionaryAcl.RemoveAccess($AccessControlType, $SecurityIdentifier, $AccessMask, $InheritanceFlags, $PropagationFlags)
            }
            Catch {
                Write-Warning -Message "could not remove Access Rights for '$Principal' from Security Descriptor for '$Service' service: $($_.Exception.Message)"
            }
        }
    }
}

# create byte array with length from updated security descriptor
Try {
    $UpdatedBytes = [System.Byte[]]::CreateInstance([System.Byte], $SecurityDescriptor.BinaryLength)
}
Catch {
    Write-Warning -Message "could not create byte array for updated security descriptor: $($_.Exception.Message)"
    Return $_
}

# write binary form of updated security descriptor to byte array
Try {
    $SecurityDescriptor.GetBinaryForm($UpdatedBytes, 0)
}
Catch {
    Write-Warning -Message "could not write binary form of security descriptor to byte array: $($_.Exception.Message)"
    Return $_
}

# update registry key
Try {
    $SecuritySubKey.SetValue('Security', $UpdatedBytes, [Microsoft.Win32.RegistryValueKind]::Binary)
}
Catch {
    Write-Warning -Message "could not update Security property of Security key for '$Service' service: $($_.Exception.Message)"
    Return $_
}

# report complete
Write-Host "removed Access Rights for '$Principal' on '$Service' service"
