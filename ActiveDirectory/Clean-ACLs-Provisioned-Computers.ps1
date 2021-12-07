# set the base DN for the object search
$base = "OU=Provisioned,OU=Computers,OU=Directory,"

# get AD naming contexts
$schema = (Get-ADRootDSE).schemaNamingContext
$domain = (Get-ADRootDSE).defaultNamingContext

# search AD for objects to reset
$search = Get-ADObject -SearchBase ($base + $domain) -Filter * -SearchScope OneLevel
$search | ForEach-Object{
    # get the object DN from the search
    $dn = $_
    
    # get the object class and DN with AD provider prefix
    $class = (Get-ADObject -Identity $dn -Properties *).objectClass
    $ad_dn = ("AD:\" + $dn)

    # get the default ACL for the object class
    $sddl = (Get-ADObject -Filter "Name -eq '$class'" -SearchBase $schema -Properties *).defaultSecurityDescriptor

    # get the ACL for the object
    $acl = Get-Acl -Path $ad_dn
    $acl.SetSecurityDescriptorSddlForm($sddl)
    $acl | Set-Acl -Path $ad_dn
}
