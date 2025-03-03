[CmdletBinding()]
Param(
    [string[]]$Name,
    [string[]]$Principals,
    [string[]]$AccessRights,
    [string]$ComputerName,
    [ValidateSet('Default', 'SDDL', 'SecurityDescriptor')]
    [string]$Output = 'Default',
    [switch]$RequireAllAccessRights
)

# define enum for service access rights
# link: https://learn.microsoft.com/en-us/windows/win32/services/service-security-and-access-rights
[Flags()] enum ServiceAccessRights {
    SERVICE_QUERY_CONFIG = 0x0001 # Required to call the QueryServiceConfig and QueryServiceConfig2 functions to query the service configuration.
    SERVICE_CHANGE_CONFIG = 0x0002 # Required to call the ChangeServiceConfig or ChangeServiceConfig2 function to change the service configuration. Because this grants the caller the right to change the executable file that the system runs, it should be granted only to administrators.
    SERVICE_QUERY_STATUS = 0x0004 # Required to call the QueryServiceStatus or QueryServiceStatusEx function to ask the service control manager about the status of the service.
    SERVICE_ENUMERATE_DEPENDENTS = 0x0008 # Required to call the EnumDependentServices function to enumerate all the services dependent on the service.
    SERVICE_START = 0x0010 # Required to call the StartService function to start the service.
    SERVICE_STOP = 0x0020 # Required to call the ControlService function to stop the service.
    SERVICE_PAUSE_CONTINUE = 0x0040 # Required to call the ControlService function to pause or continue the service.
    SERVICE_INTERROGATE = 0x0080 # Required to call the ControlService function to ask the service to report its status immediately.
    SERVICE_USER_DEFINED_CONTROL = 0x0100 # Required to call the ControlService function to specify a user-defined control code.
    DELETE = 0x10000 # Required to call the DeleteService function to delete the service.
    READ_CONTROL = 0x20000 # Required to call the QueryServiceObjectSecurity function to query the security descriptor of the service object.
    WRITE_DAC = 0x40000 # Required to call the SetServiceObjectSecurity function to modify the Dacl member of the service object's security descriptor.
    WRITE_OWNER = 0x80000 # Required to call the SetServiceObjectSecurity function to modify the Owner and Group members of the service object's security descriptor.
    SERVICE_ALL_ACCESS = 0xF01FF # Includes STANDARD_RIGHTS_REQUIRED in addition to all access rights in this table.
}

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

# if access rights provided...
If ($PSBoundParameters.ContainsKey('AccessRights')) {
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
    # report access mask
    Write-Verbose $AccessMask
}

# if principals provided...
If ($PSBoundParameters.ContainsKey('Principals')) {
    # create list for security identifiers
    $SecurityIdentifiers = [System.Collections.Generic.List[System.String]]::new()
    # loop through provided principals
    :NextPrincipal ForEach ($Principal in $Principals) {
        # convert principal to SID
        Try {
            $SecurityIdentifier = Get-ADSecurityIdentifier -Principal $Principal
        }
        Catch {
            Write-Warning "could not retrieve security identifier for principal: $Principal"
            Return $_
        }
        # add security identifier to list
        $SecurityIdentifiers.Add($SecurityIdentifier)
    }
}

# define parameters for Get-Service
$GetService = @{
    ErrorAction = [System.Management.Automation.ActionPreference]::Stop
}

# if name provided...
If ($PSBoundParameters.ContainsKey($Name)) {
    $GetService.Add('Name', $Name)
}

# if computer name provided...
If ($PSBoundParameters.ContainsKey($ComputerName)) {
    $GetService.Add('ComputerName', $ComputerName)
}

# retrieve services
Try {
    $Services = Get-Service @GetService
}
Catch {
    Write-Warning -Message "could not retrieve services: $($_.Exception.Message)"
    $PSCmdlet.ThrowTerminatingError($_)
}

# loop through each service
:NextService ForEach ($Service in $Services.Name) {
    # retrieve registry key for service
    Try {
        $RegistryKey = Get-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$Service" -ErrorAction Stop
    }
    Catch {
        Write-Warning -Message "could not retrieve registry key for '$Service' service: $($_.Exception.Message)"
        Continue NextService
    }

    # if security is not a subkey of service...
    If ('Security' -notin $RegistryKey.GetSubKeyNames()) {
        # continue to next service
        Continue NextService
    }
    
    # retrieve value of security subkey
    Try {
        $Bytes = $RegistryKey.OpenSubKey('Security', $false).GetValue('Security')
    }
    Catch {
        Write-Warning -Message "could not retrieve value of Security key for '$Service' service: $($_.Exception.Message)"
        Continue NextService
    }

    # create a security descriptor object
    # link: https://learn.microsoft.com/en-us/dotnet/api/system.security.accesscontrol.commonsecuritydescriptor
    Try {
        $SecurityDescriptor = [System.Security.AccessControl.CommonSecurityDescriptor]::new($false, $false, $Bytes, 0)
    }
    Catch {
        Write-Warning -Message "could not create security descriptor for '$Service' service: $($_.Exception.Message)"
        Continue NextService
    }

    # loop through each discretionary ACL
    :NextDiscretionaryAcl ForEach ($DiscretionaryAcl in $SecurityDescriptor.DiscretionaryAcl) {
        # if Principals provided...
        If ($PSBoundParameters.ContainsKey('Principals') -and $SecurityIdentifiers) {
            # if security identifier is NOT in the list contains ANY of the provided access rights...
            If ($DiscretionaryAcl.SecurityIdentifier -notin $SecurityIdentifiers) {
                # continue to next ACL
                Continue NextDiscretionaryAcl
            }
        }

        # if AccessRights provided...
        If ($PSBoundParameters.ContainsKey('AccessRights') -and $AccessMask) {
            # if all access rights are required...
            If ($PSBoundParameters.ContainsKey('RequireAllAccessRights') -and $RequireAllAccessRights) {
                # if access mask lacks ALL of the provided access rights...
                If (($DiscretionaryAcl.AccessMask -band $AccessMask) -ne $AccessMask) {
                    # continue to next ACL
                    Continue NextDiscretionaryAcl
                }
            }
            # if any access rights are required...
            Else {
                # if access mask lacks ANY of the provided access rights...
                If (($DiscretionaryAcl.AccessMask -band $AccessMask) -eq 0) {
                    # continue to next ACL
                    Continue NextDiscretionaryAcl
                }
            }
        }

        # if output is not default...
        If ($Output -ne 'Default') {
            Continue NextDiscretionaryAcl
        }

        # translate principal
        Try {
            $Principal = $DiscretionaryAcl.SecurityIdentifier.Translate([System.Security.Principal.NTAccount]).Value
        }
        Catch {
            $Principal = $DiscretionaryAcl.SecurityIdentifier.Value
        }

        # create object discretionary ACL
        $ServiceSecurity = [pscustomobject]@{
            Name         = $Service
            Principal    = $Principal
            AccessRights = [ServiceAccessRights]$DiscretionaryAcl.AccessMask
        }

        # return 
        Write-Output -InputObject $ServiceSecurity
    }

    # process output
    switch ($Output) {
        'SecurityDescriptor' {
            # create object with service name and security descriptor
            $ServiceSecurity = [pscustomobject]@{
                Name               = $Service
                SecurityDescriptor = $SecurityDescriptor
            }

            # write object to pipline and continue to next service
            Write-Output -InputObject $ServiceSecurity
        }
        'SDDL' {
            # create object with service name and SDDL
            $ServiceSecurity = [pscustomobject]@{
                Name = $Service
                SDDL = $SecurityDescriptor.GetSddlForm([System.Security.AccessControl.AccessControlSections]('Access', 'Audit'))
            }

            # write object to pipline and continue to next service
            Write-Output -InputObject $ServiceSecurity

        }
    }
}
