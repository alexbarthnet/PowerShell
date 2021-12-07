[CmdletBinding(DefaultParameterSetName = 'Default')]
Param(
    [Parameter(ParameterSetName = 'User')]
    [switch]$User,
    [Parameter(ParameterSetName = 'User')]
    [string]$Name,
    [string]$Server
)

# change server
If ($Server) {
    $ldap_server = $Server
}
Else {
    $ldap_server = (Get-ADDomain).PDCEmulator
}

# define global objects
$ldap_base = (Get-ADDomain).DistinguishedName
$ldap_people = @()
$ldap_people += 'OU=Austinites,OU=People', $ldap_base -join ','
# $ldap_people += 'OU=University,OU=People', $ldap_base -join ','
If ($User) {
    $ldap_query = "(&(objectCategory=Person)(objectClass=User)(utexasEduAustinMulti2=0EMCU)(sAMAccountName=$Name))"
} 
Else {
    $ldap_query = '(&(objectCategory=Person)(objectClass=User)(utexasEduAustinMulti2=0EMCU))'
}

# clear objects
$ldap_users = @()

# retrieve users from containers
ForEach ($ldap_path in $ldap_people) {
    Write-Host "base DN: $ldap_path"
    Write-Host "query: $ldap_query"
    $ldap_attrs = @('sAMAccountName', 'givenName', 'sn', 'mail', 'proxyaddresses')
    $ldap_users += Get-ADUser -Server $ldap_server -SearchBase $ldap_path -LDAPFilter $ldap_query -Properties $ldap_attrs
}

$ldap_users.Count

# process users
ForEach ($ldap_user in $ldap_users) {
    # get strings
    $user_eid = $ldap_user.sAMAccountName
    $user_first = $ldap_user.givenname
    $user_last = $ldap_user.sn

    # clear arrays
    $user_primary = @()
    $user_proxy = @()

    # query contacts
    $user_gmail = Get-ADObject -SearchBase 'OU=Gmail,OU=Contacts,OU=Exchange,DC=austin,DC=utexas,DC=edu' -LDAPFilter "(&(Name=$user_eid.*)(extensionAttribute2=UTmailBusiness))" -Properties 'Mail'

    # check exchange
    If ($ldap_user.mail -match '^.*@utexas\.edu$') {
        $user_primary += $ldap_user.mail
    }

    # check gmail
    If ($user_gmail.mail -match '^.*@utexas\.edu$') {
        $user_primary += $user_gmail.Mail
    }

    # check proxy
    ForEach ($address in $ldap_user.proxyAddresses) {
        If ($address -match '^smtp:') {
            $proxy = $address.Split(':', 2)[1]
            If ($user_primary -notcontains $proxy -and $proxy -match '^.*@utexas\.edu$') {
                $user_proxy += $proxy
            }
        }
    }

    # report
    If ($user_primary.Count -ge 1 -or $user_proxy.Count -ge 1) { 
        [PSCustomObject]@{
            EID       = $user_eid
            FirstName = $user_first
            LastName  = $user_last
            Primary   = $user_primary
            Secondary = $user_proxy
        }
    }
}
